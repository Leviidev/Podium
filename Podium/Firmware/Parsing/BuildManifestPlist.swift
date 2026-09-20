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
    /// Absent entirely on some manifest shapes this parser has seen in
    /// tests/fixtures — kept optional-with-empty-default rather than
    /// required, consistent with this type's own rule that only the
    /// three fields compatibility checking depends on are mandatory.
    let buildIdentities: [BuildIdentity]

    enum CodingKeys: String, CodingKey {
        case productVersion = "ProductVersion"
        case productBuildVersion = "ProductBuildVersion"
        case supportedProductTypes = "SupportedProductTypes"
        case buildIdentities = "BuildIdentities"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productVersion = try container.decode(String.self, forKey: .productVersion)
        productBuildVersion = try container.decode(String.self, forKey: .productBuildVersion)
        supportedProductTypes = try container.decode([String].self, forKey: .supportedProductTypes)
        buildIdentities = try container.decodeIfPresent([BuildIdentity].self, forKey: .buildIdentities) ?? []
    }

    struct BuildIdentity: Decodable {
        let manifest: [String: ManifestComponent]
        enum CodingKeys: String, CodingKey { case manifest = "Manifest" }
    }

    struct ManifestComponent: Decodable {
        let info: ComponentInfo
        enum CodingKeys: String, CodingKey { case info = "Info" }
    }

    struct ComponentInfo: Decodable {
        let path: String
        enum CodingKeys: String, CodingKey { case path = "Path" }
    }

    /// The path (inside the IPSW) of the kernelcache this manifest
    /// describes. A manifest can list multiple `BuildIdentities` (e.g.
    /// erase vs. update restore variants) — Podium's one reference
    /// firmware only needs the first, so that simplification is left
    /// undocumented further until a second firmware actually requires
    /// choosing between them.
    var kernelCachePath: String? {
        buildIdentities.first?.manifest["KernelCache"]?.info.path
    }
}
