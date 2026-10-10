import XCTest
@testable import Podium

/// Opt-in host-side measurement for choosing rootfs trims: decrypted images
/// stay ignored and are never distributed.
final class FirmwareTrimMeasurementTests: XCTestCase {
    func testMeasureRemainingLargestFilesInElevenD257() throws {
        // Point PODIUM_MEASURE_ROOTFS at a decrypted DMG (or .rootfs.hfs
        // already built by the app) to run this.
        guard let rawPath = ProcessInfo.processInfo.environment["PODIUM_MEASURE_ROOTFS"] else {
            throw XCTSkip("Set PODIUM_MEASURE_ROOTFS to a decrypted 11D257 disk image to measure trims.")
        }
        let url = URL(fileURLWithPath: rawPath)
        let volume = try HFSPlusVolume(source: try UDIFDiskImage(url: url))
        let builder = try RootFilesystemBuilder(volume: volume)
        try RootFilesystemRecipe.apply(to: builder, buildVersion: "11D257", keybagBootstrap: [UInt8]())
        var sizes: [(bytes: UInt64, path: String)] = []
        func measure(_ path: String) throws {
            for child in try builder.children(of: path) {
                let full = (path == "/" ? "" : path) + "/" + child.name
                if builder.isFolder(at: full) {
                    try measure(full)
                } else {
                    let bytes = (try? builder.contents(of: full).count) ?? 0
                    if bytes > 1 << 20 { sizes.append((UInt64(bytes), full)) }
                }
            }
        }
        try measure("/System/Library")
        try measure("/usr")
        try measure("/private/var")
        sizes.sort { $0.bytes > $1.bytes }
        XCTAssertNotNil(sizes.last) // keep the harness honest; the value is the printout
        print("== top heavy files after trims ==")
        for entry in sizes.prefix(80) { print(String(format: "%9.1f MB  %@", Double(entry.bytes) / 1e6, entry.path)) }
        var folderTotals: [String: UInt64] = [:]
        for entry in sizes {
            let parts = entry.path.split(separator: "/").map(String.init)
            let folder = "/" + parts.prefix(4).joined(separator: "/")
            folderTotals[folder, default: 0] += entry.bytes
        }
        let folders = folderTotals.sorted { $0.value > $1.value }.prefix(15)
        for (folder, bytes) in folders { print(String(format: "%9.1f MB under %@", Double(bytes) / 1e6, folder)) }
    }
}
