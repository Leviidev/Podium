import XCTest
@testable import Podium

final class IPSWParserTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodiumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeBuildManifestData(
        productVersion: String,
        buildVersion: String,
        deviceIdentifiers: [String],
        kernelCachePath: String? = nil
    ) throws -> Data {
        var plist: [String: Any] = [
            "ProductVersion": productVersion,
            "ProductBuildVersion": buildVersion,
            "SupportedProductTypes": deviceIdentifiers,
        ]
        if let kernelCachePath {
            plist["BuildIdentities"] = [
                ["Manifest": ["KernelCache": ["Info": ["Path": kernelCachePath]]]],
            ]
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func makeIPSW(
        named fileName: String = "test.ipsw",
        productVersion: String = ReferenceFirmware.productVersion,
        buildVersion: String = ReferenceFirmware.buildVersion,
        deviceIdentifiers: [String] = [ReferenceFirmware.device.identifier],
        kernelCachePath: String? = nil,
        includeManifest: Bool = true
    ) throws -> URL {
        var builder = TestZipBuilder()
        if includeManifest {
            let manifest = try makeBuildManifestData(
                productVersion: productVersion,
                buildVersion: buildVersion,
                deviceIdentifiers: deviceIdentifiers,
                kernelCachePath: kernelCachePath
            )
            builder.addEntry(name: IPSWParser.buildManifestEntryName, data: manifest, compress: false)
        }
        builder.addEntry(name: "Restore.plist", data: Data("placeholder".utf8), compress: true)

        let url = tempDirectory.appendingPathComponent(fileName)
        try builder.build().write(to: url)
        return url
    }

    func testParsesReferenceFirmwareAsCompatible() throws {
        let url = try makeIPSW()
        let parsed = try IPSWParser.parse(fileURL: url)

        XCTAssertEqual(parsed.metadata.productVersion, ReferenceFirmware.productVersion)
        XCTAssertEqual(parsed.metadata.buildVersion, ReferenceFirmware.buildVersion)
        XCTAssertEqual(parsed.metadata.supportedDeviceIdentifiers, [ReferenceFirmware.device.identifier])
        XCTAssertEqual(parsed.compatibility, .compatible)
    }

    func testKernelCachePathIsNilWhenManifestDoesNotDeclareBuildIdentities() throws {
        let url = try makeIPSW() // default: no kernelCachePath / BuildIdentities
        let parsed = try IPSWParser.parse(fileURL: url)
        XCTAssertNil(parsed.metadata.kernelCachePath)
    }

    func testKernelCachePathIsReadFromBuildIdentitiesWhenPresent() throws {
        let url = try makeIPSW(kernelCachePath: "kernelcache.release.n81")
        let parsed = try IPSWParser.parse(fileURL: url)
        XCTAssertEqual(parsed.metadata.kernelCachePath, "kernelcache.release.n81")
    }

    func testReportsFileSize() throws {
        let url = try makeIPSW()
        let expectedSize = try Int64(XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int))

        let parsed = try IPSWParser.parse(fileURL: url)
        XCTAssertEqual(parsed.metadata.fileSizeBytes, expectedSize)
    }

    func testUnsupportedDeviceIsReportedNotThrown() throws {
        let url = try makeIPSW(deviceIdentifiers: ["iPhone3,1"])
        let parsed = try IPSWParser.parse(fileURL: url)
        XCTAssertEqual(parsed.compatibility, .unsupportedDevice)
    }

    func testUnsupportedVersionIsReportedNotThrown() throws {
        let url = try makeIPSW(productVersion: "7.0", buildVersion: "11A465")
        let parsed = try IPSWParser.parse(fileURL: url)
        XCTAssertEqual(parsed.compatibility, .unsupportedVersion)
    }

    func testMissingBuildManifestThrows() throws {
        let url = try makeIPSW(includeManifest: false)
        XCTAssertThrowsError(try IPSWParser.parse(fileURL: url)) { error in
            guard case FirmwareParsingError.missingEntry(let name) = error else {
                return XCTFail("Expected .missingEntry, got \(error)")
            }
            XCTAssertEqual(name, IPSWParser.buildManifestEntryName)
        }
    }

    func testCorruptBuildManifestThrows() throws {
        var builder = TestZipBuilder()
        builder.addEntry(name: IPSWParser.buildManifestEntryName, data: Data("not a plist".utf8), compress: false)
        let url = tempDirectory.appendingPathComponent("corrupt.ipsw")
        try builder.build().write(to: url)

        XCTAssertThrowsError(try IPSWParser.parse(fileURL: url)) { error in
            guard case FirmwareParsingError.corruptPropertyList = error else {
                return XCTFail("Expected .corruptPropertyList, got \(error)")
            }
        }
    }

    func testNonZipFileThrows() throws {
        let url = tempDirectory.appendingPathComponent("plain.ipsw")
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try IPSWParser.parse(fileURL: url))
    }
}
