// SPDX-FileCopyrightText: 2021 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: MIT

import CsevenZip
import Foundation

public enum LZMAError: Error, Equatable {
    case badFile
    case noMemory
    /// The coder chain of the entry's block is not supported by this library.
    case unsupported
    /// The LZMA SDK reported an error (`SZ_ERROR_*` code) while decoding.
    case decodeFailed(code: Int32)
    /// Reading the entry would decode its whole solid block into memory (a coder chain the
    /// streaming decoder does not handle, such as BCJ2), and the block's declared unpacked size
    /// is above `Archive.maxWholeBlockBytes`.
    case blockTooLarge(unpackSize: UInt64)
}

private var moduleInit: Void = {
    // Need to run only once
    CrcGenerateTable()
}()

public class Archive {
    private(set) public var entries: [Entry] = []
    var allocImp = ISzAlloc(Alloc: SzAlloc, Free: SzFree)
    private var allocTempImp = ISzAlloc(Alloc: SzAlloc, Free: SzFree)
    var db = CSzArEx()
    /// File-backed source (`init(fileURL:)`).
    private let archiveStream: UnsafeMutablePointer<CFileInStream> = {
        let ptr = UnsafeMutablePointer<CFileInStream>.allocate(capacity: 1)
        ptr.initialize(to: CFileInStream())
        return ptr
    }()
    private var isFileOpen = false
    /// Memory-backed source (`init(data:)`): the archive bytes and the LZMA SDK stream over them.
    private var memoryBuffer: UnsafeMutableRawBufferPointer?
    private var memoryStream: UnsafeMutablePointer<CMemInStream>?
    /// Reader-backed source (`init(reader:)`): the caller's reader (kept alive by the archive) and the stream over it.
    private var positionalReader: PositionalReader?
    private var readerStream: UnsafeMutablePointer<CCallbackInStream>?

    /// Reads bytes of an archive by position, for `init(reader:)`.
    ///
    /// `read(offset, buffer)` fills up to `buffer.count` bytes starting at `offset` and returns how
    /// many it filled: 0 at or past the end, -1 on an error (the archive operation then fails with a
    /// read error). It may return fewer bytes than asked. It is called on the thread that uses the
    /// archive (an `Archive` is not thread-safe, so one call at a time).
    public final class PositionalReader: @unchecked Sendable {
        public let size: Int64
        let read: (Int64, UnsafeMutableRawBufferPointer) -> Int

        public init(size: Int64, read: @escaping (Int64, UnsafeMutableRawBufferPointer) -> Int) {
            self.size = size
            self.read = read
        }
    }
    /// The seekable stream every reader (block cache and streaming decoder) pulls the archive from.
    var seekStream: ISeekInStreamPtr {
        if let readerStream = self.readerStream {
            return UnsafePointer(readerStream.pointer(to: \.vt)!)
        }
        if let memoryStream = self.memoryStream {
            return UnsafePointer(memoryStream.pointer(to: \.vt)!)
        }
        return UnsafePointer(self.archiveStream.pointer(to: \.vt)!)
    }
    private var lookStream = CLookToRead2()
    private var blockIndex: UInt32 = 0xFFFF_FFFF  // it can have any value before first call (if outBuffer = 0)
    var outBuffer = UnsafeMutablePointer<UInt8>(bitPattern: 0)
    var outBufferSize: Int = 0  // it can have any value before first call (if outBuffer = 0)
    /// Streaming decoder of the block that was read from most recently (see ArchiveStreaming.swift).
    /// Kept between calls so that reading the files of a solid block in order decodes the block once.
    var folderStream: OpaquePointer?
    var folderStreamIndex: UInt32 = 0
    /// How many times a streaming decoder was (re)created from a block's start.
    ///
    /// Reading the files of a solid block in archive order decodes the block once, so this stays
    /// at 1 for that block; seeking backwards within the dictionary must not increase it. Public
    /// so that a client can keep its own access order honest (qooViewer regression-tests that
    /// reading a book's pages in archive order causes no restart).
    public internal(set) var folderStreamRestartCount = 0

    /// The largest solid block `read(entry:)` / `readData(entry:)` may decode whole into memory
    /// when the block's coder chain is not supported by the streaming decoder (BCJ2, ...) and
    /// they fall back to `extract(entry:)`. `nil` (the default) sets no limit. Above it, the read
    /// throws `LZMAError.blockTooLarge` before allocating anything.
    ///
    /// The fallback allocates the block's full unpacked size up front, so a tiny archive whose
    /// index declares a huge block costs that much memory just to read its first small file
    /// (a 143 KB archive with an 800 MB BCJ2 block took 845 MB). A client that reads entries it
    /// was not explicitly asked for, such as a thumbnailer, can bound that here.
    public var maxWholeBlockBytes: UInt64?

    public init(fileURL: URL) throws {
        _ = moduleInit
        let result = fileURL.path.withCString { pathPtr in
            return InFile_Open(&self.archiveStream.pointee.file, pathPtr)
        }
        if result != 0 {
            throw LZMAError.badFile
        }
        self.isFileOpen = true
        FileInStream_CreateVTable(self.archiveStream)
        try self.openDatabase()
    }

    /// Opens an archive held in memory, so that nothing has to be written to disk.
    ///
    /// The bytes are copied once into a buffer owned by the archive (`Data` does not
    /// guarantee a stable pointer for the archive's lifetime); the caller may drop its
    /// copy afterwards.
    public init(data: Data) throws {
        _ = moduleInit
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        data.copyBytes(to: buffer)
        self.memoryBuffer = buffer
        let stream = UnsafeMutablePointer<CMemInStream>.allocate(capacity: 1)
        stream.initialize(to: CMemInStream())
        MemInStream_Init(stream, buffer.baseAddress, data.count)
        self.memoryStream = stream
        try self.openDatabase()
    }

    /// Opens an archive read through a caller-supplied positional reader, so that a client can put
    /// its own I/O layer (for example a block cache over a network volume) under the decoder.
    /// The archive keeps the reader alive for its lifetime.
    public init(reader: PositionalReader) throws {
        _ = moduleInit
        self.positionalReader = reader
        let stream = UnsafeMutablePointer<CCallbackInStream>.allocate(capacity: 1)
        stream.initialize(to: CCallbackInStream())
        let callback: CallbackInStreamRead = { ctx, offset, buf, size in
            guard let ctx, let buf else { return -1 }
            let reader = Unmanaged<PositionalReader>.fromOpaque(ctx).takeUnretainedValue()
            return Int64(reader.read(offset, UnsafeMutableRawBufferPointer(start: buf, count: size)))
        }
        CallbackInStream_Init(stream, Unmanaged.passUnretained(reader).toOpaque(), callback, reader.size)
        self.readerStream = stream
        try self.openDatabase()
    }

    /// Reads the archive database (headers) through `seekStream` and builds `entries`.
    private func openDatabase() throws {
        LookToRead2_CreateVTable(&self.lookStream, 0)
        let bufSize = 1 << 18
        guard let buf = self.allocImp.Alloc(nil, bufSize)?.assumingMemoryBound(to: UInt8.self) else {
            throw LZMAError.noMemory
        }
        self.lookStream.buf = buf
        self.lookStream.bufSize = bufSize
        defer {
            self.allocImp.Free(nil, buf)
        }
        self.lookStream.realStream = self.seekStream
        SevenZip_LookToRead2_Init(&self.lookStream)

        SzArEx_Init(&self.db)
        if SzArEx_Open(&self.db, &self.lookStream.vt, &self.allocImp, &self.allocTempImp) != 0 {
            throw LZMAError.badFile
        }
        self.entries = try (0..<self.db.NumFiles).map { i in
            let len = SzArEx_GetFileNameUtf16(&self.db, Int(i), nil)
            guard let temp = SzAlloc(nil, len * MemoryLayout<UInt16>.size)?.assumingMemoryBound(to: UInt16.self) else {
                throw LZMAError.noMemory
            }
            defer {
                SzFree(nil, temp)
            }
            SzArEx_GetFileNameUtf16(&db, Int(i), temp)
            guard let filename = String(data: Data(bytes: temp, count: len * MemoryLayout<UInt16>.size - 1), encoding: .utf16LittleEndian) else {
                throw LZMAError.badFile
            }
            let filesize = SevenZip_SzArEx_GetFileSize(&self.db, i)
            let isDirectory = SevenZip_SzArEx_IsDir(&self.db, i) != 0
            // SzBitWithVals_Check returns non-zero when the file HAS the value (7z.h), so this
            // has to be `!= 0`; `Vals` itself is NULL when no file in the archive has one.
            let mtime: Date?
            if SevenZip_SzBitWithVals_Check(&db.MTime, i) != 0, let values = db.MTime.Vals {
                let high = UInt64(values[Int(i)].High)
                let low = UInt64(values[Int(i)].Low)
                // FILETIME: 100-ns ticks since 1601-01-01. Computed in Double so that a timestamp
                // before 1970 does not underflow (the UInt64 subtraction traps) and the sub-second
                // part survives.
                let ticks = Double(high << 32 | low)
                mtime = Date(timeIntervalSince1970: ticks / 10_000_000 - 11_644_473_600)
            } else {
                mtime = nil
            }
            return Entry(index: i, path: filename, uncompressedSize: filesize, directory: isDirectory, modified: mtime)
        }
    }

    deinit {
        SzFolderStream_Free(self.folderStream)
        if let pointee = self.outBuffer {
            self.allocImp.Free(nil, pointee)
        }
        SzArEx_Free(&self.db, &self.allocImp)
        // InFile_Open opened the file in init; nothing else closes it. An archive opened from
        // memory never went through InFile_Open, so its CSzFile must be left alone.
        if self.isFileOpen {
            File_Close(&self.archiveStream.pointee.file)
        }
        self.archiveStream.deinitialize(count: 1)
        self.archiveStream.deallocate()
        if let memoryStream = self.memoryStream {
            memoryStream.deinitialize(count: 1)
            memoryStream.deallocate()
        }
        self.memoryBuffer?.deallocate()
        if let readerStream = self.readerStream {
            readerStream.deinitialize(count: 1)
            readerStream.deallocate()
        }
    }

    // TODO: super large file
    public func extract(entry: Entry, bufSize: Int = 1 << 18) throws -> Data {
        if entry.uncompressedSize == 0 || entry.directory {
            return Data()
        }
        var offset: Int = 0
        var outSizeProcessed: Int = 0
        guard let buf = self.allocImp.Alloc(nil, bufSize)?.assumingMemoryBound(to: UInt8.self) else {
            throw LZMAError.noMemory
        }
        self.lookStream.buf = buf
        self.lookStream.bufSize = bufSize
        defer {
            self.allocImp.Free(nil, buf)
        }

        let result = SzArEx_Extract(
            &self.db, &self.lookStream.vt, entry.index, &self.blockIndex, &self.outBuffer, &self.outBufferSize, &offset, &outSizeProcessed,
            &self.allocImp, &self.allocTempImp)
        if result == SZ_ERROR_UNSUPPORTED {
            throw LZMAError.unsupported
        }
        if result != 0 {
            throw LZMAError.badFile
        }
        if let pointee = self.outBuffer {
            return Data(bytes: pointee.advanced(by: offset), count: outSizeProcessed)
        } else {
            throw LZMAError.badFile
        }
    }
}
