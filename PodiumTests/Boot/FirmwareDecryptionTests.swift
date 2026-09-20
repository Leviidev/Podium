import XCTest
import CommonCrypto
@testable import Podium

final class FirmwareDecryptionTests: XCTestCase {
    /// `FirmwareDecryption` itself was already validated against the
    /// real, published key for the real iPod4,1 6.1.6 kernelcache
    /// (decrypting it and running the result through `AppleLZSS`
    /// reproduces that container's own embedded checksum exactly). This
    /// test instead exercises the Swift wrapper's buffer handling in
    /// isolation: encrypt with CommonCrypto directly, decrypt with our
    /// function, and confirm they agree — independent of any specific
    /// firmware's key.
    func testRoundTripsWithCommonCryptoEncryptedData() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8(255 - $0) })
        // Exactly 32 bytes (two AES blocks) by construction, rather than
        // trusting a string literal's length at a glance.
        var plaintext = Data("Podium test payload".utf8)
        plaintext.append(Data(repeating: 0x2A, count: 32 - plaintext.count))
        XCTAssertEqual(plaintext.count, 32)

        var ciphertext = Data(count: plaintext.count)
        var bytesMoved = 0
        let status = ciphertext.withUnsafeMutableBytes { outBuffer -> CCCryptorStatus in
            plaintext.withUnsafeBytes { inBuffer -> CCCryptorStatus in
                key.withUnsafeBytes { keyBuffer -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivBuffer -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                            inBuffer.baseAddress, plaintext.count,
                            outBuffer.baseAddress, outBuffer.count, &bytesMoved
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))

        let decrypted = try FirmwareDecryption.aes256CBCDecrypt(ciphertext, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testWrongKeyLengthThrows() {
        let shortKey = Data(repeating: 0, count: 16) // AES-128 length, not 256
        let iv = Data(repeating: 0, count: 16)
        XCTAssertThrowsError(try FirmwareDecryption.aes256CBCDecrypt(Data(repeating: 0, count: 16), key: shortKey, iv: iv)) { error in
            guard case FirmwareDecryptionError.invalidKeyOrIVLength = error else {
                return XCTFail("Expected .invalidKeyOrIVLength, got \(error)")
            }
        }
    }
}
