import Foundation
import Compression

/// HFS+ transparent compression ("decmpfs"), as iOS root filesystems use
/// it: a file flagged `UF_COMPRESSED` keeps an empty data fork, and its
/// contents are described by a `com.apple.decmpfs` attribute — a
/// little-endian header (`cmpf` magic, compression type, uncompressed
/// size) followed, for type 3, by the zlib-compressed contents themselves,
/// or, for type 4, pointing at the resource fork, which holds a table of
/// 64 KB blocks, each compressed on its own.
enum Decmpfs {
    static let attributeName = "com.apple.decmpfs"
    private static let magic: UInt32 = 0x636D_7066 // "fpmc" on disk
    private static let blockSize = 64 * 1024

    static func decompress(attribute: [UInt8], resourceFork: () throws -> [UInt8]) throws -> [UInt8] {
        guard attribute.count >= 16, le32(attribute, 0) == magic else { throw HFSPlusError.corrupt("bad decmpfs header") }
        let type = le32(attribute, 4)
        let size = Int(le32(attribute, 8)) | Int(le32(attribute, 12)) << 32
        switch type {
        case 1:
            return Array(attribute.dropFirst(16).prefix(size))
        case 3:
            return try inflate(Array(attribute.dropFirst(16)), expected: size)
        case 4:
            let fork = try resourceFork()
            // Resource fork header: data section offset (big-endian); the
            // data section starts with its length, then a little-endian
            // block count and (offset, length) pairs relative to just
            // past that length word.
            guard fork.count >= 0x108 else { throw HFSPlusError.corrupt("short decmpfs resource fork") }
            let dataStart = Int(fork.be32(0)) + 4
            let blocks = Int(le32(fork, dataStart))
            var out: [UInt8] = []
            out.reserveCapacity(size)
            for block in 0..<blocks {
                let entry = dataStart + 4 + block * 8
                let offset = dataStart + Int(le32(fork, entry))
                let length = Int(le32(fork, entry + 4))
                guard offset + length <= fork.count else { throw HFSPlusError.corrupt("decmpfs block past the resource fork's end") }
                out += try inflate(Array(fork[offset..<offset + length]), expected: min(blockSize, size - out.count))
            }
            guard out.count == size else { throw HFSPlusError.corrupt("decmpfs file decompressed to \(out.count) of \(size) bytes") }
            return out
        default:
            throw HFSPlusError.unsupported("decmpfs compression type \(type)")
        }
    }

    /// One zlib stream, or — marked by a leading 0xFF — stored bytes.
    private static func inflate(_ bytes: [UInt8], expected: Int) throws -> [UInt8] {
        guard let first = bytes.first else { return [] }
        if first == 0xFF { return Array(bytes.dropFirst().prefix(expected)) }
        guard bytes.count > 2, expected > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: expected)
        let produced = bytes.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, expected, input.baseAddress! + 2, input.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == expected else { throw HFSPlusError.corrupt("zlib block inflated to \(produced) of \(expected) bytes") }
        return out
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
