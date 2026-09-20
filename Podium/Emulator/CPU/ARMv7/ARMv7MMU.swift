import Foundation

/// A real ARMv7 short-descriptor MMU translation walk: given a virtual
/// address and the guest's current TTBR0/TTBR1/TTBCR/DACR state (read
/// from `CP15State`), walks the first- and, when needed, second-level
/// translation tables *in guest physical memory* to produce a real
/// physical address — or a real translation fault when the tables say the
/// access isn't allowed. `CP15State`'s other registers are still just a
/// stored value (see its own doc comment), but once SCTLR.M is set,
/// address translation itself is no longer something this CPU can leave
/// unimplemented without silently diverging from real hardware, so this
/// exists to do it for real, per ARM DDI 0406C section B3.6.
///
/// Deliberately out of scope, honestly: the simplified/access-flag AP
/// model (SCTLR.AFE) — `ARMv7CPU` checks for and refuses that combination
/// rather than silently misapplying the legacy 3-bit AP model to it — TEX
/// remap, and any notion of a TLB (every access re-walks the tables, which
/// is slower but never stale). Podium also has no processor-mode/
/// privilege model (see `CPSR`'s doc comment), so every access is checked
/// as if privileged, which is accurate for the kernel-only boot code this
/// CPU has run so far but would be wrong for a genuine user-mode access.
enum ARMv7MMU {
    enum Access {
        case read
        case write
        case execute
    }

    private static let ttbr0Key = (opc1: 0, crn: 2, crm: 0, opc2: 0)
    private static let ttbr1Key = (opc1: 0, crn: 2, crm: 0, opc2: 1)
    private static let ttbcrKey = (opc1: 0, crn: 2, crm: 0, opc2: 2)
    private static let dacrKey = (opc1: 0, crn: 3, crm: 0, opc2: 0)

    static func translate(
        virtualAddress: UInt32,
        access: Access,
        cp15: CP15State,
        memory: MemoryBus
    ) throws -> UInt32 {
        let ttbcr = read(cp15, ttbcrKey)
        let n = Int(ttbcr.bitField(2, 0))

        // ARM DDI 0406C B3.5.4: with N==0, TTBR0 covers the whole 4GB
        // space. With N>0, TTBR0 covers VA[31:32-N] == 0 and TTBR1 covers
        // everything else.
        let useTTBR1 = n > 0 && (virtualAddress >> (32 - n)) != 0
        let ttbr = read(cp15, useTTBR1 ? ttbr1Key : ttbr0Key)

        // TTBR1's table (and TTBR0's when N==0) is always the full
        // 4096-entry, 16KB table indexed by VA[31:20]. TTBR0's table
        // shrinks to 16KB >> N (and its base must be aligned to that same
        // size) when N>0, since it only ever needs to hold entries for the
        // bottom 2^(32-N) bytes of address space.
        let effectiveN = useTTBR1 ? 0 : n
        let indexBits = UInt32(12 - effectiveN)
        let tableBaseMask = ~UInt32((1 << (14 - effectiveN)) - 1)
        let tableBase = ttbr & tableBaseMask
        let firstLevelIndex = (virtualAddress >> 20) & ((UInt32(1) << indexBits) - 1)
        let firstLevelAddress = tableBase &+ (firstLevelIndex << 2)

        let firstLevelDescriptor = try memory.readWord32(at: firstLevelAddress)
        switch firstLevelDescriptor.bitField(1, 0) {
        case 0b00, 0b11:
            throw MemoryAccessError.translationFault(
                virtualAddress: virtualAddress,
                reason: "section translation fault: first-level descriptor 0x\(firstLevelDescriptor.hexString8) at 0x\(firstLevelAddress.hexString8) is not present"
            )

        case 0b01:
            let domain = Int(firstLevelDescriptor.bitField(8, 5))
            let requiresPermissionCheck = try checkDomain(domain, cp15: cp15, virtualAddress: virtualAddress)

            let secondLevelTableBase = firstLevelDescriptor & 0xFFFF_FC00
            let secondLevelIndex = virtualAddress.bitField(19, 12)
            let secondLevelAddress = secondLevelTableBase &+ (secondLevelIndex << 2)
            let secondLevelDescriptor = try memory.readWord32(at: secondLevelAddress)

            if secondLevelDescriptor.bitField(1, 0) == 0b00 {
                throw MemoryAccessError.translationFault(
                    virtualAddress: virtualAddress,
                    reason: "page translation fault: second-level descriptor 0x\(secondLevelDescriptor.hexString8) at 0x\(secondLevelAddress.hexString8) is not present"
                )
            }

            let isLargePage = secondLevelDescriptor.bitField(1, 0) == 0b01
            if requiresPermissionCheck {
                let ap = pageAccessPermission(secondLevelDescriptor)
                let executeNever = isLargePage ? secondLevelDescriptor.bit(15) : secondLevelDescriptor.bit(0)
                try checkPermission(ap, access: access, executeNever: executeNever, virtualAddress: virtualAddress)
            }

            return isLargePage
                ? (secondLevelDescriptor & 0xFFFF_0000) | (virtualAddress & 0x0000_FFFF)
                : (secondLevelDescriptor & 0xFFFF_F000) | (virtualAddress & 0x0000_0FFF)

        default: // 0b10: section or supersection.
            let domain = Int(firstLevelDescriptor.bitField(8, 5))
            let requiresPermissionCheck = try checkDomain(domain, cp15: cp15, virtualAddress: virtualAddress)

            if requiresPermissionCheck {
                let ap = sectionAccessPermission(firstLevelDescriptor)
                let executeNever = firstLevelDescriptor.bit(4)
                try checkPermission(ap, access: access, executeNever: executeNever, virtualAddress: virtualAddress)
            }

            if firstLevelDescriptor.bit(18) {
                // Supersection (16MB). The extended base bits (PA[39:32]
                // in bits[8:5]/[23:20]) address more physical memory than
                // this 256MB guest has, so they're not extracted.
                return (firstLevelDescriptor & 0xFF00_0000) | (virtualAddress & 0x00FF_FFFF)
            } else {
                return (firstLevelDescriptor & 0xFFF0_0000) | (virtualAddress & 0x000F_FFFF)
            }
        }
    }

    /// `{APX, AP[1:0]}` combined into a 3-bit value, per ARM DDI 0406C
    /// Table B3-8 — the modern (non-subpage) access permission model.
    /// ARMv7 makes the legacy subpage-AP model (SCTLR.XP==0) obsolete, so
    /// this is the only one implemented.
    private static func sectionAccessPermission(_ descriptor: UInt32) -> UInt8 {
        UInt8((descriptor.bitField(15, 15) << 2) | descriptor.bitField(11, 10))
    }

    private static func pageAccessPermission(_ descriptor: UInt32) -> UInt8 {
        UInt8((descriptor.bitField(9, 9) << 2) | descriptor.bitField(5, 4))
    }

    /// DACR (c3, c0, 0): two bits per domain. `0b00` faults unconditionally,
    /// `0b01` ("client") defers to the AP/XN permission check, `0b11`
    /// ("manager") bypasses permission checking entirely, and the reserved
    /// `0b10` behaves as `0b00` on ARMv7 (ARM DDI 0406C B3.7.1). Returns
    /// whether the caller still needs to run the AP/XN permission check
    /// (true for client, since manager returning normally isn't enough on
    /// its own to skip it).
    private static func checkDomain(_ domain: Int, cp15: CP15State, virtualAddress: UInt32) throws -> Bool {
        let dacr = read(cp15, dacrKey)
        let mode = (dacr >> (domain * 2)) & 0b11
        switch mode {
        case 0b11:
            return false // Manager: no permission check, but the entry must still exist (checked by the caller before this runs).
        case 0b01:
            return true // Client: caller still performs the AP/XN permission check.
        default:
            throw MemoryAccessError.translationFault(
                virtualAddress: virtualAddress,
                reason: "domain \(domain) fault (DACR field 0b\(String(mode, radix: 2)))"
            )
        }
    }

    /// Table B3-8's permission model, checked as a privileged access (see
    /// this type's doc comment for why). `0b000` denies every access, and
    /// `0b100` is a reserved encoding the ARM ARM leaves UNPREDICTABLE —
    /// treated here as denying access too, rather than guessing at
    /// behavior the spec itself doesn't define. Every other AP value
    /// grants at least privileged read, so the only remaining checks are
    /// "read-only" AP values rejecting a write, and the XN bit rejecting
    /// an execute.
    private static func checkPermission(_ ap: UInt8, access: Access, executeNever: Bool, virtualAddress: UInt32) throws {
        if ap == 0b000 || ap == 0b100 {
            throw MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: "permission fault: AP 0b\(String(ap, radix: 2)) grants no access")
        }
        if access == .execute && executeNever {
            throw MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: "permission fault: XN forbids execute")
        }
        let readOnly = ap == 0b101 || ap == 0b110 || ap == 0b111
        if access == .write && readOnly {
            throw MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: "permission fault: AP 0b\(String(ap, radix: 2)) is read-only")
        }
    }

    private static func read(_ cp15: CP15State, _ key: (opc1: Int, crn: Int, crm: Int, opc2: Int)) -> UInt32 {
        cp15.read(coprocessor: 15, opc1: key.opc1, crn: key.crn, crm: key.crm, opc2: key.opc2)
    }
}
