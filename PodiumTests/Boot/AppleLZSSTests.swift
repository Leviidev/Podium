import XCTest
@testable import Podium

final class AppleLZSSTests: XCTestCase {
    /// Builds a valid "complzss" container the same way `AppleLZSS`
    /// expects to read one: 8-byte magic, three big-endian uint32 fields
    /// (checksum/decompressed size/compressed size), one reserved field,
    /// padded to the fixed 0x180-byte header, then the raw token stream.
    private func makeContainer(tokens: [UInt8], decompressed: [UInt8]) -> Data {
        var header = Data("complzss".utf8)
        func appendBE(_ value: UInt32) {
            header.append(UInt8((value >> 24) & 0xFF))
            header.append(UInt8((value >> 16) & 0xFF))
            header.append(UInt8((value >> 8) & 0xFF))
            header.append(UInt8(value & 0xFF))
        }
        appendBE(Adler32.checksum(of: decompressed))
        appendBE(UInt32(decompressed.count))
        appendBE(UInt32(tokens.count))
        appendBE(0)
        header.append(Data(repeating: 0, count: 0x180 - header.count))
        return header + Data(tokens)
    }

    func testDecompressesAllLiteralTokens() throws {
        // Flag byte 0b00000111 marks the next three tokens as literals.
        let decompressed = Array("Hi!".utf8)
        let tokens: [UInt8] = [0b0000_0111] + decompressed
        let container = makeContainer(tokens: tokens, decompressed: decompressed)

        let result = try AppleLZSS.decompress(container)
        XCTAssertEqual(Array(result), decompressed)
    }

    func testDecompressesBackReference() throws {
        // One literal 'A', then a back-reference that copies it 9 more
        // times: offset 4078 (where the first literal lands in a fresh
        // 4096-byte window) encoded as i0=0xEE, high nibble of offset in
        // j0's top nibble (0xF), copy-length-minus-3 (9-3=6) in the low
        // nibble — verified independently in Python before porting here.
        let decompressed = Array(repeating: UInt8(ascii: "A"), count: 10)
        let tokens: [UInt8] = [0b0000_0001, UInt8(ascii: "A"), 0xEE, 0xF6]
        let container = makeContainer(tokens: tokens, decompressed: decompressed)

        let result = try AppleLZSS.decompress(container)
        XCTAssertEqual(Array(result), decompressed)
    }

    func testWrongChecksumIsDetected() {
        let decompressed = Array("Hi!".utf8)
        let tokens: [UInt8] = [0b0000_0111] + decompressed
        var container = makeContainer(tokens: tokens, decompressed: decompressed)
        // Corrupt one payload byte so decompression no longer matches
        // the header's checksum, without touching the header itself.
        container[container.count - 1] ^= 0xFF

        XCTAssertThrowsError(try AppleLZSS.decompress(container)) { error in
            guard case AppleLZSSError.checksumMismatch = error else {
                return XCTFail("Expected .checksumMismatch, got \(error)")
            }
        }
    }

    func testMissingSignatureIsRejected() {
        let bogus = Data(repeating: 0, count: 0x200)
        XCTAssertThrowsError(try AppleLZSS.decompress(bogus)) { error in
            guard case AppleLZSSError.invalidHeader = error else {
                return XCTFail("Expected .invalidHeader, got \(error)")
            }
        }
    }
}

final class Adler32Tests: XCTestCase {
    func testKnownVector() {
        // Independently computed via Python's zlib.adler32 during this
        // format's initial validation against the real iPod4,1 6.1.6
        // kernelcache.
        XCTAssertEqual(Adler32.checksum(of: Array(repeating: UInt8(ascii: "A"), count: 10)), 0x0E01_028B)
    }

    func testEmptyInput() {
        XCTAssertEqual(Adler32.checksum(of: []), 1)
    }
}
