import XCTest
@testable import Podium

final class S5L8930XCDMATests: XCTestCase {
    private var memory: FlatPhysicalMemory!
    private var lines: [Int: Bool] = [:]
    private var cdma: S5L8930XCDMA!

    override func setUp() {
        memory = FlatPhysicalMemory(length: 0x1000)
        lines = [:]
        cdma = S5L8930XCDMA(memory: { [unowned self] in self.memory }, setInterruptLine: { [unowned self] line, asserted in self.lines[line] = asserted })
    }

    private func write(_ bytes: [UInt8], at address: UInt32) throws {
        try memory.writeBytes(Data(bytes), at: address)
    }

    private func words(_ bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i + $1]) << (8 * $1) } }
    }

    /// One data segment then a zero-command terminator, the shape
    /// AppleCDMA builds for a single-buffer transfer.
    private func chain(at address: UInt32, command: UInt32, buffer: UInt32, length: UInt32) throws {
        for (offset, value) in [(0, address + 0x20), (4, command), (8, buffer), (12, length), (0x24, 0)] {
            try memory.writeWord32(value, at: address + UInt32(offset))
        }
    }

    /// The sequence traced from AppleCDMA/IOAESAccelerator: AES context 1
    /// bound to channel 1, both channels configured memory-to-memory with
    /// their chains and interrupt enable, then started source first.
    private func runPair(aesControl: UInt32, key: [UInt8] = [], iv: [UInt8]) {
        cdma.aes.writeRegister(aesControl, at: 0x1000)
        for (n, word) in words(iv).enumerated() { cdma.aes.writeRegister(word, at: 0x1010 + UInt32(4 * n)) }
        for (n, word) in words(key).enumerated() { cdma.aes.writeRegister(word, at: 0x1020 + UInt32(4 * n)) }
        cdma.writeRegister(0x6, at: 0)
        for (channel, csr, chain) in [(UInt32(1), UInt32(0x188), UInt32(0x100)), (2, 0x88, 0x200)] {
            cdma.writeRegister(2, at: channel << 12)
            cdma.writeRegister(chain, at: channel << 12 | 0x14)
            cdma.writeRegister(csr, at: channel << 12)
            cdma.writeRegister(16, at: channel << 12 | 0xC)
        }
        for channel: UInt32 in [1, 2] {
            cdma.writeRegister(cdma.readRegister(at: channel << 12) | 1, at: channel << 12)
        }
    }

    /// NIST SP 800-38A F.2.1, first block: AES-128-CBC with a key in the
    /// context's key registers.
    func testMemoryToMemoryAESWithRegisteredKeyMatchesNISTVector() throws {
        let key: [UInt8] = [0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c]
        let iv: [UInt8] = Array(0..<16)
        let plaintext: [UInt8] = [0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a]
        try write(plaintext, at: 0x400)
        try chain(at: 0x100, command: 0x30103, buffer: 0x400, length: 16)
        try chain(at: 0x200, command: 0x103, buffer: 0x500, length: 16)

        runPair(aesControl: 1 << 8 | 1 << 16 | 1 << 17 | 1 << 20, key: key, iv: iv)

        XCTAssertEqual(Array(try memory.readBytes(16, at: 0x500)),
                       [0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46, 0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d])
    }

    /// The kernel's completion handler reads CSR, writes it back to clear
    /// the done bit, and must not find the start bit still set there, or
    /// the write-back would restart the channel.
    func testCompletionRaisesDoneAndInterruptThenWriteBackClearsThem() throws {
        try chain(at: 0x100, command: 0x30103, buffer: 0x400, length: 16)
        try chain(at: 0x200, command: 0x103, buffer: 0x500, length: 16)

        runPair(aesControl: 1 << 8 | 1 << 16 | 1 << 17, iv: Array(repeating: 0, count: 16))

        for channel: UInt32 in [1, 2] {
            let csr = cdma.readRegister(at: channel << 12)
            XCTAssertEqual(csr & (1 << 19), 1 << 19, "done")
            XCTAssertEqual(csr & (3 << 16), 0, "no longer running")
            XCTAssertEqual(csr & 1, 0, "start bit self-clears")
            XCTAssertEqual(cdma.readRegister(at: channel << 12 | 0xC), 0, "nothing left to transfer")
            XCTAssertEqual(lines[0x30 + Int(channel)], true)

            cdma.writeRegister(csr, at: channel << 12)
            XCTAssertEqual(cdma.readRegister(at: channel << 12) & (1 << 19), 0)
            XCTAssertEqual(lines[0x30 + Int(channel)], false)
        }
    }

    /// UID operations use the fixed stand-in key: deterministic, and
    /// decrypting with it undoes encrypting with it.
    func testUIDOperationsRoundTripThroughTheStandInKey() throws {
        let plaintext: [UInt8] = Array(repeating: 0x01, count: 16)
        try write(plaintext, at: 0x400)
        try chain(at: 0x100, command: 0x30103, buffer: 0x400, length: 16)
        try chain(at: 0x200, command: 0x103, buffer: 0x500, length: 16)
        runPair(aesControl: 1 << 8 | 1 << 16 | 1 << 17, iv: Array(repeating: 0, count: 16))
        let wrapped = Array(try memory.readBytes(16, at: 0x500))
        XCTAssertNotEqual(wrapped, plaintext)

        setUp()
        try write(wrapped, at: 0x400)
        try chain(at: 0x100, command: 0x30103, buffer: 0x400, length: 16)
        try chain(at: 0x200, command: 0x103, buffer: 0x500, length: 16)
        runPair(aesControl: 1 << 8 | 1 << 17, iv: Array(repeating: 0, count: 16))
        XCTAssertEqual(Array(try memory.readBytes(16, at: 0x500)), plaintext)
    }

    func testChannelEnableBitsReadBack() {
        cdma.writeRegister(0b110, at: 0x0)
        cdma.writeRegister(0b010, at: 0x8)
        XCTAssertEqual(cdma.readRegister(at: 0x10), 0b100)
    }
}
