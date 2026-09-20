import XCTest
@testable import Podium

final class DeviceCompatibilityTests: XCTestCase {
    private func metadata(
        productVersion: String = ReferenceFirmware.productVersion,
        buildVersion: String = ReferenceFirmware.buildVersion,
        deviceIdentifiers: [String] = [ReferenceFirmware.device.identifier]
    ) -> FirmwareMetadata {
        FirmwareMetadata(
            supportedDeviceIdentifiers: deviceIdentifiers,
            productVersion: productVersion,
            buildVersion: buildVersion,
            fileSizeBytes: 123,
            originalFileName: "test.ipsw"
        )
    }

    func testExactReferenceFirmwareIsCompatible() {
        let result = FirmwareCompatibilityChecker.evaluate(metadata())
        XCTAssertEqual(result, .compatible)
    }

    func testUnknownDeviceIsUnsupportedDevice() {
        let result = FirmwareCompatibilityChecker.evaluate(metadata(deviceIdentifiers: ["iPad2,1"]))
        XCTAssertEqual(result, .unsupportedDevice)
    }

    func testKnownDeviceWrongVersionIsUnsupportedVersion() {
        let result = FirmwareCompatibilityChecker.evaluate(metadata(productVersion: "6.1.3", buildVersion: "10B329"))
        XCTAssertEqual(result, .unsupportedVersion)
    }

    func testKnownDeviceRightVersionWrongBuildIsUnsupportedVersion() {
        // Guards against trusting ProductVersion alone: a mismatched build
        // for an otherwise-matching version string must still be rejected.
        let result = FirmwareCompatibilityChecker.evaluate(metadata(buildVersion: "10B999"))
        XCTAssertEqual(result, .unsupportedVersion)
    }

    func testMultiDeviceManifestMatchesIfReferenceDeviceIsListed() {
        let result = FirmwareCompatibilityChecker.evaluate(
            metadata(deviceIdentifiers: ["iPod4,1", "iPhone3,1"])
        )
        XCTAssertEqual(result, .compatible)
    }

    func testEmptyDeviceListIsUnsupportedDevice() {
        let result = FirmwareCompatibilityChecker.evaluate(metadata(deviceIdentifiers: []))
        XCTAssertEqual(result, .unsupportedDevice)
    }
}
