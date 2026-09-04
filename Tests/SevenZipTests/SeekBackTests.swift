import CryptoKit
import CsevenZip
import XCTest

@testable import SevenZip

/// Reading backwards inside a solid block: within the LZMA dictionary (and anywhere in a
/// Copy block) the decoder is re-used; beyond it the block is decoded again from its start.
/// `Archive.folderStreamRestartCount` counts those restarts.
final class SeekBackTests: XCTestCase {
    private var manifest: [String: String] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "streaming-fixture"))
        manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func openArchive(_ name: String) throws -> Archive {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "streaming-fixture"))
        return try Archive(fileURL: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertMatchesManifest(_ archive: Archive, _ entry: Entry, _ message: String) throws {
        let data = try archive.readData(entry: entry)
        XCTAssertEqual(sha256(data), try XCTUnwrap(manifest[entry.path]), "\(message): \(entry.path)")
    }

    /// The whole block fits in the dictionary: any order costs one decode of the block.
    func testReverseOrderWithinDictionaryDoesNotRestart() throws {
        for name in ["lzma2_solid", "lzma_solid"] {
            let archive = try openArchive(name)
            let files = archive.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
            for entry in files.reversed() {
                try assertMatchesManifest(archive, entry, name)
            }
            XCTAssertEqual(archive.folderStreamRestartCount, 1, name)
            // Alternating forwards / backwards around the middle (a viewer's prefetch pattern).
            let k = files.count / 2
            for i in [k, k + 1, k - 1, k + 2, k - 2] where files.indices.contains(i) {
                try assertMatchesManifest(archive, files[i], name)
            }
            XCTAssertEqual(archive.folderStreamRestartCount, 1, name)
        }
    }

    /// A stored (Copy) block is seekable input. 7-Zip stores every file in its own block, so
    /// what exercises SeekBack here is re-reading an entry after a prefix read.
    func testCopyBlockSeeksBackFreely() throws {
        let archive = try openArchive("copy")
        let files = archive.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
        for entry in files {
            let head = try archive.readData(entry: entry, maxByteCount: 100)
            let whole = try archive.readData(entry: entry)
            XCTAssertEqual(head, whole.prefix(100), entry.path)
            XCTAssertEqual(sha256(whole), try XCTUnwrap(manifest[entry.path]), entry.path)
            _ = try archive.readData(entry: entry) // a third time, from the block's end
        }
        XCTAssertEqual(archive.folderStreamRestartCount, files.count)
    }

    /// Beyond the dictionary the block is decoded again, and the data is still right.
    func testBeyondDictionaryRestartsAndStaysCorrect() throws {
        let archive = try openArchive("small_dict")
        let files = archive.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
        let total = files.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        XCTAssertGreaterThan(total, 64 * 1024, "fixture must be larger than its 64 KB dictionary")
        try assertMatchesManifest(archive, files.last!, "small_dict")
        try assertMatchesManifest(archive, files.first!, "small_dict")
        XCTAssertEqual(archive.folderStreamRestartCount, 2)
        for entry in files.reversed() {
            try assertMatchesManifest(archive, entry, "small_dict")
        }
    }

    /// Filtered blocks have no usable history (the dictionary holds unfiltered bytes) but
    /// must still read correctly backwards.
    func testFilteredBlocksReadBackwards() throws {
        for name in ["bcj_lzma2", "arm64_lzma2", "delta_lzma2"] {
            let archive = try openArchive(name)
            for entry in archive.entries.reversed() where !entry.directory {
                try assertMatchesManifest(archive, entry, name)
            }
        }
    }

    /// A prefix read leaves the read position mid-entry; going back to the entry start is
    /// within the dictionary and must not restart.
    func testPrefixThenWholeEntryWithoutRestart() throws {
        let archive = try openArchive("lzma2_solid")
        let entry = try XCTUnwrap(archive.entries.first { $0.path == "dir/blob_04.bin" })
        let head = try archive.readData(entry: entry, maxByteCount: 100)
        let whole = try archive.readData(entry: entry)
        XCTAssertEqual(head, whole.prefix(100))
        XCTAssertEqual(archive.folderStreamRestartCount, 1)
    }

    /// Every file's CRC is verified on a complete read, as SzArEx_Extract does; the
    /// decoder's history / re-positioning must not skip or double-count bytes.
    func testFileCrcVerifiedOnStreamingPath() throws {
        for name in ["copy", "lzma2_solid"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "streaming-fixture"))
            var bytes = try Data(contentsOf: url)
            bytes[32 + 5000] ^= 0xFF // packed data starts right after the 32-byte start header
            let archive = try Archive(data: bytes)
            let files = archive.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
            func failures(_ order: [Entry]) -> Int {
                order.reduce(0) { count, entry in
                    do { _ = try archive.readData(entry: entry); return count } catch { return count + 1 }
                }
            }
            // Backwards, forwards, and the prefix-then-whole pattern: exactly the damaged
            // data fails, never a healthy entry, however the block was navigated.
            XCTAssertGreaterThan(failures(files.reversed()), 0, name)
            XCTAssertGreaterThan(failures(files), 0, name)
            for entry in files {
                _ = try? archive.readData(entry: entry, maxByteCount: 100)
            }
            XCTAssertGreaterThan(failures(files), 0, name)
            let healthy = try Archive(fileURL: url)
            let healthyFiles = healthy.entries.filter { !$0.directory && $0.uncompressedSize > 0 }
            for entry in healthyFiles { _ = try? healthy.readData(entry: entry, maxByteCount: 100) }
            for entry in healthyFiles.reversed() { XCTAssertNoThrow(try healthy.readData(entry: entry), "\(name): \(entry.path)") }
        }
        // Prefix reads are handed out unverified but must not throw on the damaged data.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "copy", withExtension: "7z", subdirectory: "streaming-fixture"))
        var bytes = try Data(contentsOf: url)
        bytes[32 + 5000] ^= 0xFF
        let archive = try Archive(data: bytes)
        let code = try XCTUnwrap(archive.entries.first { $0.path == "code.bin" })
        XCTAssertNoThrow(try archive.readData(entry: code, maxByteCount: 100))
        XCTAssertThrowsError(try archive.readData(entry: code))
    }

    func testResidentDecoderBytes() throws {
        let archive = try openArchive("lzma2_solid")
        let entry = try XCTUnwrap(archive.entries.first { !$0.directory && $0.uncompressedSize > 0 })
        XCTAssertEqual(archive.residentDecoderBytes, 0)
        _ = try archive.readData(entry: entry)
        // dictionary (>= 4 KB for any LZMA2 prop) + probabilities + 256 KB input buffer
        XCTAssertGreaterThan(archive.residentDecoderBytes, 1 << 18)
        archive.discardFolderStream()
        XCTAssertEqual(archive.residentDecoderBytes, 0)
        _ = try archive.extract(entry: entry)
        XCTAssertGreaterThan(archive.residentDecoderBytes, 0) // the block cache
    }
}
