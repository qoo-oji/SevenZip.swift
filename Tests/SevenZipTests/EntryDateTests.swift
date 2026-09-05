import XCTest

@testable import SevenZip

/// `Entry.modified`. The 7z header carries modification times as a FILETIME table with a
/// presence bitmap; `SzBitWithVals_Check` reports whether a given file has an entry in it.
///
/// The check used to be inverted, so `modified` was always nil for archives that do carry
/// timestamps -- and, for archives that do not, the code read `MTime.Vals` while `Defs` was
/// NULL. Both fixtures below exist to keep that from coming back.
final class EntryDateTests: XCTestCase {
    private func openArchive(_ name: String) throws -> Archive {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "streaming-fixture"))
        return try Archive(fileURL: url)
    }

    /// mtime.7z holds one file touched to 2026-01-02 03:04:05 UTC (generate.sh).
    func testModifiedIsReadFromTheHeader() throws {
        let archive = try openArchive("mtime")
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "hello.txt")
        let modified = try XCTUnwrap(entry.modified, "the archive has a modification time")
        XCTAssertEqual(modified.timeIntervalSince1970, 1_767_323_045, accuracy: 0.001)
        XCTAssertEqual(String(data: try archive.readData(entry: entry), encoding: .utf8),
                       "SevenZip.swift mtime fixture\n")
    }

    /// no_mtime.7z was written with -mtm=off: the whole table is absent.
    func testArchiveWithoutTimestamps() throws {
        let archive = try openArchive("no_mtime")
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "hello.txt")
        XCTAssertNil(entry.modified)
        XCTAssertEqual(String(data: try archive.readData(entry: entry), encoding: .utf8),
                       "SevenZip.swift mtime fixture\n")
    }

    /// Every file in a normal archive gets a timestamp, and they are recent-ish (i.e. the
    /// FILETIME epoch conversion is not off by centuries).
    func testEveryEntryOfANormalArchiveHasATimestamp() throws {
        let archive = try openArchive("lzma2_solid")
        let files = archive.entries.filter { !$0.directory }
        XCTAssertFalse(files.isEmpty)
        for entry in files {
            let modified = try XCTUnwrap(entry.modified, "\(entry.path) has no modification time")
            // The fixtures were made in 2026; anything outside 2000-2100 means a broken epoch.
            XCTAssertGreaterThan(modified.timeIntervalSince1970, 946_684_800)
            XCTAssertLessThan(modified.timeIntervalSince1970, 4_102_444_800)
        }
    }
}
