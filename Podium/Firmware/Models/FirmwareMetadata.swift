import Foundation

/// Firmware facts read directly out of an IPSW's `BuildManifest.plist`,
/// independent of whether Podium considers the firmware compatible.
struct FirmwareMetadata: Codable, Hashable {
    /// Device identifiers this restore bundle supports, e.g. ["iPod4,1"].
    /// A single IPSW can list more than one board/device.
    let supportedDeviceIdentifiers: [String]
    /// e.g. "6.1.6"
    let productVersion: String
    /// e.g. "10B500"
    let buildVersion: String
    /// Size of the original IPSW file on disk, in bytes.
    let fileSizeBytes: Int64
    /// The file name the user imported, kept for display only.
    let originalFileName: String
    /// Path of the kernelcache inside the IPSW, e.g.
    /// "kernelcache.release.n81" — `nil` if the manifest didn't declare
    /// one. Needed to locate the kernel for Milestone 4 boot attempts.
    let kernelCachePath: String?
    /// Path of the device tree inside the IPSW, e.g.
    /// "Firmware/all_flash/all_flash.n81ap.production/DeviceTree.n81ap.img3"
    /// — `nil` if the manifest didn't declare one. Needed so real boot
    /// attempts can hand XNU an actual device tree instead of leaving
    /// `boot_args.deviceTreeP` honestly zero.
    let deviceTreePath: String?

    /// The primary device this firmware targets, for display purposes.
    /// IPSWs for this era of device are effectively single-device, so the
    /// first supported identifier is treated as canonical.
    var primaryDeviceIdentifier: String? {
        supportedDeviceIdentifiers.first
    }

    var primaryDevice: SupportedDevice? {
        primaryDeviceIdentifier.flatMap(DeviceCatalog.device(for:))
    }
}
