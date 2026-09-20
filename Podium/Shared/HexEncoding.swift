import Foundation

extension UInt8 {
    /// Two lowercase hex digits, zero-padded (`0x05` → "05", not "5").
    ///
    /// Deliberately not `String(format: "%02x", self)`: that path goes
    /// through C varargs promotion for a `UInt8` argument, which turned
    /// out to occasionally produce an extra spurious digit — caught by
    /// `FileHasherTests` hashing "hello world" and getting a 65-character
    /// digest back. This is plain Swift with no C interop involved, so
    /// there's nothing left to misbehave.
    var hexString: String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(self >> 4)], digits[Int(self & 0xF)]])
    }
}

extension Sequence where Element == UInt8 {
    var hexEncodedString: String {
        map(\.hexString).joined()
    }
}

extension UInt32 {
    /// 8 uppercase hex digits, zero-padded.
    var hexString8: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return bytes.hexEncodedString.uppercased()
    }
}
