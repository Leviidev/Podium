import Foundation

/// The virtual device's persistent HFS+ storage. The image lives outside the
/// imported firmware directory so deleting/reimporting an IPSW cannot erase
/// installed apps, preferences, or their data.
final class PersistentGuestStorage {
    struct Snapshot: Equatable {
        let totalBytes: UInt64
        let freeBytes: UInt64

        var usedBytes: UInt64 { totalBytes >= freeBytes ? totalBytes - freeBytes : 0 }
    }

    enum StorageError: LocalizedError, CustomStringConvertible {
        case appSupportUnavailable
        case notAnHFSVolume
        case deviceMustBePoweredOff
        case firmwareInUse
        case noFirmwareForErase
        case storageNotPrepared
        case invalidGuestFile(String)
        case duplicateGuestFile(String)
        case insufficientGuestSpace(required: UInt64, available: UInt64)
        case noFirmwareForPackageInstall
        case noCompatibleFirmwareForPackageInstall
        case noFirmwareForIPAInstall
        case noCompatibleFirmwareForIPAInstall

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .appSupportUnavailable: return "Podium couldn't locate its Application Support directory."
            case .notAnHFSVolume: return "The persistent guest disk isn't a valid HFS+ volume."
            case .deviceMustBePoweredOff: return "Power off the virtual iPod before erasing its contents."
            case .firmwareInUse: return "Power off the virtual iPod before removing its firmware."
            case .noFirmwareForErase: return "Import compatible firmware before erasing the virtual iPod."
            case .storageNotPrepared: return "Power on the virtual iPod once before adding files."
            case .invalidGuestFile: return "A selected item isn't a regular file name that can be stored on the virtual iPod."
            case .duplicateGuestFile: return "A selected filename is repeated or already exists in Media/Podium."
            case .insufficientGuestSpace: return "There isn't enough free space to add these files while keeping guest storage available."
            case .noFirmwareForPackageInstall: return "Import compatible iOS 6.1.6 firmware before installing packages."
            case .noCompatibleFirmwareForPackageInstall: return "Select compatible iOS 6.1.6 firmware before installing packages."
            case .noFirmwareForIPAInstall: return "Import compatible iOS 6.1.6 firmware before installing apps."
            case .noCompatibleFirmwareForIPAInstall: return "Select compatible iOS 6.1.6 firmware before installing apps."
            }
        }
    }

    private let fileManager: FileManager
    private let appSupportURL: URL?
    private let ioLock = NSLock()

    init(fileManager: FileManager = .default, appSupportURL: URL? = nil) {
        self.fileManager = fileManager
        self.appSupportURL = appSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// Build/device scoped location for the firmware `firmwareURL` is
    /// prepared from (matched against the validated reference builds). Keep
    /// this stable across imported IPSW UUIDs and filenames. Without a URL,
    /// the first validated build's directory is used for legacy callers
    /// that haven't got the active firmware handy.
    private func directoryURL(forFirmwareAt firmwareURL: URL? = nil) throws -> URL {
        guard let appSupportURL else { throw StorageError.appSupportUnavailable }
        var directory = appSupportURL
            .appendingPathComponent("Podium", isDirectory: true)
            .appendingPathComponent("VirtualDevices", isDirectory: true)
        if let firmwareURL,
           let manifestData = try? Data(contentsOf: firmwareURL),
           let manifest = try? PropertyListDecoder().decode(BuildManifestPlist.self, from: manifestData) {
            let reference = ReferenceFirmware.all.first {
                $0.buildVersion == manifest.productBuildVersion
            }
            if let reference {
                directory = directory
                    .appendingPathComponent(reference.device.identifier, isDirectory: true)
                    .appendingPathComponent(reference.buildVersion, isDirectory: true)
            }
        }
        return directory
    }

    func prepareUserVolume(forFirmwareAt firmwareURL: URL) throws -> (url: URL, fromOlderRecipe: Bool) {
        ioLock.lock()
        defer { ioLock.unlock() }
        let directory = try directoryURL(forFirmwareAt: firmwareURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let prepared = try RootFilesystemPreparer.prepareUserImage(forFirmwareAt: firmwareURL, in: directory)
        var fromOlderRecipe = prepared.fromOlderRecipe

        // A user volume made before a build gained (or lost) the 8 GiB md0
        // path has the wrong size for its build: iOS 7 sessions replay it
        // as a RAM disk and can't map it, and iOS 6 has no reason to keep a
        // RAM-disk-sized volume. The volume's recipe marker should already
        // catch this (it records the disk class too); the size check below
        // covers volumes promoted before that marker existed. Rebuilding
        // discards installed apps, tweaks, preferences, and guest files —
        // the same cost an owner accepted by erasing in Settings.
        let volumeMatchesSizing: Bool
        do {
            volumeMatchesSizing = try Self.volumeMatchesBuildSizing(prepared.url, firmwareURL: firmwareURL)
        } catch {
            volumeMatchesSizing = false
        }
        if fromOlderRecipe || !volumeMatchesSizing {
            fromOlderRecipe = true
            _ = try RootFilesystemPreparer.prepareUserImage(forFirmwareAt: firmwareURL, erasing: true, in: directory)
        }
        let imageHeader = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: prepared.url)
        guard imageHeader.signature == HFSPlusVolumeHeader.signatureHFSPlus || imageHeader.signature == HFSPlusVolumeHeader.signatureHFSX else {
            throw StorageError.notAnHFSVolume
        }
        return (url: prepared.url, fromOlderRecipe: fromOlderRecipe)
    }

    /// Whether the user image's volume size fits its build's boot path:
    /// md0-backed builds hold an 8 GiB volume, RAM-disk builds must fit in
    /// guest DRAM. An image of the wrong class can't be booted by whatever
    /// session would run this build.
    private static func volumeMatchesBuildSizing(_ imageURL: URL, firmwareURL: URL) throws -> Bool {
        let zip = try ZipArchiveReader(fileURL: firmwareURL)
        guard let entry = zip.entry(named: IPSWParser.buildManifestEntryName) else { return false }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try PropertyListSerialization.propertyList(from: try zip.data(for: entry), options: [], format: &format) as? [String: Any],
              let build = plist["ProductBuildVersion"] as? String else { return false }
        let header = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: imageURL)
        let volumeBytes = UInt64(header.blockSize) * UInt64(header.totalBlocks)
        let isBlockBackedSized = volumeBytes > GuestMemoryLayout.ramDiskMaximumBytes
        return isBlockBackedSized == GuestDiskBridge.supports(build: build)
    }

    func eraseActiveVolume(for firmwareURL: URL?, emulatorIsBusy: Bool) throws {
        guard !emulatorIsBusy else { throw StorageError.deviceMustBePoweredOff }
        guard let firmwareURL else { throw StorageError.noFirmwareForErase }
        _ = try erase(forFirmwareAt: firmwareURL, emulatorIsPoweredOn: false)
    }

    func removeFirmware(at firmwareURL: URL, emulatorIsBusy: Bool, removeImportedFile: () throws -> Void) throws {
        guard !emulatorIsBusy else { throw StorageError.firmwareInUse }
        ioLock.lock()
        defer { ioLock.unlock() }
        let legacy = RootFilesystemPreparer.userImageURL(forFirmwareAt: firmwareURL)
        if fileManager.fileExists(atPath: legacy.path) {
            let destination = try RootFilesystemPreparer.userImageURL(in: directoryURL(forFirmwareAt: firmwareURL))
            try RootFilesystemPreparer.migrateUserImage(from: legacy, to: destination)
            try removeImportedFile()
            try? fileManager.removeItem(at: legacy)
            try? fileManager.removeItem(at: legacy.appendingPathExtension("version"))
        } else {
            try removeImportedFile()
        }
    }

    /// Adds regular host files to a dedicated folder on the guest's persistent volume.
    /// All reads/writes happen with the emulator stopped; no host path is exposed to iOS.
    func addFiles(_ urls: [URL], emulatorIsBusy: Bool) throws {
        guard !emulatorIsBusy else { throw StorageError.deviceMustBePoweredOff }
        guard !urls.isEmpty else { return }
        ioLock.lock()
        defer { ioLock.unlock() }

        let imageURL = RootFilesystemPreparer.userImageURL(in: try directoryURL(forFirmwareAt: nil))
        guard fileManager.fileExists(atPath: imageURL.path) else { throw StorageError.storageNotPrepared }
        var selectedNames = Set<String>()
        var files: [RootFilesystemPreparer.GuestFile] = []
        var totalBytes: UInt64 = 0
        for url in urls {
            let name = url.lastPathComponent
            guard Self.isSafeGuestFileName(name), selectedNames.insert(name).inserted,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let fileSize = attributes[.size] as? NSNumber else {
                throw StorageError.invalidGuestFile(name)
            }
            let (nextBytes, overflow) = totalBytes.addingReportingOverflow(fileSize.uint64Value)
            guard !overflow else { throw StorageError.invalidGuestFile(name) }
            totalBytes = nextBytes
            files.append(.init(name: name, sourceURL: url, size: fileSize.uint64Value))
        }

        let header = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: imageURL)
        let freeBytes = UInt64(header.freeBlocks) * UInt64(header.blockSize)
        let guestReserve: UInt64 = 8 << 20
        let metadataReserve: UInt64 = 1 << 20
        let (required, overflow) = totalBytes.addingReportingOverflow(guestReserve + metadataReserve)
        guard !overflow, required <= freeBytes else {
            throw StorageError.insufficientGuestSpace(required: overflow ? .max : required, available: freeBytes)
        }

        let existing = try HFSPlusVolume(source: FileVolumeSource(url: imageURL))
        let existingBuilder = try RootFilesystemBuilder(volume: existing)
        for file in files where existingBuilder.contains("/private/var/mobile/Media/Podium/" + file.name) {
            throw StorageError.duplicateGuestFile(file.name)
        }
        try RootFilesystemPreparer.addGuestFiles(files, to: imageURL, keepingFreeSpace: guestReserve)
    }

    /// Installs Cydia-compatible Debian payloads directly into the
    /// persistent root volume. Packages with scripts, unsupported archive
    /// compression, conflicts, or unmet dependencies are rejected.
    func installDebianPackages(_ urls: [URL], forFirmwareAt firmwareURL: URL?, emulatorIsBusy: Bool) throws -> [DebianPackageInstaller.InstalledPackage] {
        guard !emulatorIsBusy else { throw StorageError.deviceMustBePoweredOff }
        guard let firmwareURL else { throw StorageError.noFirmwareForPackageInstall }
        guard RootFilesystemPreparer.isPrepared(forFirmwareAt: firmwareURL) else {
            throw StorageError.noCompatibleFirmwareForPackageInstall
        }
        guard !urls.isEmpty else { return [] }
        ioLock.lock()
        defer { ioLock.unlock() }
        let directory = try directoryURL(forFirmwareAt: firmwareURL)
        let imageURL = RootFilesystemPreparer.userImageURL(in: directory)
        guard fileManager.fileExists(atPath: imageURL.path) else { throw StorageError.storageNotPrepared }
        let staging = directory.appendingPathComponent("package-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        return try RootFilesystemPreparer.installDebianPackages(urls, to: imageURL, stagingDirectory: staging)
    }

    /// Copies basic .ipa app bundles into /Applications while the virtual iPod
    /// is powered off. The guest OS's installer, signing, and registration are not run.
    func installIPAs(_ urls: [URL], forFirmwareAt firmwareURL: URL?, emulatorIsBusy: Bool) throws -> [IPAInstaller.InstalledApp] {
        guard !emulatorIsBusy else { throw StorageError.deviceMustBePoweredOff }
        guard let firmwareURL else { throw StorageError.noFirmwareForIPAInstall }
        guard RootFilesystemPreparer.isPrepared(forFirmwareAt: firmwareURL) else {
            throw StorageError.noCompatibleFirmwareForIPAInstall
        }
        guard !urls.isEmpty else { return [] }
        ioLock.lock()
        defer { ioLock.unlock() }
        let directory = try directoryURL(forFirmwareAt: firmwareURL)
        let imageURL = RootFilesystemPreparer.userImageURL(in: directory)
        guard fileManager.fileExists(atPath: imageURL.path) else { throw StorageError.storageNotPrepared }
        let staging = directory.appendingPathComponent("ipa-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        return try RootFilesystemPreparer.installIPAs(urls, to: imageURL, stagingDirectory: staging)
    }

    static func isSafeGuestFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.unicodeScalars.contains(where: { $0.value == 0 }) && name.utf16.count <= 255
    }

    func snapshot(forFirmwareAt firmwareURL: URL? = nil) throws -> Snapshot? {
        ioLock.lock()
        defer { ioLock.unlock() }
        let imageURL = RootFilesystemPreparer.userImageURL(in: try directoryURL(forFirmwareAt: firmwareURL))
        guard fileManager.fileExists(atPath: imageURL.path) else { return nil }
        let header: HFSPlusVolumeHeader
        do {
            header = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: imageURL)
        } catch {
            throw StorageError.notAnHFSVolume
        }
        let blockSize = UInt64(header.blockSize)
        return Snapshot(totalBytes: UInt64(header.totalBlocks) * blockSize, freeBytes: UInt64(header.freeBlocks) * blockSize)
    }

    @discardableResult
    func erase(forFirmwareAt firmwareURL: URL, emulatorIsPoweredOn: Bool) throws -> (url: URL, fromOlderRecipe: Bool) {
        guard !emulatorIsPoweredOn else { throw StorageError.deviceMustBePoweredOff }
        ioLock.lock()
        defer { ioLock.unlock() }
        let directory = try directoryURL(forFirmwareAt: firmwareURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try RootFilesystemPreparer.prepareUserImage(forFirmwareAt: firmwareURL, erasing: true, in: directory)
    }
}
