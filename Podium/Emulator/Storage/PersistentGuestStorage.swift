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

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .appSupportUnavailable: return "Podium couldn't locate its Application Support directory."
            case .notAnHFSVolume: return "The persistent guest disk isn't a valid HFS+ volume."
            case .deviceMustBePoweredOff: return "Power off the virtual iPod before erasing its contents."
            case .firmwareInUse: return "Power off the virtual iPod before removing its firmware."
            case .noFirmwareForErase: return "Import compatible firmware before erasing the virtual iPod."
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

    /// Build/device scoped location, currently only `iPod4,1` / `10B500` is
    /// compatible. Keep this stable across imported IPSW UUIDs and filenames.
    private func directoryURL() throws -> URL {
        guard let appSupportURL else { throw StorageError.appSupportUnavailable }
        return appSupportURL
            .appendingPathComponent("Podium", isDirectory: true)
            .appendingPathComponent("VirtualDevices", isDirectory: true)
            .appendingPathComponent(ReferenceFirmware.device.identifier, isDirectory: true)
            .appendingPathComponent(ReferenceFirmware.buildVersion, isDirectory: true)
    }

    func prepareUserVolume(forFirmwareAt firmwareURL: URL) throws -> (url: URL, fromOlderRecipe: Bool) {
        ioLock.lock()
        defer { ioLock.unlock() }
        let directory = try directoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let prepared = try RootFilesystemPreparer.prepareUserImage(forFirmwareAt: firmwareURL, in: directory)
        let imageHeader = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: prepared.url)
        guard imageHeader.signature == HFSPlusVolumeHeader.signatureHFSPlus || imageHeader.signature == HFSPlusVolumeHeader.signatureHFSX else {
            throw StorageError.notAnHFSVolume
        }
        return prepared
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
            let destination = try RootFilesystemPreparer.userImageURL(in: directoryURL())
            try RootFilesystemPreparer.migrateUserImage(from: legacy, to: destination)
            try removeImportedFile()
            try? fileManager.removeItem(at: legacy)
            try? fileManager.removeItem(at: legacy.appendingPathExtension("version"))
        } else {
            try removeImportedFile()
        }
    }

    func snapshot() throws -> Snapshot? {
        ioLock.lock()
        defer { ioLock.unlock() }
        let imageURL = RootFilesystemPreparer.userImageURL(in: try directoryURL())
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
        let directory = try directoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try RootFilesystemPreparer.prepareUserImage(forFirmwareAt: firmwareURL, erasing: true, in: directory)
    }
}
