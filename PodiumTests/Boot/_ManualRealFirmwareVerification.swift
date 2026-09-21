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
            dumpZeroLengthFourProperties(deviceTree!)
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
        // Mirrors EmulatorCore.attemptBoot's video setup exactly, so this
        // trace reflects what the live app actually does now, not the
        // pre-video-support boot path.
        let video = BootVideoInfo(
            baseAddress: EmulatorCore.framebufferPhysicalAddress, display: 1,
            rowBytes: UInt32(EmulatorCore.framebufferWidth * 4),
            width: UInt32(EmulatorCore.framebufferWidth), height: UInt32(EmulatorCore.framebufferHeight),
            depth: 32
        )
        let bootArgs = BootArgsBuilder.build(
            virtBase: EmulatorCore.physicalMemoryBaseAddress, physBase: EmulatorCore.physicalMemoryBaseAddress,
            memSize: UInt32(EmulatorCore.physicalMemorySize), topOfKernelData: topOfKernelData,
            deviceTreeP: deviceTree != nil ? deviceTreeAddress : 0, deviceTreeLength: deviceTreeLength,
            video: video
        )
        try bus.writeBytes(bootArgs, at: bootArgsAddress)
        if let deviceTree { try bus.writeBytes(deviceTree, at: deviceTreeAddress) }

        var initialRegisters = image.initialRegisters
        initialRegisters[0] = bootArgsAddress

        let cpu = ARMv7CPU(memory: bus, jit: JITEngine())
        cpu.reset()
        cpu.loadInitialRegisters(initialRegisters)

        let fastForwarded = cpu.run(maxUnits: 50_000_000)
        print("RESULT: ran \(fastForwarded) units, pc=0x\(cpu.registers.pc.hexString8), error=\(String(describing: cpu.lastError)), thumbState=\(cpu.cpsr.thumbState)")
        if case .unsupportedInstruction(_, let haltAddress)? = cpu.lastError {
            let hw0 = try bus.readWord16(at: haltAddress)
            let hw1 = try bus.readWord16(at: haltAddress &+ 2)
            print("RAW HALFWORDS at 0x\(haltAddress.hexString8): hw0=0x\(String(format: "%04X", hw0)) hw1=0x\(String(format: "%04X", hw1))")
        }
        // ml_at_interrupt_context (real kernel disassembly, 0x8008877c):
        // r0 = *(TPIDRPRW); r2 = *(r0 + 0x4d0); r2 = *(r2 + 8);
        // return sp < r2 && sp > r2 - 0x4000.
        let tpidrprw = cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 13, crm: 0, opc2: 4)
        let ptr = try bus.readWord32(at: tpidrprw &+ 0x4D0)
        let bound = try bus.readWord32(at: ptr &+ 8)
        print("TPIDRPRW=0x\(tpidrprw.hexString8) [+0x4D0]=0x\(ptr.hexString8) [+8 of that]=0x\(bound.hexString8) sp=0x\(cpu.registers.sp.hexString8)")
        XCTAssertTrue(true)
    }

    /// Every property with a raw length of exactly 4 and value 0 —
    /// candidates for the same "unpopulated iBoot placeholder" bug class
    /// DeviceTreePatcher.patchClockPlaceholders already fixes for
    /// /cpus/cpu0's clock properties, just possibly in other nodes.
    private func dumpZeroLengthFourProperties(_ data: Data) {
        func walk(offset: Int, path: [String]) -> Int? {
            let nodeHeaderSize = 8, propertyNameSize = 32, propertyHeaderSize = 36
            guard offset + nodeHeaderSize <= data.count else { return nil }
            let nProperties = Int(data.readUInt32LE(at: offset))
            let nChildren = Int(data.readUInt32LE(at: offset + 4))
            var cursor = offset + nodeHeaderSize
            var nodeName = "?"
            for _ in 0..<nProperties {
                guard cursor + propertyHeaderSize <= data.count else { return nil }
                let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
                let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                let rawLength = data.readUInt32LE(at: cursor + propertyNameSize)
                let realLength = Int(rawLength & 0x7FFF_FFFF)
                let valueOffset = cursor + propertyHeaderSize
                if name == "name" { nodeName = String(decoding: data[data.startIndex + valueOffset..<data.startIndex + valueOffset + realLength].prefix(while: { $0 != 0 }), as: UTF8.self) }
                if realLength == 4, valueOffset + 4 <= data.count {
                    let value = data.readUInt32LE(at: valueOffset)
                    if value == 0 {
                        print("ZERO4PROP: \((path + [nodeName]).joined(separator: "/"))/\(name)")
                    }
                }
                cursor = valueOffset + ((realLength + 3) & ~3)
            }
            for _ in 0..<nChildren {
                guard let end = walk(offset: cursor, path: path + [nodeName]) else { return nil }
                cursor = end
            }
            return cursor
        }
        _ = walk(offset: 0, path: [])
    }
}
