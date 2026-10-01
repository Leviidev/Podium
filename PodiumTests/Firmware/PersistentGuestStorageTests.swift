import XCTest
import Compression
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

    func testAddingIPAArchivePreservesItInGuestStorage() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("guest-ipa.ipsw")
        try writeSyntheticHFSVolume(at: RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL))
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        let volumeURL = try storage.prepareUserVolume(forFirmwareAt: firmwareURL).url

        var archive = TestZipBuilder()
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.podiumtest",
            "CFBundleExecutable": "PodiumTest",
        ], format: .xml, options: 0)
        archive.addEntry(name: "Payload/PodiumTest.app/Info.plist", data: info, compress: true)
        archive.addEntry(name: "Payload/PodiumTest.app/PodiumTest", data: Data([0xCF, 0xFA, 0xED, 0xFE]), compress: false)
        let ipaBytes = archive.build()
        let hostIPA = temporaryDirectory.appendingPathComponent("PodiumTest.ipa")
        try ipaBytes.write(to: hostIPA)

        try storage.addFiles([hostIPA], emulatorIsBusy: false)

        let volume = try HFSPlusVolume(source: FileVolumeSource(url: volumeURL))
        let builder = try RootFilesystemBuilder(volume: volume)
        let deliveredIPA = Data(try builder.contents(of: "/private/var/mobile/Media/Podium/PodiumTest.ipa"))
        XCTAssertEqual(deliveredIPA, ipaBytes, "the persistent guest disk must retain the complete IPA archive for a future guest installer")
        let extractedArchive = temporaryDirectory.appendingPathComponent("delivered.ipa")
        try deliveredIPA.write(to: extractedArchive)
        let reader = try ZipArchiveReader(fileURL: extractedArchive)
        XCTAssertNotNil(reader.entry(named: "Payload/PodiumTest.app/Info.plist"))
        XCTAssertNotNil(reader.entry(named: "Payload/PodiumTest.app/PodiumTest"))
        XCTAssertThrowsError(try storage.addFiles([hostIPA], emulatorIsBusy: false), "re-importing the same filename must not overwrite guest data")
    }

    func testInstallingIPAExtractsAppBundleIntoApplicationsTransactionally() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("install-ipa.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let original = try Data(contentsOf: imageURL)
        let ipaURL = temporaryDirectory.appendingPathComponent("PodiumTest.ipa")
        try makeIPAArchive().write(to: ipaURL)
        let staging = temporaryDirectory.appendingPathComponent("ipa-stage", isDirectory: true)

        let apps = try RootFilesystemPreparer.installIPAs([ipaURL], to: imageURL, stagingDirectory: staging)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "IPA staging must live until the volume writer consumes the extracted files")
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "PodiumTest.app")
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.example.podiumtest")
        XCTAssertGreaterThan(apps.first?.payloadBytes ?? 0, 0)
        XCTAssertNotEqual(try Data(contentsOf: imageURL), original)
        let volume = try HFSPlusVolume(source: FileVolumeSource(url: imageURL))
        let builder = try RootFilesystemBuilder(volume: volume)
        XCTAssertTrue(builder.isFolder(at: "/Applications/PodiumTest.app"))
        XCTAssertEqual(Data(try builder.contents(of: "/Applications/PodiumTest.app/PodiumTest")), Data([0xCF, 0xFA, 0xED, 0xFE]))
        let info = try PropertyListSerialization.propertyList(
            from: Data(try builder.contents(of: "/Applications/PodiumTest.app/Info.plist")), format: nil
        ) as? [String: String]
        XCTAssertEqual(info?["CFBundleIdentifier"], "com.example.podiumtest")
        XCTAssertGreaterThanOrEqual(try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: imageURL).freeBlocks * 512, 8 << 20)

        let committed = try Data(contentsOf: imageURL)
        XCTAssertThrowsError(try RootFilesystemPreparer.installIPAs([ipaURL], to: imageURL, stagingDirectory: staging)) { error in
            guard case IPAInstaller.InstallError.alreadyInstalled = error else {
                return XCTFail("Expected duplicate app rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: imageURL), committed, "rejecting a duplicate IPA must preserve the installed volume")
    }

    func testIPAInstallerRejectsTraversalMultipleAppsMissingExecutableAndCorruptPayload() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("reject-ipa.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let original = try Data(contentsOf: imageURL)
        let staging = temporaryDirectory.appendingPathComponent("reject-ipa-stage", isDirectory: true)
        var traversal = TestZipBuilder()
        traversal.addEntry(name: "Payload/PodiumTest.app/Info.plist", data: try ipaInfoPlist())
        traversal.addEntry(name: "Payload/PodiumTest.app/../../outside", data: Data("no".utf8))
        let additionalInfo = try ipaInfoPlist()
        let multipleApps = try makeIPAArchive(extraEntries: [
            ("Payload/Other.app/Info.plist", additionalInfo),
            ("Payload/Other.app/Other", Data([1, 2, 3])),
        ])
        let missingExecutable = try makeIPAArchive(includeExecutable: false)
        var corrupt = TestZipBuilder()
        let infoData = try ipaInfoPlist()
        corrupt.addEntry(name: "Payload/PodiumTest.app/Info.plist", data: infoData)
        corrupt.addEntry(name: "Payload/PodiumTest.app/PodiumTest", data: Data([0xCF, 0xFA, 0xED, 0xFE]))
        var corruptData = corrupt.build()
        let executableOffset = 30 + "Payload/PodiumTest.app/Info.plist".utf8.count + infoData.count
            + 30 + "Payload/PodiumTest.app/PodiumTest".utf8.count
        corruptData[executableOffset] ^= 0x01

        for (name, bytes) in [("traversal", traversal.build()), ("multiple", multipleApps),
                              ("missing-executable", missingExecutable), ("corrupt", corruptData)] {
            let ipaURL = temporaryDirectory.appendingPathComponent(name + ".ipa")
            try bytes.write(to: ipaURL)
            XCTAssertThrowsError(try RootFilesystemPreparer.installIPAs([ipaURL], to: imageURL, stagingDirectory: staging), name) { error in
                guard error is IPAInstaller.InstallError else {
                    return XCTFail("Expected an IPA validation error, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: imageURL), original, "\(name) IPA must not change guest storage")
        }
    }

    func testOfflineDebianPackageInstallWritesPayloadAndPersistentDpkgRecords() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("offline-deb.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let original = try Data(contentsOf: imageURL)
        let packageURL = try makeDebPackage(name: "com.example.offline", version: "1.2-1", files: [
            .file(path: "usr/lib/podium/offline.txt", contents: Data("installed offline".utf8), mode: 0o644),
            .file(path: "usr/bin/podium-tool", contents: Data("binary".utf8), mode: 0o755),
        ])

        let stagingDirectory = temporaryDirectory.appendingPathComponent("deb-stage", isDirectory: true)
        let installed = try RootFilesystemPreparer.installDebianPackages(
            [packageURL], to: imageURL, stagingDirectory: stagingDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path), "package staging must be removed after the rebuilt volume has consumed its payloads")
        XCTAssertEqual(installed.map(\.name), ["com.example.offline"])
        XCTAssertEqual(installed.first?.version, "1.2-1")
        XCTAssertEqual(installed.first?.payloadBytes, UInt64("installed offline".utf8.count + "binary".utf8.count))
        XCTAssertNotEqual(try Data(contentsOf: imageURL), original)
        let volume = try HFSPlusVolume(source: FileVolumeSource(url: imageURL))
        let builder = try RootFilesystemBuilder(volume: volume)
        XCTAssertEqual(Data(try builder.contents(of: "/usr/lib/podium/offline.txt")), Data("installed offline".utf8))
        XCTAssertEqual(Data(try builder.contents(of: "/usr/bin/podium-tool")), Data("binary".utf8))
        let status = String(decoding: try builder.contents(of: "/var/lib/dpkg/status"), as: UTF8.self)
        XCTAssertTrue(status.contains("Package: com.example.offline"))
        XCTAssertTrue(status.contains("Status: install ok installed"))
        XCTAssertTrue(status.contains("Version: 1.2-1"))
        XCTAssertEqual(String(decoding: try builder.contents(of: "/var/lib/dpkg/info/com.example.offline.list"), as: UTF8.self),
                       "/usr/bin/podium-tool\n/usr/lib/podium/offline.txt\n")
        XCTAssertGreaterThanOrEqual(try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: imageURL).freeBlocks * 512, 8 << 20)
    }

    func testGuestPathResolverFollowsAbsoluteAndRelativeSymlinksSafely() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("symlink-paths.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let volume = try HFSPlusVolume(source: FileVolumeSource(url: imageURL))
        let builder = try RootFilesystemBuilder(volume: volume)

        try builder.addSymbolicLink("/var", target: "/private/var", owner: 0, group: 0, template: "/private/etc/fstab")
        try builder.addSymbolicLink("/private/var/etc-alias", target: "../etc", owner: 0, group: 0, template: "/private/etc/fstab")
        try builder.addSymbolicLink("/private/var/escape", target: "../../../../etc", owner: 0, group: 0, template: "/private/etc/fstab")

        XCTAssertEqual(try builder.resolvedPath("/var/lib/dpkg", resolvingFinalComponent: false), "/private/var/lib/dpkg")
        XCTAssertEqual(try builder.resolvedPath("/private/var/etc-alias/fstab"), "/private/etc/fstab")
        XCTAssertThrowsError(try builder.resolvedPath("/private/var/escape/fstab"))
    }

    func testOfflineDebianInstallRejectsScriptsDependenciesAndTraversalWithoutChangingVolume() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("reject-deb.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let original = try Data(contentsOf: imageURL)
        let stage = temporaryDirectory.appendingPathComponent("reject-stage", isDirectory: true)

        let scriptPackage = try makeDebPackage(name: "com.example.script", version: "1", script: "postinst", files: [
            .file(path: "usr/lib/script.txt", contents: Data("no".utf8), mode: 0o644),
        ])
        XCTAssertThrowsError(try RootFilesystemPreparer.installDebianPackages([scriptPackage], to: imageURL, stagingDirectory: stage)) { error in
            guard case DebianPackageInstaller.PackageError.unsupported = error else {
                return XCTFail("Expected maintainer script rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: imageURL), original)

        let dependencyPackage = try makeDebPackage(name: "com.example.needs-base", version: "1", depends: "com.example.missing (>= 1)", files: [
            .file(path: "usr/lib/dependency.txt", contents: Data("no".utf8), mode: 0o644),
        ])
        XCTAssertThrowsError(try RootFilesystemPreparer.installDebianPackages([dependencyPackage], to: imageURL, stagingDirectory: stage)) { error in
            guard case DebianPackageInstaller.PackageError.missingDependency = error else {
                return XCTFail("Expected missing dependency rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: imageURL), original)

        let traversalPackage = try makeDebPackage(name: "com.example.traversal", version: "1", files: [
            .file(path: "../outside.txt", contents: Data("no".utf8), mode: 0o644),
        ])
        XCTAssertThrowsError(try RootFilesystemPreparer.installDebianPackages([traversalPackage], to: imageURL, stagingDirectory: stage)) { error in
            guard case DebianPackageInstaller.PackageError.unsafePath = error else {
                return XCTFail("Expected unsafe path rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: imageURL), original)
    }

    func testOfflineDebianInstallSupportsGzipArchivesAndDirectories() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("gzip-deb.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let packageURL = try makeDebPackage(name: "com.example.gzip", version: "2", gzip: true, files: [
            .directory(path: "usr/share/podium", mode: 0o755),
            .file(path: "usr/share/podium/gzip.txt", contents: Data("compressed data".utf8), mode: 0o644),
        ])

        _ = try RootFilesystemPreparer.installDebianPackages(
            [packageURL], to: imageURL,
            stagingDirectory: temporaryDirectory.appendingPathComponent("gzip-stage", isDirectory: true)
        )
        let volume = try HFSPlusVolume(source: FileVolumeSource(url: imageURL))
        let builder = try RootFilesystemBuilder(volume: volume)
        XCTAssertTrue(builder.isFolder(at: "/usr/share/podium"))
        XCTAssertEqual(Data(try builder.contents(of: "/usr/share/podium/gzip.txt")), Data("compressed data".utf8))
    }

    func testOfflineDebianInstallRejectsPackageMutationOfDpkgDatabase() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("dpkg-deb.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let original = try Data(contentsOf: imageURL)
        let packageURL = try makeDebPackage(name: "com.example.forged", version: "1", files: [
            .file(path: "var/lib/dpkg/status", contents: Data("forged".utf8), mode: 0o644),
        ])
        XCTAssertThrowsError(try RootFilesystemPreparer.installDebianPackages(
            [packageURL], to: imageURL,
            stagingDirectory: temporaryDirectory.appendingPathComponent("dpkg-stage", isDirectory: true)
        ))
        XCTAssertEqual(try Data(contentsOf: imageURL), original)
    }

    func testOfflineDebianInstallRejectsMalformedAndDuplicatePackages() throws {
        let firmwareURL = temporaryDirectory.appendingPathComponent("malformed-deb.ipsw")
        let imageURL = RootFilesystemPreparer.imageURL(forFirmwareAt: firmwareURL)
        try writeSyntheticHFSVolume(at: imageURL)
        let stage = temporaryDirectory.appendingPathComponent("malformed-stage", isDirectory: true)
        let malformed = temporaryDirectory.appendingPathComponent("malformed.deb")
        try Data("not an ar archive".utf8).write(to: malformed)
        XCTAssertThrowsError(try RootFilesystemPreparer.installDebianPackages([malformed], to: imageURL, stagingDirectory: stage)) { error in
            guard case DebianPackageInstaller.PackageError.invalidArchive = error else {
                return XCTFail("Expected malformed ar rejection, got \(error)")
            }
        }

        let package = try makeDebPackage(name: "com.example.once", version: "1", files: [
            .file(path: "usr/lib/once.txt", contents: Data("one".utf8), mode: 0o644),
        ])
        _ = try RootFilesystemPreparer.installDebianPackages([package], to: imageURL, stagingDirectory: stage)
        XCTAssertThrowsError(try RootFilesystemPreparer.installDebianPackages([package], to: imageURL, stagingDirectory: stage)) { error in
            guard case DebianPackageInstaller.PackageError.duplicatePackage = error else {
                return XCTFail("Expected duplicate package rejection, got \(error)")
            }
        }
    }

    func testAddingGuestFilesRequiresPowerOffAndExistingPreparedStorage() throws {
        let storage = PersistentGuestStorage(appSupportURL: applicationSupportURL)
        XCTAssertThrowsError(try storage.addFiles([temporaryDirectory], emulatorIsBusy: true))
        XCTAssertThrowsError(try storage.addFiles([temporaryDirectory], emulatorIsBusy: false))
    }

    private func makeIPAArchive(appName: String = "PodiumTest", bundleIdentifier: String = "com.example.podiumtest",
                                includeExecutable: Bool = true, extraEntries: [(String, Data)] = []) throws -> Data {
        var archive = TestZipBuilder()
        archive.addEntry(name: "Payload/\(appName).app/Info.plist", data: try ipaInfoPlist(bundleIdentifier: bundleIdentifier), compress: true)
        if includeExecutable {
            archive.addEntry(name: "Payload/\(appName).app/\(appName)", data: Data([0xCF, 0xFA, 0xED, 0xFE]))
        }
        for (name, contents) in extraEntries { archive.addEntry(name: name, data: contents) }
        return archive.build()
    }

    private func ipaInfoPlist(bundleIdentifier: String = "com.example.podiumtest") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "PodiumTest",
        ], format: .xml, options: 0)
    }

    private enum DebTarEntry {
        case file(path: String, contents: Data, mode: UInt16)
        case directory(path: String, mode: UInt16)
        case symlink(path: String, target: String)
    }

    private func makeDebPackage(name: String, version: String, depends: String? = nil, script: String? = nil,
                                gzip: Bool = false, files: [DebTarEntry]) throws -> URL {
        let controlURL = temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString)")
        let controlPath = "Package: \(name)\nVersion: \(version)\nArchitecture: iphoneos-arm\n"
            + (depends.map { "Depends: \($0)\n" } ?? "")
            + "Description: Synthetic offline package\n"
        var controlEntries: [DebTarEntry] = [.file(path: "control", contents: Data(controlPath.utf8), mode: 0o644)]
        if let script { controlEntries.append(.file(path: script, contents: Data("#!/bin/sh\nexit 0\n".utf8), mode: 0o755)) }
        let controlTar = makeTar(controlEntries)
        let dataTar = makeTar(files)
        var archive = Data("!<arch>\n".utf8)
        appendArMember("debian-binary", contents: Data("2.0\n".utf8), to: &archive)
        appendArMember(gzip ? "control.tar.gz" : "control.tar", contents: gzip ? makeGzip(controlTar) : controlTar, to: &archive)
        appendArMember(gzip ? "data.tar.gz" : "data.tar", contents: gzip ? makeGzip(dataTar) : dataTar, to: &archive)
        try archive.write(to: controlURL)
        return controlURL
    }

    private func makeTar(_ entries: [DebTarEntry]) -> Data {
        var result = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            let path: String
            let mode: UInt16
            let owner: UInt32 = 0
            let group: UInt32 = 0
            let type: UInt8
            let target: String
            let contents: Data
            switch entry {
            case .file(let filePath, let data, let fileMode):
                path = filePath; mode = fileMode; type = 0x30; target = ""; contents = data
            case .directory(let directoryPath, let directoryMode):
                path = directoryPath; mode = directoryMode; type = 0x35; target = ""; contents = Data()
            case .symlink(let linkPath, let linkTarget):
                path = linkPath; mode = 0o777; type = 0x32; target = linkTarget; contents = Data()
            }
            writeTarString(path, into: &header, at: 0, count: 100)
            writeTarOctal(UInt64(mode), into: &header, at: 100, count: 8)
            writeTarOctal(UInt64(owner), into: &header, at: 108, count: 8)
            writeTarOctal(UInt64(group), into: &header, at: 116, count: 8)
            writeTarOctal(UInt64(contents.count), into: &header, at: 124, count: 12)
            writeTarOctal(0, into: &header, at: 136, count: 12)
            for index in 148..<156 { header[index] = 32 }
            header[156] = type
            writeTarString(target, into: &header, at: 157, count: 100)
            writeTarString("ustar", into: &header, at: 257, count: 6)
            header[262] = 0
            header[263] = 0x30
            header[264] = 0x30
            writeTarOctal(0, into: &header, at: 329, count: 8)
            writeTarOctal(0, into: &header, at: 337, count: 8)
            let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
            writeTarOctal(checksum, into: &header, at: 148, count: 6)
            header[154] = 0
            header[155] = 32
            result.append(contentsOf: header)
            result.append(contentsOf: contents)
            let padding = (512 - contents.count % 512) % 512
            if padding > 0 { result.append(Data(repeating: 0, count: padding)) }
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }

    private func makeGzip(_ data: Data) -> Data {
        var compressed = Data(count: data.count + max(256, data.count / 100 + 64))
        let compressedCount = compressed.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(outputBase, output.count, inputBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(compressedCount > 0, "fixture compression buffer must fit")
        compressed.removeSubrange(compressedCount..<compressed.count)
        var gzip = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 255])
        gzip.append(compressed)
        appendLittleEndian(crc32(data), to: &gzip)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &gzip)
        return gzip
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private func appendArMember(_ name: String, contents: Data, to archive: inout Data) {
        let nameField = (name + "/").padding(toLength: 16, withPad: " ", startingAt: 0)
        let timestamp = "0".padding(toLength: 12, withPad: " ", startingAt: 0)
        let owner = "0".padding(toLength: 6, withPad: " ", startingAt: 0)
        let group = "0".padding(toLength: 6, withPad: " ", startingAt: 0)
        let mode = "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
        let size = String(contents.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        archive.append(Data((nameField + timestamp + owner + group + mode + size + "`\n").utf8))
        archive.append(contents)
        if contents.count & 1 != 0 { archive.append(0x0A) }
    }

    private func writeTarString(_ string: String, into bytes: inout [UInt8], at offset: Int, count: Int) {
        for (index, byte) in string.utf8.prefix(count).enumerated() { bytes[offset + index] = byte }
    }

    private func writeTarOctal(_ value: UInt64, into bytes: inout [UInt8], at offset: Int, count: Int) {
        let raw = String(value, radix: 8)
        let encoded = String(repeating: "0", count: max(0, count - 1 - raw.count)) + raw
        writeTarString(encoded, into: &bytes, at: offset, count: count - 1)
        bytes[offset + count - 1] = 0
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

        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
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
