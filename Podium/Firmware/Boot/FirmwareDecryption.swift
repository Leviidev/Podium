import Foundation
import CommonCrypto

enum FirmwareDecryptionError: FriendlyError {
    case invalidKeyOrIVLength
    case cryptoFailed(status: Int32)

    var userMessage: String {
        "Podium couldn't decrypt this firmware component."
    }

    var developerDetail: String {
        switch self {
        case .invalidKeyOrIVLength: return "Key must be 32 bytes (AES-256) and IV 16 bytes."
        case .cryptoFailed(let status): return "CCCrypt failed with status \(status)."
        }
    }
}

/// Plain AES-256-CBC, no padding — the boundaries of what's meaningful
/// come from the decrypted content's own container format (`AppleLZSS`'s
/// header declares the real compressed/decompressed sizes), not from
/// PKCS7 padding.
///
/// Uses `CommonCrypto` rather than CryptoKit: CryptoKit's AES support is
/// scoped to authenticated modes (GCM), not plain CBC, which is what
/// this era of Apple firmware encryption actually uses. Confirmed
/// `CommonCrypto` imports directly into Swift on this SDK (no bridging
/// header needed) before relying on it.
enum FirmwareDecryption {
    static func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw FirmwareDecryptionError.invalidKeyOrIVLength
        }

        var output = Data(count: ciphertext.count)
        var bytesMoved = 0

        let status = output.withUnsafeMutableBytes { outBuffer -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { inBuffer -> CCCryptorStatus in
                key.withUnsafeBytes { keyBuffer -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivBuffer -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            inBuffer.baseAddress, ciphertext.count,
                            outBuffer.baseAddress, outBuffer.count,
                            &bytesMoved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw FirmwareDecryptionError.cryptoFailed(status: status)
        }
        return output.prefix(bytesMoved)
    }
}
