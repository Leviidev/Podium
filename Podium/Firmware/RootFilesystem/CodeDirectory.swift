import CryptoKit
import Foundation

/// The code signature embedded in an iOS 6 (32-bit) Mach-O, as far as
/// editing a signed binary needs: its CodeDirectory holds a SHA-1 hash of
/// every page of the file up to the signature, which the kernel checks
/// each page against as it's paged in. A page that doesn't match
/// invalidates the whole process's signature, and with it every
/// entitlement the process has — so a binary edited here gets the hashes
/// of its changed pages recomputed, and keeps a valid signature.
///
/// Layout (big-endian): an embedded-signature superblob (`0xFADE0CC0`,
/// length, count, then `(slot, offset)` pairs); slot 0 is the
/// CodeDirectory (`0xFADE0C02`): version, flags, hashOffset, identOffset,
/// nSpecialSlots, nCodeSlots, codeLimit, hashSize, hashType, spare1,
/// pageSize (log2), with code hash n at `hashOffset + n * hashSize`.
enum CodeDirectory {
    enum Error: Swift.Error {
        case unsigned
        case unsupported(String)
    }

    private static let loadCommandCodeSignature: UInt32 = 0x1D

    /// Recomputes every code page hash in `binary`'s CodeDirectory.
    static func updatePageHashes(_ binary: inout [UInt8]) throws {
        func le32(_ offset: Int) -> Int { Int(binary[offset]) | Int(binary[offset + 1]) << 8 | Int(binary[offset + 2]) << 16 | Int(binary[offset + 3]) << 24 }
        func be32(_ offset: Int) -> Int { Int(binary[offset]) << 24 | Int(binary[offset + 1]) << 16 | Int(binary[offset + 2]) << 8 | Int(binary[offset + 3]) }
        guard binary.count >= 28, le32(0) == 0xFEED_FACE else { throw Error.unsupported("not a thin 32-bit Mach-O") }

        var signatureOffset: Int?
        var command = 28
        for _ in 0..<le32(16) {
            if le32(command) == loadCommandCodeSignature { signatureOffset = le32(command + 8) }
            command += le32(command + 4)
        }
        guard let superblob = signatureOffset, be32(superblob) == 0xFADE_0CC0 else { throw Error.unsigned }

        for index in 0..<be32(superblob + 8) {
            let entry = superblob + 12 + index * 8
            guard be32(entry) == 0 else { continue }
            let directory = superblob + be32(entry + 4)
            guard be32(directory) == 0xFADE_0C02 else { throw Error.unsupported("slot 0 isn't a CodeDirectory") }
            let hashOffset = be32(directory + 16)
            let codeSlots = be32(directory + 28)
            let codeLimit = be32(directory + 32)
            let hashSize = Int(binary[directory + 36]), hashType = Int(binary[directory + 37])
            let pageSize = 1 << Int(binary[directory + 39])
            guard hashSize == 20, hashType == 1 else { throw Error.unsupported("hash type \(hashType)") }
            for page in 0..<codeSlots {
                let start = page * pageSize
                let end = min(start + pageSize, codeLimit)
                let digest = Array(Insecure.SHA1.hash(data: binary[start..<end]))
                let slot = directory + hashOffset + page * 20
                binary.replaceSubrange(slot..<(slot + 20), with: digest)
            }
            return
        }
        throw Error.unsupported("no CodeDirectory")
    }
}
