import XCTest
@testable import Podium

final class ZipArchiveReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodiumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeZip(_ data: Data, name: String = "test.zip") throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testReadsStoredEntry() throws {
        var builder = TestZipBuilder()
        let payload = Data("Hello, Podium.".utf8)
        builder.addEntry(name: "greeting.txt", data: payload, compress: false)
        let url = try writeZip(builder.build())

        let reader = try ZipArchiveReader(fileURL: url)
        let entry = try XCTUnwrap(reader.entry(named: "greeting.txt"))
        XCTAssertEqual(entry.compressionMethod, 0)
        XCTAssertEqual(try reader.data(for: entry), payload)
    }

    func testReadsDeflateCompressedEntry() throws {
        var builder = TestZipBuilder()
        let payload = Data(repeating: 0x5A, count: 4096) + Data("compressible content repeats repeats repeats".utf8)
        builder.addEntry(name: "payload.bin", data: payload, compress: true)
        let url = try writeZip(builder.build())

        let reader = try ZipArchiveReader(fileURL: url)
        let entry = try XCTUnwrap(reader.entry(named: "payload.bin"))
        XCTAssertEqual(entry.compressionMethod, 8)
        XCTAssertEqual(try reader.data(for: entry), payload)
    }

    func testReadsMultipleEntriesIndependently() throws {
        var builder = TestZipBuilder()
        builder.addEntry(name: "a.txt", data: Data("first".utf8), compress: false)
        builder.addEntry(name: "b.txt", data: Data("second, a bit longer".utf8), compress: true)
        let url = try writeZip(builder.build())

        let reader = try ZipArchiveReader(fileURL: url)
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(try reader.data(for: XCTUnwrap(reader.entry(named: "a.txt"))), Data("first".utf8))
        XCTAssertEqual(try reader.data(for: XCTUnwrap(reader.entry(named: "b.txt"))), Data("second, a bit longer".utf8))
    }

    func testMissingEntryReturnsNil() throws {
        var builder = TestZipBuilder()
        builder.addEntry(name: "present.txt", data: Data("x".utf8))
        let url = try writeZip(builder.build())

        let reader = try ZipArchiveReader(fileURL: url)
        XCTAssertNil(reader.entry(named: "missing.txt"))
    }

    func testNonZipFileThrowsNotAZipArchive() throws {
        let url = tempDirectory.appendingPathComponent("not-a-zip.ipsw")
        try Data("this is definitely not a zip file".utf8).write(to: url)

        XCTAssertThrowsError(try ZipArchiveReader(fileURL: url)) { error in
            guard case FirmwareParsingError.notAZipArchive = error else {
                return XCTFail("Expected .notAZipArchive, got \(error)")
            }
        }
    }
}
