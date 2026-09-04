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
    /// The seekable stream every reader (block cache and streaming decoder) pulls the archive from.
    var seekStream: ISeekInStreamPtr {
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
    /// How many times a streaming decoder was (re)created from a block's start. For tests:
    /// reading backwards within the dictionary must not increase it.
    var folderStreamRestartCount = 0
    /// How far back `read(entry:)` / `readData(entry:)` can move inside a solid block without
    /// decoding it again from its start, in bytes of unpacked data (0 by default).
    ///
    /// Reading backwards is free within the LZMA dictionary (typically 16–64 MB, unfiltered
    /// LZMA / LZMA2 only) and anywhere in a stored block. A reader that walks backwards —
    /// a viewer whose prefetch reaches several pages behind the page on screen — needs a
    /// window larger than a 16 MB dictionary; set this to have the decoder keep that much
    /// of its most recent output (for every coder kind) in a ring buffer. The memory is
    /// only allocated when the block's dictionary does not already cover the window, and
    /// never more than the block's size. Takes effect the next time a block's decoder is
    /// created (`discardFolderStream()` forces that).
    public var historyByteCount: Int = 0

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
            let mtime: Date?
            if SevenZip_SzBitWithVals_Check(&db.MTime, i) == 0 {
                let high: UInt64 = UInt64(db.MTime.Vals[Int(i)].High)
                let low: UInt64 = UInt64(db.MTime.Vals[Int(i)].Low)
                mtime = Date(timeIntervalSince1970: TimeInterval((high << 32 | low) / 10_000_000 - UInt64(11_644_473_600)))
            } else {
                mtime = nil
            }
            let entry = Entry(index: i, path: filename, uncompressedSize: filesize, directory: isDirectory, modified: mtime, archive: self)
            return entry
        }
    }

    deinit {
        SzFolderStream_Free(self.folderStream)
        if let pointee = self.outBuffer {
            self.allocImp.Free(nil, pointee)
        }
        SzArEx_Free(&self.db, &self.allocImp)
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
