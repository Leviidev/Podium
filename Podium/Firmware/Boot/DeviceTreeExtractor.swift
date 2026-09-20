import Foundation

enum DeviceTreeExtractionError: FriendlyError {
    case noDeviceTreePathDeclared
    case entryNotFoundInArchive(path: String)
    case unknownDecryptionKey
    case containerParsingFailed(underlying: Error)

    var userMessage: String {
        switch self {
        case .unknownDecryptionKey:
            return "Podium doesn't have a decryption key for this firmware's device tree."
        default:
            return "Podium couldn't extract the device tree from this firmware."
        }
    }

    var developerDetail: String {
        switch self {
        case .noDeviceTreePathDeclared: return "BuildManifest.plist didn't declare a DeviceTree path."
        case .entryNotFoundInArchive(let path): return "IPSW does not contain \"\(path)\"."
        case .unknownDecryptionKey: return "Encrypted device tree outside Podium's one known reference firmware."
        case .containerParsingFailed(let underlying): return underlying.localizedDescription
        }
    }
}

/// Produces a ready-to-load Apple DeviceTree binary from an imported
/// firmware's stored IPSW: locate the device tree (via the path
/// `BuildManifest.plist` declared at import time), unwrap its IMG3
/// container, and decrypt — no decompression step, unlike the
/// kernelcache, since device trees aren't LZSS-compressed. Decryption
/// only ever succeeds for Podium's one reference firmware, mirroring
/// `KernelcacheExtractor`'s scope boundary; see `ReferenceFirmwareKeys`.
enum DeviceTreeExtractor {
    static func extractDeviceTree(from firmware: ImportedFirmware, storedAt fileURL: URL) throws -> Data {
        guard let path = firmware.metadata.deviceTreePath else {
            throw DeviceTreeExtractionError.noDeviceTreePathDeclared
        }

        let reader = try ZipArchiveReader(fileURL: fileURL)
        guard let entry = reader.entry(named: path) else {
            throw DeviceTreeExtractionError.entryNotFoundInArchive(path: path)
        }
        let rawData = try reader.data(for: entry)

        let container: IMG3Container
        do {
            container = try IMG3Container(data: rawData)
        } catch {
            throw DeviceTreeExtractionError.containerParsingFailed(underlying: error)
        }

        guard container.isEncrypted else {
            return Data(container.payload.prefix(Int(container.declaredDataLength)))
        }
        guard firmware.compatibility.isCompatible else {
            throw DeviceTreeExtractionError.unknownDecryptionKey
        }
        let keys = ReferenceFirmwareKeys.deviceTree
        let decrypted = try FirmwareDecryption.aes256CBCDecrypt(container.payload, key: keys.key, iv: keys.iv)
        // Unlike the kernelcache, the device tree isn't compressed, so
        // there's no decompressor to naturally stop at the real end —
        // trim the AES block-padding remainder ourselves using the
        // container's own declared length (see `declaredDataLength`'s
        // doc comment).
        return Data(decrypted.prefix(Int(container.declaredDataLength)))
    }
}
