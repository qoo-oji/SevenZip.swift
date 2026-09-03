# SevenZip.swift

A tiny Swift library to extract 7zip archive using [LZMA SDK v26.02](https://www.7-zip.org/sdk.html).

## Feature

- [x] Extract a file from 7z archive file to memory
- [x] Read entries of a solid archive one after another with bounded memory (streaming)
- [x] Open an archive held in memory (`Archive(data:)`), e.g. a nested archive, without writing it to disk

## Requirements

- iOS 13+
- macOS 10.15+

## Not supported features

- Extract encrypted files
- Create a 7z archive

## Usage

```swift
import SevenZip

let archive: Archive = try Archive(fileURL: url)
let entry: Entry = archive.entries.first!
let path: String = entry.path
let size : UInt64 = entry.uncompressedSize
let data = try archive.extract(entry: entry)
```

### Streaming extraction (bounded memory)

`extract(entry:)` decodes the whole solid block the entry belongs to and caches it, so
reading one file from a large solid archive can cost the memory of the entire block.
`read(entry:)` / `readData(entry:)` decode only as far as needed and keep the decoder
between calls:

```swift
let archive = try Archive(fileURL: url)
for entry in archive.entries where !entry.directory {
    // Reading entries in archive order decodes each solid block exactly once.
    let data = try archive.readData(entry: entry)
}

// Only the first 4 KB (e.g. to sniff an image header)
let head = try archive.readData(entry: entry, maxByteCount: 4096)

// Chunked, without holding the whole entry in memory
try archive.read(entry: entry, chunkSize: 1 << 16) { chunk in
    fileHandle.write(Data(chunk))
    return true // false stops early
}

// Give the decoder's memory back while the archive stays open
archive.discardFolderStream()
```

Memory stays at the LZMA dictionary size plus a few hundred KB. Jumping backwards
inside a solid block restarts that block's decoder (solid blocks are one stream).
Blocks using BCJ2 fall back to `extract(entry:)`; BZip2/Deflate/AES blocks are not
supported by either path. PPMd is supported by both.

#### Archives held in memory

```swift
// e.g. a .7z stored inside another archive: no temporary file needed
let inner = try Archive(data: bytes)
```

The bytes are copied once into a buffer owned by the `Archive`; the caller may drop
its `Data` afterwards.

Details of this fork's changes: [docs/StreamingExtraction.md](docs/StreamingExtraction.md) (Japanese).

## Installation

### Swift Package Manager

Add `https://github.com/mtgto/SevenZip.swift` to your Package.swift.

**IMPORTANT NOTE**: If you are using this library, you must specify git revision, not by version. See [#1 comment](https://github.com/mtgto/SevenZip.swift/issues/1#issuecomment-1690084540) for details.

## Related projects

- [PLzmaSDK](https://github.com/OlehKulykov/PLzmaSDK)
  - iOS / macOS library which has whole features in LZMA C++ SDK
  - However, it is very slow to extract from large solid file in my environment

## License

Swift parts of this software is released under the MIT License, see [LICENSE.txt](LICENSE.txt).

LZMA SDK is placed in the public domain. See https://www.7-zip.org/sdk.html .
