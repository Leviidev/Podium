import Foundation
import CryptoKit
import Darwin

/// File-backed md0 for the exact iPod4,1 / 10B500 kernel. Small guest
/// shims still call XNU's buf_map/unmap and biodone, so its buffer cache,
/// VM mappings, scheduling, HFS driver and journal remain in charge.
/// Replacing only bcopy is insufficient: memdev.c truncates offsets and
/// capacity to 32 bits before copying. No eight-GiB guest mapping exists.
enum GuestDiskBridge {
    static let strategyAddress: UInt32 = 0x8009_76BC
    static let rawAddress: UInt32 = 0x8009_7474
    static let transferAddress: UInt32 = 0x8009_7918
    static let ioctlAddress: UInt32 = 0x8009_750C
    static let md0: UInt32 = 0x8032_B008
    static let kernelSHA256 = "415717e559c48fcf8a2aedec05d3ed2efa6312b11de942acd1c56629b72192ef"

    struct UnsupportedKernel: FriendlyError {
        var userMessage: String { "The 8 GiB disk requires the original iPod touch 4 iOS 6.1.6 firmware." }
        var developerDetail: String { "Kernel SHA-256 does not match the verified 10B500 storage ABI." }
    }

    /// The verified kernels whose storage ABI this bridge patches. Other
    /// builds boot the root filesystem as a RAM disk instead.
    static let verifiedKernels: [String: String] = ["10B500": kernelSHA256]

    static func supports(build buildVersion: String) -> Bool { verifiedKernels[buildVersion] != nil }

    static func patch(_ original: Data, buildVersion: String) throws -> Data {
        let digest = SHA256.hash(data: original).hexEncodedString
        guard digest == verifiedKernels[buildVersion] else { throw UnsupportedKernel() }
        var kernel = original
        // In this verified Mach-O __TEXT vmaddr/fileoff are 0x80001000/0.
        func put(_ hex: String, at address: UInt32) {
            let bytes = Data(hex: hex)
            let offset = Int(address - 0x8000_1000)
            kernel.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        put(strategyCode, at: strategyAddress)
        put(rawCode, at: rawAddress)
        put(rawLoopCode, at: strategyAddress + 0x100)
        put("7047", at: transferAddress + 4)
        put("7047", at: transferAddress) // bx lr; native handler supplies the result
        return kernel
    }

    static func install(on cpu: ARMv7CPU, disk: FileBackedStorage) {
        if ProcessInfo.processInfo.environment["PODIUM_DISK_TRACE"] == "1" {
            for site in [strategyAddress, UInt32(0x8009_76D4), UInt32(0x8009_76D8)] {
                cpu.nativeFunctions[site] = { c in
                    let bp = site == strategyAddress ? c.registers[0] : c.registers[4]
                    let data = (try? c.readData(bp + 60, width: 4)) ?? 0
                    let mapped = (try? c.readData(c.registers.sp + 8, width: 4)) ?? 0
                    print("[md0trace] pc=\(site.hexString8) bp=\(bp.hexString8) datap=\(data.hexString8) sp=\(c.registers.sp.hexString8) mapped=\(mapped.hexString8) r0=\(c.registers[0].hexString8) r1=\(c.registers[1].hexString8)")
                    return false
                }
            }
        }
        cpu.nativeFunctions[transferAddress] = { cpu in transfer(cpu, disk: disk); return true }
        cpu.nativeFunctions[transferAddress + 4] = { cpu in transferRawPage(cpu, disk: disk); return true }
        cpu.nativeFunctions[ioctlAddress] = { cpu in
            // Other md devices and all unrelated ioctls retain XNU behavior.
            guard cpu.registers[0] & 0x00FF_FFFF == 0 else { return false }
            let command = cpu.registers[1], output = cpu.registers[2]
            guard command == 0x4008_6419 || command == 0x4004_6419 || command == 0x2000_6416 else { return false }
            do {
                if command == 0x2000_6416 {
                    try disk.synchronize()
                } else {
                    let sector = try cpu.readData(md0 + 16, width: 4)
                    guard sector >= 512 else { throw FileBackedStorage.IOError(code: EINVAL) }
                    let blocks = (disk.byteCount + UInt64(sector) - 1) / UInt64(sector)
                    guard command == 0x4008_6419 || blocks <= UInt64(UInt32.max) else { throw FileBackedStorage.IOError(code: EOVERFLOW) }
                    try cpu.writeData(UInt32(truncatingIfNeeded: blocks), output, width: 4)
                    if command == 0x4008_6419 { try cpu.writeData(UInt32(blocks >> 32), output + 4, width: 4) }
                }
                cpu.registers[0] = 0
            } catch let error as FileBackedStorage.IOError {
                cpu.registers[0] = UInt32(error.code)
            } catch { cpu.registers[0] = UInt32(EFAULT) }
            return true
        }
    }

    /// Raw character-device I/O uses one kalloc page per call as a bounce
    /// buffer. XNU's uiomove64, in the guest, copies to/from the uio's
    /// address space and advances it; host code never dereferences a user
    /// pointer. r2:r3 is a byte offset, including unaligned raw requests.
    static func transferRawPage(_ cpu: ARMv7CPU, disk: FileBackedStorage) {
        let buffer = cpu.registers[0], requested = Int(cpu.registers[1])
        let offset = UInt64(cpu.registers[2]) | UInt64(cpu.registers[3]) << 32
        cpu.registers[1] = 0
        do {
            let flags = try cpu.readData(cpu.registers.sp, width: 4)
            let device = try cpu.readData(cpu.registers.sp + 4, width: 4)
            guard device & 0x00FF_FFFF == 0, requested <= 4096,
                  buffer & 4095 == 0, offset <= disk.byteCount else { throw FileBackedStorage.IOError(code: EINVAL) }
            let physical: UInt32
            if cpu.mmuEnabled { physical = try kernelPhysicalAddress(buffer, cpu: cpu) }
            else { physical = GuestMemoryLayout.physical(fromKernelVirtual: buffer) }
            guard let pointer = cpu.hostAddress(ofPhysicalRAM: physical) else { throw FileBackedStorage.IOError(code: EFAULT) }
            let count = Int(min(UInt64(requested), disk.byteCount - offset))
            if flags & 1 != 0 {
                let data = try disk.read(at: offset, count: count)
                if count > 0 {
                    data.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: count) }
                    cpu.didWritePhysicalRAM(at: physical)
                }
            } else {
                try disk.write(Data(bytes: pointer, count: count), at: offset)
            }
            cpu.registers[0] = 0
            cpu.registers[1] = UInt32(count)
        } catch let error as FileBackedStorage.IOError { cpu.registers[0] = UInt32(error.code) }
        catch { cpu.registers[0] = UInt32(EFAULT) }
    }

    /// Shim ABI: r0=mapped buffer, r1=count, r2:r3=64-bit block index;
    /// stack[0]=buf_flags, stack[4]=dev. Returns r0=errno, r1=bytes done.
    /// Page mappings are checked before touching storage. Each host allocation
    /// is at most one guest page, regardless of the disk's logical size.
    static func transfer(_ cpu: ARMv7CPU, disk: FileBackedStorage) {
        let buffer = cpu.registers[0], requested = Int(cpu.registers[1])
        let block = UInt64(cpu.registers[2]) | UInt64(cpu.registers[3]) << 32
        var done = 0
        defer { cpu.registers[1] = UInt32(done) }
        do {
            let flags = try cpu.readData(cpu.registers.sp, width: 4)
            let device = try cpu.readData(cpu.registers.sp + 4, width: 4)
            guard device & 0x00FF_FFFF == 0 else { throw FileBackedStorage.IOError(code: ENXIO) }
            let sector = try cpu.readData(md0 + 16, width: 4)
            let (offset, overflow) = block.multipliedReportingOverflow(by: UInt64(sector))
            guard sector >= 512, !overflow, offset <= disk.byteCount, requested <= 16 << 20 else {
                throw FileBackedStorage.IOError(code: EINVAL)
            }
            // EOF returns a full residual; requests straddling EOF are short I/O.
            let count = Int(min(UInt64(requested), disk.byteCount - offset))
            guard UInt64(buffer) + UInt64(count) <= UInt64(UInt32.max) + 1 else { throw FileBackedStorage.IOError(code: EFAULT) }
            let reading = flags & 1 != 0 // B_READ
            var pages: [(pointer: UnsafeMutableRawPointer, physical: UInt32, count: Int)] = []
            var checked = 0
            while checked < count {
                let address = buffer + UInt32(checked)
                let length = min(4096 - Int(address & 4095), count - checked)
                // Like XNU's original mdPhys path (pmap_find_phys +
                // bcopy_phys), disk I/O writes physical pages. A pinned
                // I/O buffer can have a read-only CPU mapping; requiring
                // .write here incorrectly turns that DMA into EFAULT.
                let physical = try kernelPhysicalAddress(address, cpu: cpu)
                guard let page = cpu.hostAddress(ofPhysicalRAM: physical) else { throw FileBackedStorage.IOError(code: EFAULT) }
                let pointer = page + Int(physical & 4095)
                pages.append((pointer, physical, length))
                checked += length
            }
            for page in pages {
                if reading {
                    let data = try disk.read(at: offset + UInt64(done), count: page.count)
                    data.withUnsafeBytes { page.pointer.copyMemory(from: $0.baseAddress!, byteCount: page.count) }
                    cpu.didWritePhysicalRAM(at: page.physical)
                } else {
                    try disk.write(Data(bytes: page.pointer, count: page.count), at: offset + UInt64(done))
                }
                done += page.count
            }
            cpu.registers[0] = 0
        } catch let error as FileBackedStorage.IOError {
            cpu.registers[0] = UInt32(error.code)
        } catch { cpu.registers[0] = UInt32(EFAULT) }
    }

    /// Mirrors this verified kernel's pmap_find_phys(kernel_pmap, va),
    /// including its software PTE. DMA must not use the current task's
    /// TTBR0: the buffer can belong to a different kernel pmap mapping.
    static func kernelPhysicalAddress(_ address: UInt32, cpu: ARMv7CPU) throws -> UInt32 {
        let pmap = try cpu.readData(0x802D_47E8, width: 4) // _kernel_pmap
        // Synthetic CPU tests have no XNU pmap; ordinary translation is
        // sufficient there. A real initialized kernel always supplies it.
        if pmap == 0 { return try cpu.translatedAddress(address, access: .read) }
        let table = try cpu.readData(pmap, width: 4)
        let entries = try cpu.readData(pmap + 0x54, width: 4)
        let index = address >> 20
        guard table != 0, index < entries, entries <= 4096 else { throw FileBackedStorage.IOError(code: EFAULT) }
        let descriptor = try cpu.readData(table + index * 4, width: 4)
        switch descriptor & 3 {
        case 2:
            if descriptor & 0x40000 != 0 {
                return (descriptor & 0xFF00_0000) | (address & 0x00FF_FFFF)
            }
            return (descriptor & 0xFFF0_0000) | (address & 0x000F_FFFF)
        case 1:
            let physicalTable = descriptor & 0xFFFF_FC00
            let pte = GuestMemoryLayout.kernelVirtual(fromPhysical: physicalTable) + ((address >> 10) & 0x3FC)
            // XNU stores three software words per hardware PTE after the
            // 1 KiB hardware table; its third word can encode a pending
            // mapping before the MMU descriptor has been installed.
            let software = (pte & 0xFFFF_F000) | 0x400
            let extended = try cpu.readData(software + ((pte >> 2) & 0x3FF) * 12 + 8, width: 4)
            let hardware = try cpu.readData(pte, width: 4)
            let page = extended != 0 ? ((extended ^ address) & 0xFFFF_F000) : (hardware & 0xFFFF_F000)
            guard page != 0 else { throw FileBackedStorage.IOError(code: EFAULT) }
            return page | (address & 4095)
        default: throw FileBackedStorage.IOError(code: EFAULT)
        }
    }

    // Reproducible shims and annotated disassembly are in StorageBridge/.
    static let strategyCode = "f0b585b0044605f099fb05460146204605f09efb204602a905f088fd00281cd1204605f05ffd0190204605f071fb0090204605f043fd02460b460298294600f00df903900491204605f094fd0499691a204605f07dfb039900e00e21002902d0204605f037fb204605f056ff05b0f0bd"
    static let rawCode = "00f0a2b9"
    static let rawLoopCode = "20f07f43002b01d0062070472de9f04d86b006460c46019620464bf131f9804680f00100009041f2000085f781fa8246002847d020464af197ff002846dd41f20005a84238bf054620464bf109f902900391b8f1000f22d020464bf157fb049000282fd0504600212a46049b4af1d4fe834604984bf1f2f9bbf1000f24d150462946029a039b00f06bf8834600291bd020464af16fffbbf1000f15d1cae750462946029a039b00f05bf800280fd100290cd00a465046002123464af1adfe002805d1b7e70c2002e0584600e000208346baf1000f04d0504641f2000185f730fa584606b0bde8f08d"
}
