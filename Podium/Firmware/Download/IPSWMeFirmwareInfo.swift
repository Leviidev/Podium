import Foundation

/// A single firmware entry as returned by `api.ipsw.me`'s `/v4/ipsw/{identifier}/{buildid}`
/// endpoint. ipsw.me doesn't host the file itself — `url` resolves straight to
/// Apple's own CDN; ipsw.me is only the index of which build lives where,
/// plus its checksums.
struct IPSWMeFirmwareInfo: Decodable {
    let identifier: String
    let version: String
    let buildid: String
    let sha256sum: String
    let filesize: Int64
    let url: URL
}
