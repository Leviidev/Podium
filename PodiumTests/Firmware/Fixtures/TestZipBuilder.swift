import Foundation
import Compression

/// Builds minimal, valid ZIP archives in memory for tests.
///
/// Podium's repository never ships a real (large, copyrighted) Apple
/// IPSW, so parser tests exercise the ZIP/plist format directly against
/// small synthetic fixtures built with this instead.
struct TestZipBuilder {
    private struct PendingEntry {
        let name: String
        let data: Data
        let compress: Bool
    }

    private var entries: [PendingEntry] = []

    mutating func addEntry(name: String, data: Data, compress: Bool = false) {
        entries.append(PendingEntry(name: name, data: data, compress: compress))
    }

    func build() -> Data {
        var output = Data()

        struct CentralRecord {
            let nameData: Data
            let crc32: UInt32
            let compressedSize: UInt32
            let uncompressedSize: UInt32
            let method: UInt16
            let localOffset: UInt32
        }
        var centralRecords: [CentralRecord] = []

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = Self.crc32(entry.data)
            let method: UInt16 = entry.compress ? 8 : 0
            let payload = entry.compress ? (Self.deflate(entry.data) ?? entry.data) : entry.data

            let localOffset = UInt32(output.count)

            var local = Data()
            local.appendUInt32LE(0x0403_4b50)
            local.appendUInt16LE(20)
            local.appendUInt16LE(0)
            local.appendUInt16LE(method)
            local.appendUInt16LE(0)
            local.appendUInt16LE(0)
            local.appendUInt32LE(crc)
            local.appendUInt32LE(UInt32(payload.count))
            local.appendUInt32LE(UInt32(entry.data.count))
            local.appendUInt16LE(UInt16(nameData.count))
            local.appendUInt16LE(0)
            local.append(nameData)
            local.append(payload)
            output.append(local)

            centralRecords.append(CentralRecord(
                nameData: nameData,
                crc32: crc,
                compressedSize: UInt32(payload.count),
                uncompressedSize: UInt32(entry.data.count),
                method: method,
                localOffset: localOffset
            ))
        }

        let centralDirectoryStart = UInt32(output.count)
        for record in centralRecords {
            var central = Data()
            central.appendUInt32LE(0x0201_4b50)
            central.appendUInt16LE(20)
            central.appendUInt16LE(20)
            central.appendUInt16LE(0)
            central.appendUInt16LE(record.method)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt32LE(record.crc32)
            central.appendUInt32LE(record.compressedSize)
            central.appendUInt32LE(record.uncompressedSize)
            central.appendUInt16LE(UInt16(record.nameData.count))
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt32LE(0)
            central.appendUInt32LE(record.localOffset)
            central.append(record.nameData)
            output.append(central)
        }
        let centralDirectorySize = UInt32(output.count) - centralDirectoryStart

        var eocd = Data()
        eocd.appendUInt32LE(0x0605_4b50)
        eocd.appendUInt16LE(0)
        eocd.appendUInt16LE(0)
        eocd.appendUInt16LE(UInt16(centralRecords.count))
        eocd.appendUInt16LE(UInt16(centralRecords.count))
        eocd.appendUInt32LE(centralDirectorySize)
        eocd.appendUInt32LE(centralDirectoryStart)
        eocd.appendUInt16LE(0)
        output.append(eocd)

        return output
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count + 256)
        let producedCount = output.withUnsafeMutableBytes { rawOut -> Int in
            data.withUnsafeBytes { rawIn -> Int in
                guard let outPtr = rawOut.bindMemory(to: UInt8.self).baseAddress,
                      let inPtr = rawIn.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(outPtr, rawOut.count, inPtr, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard producedCount > 0 else { return nil }
        output.removeSubrange(producedCount..<output.count)
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
