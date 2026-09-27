import Foundation

/// The S5L8930X DART (device tree `dart2`: the display IOMMU, with
/// `mapper-clcd`, `mapper-rgbout` and `mapper-scaler` as stream IDs 0, 1
/// and 2) — its segment table, and translation of device addresses back
/// to physical ones for scanout.
///
/// From the kernel's AppleS5L8930XDART: each of 4 stream IDs has 64
/// segment table entries (STEs), one per 4 MB of device address space,
/// each the physical address of a page of 1024 page table entries (bit 0
/// valid) whose own bit 0 marks a valid 4 KB page, `(pa & ~0xFFF) | 1`.
/// STEs aren't memory-mapped: the kernel writes `+0x08` and then the TLB
/// operation register `+0x00` with `(sid << 8) | (segment << 22) | 5`, or
/// writes `... | 4` there and reads the STE back from `+0x08`. `0x0FFFFF02`
/// flushes every TLB; bit 3 of `+0x00` is busy, never set here since
/// operations complete at once. Everything else is kept as written.
final class S5L8930XDART: MMIODevice {
    static let windowLength: UInt32 = 0x2000
    static let streamCount = 4
    static let segmentCount = 64

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private(set) var segmentTable = [UInt32](repeating: 0, count: streamCount * segmentCount)

    func readRegister(at offset: UInt32) -> UInt32 {
        registers[Int(offset / 4)]
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        registers[Int(offset / 4)] = value
        guard offset == 0 else { return }
        let stream = Int((value >> 8) & 3)
        let segment = Int((value >> 22) & 0x3F)
        switch value & 7 {
        case 4: registers[2] = segmentTable[stream * Self.segmentCount + segment]
        case 5: segmentTable[stream * Self.segmentCount + segment] = registers[2]
        default: break
        }
    }

    /// Whether the kernel has set up any segment for `stream` yet. Until
    /// it does (iBoot's boot logo, say), the stream's device addresses are
    /// physical ones.
    func hasSegments(stream: Int) -> Bool {
        segmentTable[stream * Self.segmentCount..<(stream + 1) * Self.segmentCount].contains { $0 & 1 != 0 }
    }

    /// The physical address `deviceAddress` maps to for `stream`, or nil
    /// when the segment or page isn't valid.
    func translate(_ deviceAddress: UInt32, stream: Int, memory: MemoryBus) -> UInt32? {
        let entry = segmentTable[stream * Self.segmentCount + Int((deviceAddress >> 22) & 0x3F)]
        guard entry & 1 != 0,
              let page = try? memory.readWord32(at: (entry & ~0xFFF) + ((deviceAddress >> 12) & 0x3FF) * 4),
              page & 1 != 0 else { return nil }
        return (page & ~0xFFF) | (deviceAddress & 0xFFF)
    }
}
