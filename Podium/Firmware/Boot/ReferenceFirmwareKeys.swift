import Foundation

/// AES key/IV for decrypting components of Podium's one reference
/// firmware (iPod4,1 / iOS 6.1.6 / 10B500).
///
/// **Source and scope, explicitly:** these values are not derived,
/// guessed, or extracted by Podium. They're copied from TheAppleWiki's
/// publicly-published, CC BY-SA-licensed firmware key research —
/// specifically "Keys:BrightonMaps 10B500 (iPod4,1)"
/// (https://theapplewiki.com/wiki/Keys:BrightonMaps_10B500_(iPod4,1)) —
/// for this one exact, decade-old, end-of-life firmware build. Using
/// this here was an explicit decision, not a default: Podium's own
/// project brief says not to implement cryptographic bypasses or
/// circumvent Apple's security mechanisms, and this — using a key the
/// security research community already extracted and published for an
/// obsolete device, purely to parse/emulate firmware Podium's owner
/// already legitimately possesses — was confirmed as the intended
/// exception rather than assumed. It does not generalize: a different
/// firmware needs its own published key (or has none, and simply can't
/// be decrypted by Podium).
///
/// Correctness here isn't an assumption either — decrypting the
/// kernelcache with this key and then running it through `AppleLZSS`
/// reproduces that container's own embedded Adler-32 checksum exactly,
/// and the result is confirmed by `file(1)` as a valid `Mach-O
/// executable arm_v7`.
enum ReferenceFirmwareKeys {
    struct ComponentKey {
        let key: Data
        let iv: Data
    }

    static let kernelcache = ComponentKey(
        key: Data(hex: "9ad44a5686bfb9604cf9a519fd6b6ad3e443184d00052fc2291d442363f94863"),
        iv: Data(hex: "d8ab4ff8b9e5c9af89b7c77842eb80bb")
    )

    /// Verified the same way as `kernelcache`: decrypting
    /// `DeviceTree.n81ap.img3`'s DATA payload with this key/IV yields
    /// readable Apple DeviceTree property strings ("device-tree",
    /// "model", "iPod4,1", "N81AP", ...), confirmed directly against
    /// the actual reference firmware file via `openssl enc -d
    /// -aes-256-cbc` before writing any decryption code.
    static let deviceTree = ComponentKey(
        key: Data(hex: "fd12079909ae24b2f8140720854608d12c066def4dc07b66f142259d2970426c"),
        iv: Data(hex: "830c518baddc2e82ad27de186a56e451")
    )
}
