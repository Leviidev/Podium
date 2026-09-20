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
/// Podium's initial supported target is intentionally exact: a single
/// device, a single iOS version, a single build. This is not a general
/// "does Podium probably work" heuristic — it's a strict match against
/// what's actually been validated.
enum FirmwareCompatibilityChecker {
    static func evaluate(_ metadata: FirmwareMetadata) -> FirmwareCompatibility {
        guard metadata.supportedDeviceIdentifiers.contains(ReferenceFirmware.device.identifier) else {
            return .unsupportedDevice
        }
        guard metadata.productVersion == ReferenceFirmware.productVersion,
              metadata.buildVersion == ReferenceFirmware.buildVersion else {
            return .unsupportedVersion
        }
        return .compatible
    }
}
