import CryptoKit
import XCTest

@testable import SevenZip

/// `Archive(data:)` must behave exactly like `Archive(fileURL:)` on the same bytes,
/// for both the block-cache path and the streaming path.
final class MemoryArchiveTests: XCTestCase {
    private func fixture(_ name: String, subdirectory: String? = "streaming-fixture") throws -> (url: URL, data: Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: subdirectory))
        return (url, try Data(contentsOf: url))
    }

    func testEntriesAndContentsMatchFileArchive() throws {
        for name in ["lzma2_solid", "ppmd_solid", "bcj_lzma2", "multiblock", "bcj2_lzma2", "copy"] {
            let (url, data) = try fixture(name)
            let fromFile = try Archive(fileURL: url)
            let fromMemory = try Archive(data: data)
            XCTAssertEqual(fromMemory.entries.map(\.path), fromFile.entries.map(\.path), name)
            XCTAssertEqual(fromMemory.entries.map(\.uncompressedSize), fromFile.entries.map(\.uncompressedSize), name)
            for (memoryEntry, fileEntry) in zip(fromMemory.entries, fromFile.entries) where !fileEntry.directory {
                XCTAssertEqual(try fromMemory.readData(entry: memoryEntry), try fromFile.readData(entry: fileEntry), "\(name): \(fileEntry.path)")
                XCTAssertEqual(try fromMemory.extract(entry: memoryEntry), try fromFile.extract(entry: fileEntry), "\(name): \(fileEntry.path)")
            }
        }
    }

    func testCallerMayDropItsDataAfterOpening() throws {
        var (_, data) = try fixture("lzma2_solid")
        let archive = try Archive(data: data)
        let expected = try archive.readData(entry: archive.entries[0])
        data = Data()  // the archive must not depend on the caller's copy
        XCTAssertEqual(try archive.readData(entry: archive.entries[0]), expected)
    }

    func testUpstreamFixturesFromMemory() throws {
        let (url, data) = try fixture("utf8", subdirectory: nil)
        let fromFile = try Archive(fileURL: url)
        let fromMemory = try Archive(data: data)
        XCTAssertEqual(fromMemory.entries.map(\.path), fromFile.entries.map(\.path))
        for (m, f) in zip(fromMemory.entries, fromFile.entries) where !f.directory {
            XCTAssertEqual(try fromMemory.extract(entry: m), try fromFile.extract(entry: f), f.path)
        }
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try Archive(data: Data("not a 7z archive".utf8)))
        XCTAssertThrowsError(try Archive(data: Data()))
    }

    func testTruncatedArchiveFailsCleanly() throws {
        let (_, data) = try fixture("lzma2_nonsolid")
        // Headers live at the end of a 7z file, so cutting the tail must be rejected at open.
        XCTAssertThrowsError(try Archive(data: data.prefix(data.count / 2)))
    }
}
