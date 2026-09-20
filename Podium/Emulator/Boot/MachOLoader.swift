import Foundation

enum MachOLoaderError: FriendlyError {
    case notMachO
    case not32BitARM
    case noEntryPoint
    case memoryWriteFailed(MemoryAccessError)

    var userMessage: String { "Podium couldn't load this kernel binary." }

    var developerDetail: String {
        switch self {
        case .notMachO: return "Missing 32-bit Mach-O magic (0xFEEDFACE)."
        case .not32BitARM: return "cputype is not CPU_TYPE_ARM (12)."
        case .noEntryPoint: return "No LC_UNIXTHREAD load command found."
        case .memoryWriteFailed(let underlying): return "\(underlying)"
        }
    }
}

/// The entry point and initial register state a loaded kernel image
/// should start executing with.
struct LoadedKernelImage {
    /// Same layout as `Registers`' own storage: index 13 = sp, 14 = lr,
    /// 15 = pc. Everything XNU's `LC_UNIXTHREAD` specifies (typically all
    /// zero except pc, per the real reference kernel this was verified
    /// against).
    let initialRegisters: [UInt32]

    var entryPointPC: UInt32 { initialRegisters[Registers.pcIndex] }
}

/// Parses a 32-bit ARM Mach-O (`MH_MAGIC` / `CPU_TYPE_ARM`) and loads its
/// `LC_SEGMENT`s into guest physical memory at their linked addresses —
/// exactly the two things Podium's first boot attempt needs. There's no
/// dynamic linking, no symbol resolution, nothing past what gets bytes
/// into memory at the right addresses and finds where to start executing.
///
/// XNU kernel images specify their entry point via `LC_UNIXTHREAD`
/// (there's no `main()` symbol the way a userspace binary would have
/// one) — confirmed directly against the real iPod4,1 6.1.6 kernel via
/// `otool -l`, which is also where the field layout below (`flavor`,
/// `count`, then 17 register words: r0–r12, sp, lr, pc, cpsr) comes from.
enum MachOLoader {
    private static let machHeaderMagic32: UInt32 = 0xFEED_FACE
    private static let cpuTypeARM: Int32 = 12
    private static let lcSegment: UInt32 = 0x1
    private static let lcUnixThread: UInt32 = 0x5
    private static let armThreadStateCount = 17
    private static let machHeaderSize = 28
    private static let segmentCommandSize = 56

    static func load(_ machO: Data, into memory: MemoryBus) throws -> LoadedKernelImage {
        guard machO.count >= machHeaderSize else { throw MachOLoaderError.notMachO }
        guard machO.readUInt32LE(at: 0) == machHeaderMagic32 else { throw MachOLoaderError.notMachO }
        guard Int32(bitPattern: machO.readUInt32LE(at: 4)) == cpuTypeARM else { throw MachOLoaderError.not32BitARM }

        let ncmds = Int(machO.readUInt32LE(at: 16))
        var offset = machHeaderSize
        var initialRegisters: [UInt32]?

        for _ in 0..<ncmds {
            guard offset + 8 <= machO.count else { break }
            let cmd = machO.readUInt32LE(at: offset)
            let cmdSize = Int(machO.readUInt32LE(at: offset + 4))
            guard cmdSize >= 8, offset + cmdSize <= machO.count else { break }

            switch cmd {
            case lcSegment:
                try loadSegment(machO, commandOffset: offset, into: memory)
            case lcUnixThread:
                initialRegisters = readUnixThreadRegisters(machO, commandOffset: offset, cmdSize: cmdSize)
            default:
                break
            }

            offset += cmdSize
        }

        guard let registers = initialRegisters else { throw MachOLoaderError.noEntryPoint }
        return LoadedKernelImage(initialRegisters: registers)
    }

    private static func loadSegment(_ machO: Data, commandOffset offset: Int, into memory: MemoryBus) throws {
        guard offset + segmentCommandSize <= machO.count else { return }

        let vmaddr = machO.readUInt32LE(at: offset + 24)
        let fileoff = Int(machO.readUInt32LE(at: offset + 32))
        let filesize = Int(machO.readUInt32LE(at: offset + 36))

        guard filesize > 0, fileoff >= 0, fileoff + filesize <= machO.count else { return }

        let start = machO.startIndex + fileoff
        let segmentData = machO.subdata(in: start..<(start + filesize))
        do {
            try memory.writeBytes(segmentData, at: vmaddr)
        } catch let error as MemoryAccessError {
            throw MachOLoaderError.memoryWriteFailed(error)
        }

        // vmsize can exceed filesize (zero-fill / .bss-style regions);
        // a freshly-allocated FlatPhysicalMemory already reads zero
        // everywhere, so there's nothing further to write for that gap.
    }

    private static func readUnixThreadRegisters(_ machO: Data, commandOffset offset: Int, cmdSize: Int) -> [UInt32]? {
        let count = Int(machO.readUInt32LE(at: offset + 12))
        let registersOffset = offset + 16
        guard count == armThreadStateCount, registersOffset + count * 4 <= machO.count else { return nil }

        var registers = [UInt32](repeating: 0, count: 16)
        for i in 0..<13 {
            registers[i] = machO.readUInt32LE(at: registersOffset + i * 4)
        }
        registers[Registers.spIndex] = machO.readUInt32LE(at: registersOffset + 13 * 4)
        registers[Registers.lrIndex] = machO.readUInt32LE(at: registersOffset + 14 * 4)
        registers[Registers.pcIndex] = machO.readUInt32LE(at: registersOffset + 15 * 4)
        return registers
    }
}
