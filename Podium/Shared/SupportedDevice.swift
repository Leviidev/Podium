import Foundation

/// A device Podium knows how to identify, independent of whether emulation
/// is actually implemented for it yet.
struct SupportedDevice: Identifiable, Hashable {
    /// Apple's internal device identifier, e.g. "iPod4,1".
    let identifier: String
    /// Full marketing name, e.g. "iPod touch (4th generation)".
    let marketingName: String
    /// Short name used in compact UI, e.g. "iPod touch 4".
    let shortName: String

    var id: String { identifier }
}

/// The catalog of devices Podium currently recognizes.
///
/// This is intentionally narrow. Podium's first hardware target is the
/// iPod touch 4th generation; broadening this catalog is a deliberate
/// future step, not an oversight.
enum DeviceCatalog {
    static let iPodTouch4 = SupportedDevice(
        identifier: "iPod4,1",
        marketingName: "iPod touch (4th generation)",
        shortName: "iPod touch 4"
    )

    static let all: [SupportedDevice] = [iPodTouch4]

    static func device(for identifier: String) -> SupportedDevice? {
        all.first { $0.identifier == identifier }
    }
}

/// The exact firmware Podium is built against during initial development.
/// Other builds/devices may parse successfully but are reported as
/// unsupported until they've been validated.
enum ReferenceFirmware {
    static let device = DeviceCatalog.iPodTouch4
    static let productVersion = "6.1.6"
    static let buildVersion = "10B500"
}
