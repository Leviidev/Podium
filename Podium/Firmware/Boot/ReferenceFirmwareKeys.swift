import Foundation

/// AES key/IV for decrypting components of validated reference firmwares.
///
/// **Source and scope, explicitly:** these values are not derived,
/// guessed, or extracted by Podium. They're copied from TheAppleWiki's
/// publicly-published, CC BY-SA-licensed firmware key research, listed
/// per-build below — for these exact, decade-old, end-of-life firmware
/// builds only. Using them is an explicit decision, not a default: an
/// unvalidated firmware gets no keys here and simply can't be decrypted.
///
/// Correctness is checked the same way for each entry — the decrypted
/// kernelcache runs through `AppleLZSS` and reproduces that container's
/// embedded Adler-32 checksum exactly, and DeviceTree masks come out as
/// readable property strings.
enum ReferenceFirmwareKeys {
    struct ComponentKey {
        let key: Data
        let iv: Data
    }

    /// One firmware build's set of decryption keys + landmark addresses.
    struct FirmwareKeys {
        /// iPod4,1 / iOS 6.1.6 / 10B500, from "Keys:BrightonMaps 10B500 (iPod4,1)"
        /// (https://theapplewiki.com/wiki/Keys:BrightonMaps_10B500_(iPod4,1)).
        static let iPodTouch4616 = FirmwareKeys(
            buildVersion: "10B500",
            kernelcache: ComponentKey(
                key: Data(hex: "9ad44a5686bfb9604cf9a519fd6b6ad3e443184d00052fc2291d442363f94863"),
                iv: Data(hex: "d8ab4ff8b9e5c9af89b7c77842eb80bb")
            ),
            deviceTree: ComponentKey(
                key: Data(hex: "fd12079909ae24b2f8140720854608d12c066def4dc07b66f142259d2970426c"),
                iv: Data(hex: "830c518baddc2e82ad27de186a56e451")
            ),
            rootFilesystem: Data(hex: "7fc7156c452e9c6d05983c5286c2ffd51a305c4bd61a7a5161a567b3b5ef88e1ff786ee9")
        )

        /// iPhone3,1 / iOS 7.1.2 / 11D257, from "Keys:Sochi 11D257 (iPhone3,1)"
        /// (https://theapplewiki.com/wiki/Keys:Sochi_11D257_(iPhone3,1)).
        /// Kernelcache key/IV verified by decrypting `kernelcache.release.n90`
        /// to an `complzss` stream whose Adler-32 (`0xbb79d960`) matches after
        /// `AppleLZSS` decompression to a valid Mach-O arm_v7; DeviceTree
        /// key/IV verified the same way (`DeviceTree.n90ap.img3` decrypts to
        /// readable property strings — "N90AP", "iPhone3,1"); root filesystem
        /// `encrcdsa` key verified by decrypting `058-4520-010.dmg` to a UDIF
        /// image whose Apple_HFS mish table expands to a valid HFSJ volume.
        static let iPhone4712 = FirmwareKeys(
            buildVersion: "11D257",
            kernelcache: ComponentKey(
                key: Data(hex: "9b05ef79c63c59e71f253219ffaa952f25f6810d3863aac2b49628e64f9f0869"),
                iv: Data(hex: "a1aee41423e11a44135233dd345433ce")
            ),
            deviceTree: ComponentKey(
                key: Data(hex: "b93c3a564dc36e184871e246fa8df725ecebafb38c042b6302b333c39e7d1787"),
                iv: Data(hex: "d2f224a2d7e04461ec12ac81f91d657a")
            ),
            rootFilesystem: Data(hex: "38d0320d099b9dd34ffb3308c53d397f14955b347d6a433fe173acc2ced1ae78756b3684")
        )

        static let all: [FirmwareKeys] = [iPodTouch4616, iPhone4712]

        static func forBuild(_ buildVersion: String) -> FirmwareKeys? {
            all.first { $0.buildVersion == buildVersion }
        }

        private init(buildVersion: String, kernelcache: ComponentKey,
                     deviceTree: ComponentKey, rootFilesystem: Data) {
            self.buildVersion = buildVersion
            self.kernelcache = kernelcache
            self.deviceTree = deviceTree
            self.rootFilesystem = rootFilesystem
        }

        let buildVersion: String
        let kernelcache: ComponentKey
        let deviceTree: ComponentKey
        /// The root filesystem disk image's `encrcdsa` key (16-byte AES key
        /// followed by the 20-byte HMAC-SHA1 key). Verified per build by
        /// decrypting its DMG to a mountable UDIF image.
        let rootFilesystem: Data
    }

    /// Keys for a build, or nil when Podium doesn't have that build's keys.
    static func forBuild(_ buildVersion: String) -> FirmwareKeys? {
        FirmwareKeys.forBuild(buildVersion)
    }
}
