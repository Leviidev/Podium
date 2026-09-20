import XCTest
import CryptoKit
@testable import Podium

final class FileHasherTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodiumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testKnownStringHashesCorrectly() throws {
        // sha256("hello world") — a widely-published test vector.
        let url = tempDirectory.appendingPathComponent("hello.txt")
        try Data("hello world".utf8).write(to: url)

        let digest = try FileHasher.sha256(of: url)
        XCTAssertEqual(digest, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func testEmptyFileHashesToKnownEmptyDigest() throws {
        let url = tempDirectory.appendingPathComponent("empty.txt")
        try Data().write(to: url)

        let digest = try FileHasher.sha256(of: url)
        XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashSpanningMultipleChunksMatchesWholeFileHash() throws {
        // Larger than FileHasher's internal 4 MB chunk size, so this
        // exercises the multi-chunk streaming path specifically.
        let url = tempDirectory.appendingPathComponent("large.bin")
        let data = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 % 256) })
        try data.write(to: url)

        let streamed = try FileHasher.sha256(of: url)
        let whole = SHA256Reference.hex(of: data)
        XCTAssertEqual(streamed, whole)
    }
}

/// A second, independent SHA-256 computation (whole-buffer, not
/// streamed) used only to cross-check `FileHasher`'s chunked
/// implementation against CryptoKit on the same input.
private enum SHA256Reference {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).hexEncodedString
    }
}
