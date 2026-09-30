import XCTest
@testable import Podium

final class PersistentGuestStorageTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var applicationSupportURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodiumStorageTests-\(UUID().uuidString)", isDirectory: true)
        applicationSupportURL = temporaryDirectory.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCreatesStablePersistentVolumeAndReportsHFSCapacity() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("imported-firmware.ipsw")
        try writeHFSImage(at: RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL), fill: 0x31, freeBlocks: 3)

        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let prepared = try storage.prepareUserVolume(forFirmwareAt: firmwareURL)
        let expectedURL = RootFilesystemPreparer.userImageURL(in: applicationSupportURL
            .appendingPathComponent("Podium/VirtualDevices/\(ReferenceFirmware.device.identifier)/\(ReferenceFirmware.buildVersion)",
                                   isDirectory: true))

        XCTAssertEqual(prepared.url, expectedURL)
        XCTAssertFalse(prepared.fromOlderRecipe)
        XCTAssertFalse(prepared.url.path.hasPrefix(temporaryDirectory.path + "/imported-firmware"))

        let snapshot = try XCTUnwrap(storage.snapshot())
        XCTAssertEqual(snapshot.totalBytes, 8 * 512)
        XCTAssertEqual(snapshot.freeBytes, 3 * 512)
        XCTAssertEqual(snapshot.usedBytes, 5 * 512)
    }

    func testMigratesLegacyImageWithoutLosingGuestChanges() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("old-install.ipsw")
        try writeHFSImage(at: RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL), fill: 0x31, freeBlocks: 3)
        let legacyURL = RootFilesystemPreparer.userImageURL(forFirmwareAt: firmwareURL)
        try writeHFSImage(at: legacyURL, fill: 0xA5, freeBlocks: 2)

        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let prepared = try storage.prepareUserVolume(forFirmwareAt: firmwareURL)

        XCTAssertTrue(prepared.fromOlderRecipe)
        XCTAssertEqual(try Data(contentsOf: prepared.url)[2048], 0xA5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try XCTUnwrap(storage.snapshot()).freeBytes, 2 * 512)
    }

    func testEraseRequiresPowerOffAndRestoresPreparedSystemImage() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("erase-test.ipsw")
        try writeHFSImage(at: RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL), fill: 0x31, freeBlocks: 3)
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let volumeURL = try storage.prepareUserVolume(forFirmwareAt: firmwareURL).url

        var changedVolume = try Data(contentsOf: volumeURL)
        changedVolume[2048] = 0xA5
        try changedVolume.write(to: volumeURL, options: .atomic)

        XCTAssertThrowsError(try storage.erase(forFirmwareAt: firmwareURL, emulatorIsPoweredOn: true))
        XCTAssertEqual(try Data(contentsOf: volumeURL)[2048], 0xA5, "a rejected erase must leave guest data unchanged")

        _ = try storage.erase(forFirmwareAt: firmwareURL, emulatorIsPoweredOn: false)
        XCTAssertEqual(try Data(contentsOf: volumeURL)[2048], 0x31)
        XCTAssertEqual(try XCTUnwrap(storage.snapshot()).freeBytes, 3 * 512)
    }

    func testPreservesExistingDurableImageWhileMigratingLegacyData() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("existing-image.ipsw")
        try writeHFSImage(at: RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL), fill: 0x31, freeBlocks: 3)
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let durableURL = try storage.prepareUserVolume(forFirmwareAt: firmwareURL).url

        var durable = try Data(contentsOf: durableURL)
        durable[2048] = 0x77
        try durable.write(to: durableURL, options: .atomic)
        let legacyURL = RootFilesystemPreparer.userImageURL(forFirmwareAt: firmwareURL)
        try writeHFSImage(at: legacyURL, fill: 0xA5, freeBlocks: 2)

        let importedURL = temporaryDirectory.appendingPathComponent("existing-image.ipsw")
        try Data("firmware".utf8).write(to: importedURL)
        var removedImportedFile = false
        try storage.removeFirmware(at: importedURL, emulatorIsBusy: false) {
            removedImportedFile = true
            try FileManager.default.removeItem(at: importedURL)
        }
        XCTAssertTrue(removedImportedFile)
        XCTAssertEqual(try Data(contentsOf: durableURL)[2048], 0x77)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedURL.path))
    }

    func testRejectsLegacyMigrationWhileFirmwareIsInUse() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("in-use.ipsw")
        let legacyURL = RootFilesystemPreparer.userImageURL(forFirmwareAt: firmwareURL)
        try writeHFSImage(at: legacyURL, fill: 0xA5, freeBlocks: 2)
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)

        XCTAssertThrowsError(try storage.removeFirmware(at: firmwareURL, emulatorIsBusy: true) {})
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testInterruptedReplacementRestoresTheLastCommittedImage() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("interrupted.ipsw")
        let preparedURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeHFSImage(at: preparedURL, fill: 0x31, freeBlocks: 3)
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let directory = applicationSupportURL
            .appendingPathComponent("Podium/VirtualDevices/\(ReferenceFirmware.device.identifier)/\(ReferenceFirmware.buildVersion)",
                                   isDirectory: true)
        let committedURL = try storage.prepareUserVolume(forFirmwareAt: firmwareURL).url
        let committed = try Data(contentsOf: committedURL)
        let backupURL = committedURL.appendingPathExtension("replacing")
        let markerURL = committedURL.appendingPathExtension("version")
        let backupMarkerURL = backupURL.appendingPathExtension("version")
        try FileManager.default.moveItem(at: committedURL, to: backupURL)
        try FileManager.default.moveItem(at: markerURL, to: backupMarkerURL)
        try writeHFSImage(at: committedURL, fill: 0xA5, freeBlocks: 2)

        let recovered = try storage.prepareUserVolume(forFirmwareAt: firmwareURL)
        XCTAssertFalse(recovered.fromOlderRecipe)
        XCTAssertEqual(try Data(contentsOf: recovered.url), committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupMarkerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRejectsInvalidHFSImageWithoutCreatingPersistentVolume() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("invalid.ipsw")
        let preparedURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try Data(repeating: 0, count: 4096).write(to: preparedURL)
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)

        XCTAssertThrowsError(try storage.prepareUserVolume(forFirmwareAt: firmwareURL))
        XCTAssertNil(try storage.snapshot())
    }

    private func writeHFSImage(at url: URL, fill: UInt8, freeBlocks: UInt32) throws {
        let blockSize: UInt32 = 512
        let totalBlocks: UInt32 = 8
        var bytes = [UInt8](repeating: fill, count: Int(blockSize * totalBlocks))
        let headerOffset = Int(HFSPlusVolumeHeader.offset)
        bytes[headerOffset] = UInt8(HFSPlusVolumeHeader.signatureHFSPlus >> 8)
        bytes[headerOffset + 1] = UInt8(HFSPlusVolumeHeader.signatureHFSPlus & 0xFF)
        putBigEndian(blockSize, into: &bytes, at: headerOffset + 40)
        putBigEndian(totalBlocks, into: &bytes, at: headerOffset + 44)
        putBigEndian(freeBlocks, into: &bytes, at: headerOffset + 48)
        try Data(bytes).write(to: url, options: .atomic)
    }

    private func putBigEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}
