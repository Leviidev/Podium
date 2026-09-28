import Foundation

/// Changes to the kernelcache's own data, made in the copy loaded into
/// guest RAM. Each is a same-length edit of the prelinked kexts' Info.plist
/// XML (`__PRELINK_INFO`), which the kernel parses at boot, so nothing
/// else in the image moves.
enum KernelcachePatcher {
    /// AppleCLCD's personality names its backlight by `BacklightMatching`
    /// (`IOPropertyMatch` `backlight-control`), and it looks for one with
    /// `getMatchingServices` — a scan of the whole I/O registry — each time
    /// it turns the backlight off or on, over and over while the panel
    /// powers down. The one service that would match, AppleARMBacklight,
    /// never registers here: before it does, it waits for the `IONVRAM`
    /// resource to restore the saved brightness, and NVRAM lives in the
    /// NAND this iPod doesn't have. So every scan comes up empty, and they
    /// took most of the time to go to sleep and nearly all of the time to
    /// shut down.
    ///
    /// Renaming the key leaves AppleCLCD knowing up front that it has no
    /// backlight — how it ends up anyway ("Where is my backlight?") —
    /// without searching.
    static func skipBacklightSearch(_ machO: inout Data) {
        let personality = "<key>AppleCLCD-8930X</key><dict><key>IOClass</key><string>AppleCLCD</string><key>"
        replace(personality + "BacklightMatching</key>", with: personality + "NoBacklightSearch</key>", in: &machO)
    }

    private static func replace(_ original: String, with replacement: String, in data: inout Data) {
        let original = Data(original.utf8), replacement = Data(replacement.utf8)
        precondition(original.count == replacement.count, "kernelcache patches keep lengths")
        guard let range = data.range(of: original) else { return }
        data.replaceSubrange(range, with: replacement)
    }
}
