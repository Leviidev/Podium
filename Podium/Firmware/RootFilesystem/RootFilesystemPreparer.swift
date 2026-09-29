import Foundation

/// Produces the root filesystem image the emulator boots from, straight
/// from the imported IPSW, once:
///
/// 1. stream the root filesystem DMG out of the IPSW (a deflated ZIP
///    entry), decrypting it (`encrcdsa`, the published key for this one
///    reference firmware) into a temporary file;
/// 2. read its HFSX partition, apply `RootFilesystemRecipe`, and write a
///    new, packed volume sized to fit in guest RAM as a RAM disk.
///
/// The result stays next to the IPSW with a version marker, so later
/// boots skip straight to booting.
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

        var description: String {
            switch self {
            case .wrongFirmware(let build): return "root filesystem preparation only supports iOS 6.1.6 (10B500); this is \(build)"
            case .missingRootFilesystem: return "the IPSW has no root filesystem image"
            case .incompleteDecryption: return "the root filesystem image ended early"
            }
        }
    }

    static let referenceBuild = "10B500"

    static func imageURL(forFirmwareAt ipswURL: URL) -> URL {
        ipswURL.deletingPathExtension().appendingPathExtension("rootfs.hfs")
    }

    /// The copy of the prepared image the app boots and the guest writes
    /// to — its data and what's installed on it outlive a power-off.
    static func userImageURL(forFirmwareAt ipswURL: URL) -> URL {
        ipswURL.deletingPathExtension().appendingPathExtension("user.hfs")
    }

    /// The user image, made from the prepared one if there isn't one yet
    /// (or `erasing` the one there): a clone, where the file system
    /// supports it, so it takes no time or space until the guest writes.
    /// Returns whether it was made from an older recipe than the current
    /// one — kept, since it holds the user's data.
    @discardableResult
    static func prepareUserImage(forFirmwareAt ipswURL: URL, erasing: Bool = false) throws -> (url: URL, fromOlderRecipe: Bool) {
        let fileManager = FileManager.default
        let prepared = imageURL(forFirmwareAt: ipswURL)
        let user = userImageURL(forFirmwareAt: ipswURL)
        let marker = markerURL(for: user)
        if erasing || !fileManager.fileExists(atPath: user.path) {
            try? fileManager.removeItem(at: user)
            if clonefile(prepared.path, user.path, 0) != 0 {
                try fileManager.copyItem(at: prepared, to: user)
            }
            try String(RootFilesystemRecipe.version).write(to: marker, atomically: true, encoding: .utf8)
        }
        let version = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (user, version != String(RootFilesystemRecipe.version))
    }

    private static func markerURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("version")
    }

    static func isPrepared(forFirmwareAt ipswURL: URL) -> Bool {
        let image = imageURL(forFirmwareAt: ipswURL)
        guard FileManager.default.fileExists(atPath: image.path),
              let marker = try? String(contentsOf: markerURL(for: image), encoding: .utf8) else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == String(RootFilesystemRecipe.version)
    }

    /// Returns the prepared image, building it first if needed.
    @discardableResult
    static func prepare(firmwareAt ipswURL: URL, keybagBootstrap: [UInt8], syncDaemon: [UInt8]? = nil, firstBootState: Data? = nil,
                        bootReadFiles: [String] = [],
                        progress: (Progress) -> Void = { _ in }) throws -> URL {
        let image = imageURL(forFirmwareAt: ipswURL)
        if isPrepared(forFirmwareAt: ipswURL) { return image }
        let fileManager = FileManager.default
        let decrypted = ipswURL.deletingPathExtension().appendingPathExtension("rootfs-decrypted.dmg")
        let partial = image.appendingPathExtension("partial")
        let keepDecrypted = ProcessInfo.processInfo.environment["PODIUM_KEEP_DECRYPTED_ROOTFS"] != nil
        defer {
            if !keepDecrypted { try? fileManager.removeItem(at: decrypted) }
            try? fileManager.removeItem(at: partial)
        }

        // 1. Extract and decrypt.
        if keepDecrypted, fileManager.fileExists(atPath: decrypted.path) {
            return try build(from: decrypted, to: image, partial: partial, keybagBootstrap: keybagBootstrap, syncDaemon: syncDaemon, firstBootState: firstBootState, bootReadFiles: bootReadFiles, progress: progress)
        }
        try decryptRootFilesystem(fromFirmwareAt: ipswURL, to: decrypted) { progress(Progress(phase: .extracting, fraction: $0)) }

        return try build(from: decrypted, to: image, partial: partial, keybagBootstrap: keybagBootstrap, syncDaemon: syncDaemon, firstBootState: firstBootState, bootReadFiles: bootReadFiles, progress: progress)
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

        fileManager.createFile(atPath: decrypted.path, contents: nil)
        let output = try FileHandle(forWritingTo: decrypted)
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
        try zip.stream(entry, progress: progress) { piece in
            try decryptor.feed(piece)
        }
        try output.write(contentsOf: buffer)
        guard decryptor.isComplete else { throw PreparationError.incompleteDecryption }
    }

    // 2. Rebuild the volume.
    private static func build(from decrypted: URL, to image: URL, partial: URL, keybagBootstrap: [UInt8], syncDaemon: [UInt8]?, firstBootState: Data?,
                              bootReadFiles: [String],
                              progress: (Progress) -> Void) throws -> URL {
        let fileManager = FileManager.default
        progress(Progress(phase: .building, fraction: 0))
        let volume = try HFSPlusVolume(source: try UDIFDiskImage(url: decrypted))
        let builder = try RootFilesystemBuilder(volume: volume)
        try RootFilesystemRecipe.apply(to: builder, keybagBootstrap: keybagBootstrap, syncDaemon: syncDaemon, firstBootState: firstBootState,
                                       bootReadFiles: bootReadFiles)
        try builder.write(to: partial, freeSpace: RootFilesystemRecipe.freeSpace) { written in
            progress(Progress(phase: .building, fraction: Double(written.bytesWritten) / Double(max(written.totalBytes, 1))))
        }

        try? fileManager.removeItem(at: image)
        try fileManager.moveItem(at: partial, to: image)
        try String(RootFilesystemRecipe.version).write(to: markerURL(for: image), atomically: true, encoding: .utf8)
        return image
    }
}
