import Foundation
import Compression
import CommonCrypto

enum DiskImageError: Error, CustomStringConvertible {
    case notUDIF
    case noHFSPartition
    case unsupportedChunk(UInt32)
    case corrupt(String)

    var description: String {
        switch self {
        case .notUDIF: return "not a UDIF disk image"
        case .noHFSPartition: return "the disk image has no HFS partition"
        case .unsupportedChunk(let type): return String(format: "unsupported disk image chunk type 0x%08x", type)
        case .corrupt(let what): return "corrupt disk image: \(what)"
        }
    }
}

/// Reads one partition of a UDIF (`.dmg`) disk image — the format of
/// iOS root filesystem images once decrypted — as a flat run of bytes.
///
/// The image ends in a 512-byte `koly` trailer pointing at an XML
/// property list whose `resource-fork`/`blkx` entries describe each
/// partition as a table (`mish`) of chunks: a run of sectors, stored raw,
/// zlib-compressed, or not at all (zero-filled). Chunks are decompressed
/// on demand, and the last few kept, since reads come in runs.
final class UDIFDiskImage: VolumeByteSource {
    struct Chunk {
        let type: UInt32
        let firstSector: UInt64
        let sectorCount: UInt64
        let dataOffset: UInt64
        let dataLength: UInt64
    }

    static let sectorSize: UInt64 = 512
    static let zlibChunk: UInt32 = 0x8000_0005
    static let rawChunk: UInt32 = 0x0000_0001
    static let zeroChunks: Set<UInt32> = [0x0000_0000, 0x0000_0002]
    static let commentChunk: UInt32 = 0x7FFF_FFFE
    static let terminatorChunk: UInt32 = 0xFFFF_FFFF

    private let fileDescriptor: Int32
    let chunks: [Chunk]
    let partitionName: String
    /// The partition's size in bytes.
    let length: UInt64
    private var cache: [(index: Int, bytes: [UInt8])] = []

    init(url: URL, partitionNameContaining wanted: String = "Apple_HFS") throws {
        fileDescriptor = open(url.path, O_RDONLY)
        guard fileDescriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, info.st_size >= 512 else { close(fileDescriptor); throw DiskImageError.notUDIF }
        let fileSize = UInt64(info.st_size)
        let trailer = try Self.pread(fileDescriptor, 512, at: fileSize - 512)
        guard trailer.prefix(4).elementsEqual("koly".utf8) else { close(fileDescriptor); throw DiskImageError.notUDIF }
        let dataForkOffset = trailer.be64(24)
        let xmlOffset = trailer.be64(0xD8)
        let xmlLength = trailer.be64(0xE0)
        guard xmlOffset + xmlLength <= fileSize else { close(fileDescriptor); throw DiskImageError.corrupt("plist outside the file") }
        let xml = try Self.pread(fileDescriptor, Int(xmlLength), at: xmlOffset)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(xml), format: nil) as? [String: Any],
              let resources = plist["resource-fork"] as? [String: Any],
              let blkx = resources["blkx"] as? [[String: Any]] else { close(fileDescriptor); throw DiskImageError.corrupt("no blkx table") }
        guard let partition = blkx.first(where: { ($0["Name"] as? String)?.contains(wanted) == true }),
              let table = partition["Data"] as? Data else { close(fileDescriptor); throw DiskImageError.noHFSPartition }
        let mish = [UInt8](table)
        guard mish.count >= 204, mish.prefix(4).elementsEqual("mish".utf8) else { close(fileDescriptor); throw DiskImageError.corrupt("bad mish header") }
        let partitionSectors = mish.be64(16)
        let chunkDataOffset = mish.be64(24)
        let count = Int(mish.be32(200))
        guard mish.count >= 204 + count * 40 else { close(fileDescriptor); throw DiskImageError.corrupt("truncated chunk table") }
        var chunks: [Chunk] = []
        for index in 0..<count {
            let o = 204 + index * 40
            let type = mish.be32(o)
            guard type != Self.commentChunk, type != Self.terminatorChunk else { continue }
            chunks.append(Chunk(type: type, firstSector: mish.be64(o + 8), sectorCount: mish.be64(o + 16),
                                dataOffset: dataForkOffset + chunkDataOffset + mish.be64(o + 24), dataLength: mish.be64(o + 32)))
        }
        self.chunks = chunks.sorted { $0.firstSector < $1.firstSector }
        partitionName = partition["Name"] as? String ?? ""
        length = partitionSectors * Self.sectorSize
    }

    deinit { close(fileDescriptor) }

    func readBytes(_ count: Int, at offset: UInt64) throws -> [UInt8] {
        guard offset + UInt64(count) <= length else { throw DiskImageError.corrupt("read past the partition's end") }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var position = offset
        let end = offset + UInt64(count)
        while position < end {
            let sector = position / Self.sectorSize
            guard let index = chunkIndex(containing: sector) else { throw DiskImageError.corrupt("no chunk covers sector \(sector)") }
            let chunk = chunks[index]
            let chunkStart = chunk.firstSector * Self.sectorSize
            let chunkEnd = chunkStart + chunk.sectorCount * Self.sectorSize
            let take = min(end, chunkEnd) - position
            if Self.zeroChunks.contains(chunk.type) {
                out.append(contentsOf: repeatElement(0, count: Int(take)))
            } else {
                let bytes = try decoded(index)
                let from = Int(position - chunkStart)
                out.append(contentsOf: bytes[from..<from + Int(take)])
            }
            position += take
        }
        return out
    }

    private func chunkIndex(containing sector: UInt64) -> Int? {
        var low = 0, high = chunks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let chunk = chunks[mid]
            if sector < chunk.firstSector { high = mid - 1 }
            else if sector >= chunk.firstSector + chunk.sectorCount { low = mid + 1 }
            else { return mid }
        }
        return nil
    }

    private func decoded(_ index: Int) throws -> [UInt8] {
        if let hit = cache.firstIndex(where: { $0.index == index }) {
            let entry = cache.remove(at: hit)
            cache.append(entry)
            return entry.bytes
        }
        let chunk = chunks[index]
        let size = Int(chunk.sectorCount * Self.sectorSize)
        let stored = try Self.pread(fileDescriptor, Int(chunk.dataLength), at: chunk.dataOffset)
        let bytes: [UInt8]
        switch chunk.type {
        case Self.rawChunk:
            guard stored.count >= size else { throw DiskImageError.corrupt("short raw chunk") }
            bytes = Array(stored.prefix(size))
        case Self.zlibChunk:
            // zlib-wrapped: skip the 2-byte header; COMPRESSION_ZLIB
            // decodes the raw DEFLATE stream inside.
            guard stored.count > 2 else { throw DiskImageError.corrupt("empty zlib chunk") }
            var output = [UInt8](repeating: 0, count: size)
            let produced = stored.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    compression_decode_buffer(out.baseAddress!, size, input.baseAddress! + 2, input.count - 2, nil, COMPRESSION_ZLIB)
                }
            }
            guard produced == size else { throw DiskImageError.corrupt("zlib chunk \(index) inflated to \(produced) of \(size) bytes") }
            bytes = output
        default:
            throw DiskImageError.unsupportedChunk(chunk.type)
        }
        cache.append((index, bytes))
        if cache.count > 8 { cache.removeFirst() }
        return bytes
    }

    private static func pread(_ fd: Int32, _ count: Int, at offset: UInt64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            guard n > 0 else { throw DiskImageError.corrupt("read failed at \(offset + UInt64(done))") }
            done += n
        }
        return bytes
    }
}

/// Decrypts an `encrcdsa` (version 2) encrypted disk image as a stream —
/// the container Apple wraps iOS root filesystem DMGs in. The key is 36
/// bytes: a 16-byte AES-128 key and a 20-byte HMAC-SHA1 key. The payload
/// after the header is split into `blockSize` blocks, each AES-128-CBC
/// with its IV the first 16 bytes of HMAC-SHA1(hmacKey, block number as
/// big-endian UInt32).
final class EncryptedDiskImageDecryptor {
    enum DecryptError: Error {
        case notEncrypted
        case badKey
        case cryptoFailed(Int32)
    }

    private let aesKey: [UInt8]
    private let hmacKey: [UInt8]
    private let output: ([UInt8]) throws -> Void
    private var pending: [UInt8] = []
    private var consumed: UInt64 = 0
    private var headerParsed = false
    private var blockSize = 0
    private var dataOffset: UInt64 = 0
    private var remaining: UInt64 = 0
    private var blockNumber: UInt32 = 0

    init(key: [UInt8], output: @escaping ([UInt8]) throws -> Void) throws {
        guard key.count == 36 else { throw DecryptError.badKey }
        aesKey = Array(key[0..<16])
        hmacKey = Array(key[16..<36])
        self.output = output
    }

    func feed(_ bytes: UnsafeRawBufferPointer) throws {
        pending.append(contentsOf: bytes)
        if !headerParsed {
            guard pending.count >= 72 else { return }
            guard pending.prefix(8).elementsEqual("encrcdsa".utf8) else { throw DecryptError.notEncrypted }
            blockSize = Int(pending.be32(52))
            remaining = pending.be64(56)
            dataOffset = pending.be64(64)
            guard blockSize >= 16, blockSize % 16 == 0 else { throw DecryptError.notEncrypted }
            headerParsed = true
        }
        if consumed < dataOffset {
            let skip = Int(min(UInt64(pending.count), dataOffset - consumed))
            pending.removeFirst(skip)
            consumed += UInt64(skip)
            if consumed < dataOffset { return }
        }
        let wholeBlocks = pending.count / blockSize
        guard wholeBlocks > 0, remaining > 0 else { return }
        var plain = [UInt8](repeating: 0, count: wholeBlocks * blockSize)
        try pending.withUnsafeBufferPointer { cipher in
            try plain.withUnsafeMutableBufferPointer { out in
                for block in 0..<wholeBlocks {
                    try decryptBlock(cipher.baseAddress! + block * blockSize, into: out.baseAddress! + block * blockSize)
                }
            }
        }
        pending.removeFirst(wholeBlocks * blockSize)
        consumed += UInt64(wholeBlocks * blockSize)
        let take = Int(min(UInt64(plain.count), remaining))
        remaining -= UInt64(take)
        try output(take == plain.count ? plain : Array(plain.prefix(take)))
    }

    var isComplete: Bool { headerParsed && remaining == 0 }

    private func decryptBlock(_ cipher: UnsafePointer<UInt8>, into plain: UnsafeMutablePointer<UInt8>) throws {
        var number = blockNumber.bigEndian
        blockNumber += 1
        var mac = [UInt8](repeating: 0, count: 20)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), hmacKey, hmacKey.count, &number, 4, &mac)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), 0, aesKey, 16, mac,
                             cipher, blockSize, plain, blockSize, &moved)
        guard status == kCCSuccess else { throw DecryptError.cryptoFailed(status) }
    }
}
