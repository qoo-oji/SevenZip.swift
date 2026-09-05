import XCTest

@testable import SevenZip

/// PPMd is one of the coders 7zDec.c knows, but only when Z7_PPMD_SUPPORT is defined;
/// without it, extracting from an archive written with -m0=ppmd fails outright.
final class PpmdTests: XCTestCase {
    func testExtractPpmdCompressedEntry() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ppmd", withExtension: "7z"))
        let archive = try Archive(fileURL: url)
        let entry = try XCTUnwrap(archive.entries.first { !$0.directory })
        XCTAssertEqual(entry.path, "LICENSE.txt")
        let data = try archive.extract(entry: entry)
        XCTAssertEqual(data.count, Int(entry.uncompressedSize))
        XCTAssertEqual(data.sha256Digest, "b28b7b6753000c2e5fe368ef69f0c7c8b09de048f8fd140cda102d736c26433b")
    }
}
