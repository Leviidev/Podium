import Foundation

/// Everything that can go wrong while reading an IPSW, translated into
/// language a non-technical user can act on. Technical detail is kept
/// around for the "Details" disclosure rather than discarded.
enum FirmwareParsingError: FriendlyError {
    case notAZipArchive
    case missingEntry(name: String)
    case corruptPropertyList(entryName: String, underlying: Error)
    case unreadableFile(underlying: Error)
    case unsupportedZipFeature(String)

    var userMessage: String {
        switch self {
        case .notAZipArchive:
            return "This file doesn't look like a valid IPSW."
        case .missingEntry:
            return "This file is missing data Podium needs to read it as firmware."
        case .corruptPropertyList:
            return "Podium couldn't read this firmware's build information."
        case .unreadableFile:
            return "Podium couldn't read this file."
        case .unsupportedZipFeature:
            return "This firmware uses a format Podium doesn't support yet."
        }
    }

    var developerDetail: String {
        switch self {
        case .notAZipArchive:
            return "No valid End Of Central Directory record found."
        case .missingEntry(let name):
            return "Archive does not contain \"\(name)\"."
        case .corruptPropertyList(let entryName, let underlying):
            return "Failed to decode \(entryName) as a property list: \(underlying.localizedDescription)"
        case .unreadableFile(let underlying):
            return underlying.localizedDescription
        case .unsupportedZipFeature(let detail):
            return detail
        }
    }
}
