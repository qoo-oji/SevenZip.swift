import XCTest

@testable import SevenZip

/// The 7z header stores modification times as a FILETIME table with a presence bitmap;
/// `SzBitWithVals_Check` reports whether a given file has an entry in it.
final class EntryDateTests: XCTestCase {
    /// mtime.7z holds one file whose modification time was set to 2026-01-02 03:04:05 UTC.
    func testModifiedIsReadFromTheHeader() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mtime", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "hello.txt")
        let modified = try XCTUnwrap(entry.modified, "the archive carries a modification time")
        XCTAssertEqual(modified.timeIntervalSince1970, 1_767_323_045, accuracy: 0.001)
    }

    /// no_mtime.7z was written with -mtm=off, so the table is absent altogether and
    /// `CSzArEx.MTime.Vals` is NULL.
    func testArchiveWithoutTimestamps() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "no_mtime", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "hello.txt")
        XCTAssertNil(entry.modified)
    }

    /// Every file of an ordinary archive has a timestamp, and it lands in this century --
    /// i.e. the FILETIME epoch conversion is not off by 369 years.
    func testEveryEntryOfANormalArchiveHasAPlausibleTimestamp() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let files = archive.entries.filter { !$0.directory }
        XCTAssertFalse(files.isEmpty)
        for entry in files {
            let modified = try XCTUnwrap(entry.modified, "\(entry.path) has no modification time")
            XCTAssertGreaterThan(modified.timeIntervalSince1970, 946_684_800)  // 2000-01-01
            XCTAssertLessThan(modified.timeIntervalSince1970, 4_102_444_800)  // 2100-01-01
        }
    }
}
