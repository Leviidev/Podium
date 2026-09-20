import Foundation

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[self.startIndex + offset]) | (UInt16(self[self.startIndex + offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[self.startIndex + offset])
            | (UInt32(self[self.startIndex + offset + 1]) << 8)
            | (UInt32(self[self.startIndex + offset + 2]) << 16)
            | (UInt32(self[self.startIndex + offset + 3]) << 24)
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        (UInt32(self[self.startIndex + offset]) << 24)
            | (UInt32(self[self.startIndex + offset + 1]) << 16)
            | (UInt32(self[self.startIndex + offset + 2]) << 8)
            | UInt32(self[self.startIndex + offset + 3])
    }

    /// Reads a fixed-width ASCII tag (e.g. a 4-character IMG3 magic) and
    /// reverses byte order — IMG3 stores every tag this way (`"Img3"` on
    /// disk as bytes reads `"3gmI"`).
    func readReversedASCIITag(at offset: Int, length: Int) -> String {
        let bytes = self.subdata(in: (self.startIndex + offset)..<(self.startIndex + offset + length))
        return String(decoding: bytes.reversed(), as: UTF8.self)
    }

    /// Decodes a lowercase/uppercase hex string into bytes. Traps on
    /// malformed input (odd length or non-hex characters) — every call
    /// site uses this only with a compile-time-constant literal, so a
    /// typo should fail loudly at first run, not silently produce wrong
    /// key material.
    init(hex: String) {
        precondition(hex.count % 2 == 0, "hex string must have an even number of characters")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("invalid hex string")
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
