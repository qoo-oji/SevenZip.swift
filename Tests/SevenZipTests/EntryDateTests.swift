import XCTest

@testable import SevenZip

/// `Entry.modified` over the streaming fixtures. The FILETIME conversion itself, and the archive
/// that carries no timestamp table at all, are covered by `ArchiveSpecTests` upstream; what is
/// left here is the sanity check across a whole archive.
final class EntryDateTests: XCTestCase {
    private func openArchive(_ name: String) throws -> Archive {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "streaming-fixture"))
        return try Archive(fileURL: url)
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
