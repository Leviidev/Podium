import Foundation

/// The result of successfully parsing an IPSW: what it is, plus whether
/// Podium currently supports it.
struct ParsedFirmware {
    let metadata: FirmwareMetadata
    let compatibility: FirmwareCompatibility
}

/// Reads an IPSW file and determines what firmware it contains.
///
/// This inspects actual file contents — the ZIP central directory and
/// `BuildManifest.plist` — rather than trusting the file name. A file
/// named `iPod4,1_6.1.6_10B500_Restore.ipsw` that doesn't actually contain
/// that firmware will be reported as whatever it actually parses to.
enum IPSWParser {
    static let buildManifestEntryName = "BuildManifest.plist"

    static func parse(fileURL: URL) throws -> ParsedFirmware {
        let reader = try ZipArchiveReader(fileURL: fileURL)

        guard let manifestEntry = reader.entry(named: buildManifestEntryName) else {
            throw FirmwareParsingError.missingEntry(name: buildManifestEntryName)
        }

        let manifestData = try reader.data(for: manifestEntry)

        let manifest: BuildManifestPlist
        do {
            manifest = try PropertyListDecoder().decode(BuildManifestPlist.self, from: manifestData)
        } catch {
            throw FirmwareParsingError.corruptPropertyList(entryName: buildManifestEntryName, underlying: error)
        }

        let fileSize = try fileSizeBytes(of: fileURL)

        let metadata = FirmwareMetadata(
            supportedDeviceIdentifiers: manifest.supportedProductTypes,
            productVersion: manifest.productVersion,
            buildVersion: manifest.productBuildVersion,
            fileSizeBytes: fileSize,
            originalFileName: fileURL.lastPathComponent,
            kernelCachePath: manifest.kernelCachePath,
            deviceTreePath: manifest.deviceTreePath
        )

        return ParsedFirmware(
            metadata: metadata,
            compatibility: FirmwareCompatibilityChecker.evaluate(metadata)
        )
    }

    private static func fileSizeBytes(of url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch {
            throw FirmwareParsingError.unreadableFile(underlying: error)
        }
    }
}
