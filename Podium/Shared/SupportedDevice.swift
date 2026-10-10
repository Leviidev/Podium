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
/// Deliberately narrow: the iPod touch 4 and the iPhone 4 are both A4
/// (S5L8930X) devices — once one boots, the other is a device-tree and
/// firmware-keys problem rather than a different SoC.
enum DeviceCatalog {
    static let iPodTouch4 = SupportedDevice(
        identifier: "iPod4,1",
        marketingName: "iPod touch (4th generation)",
        shortName: "iPod touch 4"
    )
    static let iPhone4 = SupportedDevice(
        identifier: "iPhone3,1",
        marketingName: "iPhone 4",
        shortName: "iPhone 4"
    )

    static let all: [SupportedDevice] = [iPodTouch4, iPhone4]

    static func device(for identifier: String) -> SupportedDevice? {
        all.first { $0.identifier == identifier }
    }
}

/// The exact firmware builds Podium has validated, with what each needs:
/// published decryption keys (TheAppleWiki, for these decade-old EOL
/// builds only — see `ReferenceFirmwareKeys` for the scope decision) and
/// the kernel landmark addresses the emulator's session uses. A firmware
/// is compatible only when it matches its reference exactly; anything
/// else fails with "unsupported version", deliberately.
struct ReferenceFirmware {
    let device: SupportedDevice
    let productVersion: String
    let buildVersion: String
    /// URL path for `api.ipsw.me/v4/...`, for the in-app download offer.
    let downloadIdentifier: String

    /// iPod touch 4, iOS 6.1.6 — Podium's original validated target.
    static let iPodTouch4616 = ReferenceFirmware(
        device: DeviceCatalog.iPodTouch4,
        productVersion: "6.1.6",
        buildVersion: "10B500",
        downloadIdentifier: "iPod4,1/10B500"
    )
    /// iPhone 4 (GSM), iOS 7.1.2 — port in progress; see iOS7-Port-Notes.md.
    static let iPhone4712 = ReferenceFirmware(
        device: DeviceCatalog.iPhone4,
        productVersion: "7.1.2",
        buildVersion: "11D257",
        downloadIdentifier: "iPhone3,1/11D257"
    )

    static let all: [ReferenceFirmware] = [iPodTouch4616, iPhone4712]

    static func matching(_ metadata: FirmwareMetadata) -> ReferenceFirmware? {
        all.first { reference in
            metadata.supportedDeviceIdentifiers.contains(reference.device.identifier)
                && metadata.productVersion == reference.productVersion
                && metadata.buildVersion == reference.buildVersion
        }
    }

    var keys: ReferenceFirmwareKeys.FirmwareKeys? { ReferenceFirmwareKeys.forBuild(buildVersion) }
}
