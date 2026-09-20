import Foundation
import Observation

/// Owns every firmware Podium has imported: where it lives on disk, what
/// Podium knows about it, and which one (if any) is the active emulator
/// target.
///
/// Imported firmware is always a *copy*. Podium never reads from, writes
/// to, or deletes the user's original IPSW file — only from its own
/// storage directory under Application Support.
@MainActor
@Observable
final class FirmwareLibrary {
    private(set) var firmwares: [ImportedFirmware] = []
    private(set) var isImporting = false

    private let fileManager: FileManager
    private let storageDirectoryURL: URL
    private let indexFileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageDirectoryURL = appSupport.appendingPathComponent("Podium/Firmware", isDirectory: true)
        indexFileURL = storageDirectoryURL.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        firmwares = Self.loadIndex(at: indexFileURL)
    }

    var activeFirmware: ImportedFirmware? {
        firmwares.first { $0.isActive }
    }

    func fileURL(for firmware: ImportedFirmware) -> URL {
        storageDirectoryURL.appendingPathComponent(firmware.storedFileName)
    }

    /// Copies `sourceURL` into Podium's storage, then parses the copy.
    /// `sourceURL` is expected to be a security-scoped URL handed to us by
    /// a file picker (`.fileImporter`); this handles start/stop access.
    @discardableResult
    func importFirmware(from sourceURL: URL) async throws -> ImportedFirmware {
        isImporting = true
        defer { isImporting = false }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let storedFileName = "\(id.uuidString).ipsw"
        let destinationURL = storageDirectoryURL.appendingPathComponent(storedFileName)
        let fileManager = fileManager

        do {
            try await Task.detached(priority: .utility) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }.value

            let parsed = try await Task.detached(priority: .utility) {
                try IPSWParser.parse(fileURL: destinationURL)
            }.value

            let record = ImportedFirmware(
                id: id,
                metadata: parsed.metadata,
                compatibility: parsed.compatibility,
                importedAt: Date(),
                storedFileName: storedFileName,
                isActive: firmwares.isEmpty
            )
            firmwares.append(record)
            try persistIndex()
            return record
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func remove(_ firmware: ImportedFirmware) throws {
        try? fileManager.removeItem(at: fileURL(for: firmware))
        firmwares.removeAll { $0.id == firmware.id }
        try persistIndex()
    }

    func setActive(_ firmware: ImportedFirmware) {
        guard firmwares.contains(where: { $0.id == firmware.id }) else { return }
        for index in firmwares.indices {
            firmwares[index].isActive = (firmwares[index].id == firmware.id)
        }
        try? persistIndex()
    }

    /// Re-parses the stored copy and confirms it still matches what
    /// Podium recorded at import time. This is a consistency check, not a
    /// cryptographic signature verification.
    func verify(_ firmware: ImportedFirmware) async -> Bool {
        let url = fileURL(for: firmware)
        return await Task.detached(priority: .utility) {
            guard let parsed = try? IPSWParser.parse(fileURL: url) else { return false }
            return parsed.metadata == firmware.metadata
        }.value
    }

    private func persistIndex() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(firmwares)
        try data.write(to: indexFileURL, options: .atomic)
    }

    private static func loadIndex(at url: URL) -> [ImportedFirmware] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ImportedFirmware].self, from: data)) ?? []
    }
}
