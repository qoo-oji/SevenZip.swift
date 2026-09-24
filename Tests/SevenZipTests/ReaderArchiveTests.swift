import XCTest

@testable import SevenZip

/// `Archive(reader:)` must behave exactly like `Archive(fileURL:)` on the same bytes,
/// for both the block-cache path and the streaming path.
final class ReaderArchiveTests: XCTestCase {
    private func fixture(_ name: String, subdirectory: String? = "streaming-fixture") throws -> (url: URL, data: Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: subdirectory))
        return (url, try Data(contentsOf: url))
    }

    /// A reader over `data` that returns at most `maxChunk` bytes per call (to exercise short reads).
    private func reader(_ data: Data, maxChunk: Int = .max) -> Archive.PositionalReader {
        Archive.PositionalReader(size: Int64(data.count)) { offset, buffer in
            guard offset >= 0, offset < Int64(data.count) else { return 0 }
            let start = Int(offset)
            let count = min(buffer.count, data.count - start, maxChunk)
            data.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count]), from: start..<(start + count))
            return count
        }
    }

    func testEntriesAndContentsMatchFileArchive() throws {
        for name in ["lzma2_solid", "ppmd_solid", "bcj_lzma2", "multiblock", "bcj2_lzma2", "copy"] {
            let (url, data) = try fixture(name)
            let fromFile = try Archive(fileURL: url)
            for maxChunk in [Int.max, 4099] {
                let fromReader = try Archive(reader: reader(data, maxChunk: maxChunk))
                XCTAssertEqual(fromReader.entries.map(\.path), fromFile.entries.map(\.path), name)
                XCTAssertEqual(fromReader.entries.map(\.uncompressedSize), fromFile.entries.map(\.uncompressedSize), name)
                for (readerEntry, fileEntry) in zip(fromReader.entries, fromFile.entries) where !fileEntry.directory {
                    XCTAssertEqual(try fromReader.readData(entry: readerEntry), try fromFile.readData(entry: fileEntry), "\(name): \(fileEntry.path)")
                    XCTAssertEqual(try fromReader.extract(entry: readerEntry), try fromFile.extract(entry: fileEntry), "\(name): \(fileEntry.path)")
                }
            }
        }
    }

    func testUpstreamFixturesFromReader() throws {
        let (url, data) = try fixture("utf8", subdirectory: nil)
        let fromFile = try Archive(fileURL: url)
        let fromReader = try Archive(reader: reader(data))
        XCTAssertEqual(fromReader.entries.map(\.path), fromFile.entries.map(\.path))
        for (r, f) in zip(fromReader.entries, fromFile.entries) where !f.directory {
            XCTAssertEqual(try fromReader.extract(entry: r), try fromFile.extract(entry: f), f.path)
        }
    }

    func testReadErrorFailsCleanly() throws {
        let (_, data) = try fixture("lzma2_solid")
        XCTAssertThrowsError(try Archive(reader: Archive.PositionalReader(size: Int64(data.count)) { _, _ in -1 }))
        // Headers (at the end) readable, packed data (at the start) not: opening works, reading fails.
        let headerStart = Int64(data.count / 2)
        let flaky = Archive.PositionalReader(size: Int64(data.count)) { offset, buffer in
            guard offset >= headerStart, offset < Int64(data.count) else { return -1 }
            let start = Int(offset)
            let count = min(buffer.count, data.count - start)
            data.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count]), from: start..<(start + count))
            return count
        }
        if let archive = try? Archive(reader: flaky), let entry = archive.entries.first(where: { !$0.directory }) {
            XCTAssertThrowsError(try archive.readData(entry: entry))
        }
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try Archive(reader: reader(Data("not a 7z archive".utf8))))
        XCTAssertThrowsError(try Archive(reader: reader(Data())))
    }
}
