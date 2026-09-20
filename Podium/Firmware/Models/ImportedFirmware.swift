import Foundation

/// A firmware image Podium has imported into its own storage, plus the
/// bookkeeping the firmware library needs to manage it.
struct ImportedFirmware: Codable, Identifiable, Hashable {
    let id: UUID
    let metadata: FirmwareMetadata
    let compatibility: FirmwareCompatibility
    let importedAt: Date
    /// File name inside Podium's firmware storage directory. Never the
    /// original path — Podium copies firmware in rather than referencing
    /// the user's original file, so the import survives the source file
    /// moving or being deleted.
    let storedFileName: String
    var isActive: Bool

    var displayName: String {
        metadata.primaryDevice?.shortName ?? metadata.primaryDeviceIdentifier ?? "Unknown device"
    }
}
