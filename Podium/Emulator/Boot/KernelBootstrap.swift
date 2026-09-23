import Foundation

/// Does what iBoot does before jumping to the kernel: fills in the device
/// tree properties the kernel can't boot without, backs the SoC's
/// peripheral windows, loads the kernel into DRAM at its physical
/// address, and lays out `boot_args`, the device tree and the `pram`
/// region after it — all per `GuestMemoryLayout`.
///
/// Callers register any peripheral with real behavior (see
/// `S5L8930XPlatform.regions`) on `bus` *before* calling this: the plain-
/// storage backing added here for every other device-tree peripheral goes
/// after it, and the bus hands each access to the first region that
/// accepts it.
enum KernelBootstrap {
    struct Prepared {
        /// All 16 registers the CPU starts with: the physical entry point
        /// in pc, and r0 pointing at `boot_args` (physical — the MMU is off).
        let initialRegisters: [UInt32]
        let bootArgsAddress: UInt32
        let deviceTreeAddress: UInt32?
        let deviceTreeLength: Int
        let memorySizeGivenToKernel: UInt32
        /// The panic-log region (`/pram`), physical.
        let pramAddress: UInt32
        let pramSize: UInt32
        /// Where the caller must put the root filesystem image, if one was
        /// asked for (physical, page-aligned; see `ramDiskSize`).
        let ramDiskAddress: UInt32?
        var entryPoint: UInt32 { initialRegisters[Registers.pcIndex] }
    }

    private static let pramSize: UInt32 = 0x1000
    /// 1 MB: a section boundary for the guest, and a multiple of any host
    /// page size, so the image can be mapped straight from its file.
    private static let ramDiskAlignment: UInt32 = 0x10_0000

    /// The boot-args used with a root RAM disk: root on `md0`, and AMFI's
    /// code-signing/entitlement enforcement off (the trimmed root
    /// filesystem isn't the signed original any more, so its binaries'
    /// signatures and entitlement hashes no longer match what's recorded
    /// for them — `amfi_get_out_of_my_way`/`cs_enforcement_disable` alone
    /// still left AMFI killing every exec with "missing or invalid
    /// entitlement hash", which put several daemons into a launchd
    /// respawn loop; `amfi_allow_any_signature` covers that check too).
    static let ramDiskBootArguments = "rd=md0 amfi_get_out_of_my_way=1 amfi_allow_any_signature=1 cs_enforcement_disable=1 -v"

    /// - Parameter peripheralBacking: wraps each plain-storage peripheral
    ///   region before it's added (a tracing wrapper, for instance).
    /// - Parameter ramDiskSize: reserves room for a root filesystem image
    ///   of this many bytes, as iBoot does for a restore ramdisk: inside
    ///   the static region below `topOfKernelData`, so the kernel never
    ///   hands its pages out, and recorded in `/chosen/memory-map`. The
    ///   caller loads the image at `Prepared.ramDiskAddress`.
    static func prepare(
        kernel machO: Data,
        deviceTree: Data?,
        on bus: SegmentedMemoryBus,
        ramDiskSize: Int? = nil,
        bootArguments: String? = nil,
        peripheralBacking: (FlatPhysicalMemory) -> MemoryBus = { $0 }
    ) throws -> Prepared {
        var deviceTree = deviceTree
        if deviceTree != nil {
            // Before any layout below: the clock patch grows the tree.
            DeviceTreePatcher.patchClockPlaceholders(&deviceTree!)
            DeviceTreePatcher.patchNVRAMProxyData(&deviceTree!)
            DeviceTreePatcher.patchClockFrequencies(&deviceTree!)
            for region in DeviceTreeMemoryMap.peripheralRegions(in: deviceTree!, excluding: GuestMemoryLayout.ramPhysicalRange) {
                bus.addRegion(peripheralBacking(FlatPhysicalMemory(length: Int(region.size), baseAddress: region.address)))
            }
        }

        if deviceTree != nil {
            try leaveDisplayControllerRunning(on: bus)
        }

        let image = try MachOLoader.load(machO, into: bus, physicalAddressForVirtual: GuestMemoryLayout.physical(fromKernelVirtual:))

        // Each component on its own page after the kernel, as iBoot does;
        // `topOfKernelData` covers them all so the kernel's early allocator
        // never reuses this range. It goes straight into TTBR0 in the
        // kernel's start code, whose low 14 bits are ignored — hence the
        // 16 KB alignment.
        let bootArgsAddress = align(image.highestAddressUsed, 0x1000)
        let deviceTreeAddress = align(bootArgsAddress + UInt32(BootArgsBuilder.structSize), 0x1000)
        // The RAM disk entry grows the tree, so it's added before the
        // tree's length is final; its address only depends on where the
        // tree starts, with slack for the entry itself.
        let ramDiskAddress: UInt32? = ramDiskSize.map { _ in
            align(deviceTreeAddress + UInt32(deviceTree?.count ?? 0) + 0x1000 + pramSize, ramDiskAlignment)
        }
        if let ramDiskAddress, let ramDiskSize, deviceTree != nil {
            DeviceTreePatcher.addRAMDisk(&deviceTree!, physicalAddress: ramDiskAddress, size: UInt32(ramDiskSize))
            DeviceTreePatcher.disableSecureRootCheck(&deviceTree!)
        }
        let deviceTreeLength = UInt32(deviceTree?.count ?? 0)
        let pramAddress = align(deviceTreeAddress + deviceTreeLength, 0x1000)
        if deviceTree != nil {
            DeviceTreePatcher.patchPramRegion(&deviceTree!, physicalAddress: pramAddress, size: pramSize)
        }
        var staticEnd = pramAddress + pramSize
        if let ramDiskAddress, let ramDiskSize {
            precondition(ramDiskAddress >= staticEnd, "RAM disk overlaps the device tree")
            staticEnd = ramDiskAddress + UInt32(ramDiskSize)
        }
        let topOfKernelData = align(staticEnd, 0x4000)

        // The framebuffer sits at the top of DRAM; like iBoot's display
        // carve-out, it's left out of the memory given to the kernel so the
        // VM system never hands those pages out as ordinary RAM.
        let memorySize = (GuestMemoryLayout.framebufferPhysicalAddress - GuestMemoryLayout.ramPhysicalBase) & ~UInt32(0xF_FFFF)

        // deviceTreeP is a kernel virtual address; everything else here is
        // physical. v_display 1 is iBoot's convention for the main LCD.
        let video = BootVideoInfo(
            baseAddress: GuestMemoryLayout.framebufferPhysicalAddress,
            display: 1,
            rowBytes: GuestMemoryLayout.framebufferRowBytes,
            width: UInt32(GuestMemoryLayout.framebufferWidth),
            height: UInt32(GuestMemoryLayout.framebufferHeight),
            depth: 32
        )
        let bootArgs = BootArgsBuilder.build(
            virtBase: GuestMemoryLayout.kernelVirtualBase,
            physBase: GuestMemoryLayout.ramPhysicalBase,
            memSize: memorySize,
            topOfKernelData: topOfKernelData,
            deviceTreeP: deviceTree != nil ? GuestMemoryLayout.kernelVirtual(fromPhysical: deviceTreeAddress) : 0,
            deviceTreeLength: deviceTreeLength,
            video: video,
            commandLine: bootArguments ?? (ramDiskSize != nil ? ramDiskBootArguments : "")
        )
        try bus.writeBytes(bootArgs, at: bootArgsAddress)
        if let deviceTree {
            try bus.writeBytes(deviceTree, at: deviceTreeAddress)
        }

        var registers = image.initialRegisters
        registers[0] = bootArgsAddress
        return Prepared(
            initialRegisters: registers,
            bootArgsAddress: bootArgsAddress,
            deviceTreeAddress: deviceTree != nil ? deviceTreeAddress : nil,
            deviceTreeLength: Int(deviceTreeLength),
            memorySizeGivenToKernel: memorySize,
            pramAddress: pramAddress,
            pramSize: pramSize,
            ramDiskAddress: ramDiskAddress
        )
    }

    /// iBoot brings the LCD up to show the boot logo and leaves the CLCD
    /// controller running, and `AppleCLCD` refuses to load otherwise ("CLCD
    /// not initied by iBoot, driver will not load"): in its second register
    /// window (`clcd` `reg` index 1, physical `0x89200000`) it wants the
    /// enable bit, `+0x50` bit 0, and a nonzero panel size at `+0x60` —
    /// width in bits [10:0], height in bits [26:16]. This leaves exactly
    /// that state behind, for the panel's real 640x960.
    static let clcdSecondaryWindow: UInt32 = 0x8920_0000

    private static func leaveDisplayControllerRunning(on bus: SegmentedMemoryBus) throws {
        let size = UInt32(GuestMemoryLayout.framebufferHeight) << 16 | UInt32(GuestMemoryLayout.framebufferWidth)
        try bus.writeWord32(size, at: clcdSecondaryWindow + 0x60)
        try bus.writeWord32(1, at: clcdSecondaryWindow + 0x50)
    }

    private static func align(_ value: UInt32, _ alignment: UInt32) -> UInt32 {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
