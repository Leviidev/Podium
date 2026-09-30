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

    func testGuestFileNamesCannotEscapeTheDedicatedMediaFolder() {
        XCTAssertTrue(PersistentGuestStorage.isSafeGuestFileName("notes.txt"))
        XCTAssertTrue(PersistentGuestStorage.isSafeGuestFileName("Calendar.sqlite"))
        XCTAssertFalse(PersistentGuestStorage.isSafeGuestFileName("../outside"))
        XCTAssertFalse(PersistentGuestStorage.isSafeGuestFileName("subfolder/file"))
        XCTAssertFalse(PersistentGuestStorage.isSafeGuestFileName(""))
        XCTAssertFalse(PersistentGuestStorage.isSafeGuestFileName(String(repeating: "x", count: 256)))
    }

    func testAddingGuestFileRebuildsTheVolumeAndPreservesTheOriginalImage() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("guest-file.ipsw")
        try writeSyntheticHFSVolume(at: RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL))
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let volumeURL = try storage.prepareUserVolume(forFirmwareAt: firmwareURL).url
        let originalImage = try Data(contentsOf: volumeURL)
        let hostFile = temporaryDirectory.appendingPathComponent("hello.txt")
        let guestBytes = Data("hello from the host".utf8)
        try guestBytes.write(to: hostFile)

        try storage.addFiles([hostFile], emulatorIsBusy: false)

        let volume = try HFSPlusVolume(source: FileVolumeSource(url: volumeURL))
        let builder = try RootFilesystemBuilder(volume: volume)
        XCTAssertEqual(Data(try builder.contents(of: "/private/var/mobile/Media/Podium/hello.txt")), guestBytes)
        XCTAssertNotEqual(try Data(contentsOf: volumeURL), originalImage)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(storage.snapshot()).freeBytes, 8 << 20)
    }

    func testAddingGuestFilesRequiresPowerOffAndExistingPreparedStorage() throws {
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        XCTAssertThrowsError(try storage.addFiles([temporaryDirectory], emulatorIsBusy: true))
        XCTAssertThrowsError(try storage.addFiles([temporaryDirectory], emulatorIsBusy: false))
    }

    private func writeSyntheticHFSVolume(at url: URL) throws {
        let blockSize: UInt32 = 512
        let totalBlocks: UInt32 = 65_536
        let volumeBytes = UInt64(blockSize) * UInt64(totalBlocks)
        let root = HFSPlusCatalogRecord(parentID: 1, name: [], data: folderRecordData(id: 2))
        let privateFolder = HFSPlusCatalogRecord(parentID: 2, name: Array("private".utf16), data: folderRecordData(id: 3))
        let varFolder = HFSPlusCatalogRecord(parentID: 3, name: Array("var".utf16), data: folderRecordData(id: 4))
        let mobileFolder = HFSPlusCatalogRecord(parentID: 4, name: Array("mobile".utf16), data: folderRecordData(id: 5))
        let etcFolder = HFSPlusCatalogRecord(parentID: 3, name: Array("etc".utf16), data: folderRecordData(id: 6))
        var fstabData = [UInt8](repeating: 0, count: 248)
        putBigEndian(UInt16(HFSPlusCatalogRecord.fileType), into: &fstabData, at: 0)
        putBigEndian(UInt16(0x0002), into: &fstabData, at: 2)
        putBigEndian(UInt32(7), into: &fstabData, at: 8)
        putBigEndian(UInt32(0o100644), into: &fstabData, at: 42)
        HFSPlusForkData.contiguous(logicalSize: 8, startBlock: 20, blockCount: 1).write(into: &fstabData, at: 88)
        let fstab = HFSPlusCatalogRecord(parentID: 6, name: Array("fstab".utf16), data: fstabData)
        let items = [root, privateFolder, varFolder, mobileFolder, etcFolder, fstab]
        let catalog = items.flatMap { [$0, HFSPlusCatalogRecord.thread(for: $0)] }
            .sorted(by: HFSPlusCatalogRecord.areInIncreasingOrder)
            .map { BTreeRecord(key: $0.key, data: $0.data) }
        let btreeHeader = BTreeHeader(nodeSize: 512, maxKeyLength: 516, clumpSize: 512,
                                      btreeType: 0, keyCompareType: 0, attributes: BTreeBuilder.variableIndexKeysAttribute)
        let catalogBytes = try BTreeBuilder.build(records: catalog, header: btreeHeader, totalNodes: 16)
        let extentsBytes = try BTreeBuilder.build(records: [], header: btreeHeader, totalNodes: 1)

        var headerBytes = [UInt8](repeating: 0, count: HFSPlusVolumeHeader.byteCount)
        putBigEndian(HFSPlusVolumeHeader.signatureHFSPlus, into: &headerBytes, at: 0)
        putBigEndian(blockSize, into: &headerBytes, at: 40)
        putBigEndian(totalBlocks, into: &headerBytes, at: 44)
        putBigEndian(totalBlocks - 32, into: &headerBytes, at: 48)
        putBigEndian(UInt32(8), into: &headerBytes, at: 64)
        HFSPlusForkData.contiguous(logicalSize: UInt64(extentsBytes.count), startBlock: 3, blockCount: 1)
            .write(into: &headerBytes, at: 192)
        HFSPlusForkData.contiguous(logicalSize: UInt64(catalogBytes.count), startBlock: 4,
                                   blockCount: UInt32(catalogBytes.count / Int(blockSize)))
            .write(into: &headerBytes, at: 272)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: volumeBytes)
        try handle.seek(toOffset: 3 * UInt64(blockSize))
        try handle.write(contentsOf: Data(extentsBytes))
        try handle.seek(toOffset: 4 * UInt64(blockSize))
        try handle.write(contentsOf: Data(catalogBytes))
        try handle.seek(toOffset: 20 * UInt64(blockSize))
        try handle.write(contentsOf: Data("fstab!!!".utf8))
        try handle.seek(toOffset: HFSPlusVolumeHeader.offset)
        try handle.write(contentsOf: Data(headerBytes))
        try handle.seek(toOffset: volumeBytes - HFSPlusVolumeHeader.offset)
        try handle.write(contentsOf: Data(headerBytes))
        try handle.synchronize()
    }

    private func folderRecordData(id: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 88)
        putBigEndian(UInt16(HFSPlusCatalogRecord.folderType), into: &data, at: 0)
        putBigEndian(id, into: &data, at: 8)
        putBigEndian(UInt32(501), into: &data, at: 32)
        putBigEndian(UInt32(501), into: &data, at: 36)
        putBigEndian(UInt16(0o040755), into: &data, at: 42)
        return data
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

    private func putBigEndian(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private func putBigEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}
