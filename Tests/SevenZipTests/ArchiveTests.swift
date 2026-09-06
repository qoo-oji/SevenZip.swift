import XCTest

@testable import SevenZip

final class ArchiveSpecTests: XCTestCase {
    func testOpen() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "LICENSE.txt")
        XCTAssertEqual(entry.uncompressedSize, 1094)
        XCTAssertFalse(entry.directory)
        let data = try archive.extract(entry: entry)
        XCTAssertEqual(data.sha256Digest, "b28b7b6753000c2e5fe368ef69f0c7c8b09de048f8fd140cda102d736c26433b")
    }

    func testLargeFile() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "largefile", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "631px-FullMoon2010.bmp")
        var data = try archive.extract(entry: entry)
        XCTAssertEqual(data.sha256Digest, "d666500f1a28b5a40d09a2a1e7558cd3cdd60120b2d4bba0dcf05e78b41b075e")
        data = try archive.extract(entry: entry, bufSize: Int(entry.uncompressedSize))
        XCTAssertEqual(data.sha256Digest, "d666500f1a28b5a40d09a2a1e7558cd3cdd60120b2d4bba0dcf05e78b41b075e")
    }

    func testUtf8Archive() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "utf8", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        XCTAssertTrue(archive.entries.contains { $0.path == "日本語🧔‍♂️🍺" })
        XCTAssertTrue(archive.entries.contains { $0.path.contains("これは月の画像です.jpg") })
        XCTAssertTrue(archive.entries.contains { $0.path.contains("Здравствуйте.jpg") })
    }

    func testEmptyArchive() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "empty", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        let data = try archive.extract(entry: entry)
        XCTAssertEqual(data.count, 0)
    }

    /// The 7z header stores modification times as a FILETIME table with a presence bitmap;
    /// `SzBitWithVals_Check` reports whether a given file has an entry in it.
    /// mtime.7z holds one file whose modification time was set to 2026-01-02 03:04:05 UTC.
    func testModified() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mtime", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "hello.txt")
        let modified = try XCTUnwrap(entry.modified, "the archive carries a modification time")
        XCTAssertEqual(modified.timeIntervalSince1970, 1_767_323_045, accuracy: 0.001)
    }

    /// no_mtime.7z was written with -mtm=off, so the table is absent altogether and
    /// `CSzArEx.MTime.Vals` is NULL.
    func testNoTimestampArchive() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "no_mtime", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "hello.txt")
        XCTAssertNil(entry.modified)
    }

    /// PPMd is one of the coders 7zDec.c knows, but only when Z7_PPMD_SUPPORT is defined.
    func testExtractPpmdCompressedEntry() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ppmd", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first { !$0.directory })
        XCTAssertEqual(entry.path, "LICENSE.txt")
        let data = try archive.extract(entry: entry)
        XCTAssertEqual(data.count, Int(entry.uncompressedSize))
        XCTAssertEqual(data.sha256Digest, "b28b7b6753000c2e5fe368ef69f0c7c8b09de048f8fd140cda102d736c26433b")
    }

    /// `Archive` owns the archive's file descriptor, the parsed index and `outBuffer`, and none
    /// of them are given back before `deinit` runs, so it has to die with its last reference.
    /// While `Entry` referred back to its archive, the stored `entries` formed a cycle and no
    /// `Archive` was ever deallocated.
    func testArchiveIsReleasedWithItsLastReference() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "7z"))
        weak var weakArchive: Archive?
        try autoreleasepool {
            var archive: Archive? = try Archive(fileURL: url)
            weakArchive = archive
            let entry = try XCTUnwrap(archive?.entries.first)
            _ = try archive?.extract(entry: entry)
            archive = nil
            // The entry stays usable once its archive is gone: it holds no reference to it.
            XCTAssertEqual(entry.path, "LICENSE.txt")
        }
        XCTAssertNil(weakArchive, "the archive outlived its last reference; its file descriptor and buffers leak")
    }
}
