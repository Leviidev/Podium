import XCTest
@testable import Podium

final class DisplayScanoutTests: XCTestCase {
    private var ram: FlatPhysicalMemory!
    private var pipe: FlatPhysicalMemory!
    private var bus: SegmentedMemoryBus!
    private var dart: S5L8930XDART!
    private var scanout: DisplayScanout!

    override func setUp() {
        ram = FlatPhysicalMemory(length: 0x20000, baseAddress: 0x4000_0000)
        pipe = FlatPhysicalMemory(length: 0x7000, baseAddress: DisplayScanout.pipeBase)
        bus = SegmentedMemoryBus(regions: [ram, pipe])
        dart = S5L8930XDART()
        let boot = GuestFramebuffer(memory: ram, baseAddress: 0x4001_0000, pixelWidth: 4, pixelHeight: 2)
        scanout = DisplayScanout(memory: bus, dart: dart, bootFramebuffer: boot)
    }

    private func frame() -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: 8)
        pixels.withUnsafeMutableBytes { scanout.copyCurrentFrame(into: $0) }
        return pixels
    }

    func testFallsBackToTheBootFramebufferUntilALayerIsEnabled() throws {
        try ram.writeWord32(0xFF12_3456, at: 0x4001_0000)
        XCTAssertEqual(frame()[0], 0xFF12_3456)
    }

    /// A 2x2 BGRA layer at device address 0x1FF8, straddling two device
    /// pages that the DART maps to physical pages far apart: each row
    /// must be fetched page by page.
    func testFetchesLayerRowsThroughTheDART() throws {
        dart.writeRegister(0x4000_1001, at: 0x08)
        dart.writeRegister(5, at: 0x00)
        try ram.writeWord32(0x4000_4001, at: 0x4000_1000 + 1 * 4)
        try ram.writeWord32(0x4000_9001, at: 0x4000_1000 + 2 * 4)
        // Row 0: 0x1FF8 (page 1, end) and 0x1FFC; row 1 at stride 0x40:
        // 0x2038 and 0x203C, on page 2.
        try ram.writeWord32(0x0011_1111, at: 0x4000_4FF8)
        try ram.writeWord32(0x0022_2222, at: 0x4000_4FFC)
        try ram.writeWord32(0x0033_3333, at: 0x4000_9038)
        try ram.writeWord32(0x0044_4444, at: 0x4000_903C)
        let layer = DisplayScanout.pipeBase + DisplayScanout.layerOffsets[0]
        try bus.writeWord32(1, at: layer)
        try bus.writeWord32(0x1FF8, at: layer + 4)
        try bus.writeWord32(0x40 | 2, at: layer + 8)
        try bus.writeWord32(2 << 16 | 2, at: layer + 0x20)

        XCTAssertEqual(frame(), [0xFF11_1111, 0xFF22_2222, 0xFF00_0000, 0xFF00_0000,
                                 0xFF33_3333, 0xFF44_4444, 0xFF00_0000, 0xFF00_0000])
    }
}
