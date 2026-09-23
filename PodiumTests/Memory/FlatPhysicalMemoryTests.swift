import XCTest
@testable import Podium

final class FlatPhysicalMemoryTests: XCTestCase {
    func testWriteThenReadByte() throws {
        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeByte(0x42, at: 4)
        XCTAssertEqual(try memory.readByte(at: 4), 0x42)
    }

    func testWord16RoundTripIsLittleEndian() throws {
        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeWord16(0xABCD, at: 0)
        XCTAssertEqual(try memory.readByte(at: 0), 0xCD)
        XCTAssertEqual(try memory.readByte(at: 1), 0xAB)
        XCTAssertEqual(try memory.readWord16(at: 0), 0xABCD)
    }

    func testWord32RoundTripIsLittleEndian() throws {
        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeWord32(0x11223344, at: 8)
        XCTAssertEqual(try memory.readByte(at: 8), 0x44)
        XCTAssertEqual(try memory.readByte(at: 9), 0x33)
        XCTAssertEqual(try memory.readByte(at: 10), 0x22)
        XCTAssertEqual(try memory.readByte(at: 11), 0x11)
        XCTAssertEqual(try memory.readWord32(at: 8), 0x11223344)
    }

    func testReadPastEndThrowsUnmapped() {
        let memory = FlatPhysicalMemory(length: 16)
        XCTAssertThrowsError(try memory.readByte(at: 16)) { error in
            XCTAssertEqual(error as? MemoryAccessError, .unmappedAddress(16))
        }
    }

    func testWord32StraddlingEndThrowsOutOfBounds() {
        let memory = FlatPhysicalMemory(length: 16)
        XCTAssertThrowsError(try memory.readWord32(at: 14)) { error in
            XCTAssertEqual(error as? MemoryAccessError, .outOfBounds(address: 14, length: 4))
        }
    }

    func testAddressBelowBaseIsUnmapped() {
        let memory = FlatPhysicalMemory(length: 16, baseAddress: 0x1000)
        XCTAssertThrowsError(try memory.readByte(at: 0x0FFF)) { error in
            XCTAssertEqual(error as? MemoryAccessError, .unmappedAddress(0x0FFF))
        }
    }

    func testNonZeroBaseAddressTranslatesCorrectly() throws {
        let memory = FlatPhysicalMemory(length: 16, baseAddress: 0x1000)
        try memory.writeByte(0x7, at: 0x1000)
        XCTAssertEqual(try memory.readByte(at: 0x1000), 0x7)
    }

    func testAddressNearUInt32MaxDoesNotOverflow() {
        let memory = FlatPhysicalMemory(length: 16, baseAddress: 0xFFFF_FFF0)
        XCTAssertThrowsError(try memory.readWord32(at: 0xFFFF_FFFE)) { error in
            XCTAssertEqual(error as? MemoryAccessError, .outOfBounds(address: 0xFFFF_FFFE, length: 4))
        }
    }

    /// A file mapped over part of the region reads back through it,
    /// copy-on-write: guest writes change memory, never the file.
    func testMapFileIsCopyOnWrite() throws {
        let page = Int(getpagesize())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("podium-mapfile-\(UUID().uuidString)")
        var contents = Data(repeating: 0xAB, count: page)
        contents[0] = 0x11
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = FlatPhysicalMemory(length: page * 4, baseAddress: 0x4000_0000)
        try memory.writeByte(0x55, at: 0x4000_0000)
        let address = 0x4000_0000 + UInt32(page)
        XCTAssertEqual(try memory.mapFile(url, at: address), page)
        XCTAssertEqual(try memory.readByte(at: address), 0x11)
        XCTAssertEqual(try memory.readByte(at: address + 1), 0xAB)
        XCTAssertEqual(try memory.readByte(at: 0x4000_0000), 0x55, "memory outside the mapping is untouched")

        try memory.writeByte(0x22, at: address)
        XCTAssertEqual(try memory.readByte(at: address), 0x22)
        XCTAssertEqual(try Data(contentsOf: url)[0], 0x11, "the file itself never changes")
    }

    func testMapFileRejectsMisalignedAddress() {
        let memory = FlatPhysicalMemory(length: Int(getpagesize()) * 2)
        XCTAssertThrowsError(try memory.mapFile(URL(fileURLWithPath: "/dev/null"), at: 1))
    }
}
