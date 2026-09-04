// SPDX-FileCopyrightText: 2026 qoo
// SPDX-License-Identifier: MIT

import CsevenZip
import Foundation

/// Streaming (pull-based) reading of entries.
///
/// `extract(entry:)` decodes the whole solid block an entry belongs to and keeps that
/// buffer cached, so a single small file can cost gigabytes of memory on a large solid
/// archive. The methods below instead decode only as far as the requested entry, with
/// memory bounded by the decoder state (the LZMA dictionary) plus a few hundred KB:
///
/// - Reading the entries of a solid block **in archive order** decodes the block exactly
///   once in total, because the decoder is kept and resumed between calls.
/// - Jumping **backwards** inside a block is free while the target is still in the
///   decoder's dictionary (LZMA / LZMA2 without a branch filter: the last `dicSize`
///   bytes, typically 16–64 MB) or the block is stored (Copy). Further back, the block is
///   decoded again from its start (inherent to solid compression: the block is one stream).
/// - Blocks whose coder chain the streaming decoder does not handle (BCJ2, BZip2,
///   Deflate, AES, ...) transparently fall back to `extract(entry:)`.
///
/// The folder CRC stored in the archive is verified when a block has been read through
/// to its end; a mismatch is reported on the read that reaches the end.
extension Archive {
    /// Reads the entry's bytes sequentially, handing them to `body` in chunks of at most
    /// `chunkSize` bytes. `body` returns `false` to stop early (for example after a prefix).
    /// The buffer passed to `body` is only valid during the call.
    ///
    /// The entry's CRC (stored per file by 7-Zip) is verified once the entry has been decoded
    /// through to its end — also when `body` stopped on the last chunk — and a mismatch
    /// throws `LZMAError.decodeFailed(code: SZ_ERROR_CRC)` after the chunks were delivered.
    /// A read that stops before the end is not verified.
    ///
    /// Empty entries and directories complete without calling `body`.
    public func read(entry: Entry, chunkSize: Int = 1 << 16, _ body: (UnsafeRawBufferPointer) throws -> Bool) throws {
        if entry.uncompressedSize == 0 || entry.directory {
            return
        }
        let fileIndex = Int(entry.index)
        let folderIndex = self.db.FileToFolder[fileIndex]
        guard folderIndex != UInt32.max else {
            return  // no data stream (empty file)
        }
        let offsetInFolder = self.db.UnpackPositions[fileIndex]
            - self.db.UnpackPositions[Int(self.db.FolderToFile[Int(folderIndex)])]

        guard let stream = try self.folderStream(for: folderIndex, positionedAt: offsetInFolder) else {
            // Unsupported coder chain: fall back to the block cache.
            let data = try self.extract(entry: entry)
            try data.withUnsafeBytes { (whole: UnsafeRawBufferPointer) in
                var start = 0
                while start < whole.count {
                    let end = min(start + max(chunkSize, 1), whole.count)
                    if try !body(UnsafeRawBufferPointer(rebasing: whole[start..<end])) {
                        return
                    }
                    start = end
                }
            }
            return
        }

        var remaining = entry.uncompressedSize
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(chunkSize, 1), alignment: 16)
        defer { buffer.deallocate() }
        // The entry's own CRC (7-Zip stores one per file; the block CRC that SzFolderStream
        // checks is usually absent). SzArEx_Extract verifies it too, so a reader must not
        // lose that by switching to this path. Only a complete read can be checked; a
        // caller that stops early gets what it asked for, unverified.
        let expectedCrc: UInt32? = SevenZip_SzBitUi32s_Check(&self.db.CRCs, entry.index) != 0
            ? self.db.CRCs.Vals[fileIndex] : nil
        var crc: UInt32 = 0xFFFF_FFFF
        while remaining > 0 {
            var size = Int(min(UInt64(buffer.count), remaining))
            let result = SzFolderStream_Read(stream, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), &size)
            if result != SZ_OK {
                self.discardFolderStream()
                throw LZMAError.decodeFailed(code: result)
            }
            if size == 0 {
                self.discardFolderStream()
                throw LZMAError.badFile  // block ended before the entry did
            }
            remaining -= UInt64(size)
            if expectedCrc != nil {
                crc = CrcUpdate(crc, buffer.baseAddress, size)
            }
            if try !body(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<size])),
               remaining > 0 {
                return  // stopped early: the entry was not read through, nothing to verify
            }
        }
        if let expectedCrc, crc ^ 0xFFFF_FFFF != expectedCrc {
            throw LZMAError.decodeFailed(code: SZ_ERROR_CRC)
        }
    }

    /// Reads the entry into memory, at most `maxByteCount` bytes (the whole entry by default).
    ///
    /// The entry's CRC is verified when the entry is read through to its end (see `read`).
    /// A prefix read decodes in chunks no larger than `maxByteCount`, so it stops short of
    /// the end and is handed out unverified, like the partial reads of `read` itself.
    public func readData(entry: Entry, maxByteCount: Int? = nil) throws -> Data {
        let limit = maxByteCount.map { UInt64(max($0, 0)) } ?? entry.uncompressedSize
        var data = Data(capacity: Int(min(limit, entry.uncompressedSize)))
        let chunkSize = Int(min(UInt64(1 << 16), max(limit, 1)))
        try self.read(entry: entry, chunkSize: chunkSize) { chunk in
            let take = Int(min(UInt64(chunk.count), limit - UInt64(data.count)))
            data.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[0..<take]))
            return UInt64(data.count) < limit
        }
        return data
    }

    /// Memory the archive is holding for decoding right now: the streaming decoder of the
    /// most recently read block (LZMA dictionary and probabilities, or the PPMd model, plus
    /// its buffers) and the block cache that `extract(entry:)` keeps. 0 when nothing has
    /// been read yet or after `discardFolderStream()`.
    public var residentDecoderBytes: Int {
        var bytes = 0
        if let stream = self.folderStream {
            bytes += SzFolderStream_GetResidentBytes(stream)
        }
        if self.outBuffer != nil {
            bytes += self.outBufferSize
        }
        return bytes
    }

    /// Releases the decoder kept for the most recently read block. The next read
    /// decodes from the block's start again. Useful to give memory back when the
    /// archive stays open but will not be read from for a while.
    public func discardFolderStream() {
        SzFolderStream_Free(self.folderStream)
        self.folderStream = nil
    }

    /// Returns the streaming decoder for `folderIndex`, positioned at `offset`, reusing
    /// the current one when it is on the same block and `offset` is ahead of it or still
    /// within reach behind it (`SzFolderStream_CanSeekBack`).
    /// Returns nil when the block's coder chain is not supported by the streaming decoder.
    private func folderStream(for folderIndex: UInt32, positionedAt offset: UInt64) throws -> OpaquePointer? {
        if let stream = self.folderStream, self.folderStreamIndex == folderIndex {
            if SzFolderStream_GetPosition(stream) <= offset {
                try self.skip(stream, to: offset)
                return stream
            }
            if SzFolderStream_CanSeekBack(stream, offset) != 0 {
                let result = SzFolderStream_SeekBack(stream, offset)
                if result != SZ_OK {
                    self.discardFolderStream()
                    throw LZMAError.decodeFailed(code: result)
                }
                return stream
            }
        }
        self.discardFolderStream()
        self.folderStreamRestartCount += 1

        var created: OpaquePointer?
        let result = SzFolderStream_Create(
            &created, &self.db, self.seekStream, folderIndex, max(self.historyByteCount, 0), &self.allocImp)
        switch result {
        case SZ_OK:
            break
        case SZ_ERROR_UNSUPPORTED:
            return nil
        case SZ_ERROR_MEM:
            throw LZMAError.noMemory
        default:
            throw LZMAError.decodeFailed(code: result)
        }
        guard let stream = created else {
            throw LZMAError.noMemory
        }
        self.folderStream = stream
        self.folderStreamIndex = folderIndex
        try self.skip(stream, to: offset)
        return stream
    }

    private func skip(_ stream: OpaquePointer, to offset: UInt64) throws {
        let position = SzFolderStream_GetPosition(stream)
        if offset > position {
            let result = SzFolderStream_Skip(stream, offset - position)
            if result != SZ_OK {
                self.discardFolderStream()
                throw LZMAError.decodeFailed(code: result)
            }
        }
    }
}
