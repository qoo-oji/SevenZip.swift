# ストリーミング取り出し(フォーク独自の変更)

このフォーク(qoo-oji/SevenZip.swift)が upstream(mtgto/SevenZip.swift、`215c504` "Bump up LZMA SDK to v26.02")
に対して加えた変更の記録です。upstream へ還元する予定はなく、フォークとして育てる前提です。

## 目的

upstream の `Archive.extract(entry:)` は LZMA SDK の `SzArEx_Extract` を使っており、エントリ 1 つを取り出すために
そのエントリが属する**ソリッドブロック(7z の "folder")全体**を 1 つのバッファに伸長し、別のブロックを要求するか
`Archive` が解放されるまでそのバッファを保持し続けます。7-Zip の既定はソリッド圧縮なので、GB 級の書庫では
GB 単位のメモリが常駐します。

このフォークは、ブロックを**要求されたぶんだけ**伸長する引き出し型(pull 型)のデコーダを追加し、
メモリを「デコーダの状態(LZMA 辞書)+数百 KB」に抑えます。設計は The Unarchiver(XADMaster)の
`CSStreamHandle` / `XAD7ZipParser` を手本にしています。

## 追加・変更したファイル

| ファイル | 内容 |
|---|---|
| `Sources/CsevenZip/7zFolderStream.h` / `.c`(新規) | 1 ブロックぶんのストリーミングデコーダ(C)。7zDec.c の `SzFolder_Decode2` のコーダ連鎖の扱いを、逐次 API(`LzmaDec_DecodeToBuf` / `Lzma2Dec_DecodeToBuf` / `Ppmd7z_DecodeSymbol`)で駆動する形に書き直したもの |
| `Sources/CsevenZip/include/sevenzip.h` | 上記ヘッダを Swift へ公開 |
| `Sources/SevenZip/ArchiveStreaming.swift`(新規) | Swift 側 API(`read` / `readData` / `discardFolderStream`) |
| `Sources/CsevenZip/7zMemInStream.h` / `.c`(新規) | メモリ上のバッファを読む `ISeekInStream`。`Archive(data:)` の土台 |
| `Sources/SevenZip/Archive.swift` | `init(data:)`(メモリから開く)を追加し、ファイル/メモリどちらの入力も `seekStream` 経由で読むように整理。deinit でファイルを閉じる(upstream は閉じていなかった)。ブロックデコーダを保持するプロパティと deinit での解放。`db` / `archiveStream` / `allocImp` を internal に。`LZMAError` を public にし `.unsupported` / `.decodeFailed(code:)` を追加。`extract(entry:)` は非対応構成で `.unsupported` を投げる(従来は `.badFile`) |
| `Package.swift` | `7zFolderStream.c` をソースに追加。`Z7_PPMD_SUPPORT` を定義(下記)。`sevenzip-bench` 実行ターゲットと `streaming-fixture` リソースを追加 |
| `Sources/sevenzip-bench/main.swift`(新規) | 旧経路と新経路の時間・メモリ比較ツール |
| `Tests/SevenZipTests/StreamingTests.swift`(新規) | ストリーミング経路のテスト |
| `Tests/SevenZipTests/streaming-fixture/`(新規) | テスト用書庫 14 種と sha256 の manifest、生成スクリプト |
| `README.md` / `CHANGELOG.md` | 機能と使い方の追記 |

既存の公開 API(`Archive.init` / `entries` / `extract(entry:bufSize:)` / `Entry`)は変更していません。

## API

```swift
// エントリを順にチャンクで受け取る。false を返すと途中で止まる
try archive.read(entry: entry, chunkSize: 1 << 16) { chunk in
    // chunk: UnsafeRawBufferPointer(この呼び出しの間だけ有効)
    return true
}

// エントリ全体、または先頭 maxByteCount バイトだけを Data として得る
let data = try archive.readData(entry: entry)
let head = try archive.readData(entry: entry, maxByteCount: 4096)

// 保持しているブロックデコーダを解放する(次の読み取りはブロック先頭からやり直し)
archive.discardFolderStream()

// いま保持しているデコーダのメモリ(LZMA 辞書+バッファ、および extract のブロックキャッシュ)
let bytes = archive.residentDecoderBytes

// ブロック先頭からデコーダを作り直した回数(読み方の検証用。下記「ブロックデコーダの再利用」)
let restarts = archive.folderStreamRestartCount
```

- 空ファイルとディレクトリは `body` を呼ばずに終了し、`readData` は空の `Data` を返します。
- 同じ `Archive` を複数スレッドから同時に使うことはできません(upstream と同じ)。デコーダの状態は `Archive` が 1 つだけ保持します。

## メモリ上の書庫を開く(`Archive(data:)`)

入れ子の書庫を一時ファイルに書き出さずに読むための入口です。LZMA SDK の入力は `ISeekInStream` という
仮想テーブルなので、`7zMemInStream.c` にメモリ上のバッファを読む実装(Read と Seek だけ)を足し、
`Archive` はファイル(`CFileInStream`)とメモリ(`CMemInStream`)のどちらかを `seekStream` として
持つようにしました。ヘッダの読み込み(`SzArEx_Open`)、旧経路(`SzArEx_Extract`)、ストリーミング経路
(`SzFolderStream`)はいずれもこの `seekStream` から読むので、以後の処理はファイルの場合と同じです。

渡された `Data` は `Archive` が持つバッファへ **1 回コピー**します。`Archive` は開いたまま長く生きる
オブジェクトで、`Data` のポインタは `withUnsafeBytes` の外では安定が保証されないためです。呼び出し側は
開いたあと自分の `Data` を手放して構いません(その時点で書庫 1 つぶんのメモリになります)。

## 動作

### ブロックデコーダの再利用

`Archive` は「最後に読んだブロックのデコーダ」を 1 つ保持します(`folderStream` / `folderStreamIndex`)。
エントリを読むときは:

1. エントリのブロック番号(`db.FileToFolder`)とブロック内オフセット(`db.UnpackPositions` の差)を求める。
2. 保持中のデコーダが同じブロックで、現在位置がオフセット以下なら、そこまで**読み捨てて**進む。
3. 現在位置より前でも、`SzFolderStream_CanSeekBack` が真なら `SzFolderStream_SeekBack` で**戻る**(下記)。
4. そうでなければデコーダを作り直し、ブロック先頭からオフセットまで読み捨てる。
5. エントリのサイズぶんを読む。読み終えた位置は次のエントリの先頭なので、書庫順に読む限りブロックは 1 回しか伸長されない。

### 後方へ戻る(`SzFolderStream_SeekBack`)

ソリッド圧縮では 1 ブロック = 1 本のストリームなので、一般には前の位置へは先頭からの伸長し直しでしか
戻れません。ただし 2 つの場合は伸長せずに戻れます:

- **Copy(無圧縮)ブロック**: 入力そのものなので、パックストリーム内の位置を動かすだけ。
- **フィルタ無しの LZMA / LZMA2**: デコーダの辞書(`CLzmaDec.dic`)は直近 `dicBufSize` バイトの出力を
  保持するリングバッファなので、その範囲内なら辞書から**そのまま渡し直す**(replay)。読み出し位置
  `readPos` をデコーダの位置 `position` より後ろへ置き、追いつくまで辞書から複写し、追いついたら
  伸長を再開する。辞書は通常 16〜64MB(7-Zip の既定は 16MB、-mx=9 で 64MB)。

フィルタ(BCJ など)付きのブロックでは辞書が持つのはフィルタ前のバイト列なので使えず、PPMd には
履歴がありません。これらとブロック外へは従来どおり作り直しになります。

ブロック CRC の積算は「初めて伸長したバイト」だけを対象にするため(`crcPos`)、Copy ブロックで戻って
同じバイトを再び伸長しても二重には数えません。

### 対応するコーダ構成

7zDec.c が扱う構成のうち、BCJ2 を除いたものに対応します。

- 主コーダ 1 つ: Copy / LZMA / LZMA2 / PPMd
- 主コーダ + フィルタ 1 段: Delta、BCJ(x86)、PPC、IA64、ARM、ARMT、SPARC、ARM64、RISC-V

フィルタは 256KB 単位で適用し、変換関数が処理しきれなかった末尾(先読みぶん、最大 16 バイト)を次の
チャンクの先頭へ持ち越します。`pc`(仮想アドレス)は処理したバイト数ぶん進めます。

フィルタは処理しきれなかった末尾(1 命令に満たない数バイト)を次の読み出しへ持ち越しますが、ブロックの
最後の詰め直しでそれしか残らない場合(256KB の詰め直し直後の 2〜3 バイト、あるいはそもそも数バイトの
ブロック)は「処理 0 バイト」になります。`FillFilter` はその場合に主コーダをもう一度引き、尽きていれば
素通しします(XzDec の `XzBcFilterState_Code2` と同じ)。最初の実装はここで入力終端と誤認して
`SZ_ERROR_INPUT_EOF` を返していました(`filter_tail_*.7z` のテスト)。

上記以外(BCJ2、BZip2、Deflate、7zAES など)は `SzFolderStream_Create` が `SZ_ERROR_UNSUPPORTED` を返し、
Swift 側は**従来の `extract(entry:)` にフォールバック**します。したがって `read` / `readData` が読める書庫の範囲は
`extract` 以上です。BZip2 / Deflate / 暗号化は 7zDec.c 側にも実装が無いので、どちらの経路でも失敗します。

### 入力の読み方

パック済みデータは `ISeekInStream`(`CFileInStream`)から 256KB ずつ読みます。読む前に毎回 seek するので、
`extract(entry:)` が使う `CLookToRead2` と同じファイルハンドルを共有しても位置がずれません
(同時には使わない前提)。

### CRC

7-Zip が書くのはふつう**ファイル単位**の CRC(SubStreamsInfo)で、ブロック単位の CRC はまず入っていません。
`SzArEx_Extract` はファイル単位の CRC を検証するので、ストリーミング経路も同じにしてあります:
`read(entry:)` はエントリを末尾まで読み切った時点(`body` が最後のチャンクで `false` を返した場合も含む)で
CRC を照合し、不一致なら `LZMAError.decodeFailed(code: SZ_ERROR_CRC)` を投げます(チャンクは渡し終えた後)。
途中で止めた読み取りと `readData(maxByteCount:)` の先頭読みは検証されません。

書庫にブロックの CRC もある場合は、読み捨てを含む全バイトが `SzFolderStream_Read` を通るため、
ブロック末尾まで読み切った時点で同様に検証します。

### アロケータ

`SzFolderStream_Create` に渡された `ISzAlloc` は**値で複製**して保持します。Swift から `&allocImp` で渡される
ポインタは呼び出しの間しか有効でないためです(最初の実装で SIGBUS を起こした箇所)。

### PPMd

upstream は 7zDec.c の `Z7_PPMD_SUPPORT` を定義しておらず、PPMd 圧縮の 7z は `extract` で失敗していました。
`Ppmd7.c` / `Ppmd7Dec.c` は元々コンパイル対象だったため、`Package.swift` で定義を有効にしました。
これにより従来の `extract(entry:)` でも PPMd を読めます。

## 実測

`sevenzip-bench` による、JPEG 130 枚(308MB)をソリッド LZMA2(辞書 32MB)で固めた書庫の結果(Apple M4)。
footprint は `task_vm_info.phys_footprint`。

| シナリオ | `extract` | `readData` |
|---|---|---|
| 全エントリを書庫順に読む | 8.2 s / 364MB | 8.3 s / 88MB |
| 中間の 1 エントリだけ | 8.3 s / 311MB | 5.4 s / 35MB |
| 続けてその 1 つ前 | (キャッシュ) | 0.00 s(辞書から。辞書の外なら先頭からやり直し) |
| 続けてその 1 つ後 | (キャッシュ) | 0.04 s(続きから) |

伸長速度はどちらも約 37MB/s で、LZMA SDK の C デコーダの速さそのものです(同じ書庫を 7zz の単スレッドで
テストすると 52MB/s)。非ソリッドの書庫では両経路とも 1 エントリ 20ms 程度で差はありません。

## テスト

```sh
swift test
```

`Tests/SevenZipTests/streaming-fixture/` の書庫は `generate.sh` で再生成できます(Homebrew の `sevenzip` = `7zz` が必要)。
内容は乱数シード固定で決定的に作られ、各ファイルの sha256 が `manifest.json` に入ります。テストはこの manifest を
正解として、書庫順・逆順・同一エントリの再読・先頭だけ・小さいチャンク・空ファイル・フォールバック(BCJ2)・
非対応(BZip2 / Deflate)・`discardFolderStream` 後の読み取り・`extract` との一致を確認します。
`bcj_boundary.7z` は 700KB の疑似 x86 コードで、フィルタの 256KB 境界が変換対象の途中に複数回落ちる
ケースです。

`mtime.7z` / `no_mtime.7z` は `Entry.modified`(ヘッダーの FILETIME)用です。前者は
2026-01-02 03:04:05 UTC に固定した 1 ファイル、後者は `-mtm=off` で日時を一切持たない書庫
(`CSzArEx.MTime.Defs` が NULL になる経路)。

## ベンチ

```sh
swift build -c release
.build/release/sevenzip-bench path/to/archive.7z            # 全シナリオ
.build/release/sevenzip-bench path/to/archive.7z mid-stream # 1 シナリオ
```

シナリオは `seq-extract` / `seq-stream` / `mid-extract` / `mid-stream` / `jump-stream`。footprint を正確に見たいときは
1 回の実行につき 1 シナリオにしてください(同じプロセス内では前のシナリオの解放が数字に残ることがあります)。

## 既知の制限

- BCJ2 はストリーミングせず `extract` に任せる(ブロック丸ごと伸長)。x86 実行ファイル向けの構成なので画像用途では出ない。
- 後方ジャンプは LZMA 辞書の範囲(通常 16〜64MB)か Copy ブロック内なら無料、それより外はブロック先頭からの
  やり直し。ブロックを**前後交互**に舐めるような読み方は辞書の外へすぐ出るので、利用側は書庫順に読むこと
  (中央から前後交互に 100 エントリ 250MB を読むと、書庫順なら 10 秒のところが 230 秒になる)。
- `Archive` はスレッドセーフではない。

## upstream から直したもの

- **`Entry.modified` が常に nil だった。** `Archive.init` の
  `SevenZip_SzBitWithVals_Check(&db.MTime, i) == 0` は条件が逆で(このマクロは値が**ある**ときに
  非 0 を返す。`7z.h`)、日時を持つ書庫でも nil になり、逆に日時を持たない書庫では `MTime.Vals` を
  NULL のまま読んでいた。`!= 0` と `Vals` の nil 検査へ直し、FILETIME → Unix 時間の計算も
  1970 より前でアンダーフローしないよう Double で行うようにした(`EntryDateTests`)。

## upstream への追従

upstream の更新は主に LZMA SDK の差し替え(`Sources/CsevenZip/` 一式)です。`7zFolderStream.c` は SDK の公開 API
(`SzGetNextFolderItem`、`LzmaDec_*`、`Lzma2Dec_*`、`Ppmd7*`、`Bra.h`、`Delta.h`)だけに依存しているので、
SDK 更新時はこれらのシグネチャが変わっていないかを確認し、`swift test` を通せば十分です。
`git fetch upstream && git merge upstream/main` で取り込みます。
