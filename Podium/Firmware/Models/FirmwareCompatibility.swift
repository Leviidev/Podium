import Foundation

/// Whether Podium can use a given firmware as an emulator target, and why.
enum FirmwareCompatibility: Codable, Hashable {
    case compatible
    /// The IPSW parsed fine, but none of its supported devices are ones
    /// Podium knows about.
    case unsupportedDevice
    /// The device is recognized, but this exact iOS version/build hasn't
    /// been validated against Podium's firmware parser and emulator work.
    case unsupportedVersion

    var isCompatible: Bool { self == .compatible }

    var summary: String {
        switch self {
        case .compatible: return "Compatible"
        case .unsupportedDevice: return "Unsupported device"
        case .unsupportedVersion: return "Unsupported version"
        }
    }
}

/// Decides compatibility for parsed firmware metadata.
///
/// Podium is deliberately exact: a firmware is compatible when it matches
/// — device, iOS version, and build — one of the validated reference
/// builds exactly. This is not a "does it probably work" heuristic; with
/// an unvalidated build the rest of the pipeline has no symbol tables,
/// no keys, and no tested recipe.
enum FirmwareCompatibilityChecker {
    static func evaluate(_ metadata: FirmwareMetadata) -> FirmwareCompatibility {
        guard ReferenceFirmware.matching(metadata) != nil else {
            if metadata.supportedDeviceIdentifiers.contains(where: { DeviceCatalog.device(for: $0) != nil }) {
                return .unsupportedVersion
            }
            return .unsupportedDevice
        }
        return .compatible
    }
}
