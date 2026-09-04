import CryptoKit
import XCTest

@testable import SevenZip

/// Exercises `Archive.read(entry:)` / `readData(entry:)` against the archives in
/// `streaming-fixture/` (regenerate with `generate.sh`; `manifest.json` holds the
/// sha256 of every payload file and is the oracle).
final class StreamingTests: XCTestCase {
    private static let streamingArchives = [
        "lzma2_solid", "lzma_solid", "ppmd_solid", "lzma2_nonsolid", "copy",
        "delta_lzma2", "bcj_lzma2", "arm64_lzma2", "multiblock", "header_plain", "bcj_boundary",
        "filter_tail_arm64", "filter_tail_bcj", "small_dict",
    ]
    /// Coder chains the streaming decoder hands over to `extract(entry:)`.
    private static let fallbackArchives = ["bcj2_lzma2"]
    /// Coder chains neither path supports (7zDec.c has no BZip2/Deflate).
    private static let unsupportedArchives = ["bzip2", "deflate"]

    private var manifest: [String: String] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "streaming-fixture"))
        manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        XCTAssertFalse(manifest.isEmpty)
    }

    private func openArchive(_ name: String) throws -> Archive {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "streaming-fixture"))
        return try Archive(fileURL: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expectedDigest(for entry: Entry) throws -> String {
        try XCTUnwrap(manifest[entry.path], "no manifest entry for \(entry.path)")
    }

    // MARK: - Whole entries, archive order

    func testSequentialReadMatchesManifest() throws {
        for name in Self.streamingArchives + Self.fallbackArchives {
            let archive = try openArchive(name)
            let files = archive.entries.filter { !$0.directory }
            XCTAssertFalse(files.isEmpty, name)
            for entry in files {
                let data = try archive.readData(entry: entry)
                XCTAssertEqual(data.count, Int(entry.uncompressedSize), "\(name): \(entry.path)")
                XCTAssertEqual(sha256(data), try expectedDigest(for: entry), "\(name): \(entry.path)")
            }
        }
    }

    // MARK: - Random access (backward jumps restart the block)

    func testReverseOrderReadMatchesManifest() throws {
        for name in Self.streamingArchives {
            let archive = try openArchive(name)
            for entry in archive.entries.reversed() where !entry.directory {
                let data = try archive.readData(entry: entry)
                XCTAssertEqual(sha256(data), try expectedDigest(for: entry), "\(name): \(entry.path)")
            }
        }
    }

    func testRereadingSameEntryTwice() throws {
        let archive = try openArchive("lzma2_solid")
        let entry = try XCTUnwrap(archive.entries.first { $0.path == "dir/blob_04.bin" })
        let first = try archive.readData(entry: entry)
        let second = try archive.readData(entry: entry)
        XCTAssertEqual(first, second)
        XCTAssertEqual(sha256(first), try expectedDigest(for: entry))
    }

    // MARK: - Partial reads

    func testPrefixRead() throws {
        for name in ["lzma2_solid", "delta_lzma2", "bcj_lzma2", "bcj2_lzma2"] {
            let archive = try openArchive(name)
            let entry = try XCTUnwrap(archive.entries.first { $0.path == "code.bin" })
            let whole = try archive.readData(entry: entry)
            let prefix = try archive.readData(entry: entry, maxByteCount: 1000)
            XCTAssertEqual(prefix.count, 1000, name)
            XCTAssertEqual(prefix, whole.prefix(1000), name)
            // A prefix read leaves the decoder mid-entry; the next full read must still be right.
            XCTAssertEqual(sha256(try archive.readData(entry: entry)), try expectedDigest(for: entry), name)
        }
    }

    func testChunkedReadStopsWhenBodyReturnsFalse() throws {
        let archive = try openArchive("lzma2_solid")
        let entry = try XCTUnwrap(archive.entries.first { $0.path == "text_00.txt" })
        var calls = 0
        try archive.read(entry: entry, chunkSize: 1024) { chunk in
            XCTAssertLessThanOrEqual(chunk.count, 1024)
            calls += 1
            return calls < 3
        }
        XCTAssertEqual(calls, 3)
    }

    func testSmallChunksReassemble() throws {
        let archive = try openArchive("arm64_lzma2")
        for entry in archive.entries where !entry.directory {
            var data = Data()
            try archive.read(entry: entry, chunkSize: 7) { chunk in
                data.append(contentsOf: chunk)
                return true
            }
            XCTAssertEqual(sha256(data), try expectedDigest(for: entry), entry.path)
        }
    }

    // MARK: - Edge cases

    func testEmptyEntryAndDirectory() throws {
        let archive = try openArchive("lzma2_solid")
        let empty = try XCTUnwrap(archive.entries.first { $0.path == "empty.txt" })
        XCTAssertEqual(try archive.readData(entry: empty).count, 0)
        let dir = try XCTUnwrap(archive.entries.first { $0.directory })
        XCTAssertEqual(try archive.readData(entry: dir).count, 0)
    }

    func testUnsupportedCoderChainsThrow() throws {
        for name in Self.unsupportedArchives {
            let archive = try openArchive(name)
            let entry = try XCTUnwrap(archive.entries.first { !$0.directory && $0.uncompressedSize > 0 })
            XCTAssertThrowsError(try archive.readData(entry: entry), name)
        }
    }

    func testDiscardFolderStreamThenRead() throws {
        let archive = try openArchive("multiblock")
        let entries = archive.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
        _ = try archive.readData(entry: entries[0])
        archive.discardFolderStream()
        let data = try archive.readData(entry: entries[1])
        XCTAssertEqual(sha256(data), try expectedDigest(for: entries[1]))
    }

    /// The legacy block-cache path must agree with the streaming path (and now covers PPMd).
    func testExtractAgreesWithStreaming() throws {
        for name in Self.streamingArchives {
            let archive = try openArchive(name)
            for entry in archive.entries where !entry.directory {
                XCTAssertEqual(try archive.extract(entry: entry), try archive.readData(entry: entry), "\(name): \(entry.path)")
            }
        }
    }
}
