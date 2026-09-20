import Foundation

enum AppleLZSSError: FriendlyError {
    case invalidHeader
    case truncatedInput
    case checksumMismatch(expected: UInt32, computed: UInt32)

    var userMessage: String {
        "Podium couldn't decompress this firmware component."
    }

    var developerDetail: String {
        switch self {
        case .invalidHeader: return "Missing or malformed \"complzss\" header."
        case .truncatedInput: return "Compressed data is shorter than the header declares."
        case .checksumMismatch(let expected, let computed):
            return String(format: "Adler-32 mismatch: expected 0x%08X, computed 0x%08X.", expected, computed)
        }
    }
}

/// Decompresses Apple's "complzss" container: an Adler-32-checked header
/// (`"complzss"` magic, checksum, decompressed/compressed sizes, padded
/// to a fixed size) wrapping a classic LZSS-compressed bitstream —
/// Okumura's widely-used 1989 reference algorithm (4096-byte sliding
/// window, matches of length 3–18, a per-8-token flag byte selecting
/// literal vs. back-reference for each token).
///
/// Verified end-to-end against the real iPod4,1 6.1.6 kernelcache:
/// decompressing it reproduces the header's own embedded Adler-32
/// checksum exactly, and the result is independently confirmed as a
/// valid Mach-O by both this checksum match and `file(1)`.
enum AppleLZSS {
    private static let headerSize = 0x180
    private static let windowSize = 4096
    private static let maxMatchLength = 18
    private static let minMatchThreshold = 2

    static func decompress(_ input: Data) throws -> Data {
        guard input.count >= headerSize else { throw AppleLZSSError.invalidHeader }
        let signature = input.subdata(in: input.startIndex..<(input.startIndex + 8))
        guard signature.elementsEqual(Array("complzss".utf8)) else { throw AppleLZSSError.invalidHeader }

        let expectedChecksum = input.readUInt32BE(at: 8)
        let uncompressedSize = Int(input.readUInt32BE(at: 12))
        let compressedSize = Int(input.readUInt32BE(at: 16))

        guard input.count >= headerSize + compressedSize else { throw AppleLZSSError.truncatedInput }
        let compressedStart = input.startIndex + headerSize
        let compressed = [UInt8](input.subdata(in: compressedStart..<(compressedStart + compressedSize)))

        let decompressed = decode(compressed, expectedOutputLength: uncompressedSize)

        let computedChecksum = Adler32.checksum(of: decompressed)
        guard computedChecksum == expectedChecksum else {
            throw AppleLZSSError.checksumMismatch(expected: expectedChecksum, computed: computedChecksum)
        }

        return Data(decompressed)
    }

    private static func decode(_ compressed: [UInt8], expectedOutputLength: Int) -> [UInt8] {
        var window = [UInt8](repeating: 0x20, count: windowSize + maxMatchLength - 1)
        var windowPosition = windowSize - maxMatchLength

        var output = [UInt8]()
        output.reserveCapacity(expectedOutputLength)

        var position = 0
        var flags: UInt32 = 0
        let count = compressed.count

        while output.count < expectedOutputLength {
            flags >>= 1
            if flags & 0x100 == 0 {
                guard position < count else { break }
                flags = UInt32(compressed[position]) | 0xFF00
                position += 1
            }

            if flags & 1 != 0 {
                guard position < count else { break }
                let byte = compressed[position]
                position += 1
                output.append(byte)
                window[windowPosition] = byte
                windowPosition = (windowPosition + 1) % windowSize
            } else {
                guard position + 1 < count else { break }
                let low = Int(compressed[position])
                let high = Int(compressed[position + 1])
                position += 2

                let matchOffset = low | ((high & 0xF0) << 4)
                let matchLength = (high & 0x0F) + minMatchThreshold

                for step in 0...matchLength {
                    let byte = window[(matchOffset + step) % windowSize]
                    output.append(byte)
                    window[windowPosition] = byte
                    windowPosition = (windowPosition + 1) % windowSize
                    if output.count >= expectedOutputLength { break }
                }
            }
        }

        return output
    }
}

/// The checksum `AppleLZSS`'s header verifies against — the standard
/// zlib/RFC-1950 Adler-32 algorithm (a checksum, not a cryptographic
/// primitive, so it belongs alongside the format it's checking rather
/// than a general crypto module).
enum Adler32 {
    private static let modulus: UInt32 = 65521

    static func checksum(of bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}
