import XCTest
@testable import Podium

final class ManualRealFirmwareVerification: XCTestCase {
    func testTraceZcramLoop() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ipswURL = repoRoot.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")

        let parsed = try IPSWParser.parse(fileURL: ipswURL)
        let firmware = ImportedFirmware(
            id: UUID(), metadata: parsed.metadata, compatibility: parsed.compatibility,
            importedAt: Date(), storedFileName: "trace.ipsw", isActive: true
        )

        let machO = try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: ipswURL)
        var deviceTree = try? DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: ipswURL)

        let ram = FlatPhysicalMemory(length: EmulatorCore.physicalMemorySize, baseAddress: EmulatorCore.physicalMemoryBaseAddress)
        let lowSRAM = FlatPhysicalMemory(length: 0x0010_0000, baseAddress: 0)
        let bus = SegmentedMemoryBus(regions: [ram, lowSRAM])

        let image = try MachOLoader.load(machO, into: bus)
        let bootArgsAddress = (image.highestAddressUsed + 0xFFF) & ~UInt32(0xFFF)

        if deviceTree != nil {
            DeviceTreePatcher.patchClockPlaceholders(&deviceTree!)
            let ramRange = EmulatorCore.physicalMemoryBaseAddress..<(EmulatorCore.physicalMemoryBaseAddress &+ UInt32(EmulatorCore.physicalMemorySize))
            for region in DeviceTreeMemoryMap.peripheralRegions(in: deviceTree!, excluding: ramRange) {
                bus.addRegion(FlatPhysicalMemory(length: Int(region.size), baseAddress: region.address))
            }
        }

        let deviceTreeAddress = (bootArgsAddress + UInt32(BootArgsBuilder.structSize) + 0xFFF) & ~UInt32(0xFFF)
        let deviceTreeLength = UInt32(deviceTree?.count ?? 0)
        let pramAddress = (deviceTreeAddress + deviceTreeLength + 0xFFF) & ~UInt32(0xFFF)
        let pramSize: UInt32 = 0x1000
        if deviceTree != nil {
            DeviceTreePatcher.patchPramRegion(&deviceTree!, physicalAddress: pramAddress, size: pramSize)
        }

        let topOfKernelData = (pramAddress + pramSize + 0x3FFF) & ~UInt32(0x3FFF)
        let bootArgs = BootArgsBuilder.build(
            virtBase: EmulatorCore.physicalMemoryBaseAddress, physBase: EmulatorCore.physicalMemoryBaseAddress,
            memSize: UInt32(EmulatorCore.physicalMemorySize), topOfKernelData: topOfKernelData,
            deviceTreeP: deviceTree != nil ? deviceTreeAddress : 0, deviceTreeLength: deviceTreeLength
        )
        try bus.writeBytes(bootArgs, at: bootArgsAddress)
        if let deviceTree { try bus.writeBytes(deviceTree, at: deviceTreeAddress) }

        var initialRegisters = image.initialRegisters
        initialRegisters[0] = bootArgsAddress

        let cpu = ARMv7CPU(memory: bus, jit: JITEngine())
        cpu.reset()
        cpu.loadInitialRegisters(initialRegisters)

        let fastForwarded = cpu.run(maxUnits: 50_000_000)
        print("RESULT: ran \(fastForwarded) units, pc=0x\(cpu.registers.pc.hexString8), error=\(String(describing: cpu.lastError))")
        XCTAssertTrue(true)
    }
}
