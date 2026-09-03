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
3. そうでなければデコーダを作り直し、ブロック先頭からオフセットまで読み捨てる。
4. エントリのサイズぶんを読む。読み終えた位置は次のエントリの先頭なので、書庫順に読む限りブロックは 1 回しか伸長されない。

後方へ戻るとき(3)のやり直しはソリッド圧縮の性質上避けられません。1 ブロック = 1 本のストリームです。

### 対応するコーダ構成

7zDec.c が扱う構成のうち、BCJ2 を除いたものに対応します。

- 主コーダ 1 つ: Copy / LZMA / LZMA2 / PPMd
- 主コーダ + フィルタ 1 段: Delta、BCJ(x86)、PPC、IA64、ARM、ARMT、SPARC、ARM64、RISC-V

フィルタは 256KB 単位で適用し、変換関数が処理しきれなかった末尾(先読みぶん、最大 16 バイト)を次の
チャンクの先頭へ持ち越します。`pc`(仮想アドレス)は処理したバイト数ぶん進めます。

上記以外(BCJ2、BZip2、Deflate、7zAES など)は `SzFolderStream_Create` が `SZ_ERROR_UNSUPPORTED` を返し、
Swift 側は**従来の `extract(entry:)` にフォールバック**します。したがって `read` / `readData` が読める書庫の範囲は
`extract` 以上です。BZip2 / Deflate / 暗号化は 7zDec.c 側にも実装が無いので、どちらの経路でも失敗します。

### 入力の読み方

パック済みデータは `ISeekInStream`(`CFileInStream`)から 256KB ずつ読みます。読む前に毎回 seek するので、
`extract(entry:)` が使う `CLookToRead2` と同じファイルハンドルを共有しても位置がずれません
(同時には使わない前提)。

### CRC

書庫にブロックの CRC がある場合、読み捨てを含む全バイトが `SzFolderStream_Read` を通るため、ブロック末尾まで
読み切った時点で検証し、不一致なら末尾に達した読み取りが `LZMAError.decodeFailed(code: SZ_ERROR_CRC)` になります。
途中までしか読まないブロックは検証されません(ファイル単位の CRC は upstream と同じく検証していません)。

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
| 続けてその 1 つ前 | (キャッシュ) | 5.4 s(先頭からやり直し) |
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
- 後方ジャンプはブロック先頭からのやり直し。必要なら利用側でページキャッシュを持つ。
- `Archive` はスレッドセーフではない。

## upstream への追従

upstream の更新は主に LZMA SDK の差し替え(`Sources/CsevenZip/` 一式)です。`7zFolderStream.c` は SDK の公開 API
(`SzGetNextFolderItem`、`LzmaDec_*`、`Lzma2Dec_*`、`Ppmd7*`、`Bra.h`、`Delta.h`)だけに依存しているので、
SDK 更新時はこれらのシグネチャが変わっていないかを確認し、`swift test` を通せば十分です。
`git fetch upstream && git merge upstream/main` で取り込みます。
