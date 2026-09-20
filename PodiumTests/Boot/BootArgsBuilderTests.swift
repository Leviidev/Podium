import XCTest
@testable import Podium

/// Checks the built struct byte-for-byte against the field offsets in
/// Apple's own open-source `pexpert/pexpert/arm/boot.h`, independent of
/// `BootArgsBuilder`'s own implementation (a test that just re-ran the
/// same offset constants wouldn't catch a transcription error shared by
/// both).
final class BootArgsBuilderTests: XCTestCase {
    func testStructSizeMatchesRealBootArgs() {
        XCTAssertEqual(BootArgsBuilder.structSize, 320)
    }

    func testFieldsLandAtTheirRealOffsets() {
        let data = BootArgsBuilder.build(
            virtBase: 0x8000_0000,
            physBase: 0x8000_0000,
            memSize: 0x1000_0000,
            topOfKernelData: 0x8100_0140,
            deviceTreeP: 0x8200_0000,
            deviceTreeLength: 0x1234,
            commandLine: "hi"
        )

        XCTAssertEqual(data.count, 320)

        func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8) }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }

        XCTAssertEqual(u16(0), 1, "Revision")
        XCTAssertEqual(u16(2), 3, "Version — the real iPod4,1 6.1.6 kernel panics with \"Epoch Mismatch\" unless this is exactly 3")
        XCTAssertEqual(u32(4), 0x8000_0000, "virtBase")
        XCTAssertEqual(u32(8), 0x8000_0000, "physBase — what the real kernel reads first, via ldr r8, [r0, #8]")
        XCTAssertEqual(u32(12), 0x1000_0000, "memSize")
        XCTAssertEqual(u32(16), 0x8100_0140, "topOfKernelData")
        // Boot_Video: offset 20, 24 bytes, all zero (no framebuffer yet).
        for byte in data[20..<44] {
            XCTAssertEqual(byte, 0)
        }
        XCTAssertEqual(u32(44), 0, "machineType")
        XCTAssertEqual(u32(48), 0x8200_0000, "deviceTreeP")
        XCTAssertEqual(u32(52), 0x1234, "deviceTreeLength")
        XCTAssertEqual(data[56], UInt8(ascii: "h"))
        XCTAssertEqual(data[57], UInt8(ascii: "i"))
        XCTAssertEqual(data[58], 0, "CommandLine is null-terminated/zero-padded past the string")
        XCTAssertEqual(u32(312), 0, "bootFlags")
        XCTAssertEqual(u32(316), 0x1000_0000, "memSizeActual")
    }

    func testPhysBaseOffsetMatchesWhatTheRealKernelReads() {
        // The real iPod4,1 6.1.6 kernel's very first boot_args access is
        // `ldr r8, [r0, #0x8]`, then `[r0, #0x4]`, then `[r0, #0xc]` —
        // physBase, virtBase, memSize, in that order. This just pins the
        // offsets those three specific reads depend on.
        let data = BootArgsBuilder.build(
            virtBase: 0x1111_1111,
            physBase: 0x2222_2222,
            memSize: 0x3333_3333,
            topOfKernelData: 0,
            deviceTreeP: 0,
            deviceTreeLength: 0
        )
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        XCTAssertEqual(u32(0x4), 0x1111_1111)
        XCTAssertEqual(u32(0x8), 0x2222_2222)
        XCTAssertEqual(u32(0xc), 0x3333_3333)
    }
}
