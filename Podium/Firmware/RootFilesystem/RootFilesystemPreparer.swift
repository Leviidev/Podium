import Foundation
import Darwin

/// Produces the root filesystem image the emulator boots from, straight
/// from the imported IPSW, once:
///
/// 1. stream the root filesystem DMG out of the IPSW (a deflated ZIP
///    entry), decrypting it (`encrcdsa`, the published key for this one
///    reference firmware) into a temporary file;
/// 2. read its HFSX partition, apply `RootFilesystemRecipe`, and write a
///    new, packed volume sized to fit in guest RAM as a RAM disk.
///
/// The prepared system image stays next to the IPSW with a version marker;
/// the persistent user image is owned by the app's support store.
enum RootFilesystemPreparer {
    enum Phase: Equatable {
        case extracting
        case building
    }

    struct Progress: Equatable {
        let phase: Phase
        /// 0...1 within the phase.
        let fraction: Double
    }

    enum PreparationError: Error, CustomStringConvertible {
        case wrongFirmware(String)
        case missingRootFilesystem
        case incompleteDecryption
        case invalidHFSImage(String)

        var description: String {
            switch self {
            case .wrongFirmware(let build): return "root filesystem preparation only supports iOS 6.1.6 (10B500); this is \(build)"
            case .missingRootFilesystem: return "the IPSW has no root filesystem image"
            case .incompleteDecryption: return "the root filesystem image ended early"
            case .invalidHFSImage(let detail): return "invalid HFS+ disk image: \(detail)"
            }
        }
    }

    static let referenceBuild = "10B500"

    static func imageURL(forFirmwareAt ipswURL: URL) -> URL {
        ipswURL.deletingPathExtension().appendingPathExtension("rootfs.hfs")
    }

    /// Stable user-volume location in Application Support; independent of
    /// the imported IPSW's generated filename and lifetime.
    static func userImageURL(in directory: URL) -> URL {
        directory.appendingPathComponent("user.hfs")
    }

    /// Legacy path retained for the standalone trace and old installations.
    static func userImageURL(forFirmwareAt ipswURL: URL) -> URL {
        ipswURL.deletingPathExtension().appendingPathExtension("user.hfs")
    }

    /// Creates the persistent volume once. `erasing` explicitly discards
    /// its installed apps, tweaks, preferences, and guest files.
    @discardableResult
    static func prepareUserImage(forFirmwareAt ipswURL: URL, erasing: Bool = false,
                                 in directory: URL? = nil) throws -> (url: URL, fromOlderRecipe: Bool) {
        let fileManager = FileManager.default
        let prepared = imageURL(forFirmwareAt: ipswURL)
        let user = directory.map(userImageURL(in:)) ?? userImageURL(forFirmwareAt: ipswURL)
        if let directory { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        try recoverInterruptedReplacement(at: user, fileManager: fileManager)

        let legacy = directory == nil ? nil : userImageURL(forFirmwareAt: ipswURL)
        let userExists = fileManager.fileExists(atPath: user.path)
        let hasLegacyVolume = !erasing && !userExists && legacy.map { fileManager.fileExists(atPath: $0.path) } == true
        if erasing || !userExists {
            let source = hasLegacyVolume ? legacy! : prepared
            let temporary = user.appendingPathExtension("creating")
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: markerURL(for: temporary))
            defer {
                try? fileManager.removeItem(at: temporary)
                try? fileManager.removeItem(at: markerURL(for: temporary))
            }
            guard fileManager.fileExists(atPath: source.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            try copyHFSImage(from: source, to: temporary, fileManager: fileManager)
            let sourceVersion = source == prepared
                ? String(RootFilesystemRecipe.version)
                : try? String(contentsOf: markerURL(for: source), encoding: .utf8)
            try safelyPromote(temporary, to: user, markerVersion: sourceVersion, fileManager: fileManager)

            if hasLegacyVolume, let legacy {
                try? fileManager.removeItem(at: legacy)
                try? fileManager.removeItem(at: markerURL(for: legacy))
            }
        }
        let version = (try? String(contentsOf: markerURL(for: user), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (user, version != String(RootFilesystemRecipe.version))
    }

    private static func markerURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("version")
    }

    /// Validates and transactionally copies a legacy IPSW-adjacent user
    /// image into the durable Application Support location. Existing data
    /// at the destination is never overwritten by a migration.
    static func migrateUserImage(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try recoverInterruptedReplacement(at: destination, fileManager: fileManager)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("migrating")
        try? fileManager.removeItem(at: temporary)
        try? fileManager.removeItem(at: markerURL(for: temporary))
        defer {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: markerURL(for: temporary))
        }
        try copyHFSImage(from: source, to: temporary, fileManager: fileManager)
        let version = try? String(contentsOf: markerURL(for: source), encoding: .utf8)
        try safelyPromote(temporary, to: destination, markerVersion: version, fileManager: fileManager)
    }

    /// Copies only a complete, valid HFS+ image. `clonefile` is preferred
    /// for speed; if it fails, remove any partial destination before making
    /// a byte-for-byte copy.
    private static func copyHFSImage(from source: URL, to destination: URL, fileManager: FileManager) throws {
        _ = try readHFSPlusVolumeHeader(at: source)
        if clonefile(source.path, destination.path, 0) != 0 {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
        }
        _ = try readHFSPlusVolumeHeader(at: destination)
    }

    /// Reads and validates the primary HFS+ volume header in a raw image.
    static func readHFSPlusVolumeHeader(at image: URL) throws -> HFSPlusVolumeHeader {
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PreparationError.invalidHFSImage("couldn't read the image size")
        }
        let fileSize = size.uint64Value
        guard fileSize >= HFSPlusVolumeHeader.offset + UInt64(HFSPlusVolumeHeader.byteCount) else {
            throw PreparationError.invalidHFSImage("the file is shorter than its volume header")
        }
        let source = try FileVolumeSource(url: image)
        let header: HFSPlusVolumeHeader
        do {
            header = HFSPlusVolumeHeader(bytes: try source.readBytes(HFSPlusVolumeHeader.byteCount, at: HFSPlusVolumeHeader.offset))
        } catch {
            throw PreparationError.invalidHFSImage("couldn't read the volume header")
        }
        guard header.signature == HFSPlusVolumeHeader.signatureHFSPlus || header.signature == HFSPlusVolumeHeader.signatureHFSX else {
            throw PreparationError.invalidHFSImage("the volume signature isn't HFS+ or HFSX")
        }
        guard header.blockSize >= 512, header.blockSize & (header.blockSize - 1) == 0,
              header.totalBlocks > 0, header.freeBlocks <= header.totalBlocks else {
            throw PreparationError.invalidHFSImage("the allocation counts or block size are invalid")
        }
        let (volumeSize, overflow) = UInt64(header.blockSize).multipliedReportingOverflow(by: UInt64(header.totalBlocks))
        guard !overflow else { throw PreparationError.invalidHFSImage("the volume size overflows") }
        guard volumeSize >= HFSPlusVolumeHeader.offset + UInt64(HFSPlusVolumeHeader.byteCount), volumeSize <= fileSize else {
            throw PreparationError.invalidHFSImage("the volume header extends beyond the disk image")
        }
        return header
    }

    /// If a prior process stopped halfway through replacing an image, roll
    /// back to the complete old image rather than mistaking the staged one
    /// for committed user data. A missing version marker is harmless: it
    /// only causes the caller to rebuild or report an older recipe.
    private static func recoverInterruptedReplacement(at destination: URL, fileManager: FileManager) throws {
        let backup = destination.appendingPathExtension("replacing")
        let backupMarker = markerURL(for: backup)
        let marker = markerURL(for: destination)
        if fileManager.fileExists(atPath: backup.path) {
            // Promotion commits only after both new files reach their final
            // paths. Before then, restore the old image and its marker, if
            // the old marker had already been moved aside.
            if fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: marker.path) {
                try fileManager.removeItem(at: backup)
                try? fileManager.removeItem(at: backupMarker)
            } else {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                if fileManager.fileExists(atPath: backupMarker.path) {
                    if fileManager.fileExists(atPath: marker.path) {
                        try fileManager.removeItem(at: marker)
                    }
                    try fileManager.moveItem(at: backupMarker, to: marker)
                }
                try fileManager.moveItem(at: backup, to: destination)
            }
        } else {
            // A new image can survive a first-time copy without a marker
            // only if it came from an older release. Do not delete it.
            try? fileManager.removeItem(at: backupMarker)
        }

    }

    /// Stages the version marker beside the complete temporary image, then
    /// renames the old image out of the way before promoting the new one.
    /// The backup remains until both new files are in place; recovery always
    /// prefers the old complete image if a process dies during that window.
    private static func safelyPromote(_ temporary: URL, to destination: URL, markerVersion: String?,
                                      fileManager: FileManager) throws {
        try recoverInterruptedReplacement(at: destination, fileManager: fileManager)
        let marker = markerURL(for: destination)
        let temporaryMarker = markerURL(for: temporary)
        let backup = destination.appendingPathExtension("replacing")
        let backupMarker = markerURL(for: backup)
        if let markerVersion {
            try markerVersion.write(to: temporaryMarker, atomically: true, encoding: .utf8)
        } else {
            try? fileManager.removeItem(at: temporaryMarker)
        }

        var movedOldImage = false
        var movedOldMarker = false
        var movedNewImage = false
        var movedNewMarker = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedOldImage = true
            }
            if fileManager.fileExists(atPath: marker.path) {
                try fileManager.moveItem(at: marker, to: backupMarker)
                movedOldMarker = true
            }
            try fileManager.moveItem(at: temporary, to: destination)
            movedNewImage = true
            if markerVersion != nil {
                try fileManager.moveItem(at: temporaryMarker, to: marker)
                movedNewMarker = true
            }

            // Deleting the backup is the transaction's commit point. If it
            // fails, the catch path removes the staged image and restores it.
            if movedOldImage {
                try fileManager.removeItem(at: backup)
                movedOldImage = false
            }
            if movedOldMarker { try? fileManager.removeItem(at: backupMarker) }
        } catch {
            if movedNewImage { try? fileManager.removeItem(at: destination) }
            if movedNewMarker { try? fileManager.removeItem(at: marker) }
            if movedOldImage { try? fileManager.moveItem(at: backup, to: destination) }
            if movedOldMarker {
                try? fileManager.removeItem(at: marker)
                try? fileManager.moveItem(at: backupMarker, to: marker)
            }
            // If an in-process rollback fails, startup recovery can finish it.
            throw error
        }
    }

    private static func isPrepared(_ image: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: image.path),
              let marker = try? String(contentsOf: markerURL(for: image), encoding: .utf8) else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == String(RootFilesystemRecipe.version)
    }

    static func isPrepared(forFirmwareAt ipswURL: URL) -> Bool {
        isPrepared(imageURL(forFirmwareAt: ipswURL), fileManager: .default)
    }

    /// Returns the prepared system image, building it first if needed.
    @discardableResult
    static func prepare(firmwareAt ipswURL: URL, keybagBootstrap: [UInt8], syncDaemon: [UInt8]? = nil, firstBootState: Data? = nil,
                        bootReadFiles: [String] = [],
                        progress: (Progress) -> Void = { _ in }) throws -> URL {
        let fileManager = FileManager.default
        let image = imageURL(forFirmwareAt: ipswURL)
        try recoverInterruptedReplacement(at: image, fileManager: fileManager)
        if isPrepared(image, fileManager: fileManager) { return image }

        // Finish an image written successfully before a previous launch was
        // able to promote its atomic temporary into the normal prepared path.
        let readyImage = image.appendingPathExtension("ready")
        let readyMarker = markerURL(for: readyImage)
        if fileManager.fileExists(atPath: readyImage.path),
           let readyVersion = try? String(contentsOf: readyMarker, encoding: .utf8),
           readyVersion.trimmingCharacters(in: .whitespacesAndNewlines) == String(RootFilesystemRecipe.version) {
            try safelyPromote(readyImage, to: image, markerVersion: readyVersion, fileManager: fileManager)
            return image
        }

        let decrypted = ipswURL.deletingPathExtension().appendingPathExtension("rootfs-decrypted.dmg")
        let partial = image.appendingPathExtension("partial")
        let keepDecrypted = ProcessInfo.processInfo.environment["PODIUM_KEEP_DECRYPTED_ROOTFS"] != nil
        defer {
            if !keepDecrypted { try? fileManager.removeItem(at: decrypted) }
            try? fileManager.removeItem(at: partial)
        }

        if keepDecrypted, fileManager.fileExists(atPath: decrypted.path) {
            return try build(from: decrypted, to: image, partial: partial, keybagBootstrap: keybagBootstrap,
                             syncDaemon: syncDaemon, firstBootState: firstBootState, bootReadFiles: bootReadFiles, progress: progress)
        }
        try decryptRootFilesystem(fromFirmwareAt: ipswURL, to: decrypted) { progress(Progress(phase: .extracting, fraction: $0)) }
        return try build(from: decrypted, to: image, partial: partial, keybagBootstrap: keybagBootstrap,
                         syncDaemon: syncDaemon, firstBootState: firstBootState, bootReadFiles: bootReadFiles, progress: progress)
    }

    /// Streams the root filesystem DMG out of the IPSW, decrypting it into
    /// `decrypted` (a UDIF image).
    static func decryptRootFilesystem(fromFirmwareAt ipswURL: URL, to decrypted: URL, progress: (Double) -> Void = { _ in }) throws {
        let fileManager = FileManager.default
        let zip = try ZipArchiveReader(fileURL: ipswURL)
        guard let manifestEntry = zip.entry(named: IPSWParser.buildManifestEntryName) else { throw PreparationError.missingRootFilesystem }
        let manifest = try PropertyListDecoder().decode(BuildManifestPlist.self, from: try zip.data(for: manifestEntry))
        guard manifest.productBuildVersion == referenceBuild else { throw PreparationError.wrongFirmware(manifest.productBuildVersion) }
        guard let path = manifest.rootFilesystemPath, let entry = zip.entry(named: path) else { throw PreparationError.missingRootFilesystem }

        let temporary = decrypted.appendingPathExtension("partial")
        try? fileManager.removeItem(at: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        fileManager.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var buffer = Data()
        buffer.reserveCapacity(8 << 20)
        let decryptor = try EncryptedDiskImageDecryptor(key: [UInt8](ReferenceFirmwareKeys.rootFilesystem)) { plain in
            buffer.append(contentsOf: plain)
            if buffer.count >= 8 << 20 {
                try output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try zip.stream(entry, progress: progress) { piece in try decryptor.feed(piece) }
        try output.write(contentsOf: buffer)
        guard decryptor.isComplete else { throw PreparationError.incompleteDecryption }
        try output.synchronize()
        try? fileManager.removeItem(at: decrypted)
        try fileManager.moveItem(at: temporary, to: decrypted)
    }

    private static func build(from decrypted: URL, to image: URL, partial: URL, keybagBootstrap: [UInt8], syncDaemon: [UInt8]?,
                              firstBootState: Data?, bootReadFiles: [String], progress: (Progress) -> Void) throws -> URL {
        let fileManager = FileManager.default
        progress(Progress(phase: .building, fraction: 0))
        let volume = try HFSPlusVolume(source: try UDIFDiskImage(url: decrypted))
        let builder = try RootFilesystemBuilder(volume: volume)
        try RootFilesystemRecipe.apply(to: builder, keybagBootstrap: keybagBootstrap, syncDaemon: syncDaemon, firstBootState: firstBootState,
                                       bootReadFiles: bootReadFiles)
        try builder.write(to: partial, freeSpace: RootFilesystemRecipe.freeSpace) { written in
            progress(Progress(phase: .building, fraction: Double(written.bytesWritten) / Double(max(written.totalBytes, 1))))
        }

        let ready = image.appendingPathExtension("ready")
        try? fileManager.removeItem(at: ready)
        try? fileManager.removeItem(at: markerURL(for: ready))
        try fileManager.moveItem(at: partial, to: ready)
        let version = String(RootFilesystemRecipe.version)
        try version.write(to: markerURL(for: ready), atomically: true, encoding: .utf8)
        try safelyPromote(ready, to: image, markerVersion: version, fileManager: fileManager)
        return image
    }
}
