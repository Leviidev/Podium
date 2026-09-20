import Foundation

/// Mirrors the subset of `BuildManifest.plist` Podium reads.
///
/// Structure is based on publicly documented `BuildManifest.plist` layouts
/// used across the iOS restore/jailbreak tooling community (e.g. futurerestore,
/// ipsw.me) for this era of firmware, not on any Apple specification —
/// Apple does not publish this format. Field presence has been observed to
/// vary across iOS versions, so every field here is optional except the
/// three Podium's compatibility check depends on, and decoding falls back
/// to a clear parsing error rather than guessing at missing data.
struct BuildManifestPlist: Decodable {
    let productVersion: String
    let productBuildVersion: String
    let supportedProductTypes: [String]

    enum CodingKeys: String, CodingKey {
        case productVersion = "ProductVersion"
        case productBuildVersion = "ProductBuildVersion"
        case supportedProductTypes = "SupportedProductTypes"
    }
}
