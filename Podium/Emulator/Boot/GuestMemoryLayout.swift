import Foundation

/// Where things live in the guest's physical and virtual address spaces —
/// the iPod touch 4's (S5L8930X) real layout, as iBoot hands it to the
/// kernel.
///
/// DRAM is physical `0x40000000` up: the iPod touch 4 has 256 MB, but
/// Podium gives the guest 1 GB (all of `0x40000000`–`0x7FFFFFFF`, the
/// whole window below the peripherals), because the root filesystem RAM
/// disk has to live inside DRAM, in the kernel's static region — XNU's
/// memory device reads it through the linear map — and the trimmed root
/// filesystem alone is ~690 MB. What's left over is still more usable RAM
/// than the real device's. Untouched guest pages cost the host nothing
/// (see `FlatPhysicalMemory`). The kernel is
/// linked at `0x80001000` and maps all of DRAM linearly from virtual
/// `0x80000000` (`boot_args.virtBase`/`physBase`). Physical `0x80000000`
/// and up is *not* RAM: `arm-io`'s `ranges` place the SoC's peripherals
/// there (child address + `0x80000000` — the IOP at `0x86300000`, UARTs
/// at `0x825xxxxx`, the display controller at `0x89xxxxxx`, ...). An
/// earlier layout put DRAM at physical `0x80000000` so virtual and
/// physical addresses matched, which silently turned every access to
/// those peripherals into reads and writes of kernel RAM.
enum GuestMemoryLayout {
    static let ramPhysicalBase: UInt32 = 0x4000_0000
    static let ramSize = 1024 * 1024 * 1024
    static let kernelVirtualBase: UInt32 = 0x8000_0000

    static var ramPhysicalRange: Range<UInt32> {
        ramPhysicalBase..<(ramPhysicalBase &+ UInt32(ramSize))
    }

    /// Kernel virtual address -> physical, through the linear map.
    static func physical(fromKernelVirtual address: UInt32) -> UInt32 {
        address &- kernelVirtualBase &+ ramPhysicalBase
    }

    /// Physical DRAM address -> the kernel's linear-map virtual address.
    static func kernelVirtual(fromPhysical address: UInt32) -> UInt32 {
        address &- ramPhysicalBase &+ kernelVirtualBase
    }

    /// The iPod touch 4's panel resolution (portrait 640x960), and a 32-bit framebuffer at the
    /// very top of DRAM — clear of everything `KernelBootstrap` places at
    /// the bottom.
    static let framebufferWidth = 640
    static let framebufferHeight = 960
    static let framebufferRowBytes = UInt32(framebufferWidth * 4)
    static let framebufferSize = framebufferRowBytes * UInt32(framebufferHeight)
    static let framebufferPhysicalAddress: UInt32 = ramPhysicalBase &+ UInt32(ramSize) &- framebufferSize
}
