import XCTest

@testable import SevenZip

/// `Archive` must actually die when its last user lets go of it: it owns the archive's file
/// descriptor, the parsed index, `outBuffer` and -- the big one -- the streaming decoder's LZMA
/// dictionary, none of which are freed before `deinit` runs.
///
/// `Entry` used to hold a strong reference back to its archive, so an `Archive` storing its
/// `[Entry]` could never reach a retain count of zero: every archive opened stayed resident for
/// the life of the process. Upstream broke that cycle by removing `Entry.archive` (v0.4.0), and
/// `ArchiveSpecTests` covers the file-backed case; what is tested here is the fork's own memory:
/// the folder stream's dictionary and an archive opened from `Data`.
final class ArchiveLifetimeTests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "streaming-fixture"))
    }

    func testArchiveIsReleasedWithItsLastReference() throws {
        let url = try fixtureURL("lzma2_solid")
        weak var weakArchive: Archive?
        try autoreleasepool {
            var archive: Archive? = try Archive(fileURL: url)
            weakArchive = archive
            // Read something so that a folder stream (and its dictionary) exists to be freed.
            let entry = try XCTUnwrap(archive?.entries.first { !$0.directory && $0.uncompressedSize > 0 })
            _ = try archive?.readData(entry: entry)
            XCTAssertGreaterThan(try XCTUnwrap(archive?.residentDecoderBytes), 0)
            archive = nil
        }
        XCTAssertNil(weakArchive, "the archive outlived its last reference; its decoder memory and file handle leak")
    }

    func testArchiveOpenedFromMemoryIsReleasedWithItsLastReference() throws {
        let data = try Data(contentsOf: try fixtureURL("lzma2_solid"))
        weak var weakArchive: Archive?
        try autoreleasepool {
            var archive: Archive? = try Archive(data: data)
            weakArchive = archive
            let entry = try XCTUnwrap(archive?.entries.first { !$0.directory && $0.uncompressedSize > 0 })
            _ = try archive?.readData(entry: entry)
            archive = nil
        }
        XCTAssertNil(weakArchive, "the in-memory archive outlived its last reference; its copy of the bytes leaks")
    }

    /// `deinit` closes the file. Before that (and while the cycle above kept `deinit` from
    /// running at all) every opened archive burned a descriptor for good.
    func testOpeningManyArchivesDoesNotLeakFileDescriptors() throws {
        let url = try fixtureURL("lzma2_solid")
        _ = try Archive(fileURL: url)  // warm up whatever the first open allocates
        let before = try openDescriptorCount()
        for _ in 0..<200 {
            autoreleasepool {
                _ = try? Archive(fileURL: url)
            }
        }
        let after = try openDescriptorCount()
        XCTAssertLessThan(after - before, 10, "leaked \(after - before) descriptors over 200 opens")
    }

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}
