import Foundation
import Compression

/// One file entry from a ZIP central directory.
struct ZipEntry {
    let name: String
    let compressionMethod: UInt16
    let generalPurposeFlags: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let crc32: UInt32
    /// Unix permission/type bits from the central-directory external attributes.
    let unixMode: UInt16

    var isDirectory: Bool { name.hasSuffix("/") || unixMode & 0o170000 == 0o040000 }
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

    /// Opens the named archive member and streams its uncompressed bytes
    /// directly to the caller, without building an intermediate `Data`.
    func stream(named name: String, progress: (Double) -> Void = { _ in }, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard let entry = entry(named: name) else { throw FirmwareParsingError.missingEntry(name: name) }
        try stream(entry, progress: progress, body)
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

    /// Streams an entry's decompressed bytes to `body` a piece at a time,
    /// for entries too large to hold in memory (an IPSW's root filesystem
    /// image is most of a gigabyte). `progress` gets the fraction of the
    /// entry's compressed bytes read so far.
    func stream(_ entry: ZipEntry, progress: (Double) -> Void = { _ in }, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        try fileHandle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try fileHandle.read(upToCount: 30), header.count == 30,
              header.readUInt32LE(at: 0) == Self.localFileHeaderSignature,
              header.readUInt16LE(at: 8) == entry.compressionMethod,
              header.readUInt16LE(at: 6) == entry.generalPurposeFlags,
              entry.generalPurposeFlags & ~UInt16(0x080E) == 0 else {
            throw FirmwareParsingError.notAZipArchive
        }
        let nameLength = UInt64(header.readUInt16LE(at: 26))
        let extraLength = UInt64(header.readUInt16LE(at: 28))
        guard nameLength <= UInt64(Int.max),
              entry.localHeaderOffset <= UInt64.max - 30 - nameLength - extraLength else {
            throw FirmwareParsingError.notAZipArchive
        }
        let nameOffset = entry.localHeaderOffset + 30
        try fileHandle.seek(toOffset: nameOffset)
        let localName = try readExact(count: Int(nameLength))
        guard String(data: localName, encoding: .utf8) == entry.name else { throw FirmwareParsingError.notAZipArchive }
        let payloadOffset = nameOffset + nameLength + extraLength
        guard entry.compressedSize <= UInt64.max - payloadOffset,
              payloadOffset + entry.compressedSize <= (try Self.fileLength(of: fileHandle)) else {
            throw FirmwareParsingError.notAZipArchive
        }
        try fileHandle.seek(toOffset: payloadOffset)
        let readSize = 1 << 20
        var remaining = entry.compressedSize

        if entry.compressionMethod == 0 {
            while remaining > 0 {
                let piece = try readExact(count: Int(min(UInt64(readSize), remaining)))
                remaining -= UInt64(piece.count)
                try piece.withUnsafeBytes(body)
                progress(1 - Double(remaining) / Double(max(entry.compressedSize, 1)))
            }
            return
        }
        guard entry.compressionMethod == 8 else {
            throw FirmwareParsingError.unsupportedZipFeature("Compression method \(entry.compressionMethod) is not supported.")
        }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw FirmwareParsingError.unsupportedZipFeature("Couldn't start a deflate stream.")
        }
        defer { compression_stream_destroy(streamPointer) }
        let outputSize = 4 << 20
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputSize)
        defer { output.deallocate() }
        var finished = false
        while !finished {
            let piece = remaining > 0 ? try readExact(count: Int(min(UInt64(readSize), remaining))) : Data()
            remaining -= UInt64(piece.count)
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            var producedAny = false
            try piece.withUnsafeBytes { input in
                streamPointer.pointee.src_ptr = input.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(output)
                streamPointer.pointee.src_size = input.count
                repeat {
                    streamPointer.pointee.dst_ptr = output
                    streamPointer.pointee.dst_size = outputSize
                    let status = compression_stream_process(streamPointer, flags)
                    guard status != COMPRESSION_STATUS_ERROR else {
                        throw FirmwareParsingError.unsupportedZipFeature("Corrupt deflate data in \(entry.name).")
                    }
                    let produced = outputSize - streamPointer.pointee.dst_size
                    if produced > 0 {
                        producedAny = true
                        try body(UnsafeRawBufferPointer(start: output, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        guard streamPointer.pointee.src_size == 0, remaining == 0 else {
                            throw FirmwareParsingError.unsupportedZipFeature("Trailing data in deflate stream for \(entry.name).")
                        }
                        finished = true
                        break
                    }
                } while streamPointer.pointee.src_size > 0 || streamPointer.pointee.dst_size == 0
            }
            progress(1 - Double(remaining) / Double(max(entry.compressedSize, 1)))
            if !finished, piece.isEmpty, !producedAny {
                throw FirmwareParsingError.unsupportedZipFeature("\(entry.name) ended before its deflate stream did.")
            }
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
            let versionMadeBy = directoryData.readUInt16LE(at: cursor + 4)
            let generalPurposeFlags = directoryData.readUInt16LE(at: cursor + 8)
            let compressionMethod = directoryData.readUInt16LE(at: cursor + 10)
            let crc32 = directoryData.readUInt32LE(at: cursor + 16)
            let compressedSize = directoryData.readUInt32LE(at: cursor + 20)
            let uncompressedSize = directoryData.readUInt32LE(at: cursor + 24)
            let nameLength = Int(directoryData.readUInt16LE(at: cursor + 28))
            let extraLength = Int(directoryData.readUInt16LE(at: cursor + 30))
            let commentLength = Int(directoryData.readUInt16LE(at: cursor + 32))
            let externalAttributes = directoryData.readUInt32LE(at: cursor + 38)
            let localHeaderOffset = directoryData.readUInt32LE(at: cursor + 42)
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, localHeaderOffset != 0xFFFF_FFFF else {
                throw FirmwareParsingError.unsupportedZipFeature("This ZIP uses ZIP64 entry sizes or offsets.")
            }

            let nameStart = cursor + 46
            guard nameStart + nameLength <= directoryData.count,
                  let name = String(data: directoryData.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) else {
                throw FirmwareParsingError.notAZipArchive
            }

            entries.append(ZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                generalPurposeFlags: generalPurposeFlags,
                compressedSize: UInt64(compressedSize),
                uncompressedSize: UInt64(uncompressedSize),
                localHeaderOffset: UInt64(localHeaderOffset),
                crc32: crc32,
                unixMode: versionMadeBy >> 8 == 3 ? UInt16(externalAttributes >> 16) : 0
            ))

            cursor = nameStart + nameLength + extraLength + commentLength
        }
        guard entries.count == Int(totalEntries) else { throw FirmwareParsingError.notAZipArchive }

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
