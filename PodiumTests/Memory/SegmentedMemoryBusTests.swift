import XCTest
@testable import Podium

final class SegmentedMemoryBusTests: XCTestCase {
    func testRoutesReadsAndWritesToTheContainingRegion() throws {
        let ram = FlatPhysicalMemory(length: 0x1000, baseAddress: 0x8000_0000)
        let armIO = FlatPhysicalMemory(length: 0x1000, baseAddress: 0xBFC0_0000)
        let bus = SegmentedMemoryBus(regions: [ram, armIO])

        try bus.writeWord32(0x1111_1111, at: 0x8000_0010)
        try bus.writeWord32(0x2222_2222, at: 0xBFC0_0010)

        XCTAssertEqual(try bus.readWord32(at: 0x8000_0010), 0x1111_1111)
        XCTAssertEqual(try bus.readWord32(at: 0xBFC0_0010), 0x2222_2222)
        // Each region's own storage is untouched by the other's write.
        XCTAssertEqual(try ram.readWord32(at: 0x8000_0010), 0x1111_1111)
        XCTAssertEqual(try armIO.readWord32(at: 0xBFC0_0010), 0x2222_2222)
    }

    func testThrowsUnmappedForAnAddressInNoRegion() {
        let ram = FlatPhysicalMemory(length: 0x1000, baseAddress: 0x8000_0000)
        let armIO = FlatPhysicalMemory(length: 0x1000, baseAddress: 0xBFC0_0000)
        let bus = SegmentedMemoryBus(regions: [ram, armIO])

        XCTAssertThrowsError(try bus.readByte(at: 0x9000_0000)) { error in
            XCTAssertEqual(error as? MemoryAccessError, .unmappedAddress(0x9000_0000))
        }
    }

    func testLengthIsTheSumOfAllRegions() {
        let ram = FlatPhysicalMemory(length: 0x1000, baseAddress: 0x8000_0000)
        let armIO = FlatPhysicalMemory(length: 0x2000, baseAddress: 0xBFC0_0000)
        let bus = SegmentedMemoryBus(regions: [ram, armIO])

        XCTAssertEqual(bus.length, 0x3000)
    }
}
