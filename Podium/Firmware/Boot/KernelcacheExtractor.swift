import Foundation

enum KernelcacheExtractionError: FriendlyError {
    case noKernelCachePathDeclared
    case entryNotFoundInArchive(path: String)
    case unknownDecryptionKey
    case containerParsingFailed(underlying: Error)
    case decompressionFailed(underlying: Error)

    var userMessage: String {
        switch self {
        case .unknownDecryptionKey:
            return "Podium doesn't have a decryption key for this firmware's kernel."
        default:
            return "Podium couldn't extract the kernel from this firmware."
        }
    }

    var developerDetail: String {
        switch self {
        case .noKernelCachePathDeclared: return "BuildManifest.plist didn't declare a KernelCache path."
        case .entryNotFoundInArchive(let path): return "IPSW does not contain \"\(path)\"."
        case .unknownDecryptionKey: return "Encrypted kernelcache outside Podium's one known reference firmware."
        case .containerParsingFailed(let underlying): return underlying.localizedDescription
        case .decompressionFailed(let underlying): return underlying.localizedDescription
        }
    }
}

/// Produces a ready-to-load kernel Mach-O from an imported firmware's
/// stored IPSW: locate the kernelcache (via the path `BuildManifest.plist`
/// declared at import time), unwrap its IMG3 container, decrypt if
/// necessary, and decompress. Decryption only ever succeeds for Podium's
/// one reference firmware — see `ReferenceFirmwareKeys` for why that's a
/// deliberate scope boundary, not a missing feature.
enum KernelcacheExtractor {
    static func extractKernelMachO(from firmware: ImportedFirmware, storedAt fileURL: URL) throws -> Data {
        guard let path = firmware.metadata.kernelCachePath else {
            throw KernelcacheExtractionError.noKernelCachePathDeclared
        }

        let reader = try ZipArchiveReader(fileURL: fileURL)
        guard let entry = reader.entry(named: path) else {
            throw KernelcacheExtractionError.entryNotFoundInArchive(path: path)
        }
        let rawData = try reader.data(for: entry)

        let container: IMG3Container
        do {
            container = try IMG3Container(data: rawData)
        } catch {
            throw KernelcacheExtractionError.containerParsingFailed(underlying: error)
        }

        var payload = container.payload
        if container.isEncrypted {
            guard firmware.compatibility.isCompatible else {
                throw KernelcacheExtractionError.unknownDecryptionKey
            }
            let keys = ReferenceFirmwareKeys.kernelcache
            payload = try FirmwareDecryption.aes256CBCDecrypt(payload, key: keys.key, iv: keys.iv)
        }

        do {
            return try AppleLZSS.decompress(payload)
        } catch {
            throw KernelcacheExtractionError.decompressionFailed(underlying: error)
        }
    }
}
