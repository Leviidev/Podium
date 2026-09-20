import Foundation

enum FirmwareDownloadError: FriendlyError {
    case network(underlying: Error)
    case notFound
    case decodingFailed(underlying: Error)
    case checksumMismatch

    var userMessage: String {
        switch self {
        case .network:
            return "Podium couldn't reach ipsw.me to download the firmware."
        case .notFound:
            return "The reference firmware isn't available for download right now."
        case .decodingFailed:
            return "Podium got an unexpected response while looking up the firmware."
        case .checksumMismatch:
            return "The downloaded firmware didn't match its expected checksum."
        }
    }

    var developerDetail: String {
        switch self {
        case .network(let underlying):
            return underlying.localizedDescription
        case .notFound:
            return "api.ipsw.me returned no firmware for iPod4,1 / 10B500."
        case .decodingFailed(let underlying):
            return underlying.localizedDescription
        case .checksumMismatch:
            return "SHA-256 of the downloaded file did not match ipsw.me's reported sha256sum."
        }
    }
}
