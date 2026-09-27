import XCTest
@testable import Podium

final class S5L8930XDARTTests: XCTestCase {
    private var dart: S5L8930XDART!
    private var memory: FlatPhysicalMemory!

    override func setUp() {
        dart = S5L8930XDART()
        memory = FlatPhysicalMemory(length: 0x10000, baseAddress: 0x4000_0000)
    }

    /// AppleS5L8930XDART's `_dartSetSTE`: the entry in `+0x08`, then the
    /// operation `(sid << 8) | (segment << 22) | 5` in `+0x00`.
    private func setSegment(_ segment: UInt32, stream: UInt32, to entry: UInt32) {
        dart.writeRegister(entry, at: 0x08)
        dart.writeRegister(stream << 8 | segment << 22 | 5, at: 0x00)
    }

    func testSegmentEntriesReadBackThroughTheOperationRegister() {
        setSegment(3, stream: 1, to: 0x4000_1001)
        setSegment(0, stream: 0, to: 0x4000_2001)
        dart.writeRegister(1 << 8 | 3 << 22 | 4, at: 0x00)
        XCTAssertEqual(dart.readRegister(at: 0x08), 0x4000_1001)
        XCTAssertEqual(dart.readRegister(at: 0x00) & 8, 0, "never busy")
    }

    func testTranslatesThroughSegmentAndPageTables() throws {
        // Segment 1 (device 0x0040_0000...) of stream 0: page table at 0x4000_1000.
        setSegment(1, stream: 0, to: 0x4000_1001)
        try memory.writeWord32(0x4000_8001, at: 0x4000_1000 + 2 * 4)
        XCTAssertEqual(dart.translate(0x0040_2ABC, stream: 0, memory: memory), 0x4000_8ABC)
        XCTAssertNil(dart.translate(0x0040_3000, stream: 0, memory: memory), "invalid page")
        XCTAssertNil(dart.translate(0x0040_2ABC, stream: 1, memory: memory), "other stream's segment is invalid")
    }
}
