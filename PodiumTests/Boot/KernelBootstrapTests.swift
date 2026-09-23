import XCTest
@testable import Podium

final class KernelBootstrapTests: XCTestCase {
    private func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// A minimal kernel: one segment at the real link address with a
    /// 4-byte payload, and an LC_UNIXTHREAD entry point.
    private func makeKernel(vmaddr: UInt32, payload: Data, entry: UInt32) -> Data {
        let headerSize = 28, segmentSize = 56, threadSize = 8 + 8 + 17 * 4
        var segment = le32(0x1) + le32(UInt32(segmentSize)) + Data(repeating: 0, count: 16)
        segment += le32(vmaddr) + le32(UInt32(payload.count))
        segment += le32(UInt32(headerSize + segmentSize + threadSize)) + le32(UInt32(payload.count))
        segment += le32(7) + le32(7) + le32(0) + le32(0)
        var thread = le32(0x5) + le32(UInt32(threadSize)) + le32(1) + le32(17)
        for _ in 0..<15 { thread += le32(0) }
        thread += le32(entry) + le32(0)
        let header = le32(0xFEED_FACE) + le32(12) + le32(0) + le32(2) + le32(2) + le32(UInt32(segmentSize + threadSize)) + le32(0)
        return header + segment + thread + payload
    }

    private func word(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    /// The kernel lands at its physical address in DRAM (virtual
    /// `0x8000xxxx` -> physical `0x4000xxxx`), starts there with the MMU
    /// off, and gets `boot_args` in r0 with the real A4 bases.
    func testLoadsKernelThroughTheLinearMapAndLaysOutBootArgs() throws {
        let ram = FlatPhysicalMemory(length: GuestMemoryLayout.ramSize, baseAddress: GuestMemoryLayout.ramPhysicalBase)
        let bus = SegmentedMemoryBus(regions: [ram])
        let kernel = makeKernel(vmaddr: 0x8000_1000, payload: Data([0xDE, 0xAD, 0xBE, 0xEF]), entry: 0x8000_1000)

        let prepared = try KernelBootstrap.prepare(kernel: kernel, deviceTree: nil, on: bus)

        XCTAssertEqual(try bus.readWord32(at: 0x4000_1000), 0xEFBE_ADDE)
        XCTAssertEqual(prepared.entryPoint, 0x4000_1000)
        XCTAssertEqual(prepared.initialRegisters[0], prepared.bootArgsAddress)
        XCTAssertEqual(prepared.bootArgsAddress, 0x4000_2000, "the page after the kernel")
        XCTAssertNil(prepared.deviceTreeAddress)

        let bootArgs = try bus.readBytes(BootArgsBuilder.structSize, at: prepared.bootArgsAddress)
        XCTAssertEqual(word(bootArgs, 4), 0x8000_0000, "virtBase")
        XCTAssertEqual(word(bootArgs, 8), 0x4000_0000, "physBase")
        XCTAssertEqual(word(bootArgs, 12), prepared.memorySizeGivenToKernel, "memSize")
        XCTAssertEqual(word(bootArgs, 20), GuestMemoryLayout.framebufferPhysicalAddress, "video base is physical")

        let topOfKernelData = word(bootArgs, 16)
        XCTAssertEqual(topOfKernelData & 0x3FFF, 0, "goes straight into TTBR0: 16 KB aligned")
        XCTAssertGreaterThanOrEqual(topOfKernelData, prepared.pramAddress + prepared.pramSize)
    }

    /// The framebuffer carve-out at the top of DRAM is never handed to
    /// the kernel as ordinary memory.
    func testMemoryGivenToKernelStopsBelowTheFramebuffer() throws {
        let ram = FlatPhysicalMemory(length: GuestMemoryLayout.ramSize, baseAddress: GuestMemoryLayout.ramPhysicalBase)
        let kernel = makeKernel(vmaddr: 0x8000_1000, payload: Data([0, 0, 0, 0]), entry: 0x8000_1000)
        let prepared = try KernelBootstrap.prepare(kernel: kernel, deviceTree: nil, on: SegmentedMemoryBus(regions: [ram]))
        XCTAssertLessThanOrEqual(GuestMemoryLayout.ramPhysicalBase + prepared.memorySizeGivenToKernel, GuestMemoryLayout.framebufferPhysicalAddress)
        XCTAssertEqual(prepared.memorySizeGivenToKernel & 0xF_FFFF, 0)
    }

    func testLinearMapConversionsRoundTrip() {
        XCTAssertEqual(GuestMemoryLayout.physical(fromKernelVirtual: 0x8000_1000), 0x4000_1000)
        XCTAssertEqual(GuestMemoryLayout.kernelVirtual(fromPhysical: 0x4FFF_F000), 0x8FFF_F000)
        XCTAssertFalse(GuestMemoryLayout.ramPhysicalRange.contains(0x8630_0000), "peripherals, not RAM")
    }

    /// A RAM disk goes in the static region — after the device tree and
    /// pram, 1 MB aligned, below `topOfKernelData` — and switches the
    /// boot-args to root on it.
    func testRAMDiskIsPlacedInTheStaticRegion() throws {
        let ram = FlatPhysicalMemory(length: GuestMemoryLayout.ramSize, baseAddress: GuestMemoryLayout.ramPhysicalBase)
        let kernel = makeKernel(vmaddr: 0x8000_1000, payload: Data([0, 0, 0, 0]), entry: 0x8000_1000)
        let size = 0x0300_0000
        let prepared = try KernelBootstrap.prepare(kernel: kernel, deviceTree: nil, on: SegmentedMemoryBus(regions: [ram]), ramDiskSize: size)

        guard let address = prepared.ramDiskAddress else { return XCTFail("no RAM disk address") }
        XCTAssertEqual(address & 0xF_FFFF, 0)
        XCTAssertGreaterThanOrEqual(address, prepared.pramAddress + prepared.pramSize)
        let bootArgs = try ram.readBytes(BootArgsBuilder.structSize, at: prepared.bootArgsAddress)
        XCTAssertGreaterThanOrEqual(word(bootArgs, 16), address + UInt32(size), "topOfKernelData covers the RAM disk")
        let commandLine = String(decoding: bootArgs[56..<312].prefix(while: { $0 != 0 }), as: UTF8.self)
        XCTAssertTrue(commandLine.contains("rd=md0"))
    }
}
