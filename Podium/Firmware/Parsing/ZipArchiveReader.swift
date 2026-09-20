import Foundation
import Compression

/// One file entry from a ZIP central directory.
struct ZipEntry {
    let name: String
    let compressionMethod: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let crc32: UInt32
}

/// Reads the central directory of a ZIP archive and extracts individual
/// entries on demand, without loading the whole archive into memory.
///
/// IPSWs are plain ZIP files (renamed `.ipsw`), commonly hundreds of
/// megabytes to a few gigabytes. Podium only ever needs a handful of small
/// named entries out of them (`BuildManifest.plist` first), so this reads
/// just the central directory plus the specific bytes of each requested
/// entry, via random access (`FileHandle.seek`), rather than unzipping
/// everything up front.
///
/// This implements the subset of the ZIP format (PKWARE APPNOTE.TXT)
/// needed for that: the End Of Central Directory record, central and
/// local file headers, and compression methods 0 (stored) and 8
/// (deflate). ZIP64 (needed only past ~4 GB / 65535 entries) is detected
/// and reported as unsupported rather than silently mis-read — no IPSW
/// for this device generation approaches that size, but a wrong read of
/// one that did would be worse than a clear error.
final class ZipArchiveReader {
    private let fileHandle: FileHandle
    let entries: [ZipEntry]

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x0706_4b50

    init(fileURL: URL) throws {
        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw FirmwareParsingError.unreadableFile(underlying: error)
        }
        let length = try Self.fileLength(of: fileHandle)
        entries = try Self.readCentralDirectory(fileHandle, fileLength: length)
    }

    deinit {
        try? fileHandle.close()
    }

    func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name }
    }

    /// Extracts and, if needed, decompresses a single entry's data.
    func data(for entry: ZipEntry) throws -> Data {
        try fileHandle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try fileHandle.read(upToCount: 30), header.count == 30 else {
            throw FirmwareParsingError.unreadableFile(underlying: CocoaError(.fileReadCorruptFile))
        }
        let signature = header.readUInt32LE(at: 0)
        guard signature == Self.localFileHeaderSignature else {
            throw FirmwareParsingError.notAZipArchive
        }
        let nameLength = Int(header.readUInt16LE(at: 26))
        let extraLength = Int(header.readUInt16LE(at: 28))
        try fileHandle.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(nameLength + extraLength))

        let compressed = try readExact(count: Int(entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw FirmwareParsingError.unsupportedZipFeature("Compression method \(entry.compressionMethod) is not supported.")
        }
    }

    private func readExact(count: Int) throws -> Data {
        guard let data = try fileHandle.read(upToCount: count), data.count == count else {
            throw FirmwareParsingError.unreadableFile(underlying: CocoaError(.fileReadCorruptFile))
        }
        return data
    }

    // MARK: - Central directory

    private static func fileLength(of handle: FileHandle) throws -> UInt64 {
        let current = try handle.offset()
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: current)
        return end
    }

    /// Scans backward from the end of the file for the End Of Central
    /// Directory signature. The EOCD record is fixed-size except for a
    /// trailing comment (0-65535 bytes), so it can appear anywhere in the
    /// last ~64 KB of the file.
    private static func readCentralDirectory(_ handle: FileHandle, fileLength: UInt64) throws -> [ZipEntry] {
        let searchWindow = min(fileLength, 66_000)
        let searchStart = fileLength - searchWindow
        try handle.seek(toOffset: searchStart)
        guard let tail = try handle.read(upToCount: Int(searchWindow)) else {
            throw FirmwareParsingError.notAZipArchive
        }

        guard let eocdRange = tail.lastRange(ofFourByteLESignature: endOfCentralDirectorySignature) else {
            throw FirmwareParsingError.notAZipArchive
        }

        let eocd = tail.subdata(in: eocdRange)
        guard eocd.count >= 22 else {
            throw FirmwareParsingError.notAZipArchive
        }

        let totalEntries = eocd.readUInt16LE(at: 10)
        let centralDirectorySize = eocd.readUInt32LE(at: 12)
        let centralDirectoryOffset = eocd.readUInt32LE(at: 16)

        if totalEntries == 0xFFFF || centralDirectoryOffset == 0xFFFF_FFFF {
            throw FirmwareParsingError.unsupportedZipFeature("This IPSW uses ZIP64, which Podium doesn't parse yet.")
        }

        try handle.seek(toOffset: UInt64(centralDirectoryOffset))
        guard let directoryData = try handle.read(upToCount: Int(centralDirectorySize)),
              directoryData.count == Int(centralDirectorySize) else {
            throw FirmwareParsingError.notAZipArchive
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(totalEntries))
        var cursor = 0
        while cursor + 46 <= directoryData.count {
            guard directoryData.readUInt32LE(at: cursor) == centralDirectoryHeaderSignature else {
                break
            }
            let compressionMethod = directoryData.readUInt16LE(at: cursor + 10)
            let crc32 = directoryData.readUInt32LE(at: cursor + 16)
            let compressedSize = directoryData.readUInt32LE(at: cursor + 20)
            let uncompressedSize = directoryData.readUInt32LE(at: cursor + 24)
            let nameLength = Int(directoryData.readUInt16LE(at: cursor + 28))
            let extraLength = Int(directoryData.readUInt16LE(at: cursor + 30))
            let commentLength = Int(directoryData.readUInt16LE(at: cursor + 32))
            let localHeaderOffset = directoryData.readUInt32LE(at: cursor + 42)

            let nameStart = cursor + 46
            guard nameStart + nameLength <= directoryData.count,
                  let name = String(data: directoryData.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) else {
                throw FirmwareParsingError.notAZipArchive
            }

            entries.append(ZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: UInt64(compressedSize),
                uncompressedSize: UInt64(uncompressedSize),
                localHeaderOffset: UInt64(localHeaderOffset),
                crc32: crc32
            ))

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    /// Decompresses a raw DEFLATE stream (ZIP compression method 8).
    ///
    /// Assumption: Apple's Compression framework's `COMPRESSION_ZLIB`
    /// algorithm operates on raw DEFLATE (RFC 1951) data, not zlib-wrapped
    /// data (RFC 1950, which adds a 2-byte header and Adler-32 trailer).
    /// This matches ZIP's own entry format and is the standard way to
    /// decode ZIP deflate data with this framework without a third-party
    /// zlib dependency.
    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let producedCount: Int = try output.withUnsafeMutableBytes { rawOut in
            guard let outPtr = rawOut.bindMemory(to: UInt8.self).baseAddress else {
                throw FirmwareParsingError.unreadableFile(underlying: CocoaError(.fileReadCorruptFile))
            }
            return try compressed.withUnsafeBytes { rawIn -> Int in
                guard let inPtr = rawIn.bindMemory(to: UInt8.self).baseAddress else {
                    throw FirmwareParsingError.unreadableFile(underlying: CocoaError(.fileReadCorruptFile))
                }
                let result = compression_decode_buffer(
                    outPtr, expectedSize,
                    inPtr, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
                guard result == expectedSize else {
                    throw FirmwareParsingError.unsupportedZipFeature("Deflate output size mismatch (expected \(expectedSize), got \(result)).")
                }
                return result
            }
        }
        output.removeSubrange(producedCount..<output.count)
        return output
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[self.startIndex + offset]) | (UInt16(self[self.startIndex + offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[self.startIndex + offset])
            | (UInt32(self[self.startIndex + offset + 1]) << 8)
            | (UInt32(self[self.startIndex + offset + 2]) << 16)
            | (UInt32(self[self.startIndex + offset + 3]) << 24)
    }

    /// Finds the last occurrence of a 4-byte little-endian signature,
    /// searching from the end (EOCD is always the *last* such record).
    func lastRange(ofFourByteLESignature signature: UInt32) -> Range<Int>? {
        guard count >= 4 else { return nil }
        let bytes: [UInt8] = [
            UInt8(signature & 0xFF),
            UInt8((signature >> 8) & 0xFF),
            UInt8((signature >> 16) & 0xFF),
            UInt8((signature >> 24) & 0xFF),
        ]
        let base = startIndex
        var i = count - 4
        while i >= 0 {
            if self[base + i] == bytes[0], self[base + i + 1] == bytes[1],
               self[base + i + 2] == bytes[2], self[base + i + 3] == bytes[3] {
                return i..<count
            }
            i -= 1
        }
        return nil
    }
}
