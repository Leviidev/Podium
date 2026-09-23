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
/// remap. Permissions are checked for the access's privilege: User-mode
/// accesses get the user half of Table B3-8 (copy-on-write and read-only
/// user mappings depend on it). `ARMv7CPU` keeps a TLB of successful walks
/// in front of this (see `translatedAddress`).
enum ARMv7MMU {
    enum Access {
        case read
        case write
        case execute
    }


    static func translate(
        virtualAddress: UInt32,
        access: Access,
        cp15: CP15State,
        memory: MemoryBus,
        privileged: Bool = true
    ) throws -> UInt32 {
        try translate(virtualAddress: virtualAddress, access: access, ttbcr: cp15.ttbcr, ttbr0: cp15.ttbr0, ttbr1: cp15.ttbr1,
                      dacr: cp15.dacr, memory: memory, privileged: privileged)
    }

    /// The walk itself, taking just the registers it reads (passing the
    /// whole `CP15State` copied its storage dictionary on every access).
    static func translate(
        virtualAddress: UInt32,
        access: Access,
        ttbcr: UInt32,
        ttbr0: UInt32,
        ttbr1: UInt32,
        dacr: UInt32,
        memory: MemoryBus,
        privileged: Bool
    ) throws -> UInt32 {
        let n = Int(ttbcr.bitField(2, 0))

        // ARM DDI 0406C B3.5.4: with N==0, TTBR0 covers the whole 4GB
        // space. With N>0, TTBR0 covers VA[31:32-N] == 0 and TTBR1 covers
        // everything else.
        let useTTBR1 = n > 0 && (virtualAddress >> (32 - n)) != 0
        let ttbr = useTTBR1 ? ttbr1 : ttbr0

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
        let isWrite = access == .write
        switch firstLevelDescriptor.bitField(1, 0) {
        case 0b00, 0b11:
            throw MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: .sectionTranslation, isWrite: isWrite)

        case 0b01:
            // The second-level entry is fetched and checked before the
            // domain: a translation fault takes priority over a domain
            // fault (ARM DDI 0406C B3.12.3).
            let secondLevelTableBase = firstLevelDescriptor & 0xFFFF_FC00
            let secondLevelIndex = virtualAddress.bitField(19, 12)
            let secondLevelAddress = secondLevelTableBase &+ (secondLevelIndex << 2)
            let secondLevelDescriptor = try memory.readWord32(at: secondLevelAddress)

            if secondLevelDescriptor.bitField(1, 0) == 0b00 {
                throw MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: .pageTranslation, isWrite: isWrite)
            }

            let domain = Int(firstLevelDescriptor.bitField(8, 5))
            let requiresPermissionCheck = try checkDomain(domain, isPage: true, dacr: dacr, virtualAddress: virtualAddress, isWrite: isWrite)

            let isLargePage = secondLevelDescriptor.bitField(1, 0) == 0b01
            if requiresPermissionCheck {
                let ap = pageAccessPermission(secondLevelDescriptor)
                let executeNever = isLargePage ? secondLevelDescriptor.bit(15) : secondLevelDescriptor.bit(0)
                try checkPermission(ap, access: access, executeNever: executeNever, isPage: true, privileged: privileged, virtualAddress: virtualAddress)
            }

            return isLargePage
                ? (secondLevelDescriptor & 0xFFFF_0000) | (virtualAddress & 0x0000_FFFF)
                : (secondLevelDescriptor & 0xFFFF_F000) | (virtualAddress & 0x0000_0FFF)

        default: // 0b10: section or supersection.
            let domain = Int(firstLevelDescriptor.bitField(8, 5))
            let requiresPermissionCheck = try checkDomain(domain, isPage: false, dacr: dacr, virtualAddress: virtualAddress, isWrite: isWrite)

            if requiresPermissionCheck {
                let ap = sectionAccessPermission(firstLevelDescriptor)
                let executeNever = firstLevelDescriptor.bit(4)
                try checkPermission(ap, access: access, executeNever: executeNever, isPage: false, privileged: privileged, virtualAddress: virtualAddress)
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
    private static func checkDomain(_ domain: Int, isPage: Bool, dacr: UInt32, virtualAddress: UInt32, isWrite: Bool) throws -> Bool {
        let mode = (dacr >> (domain * 2)) & 0b11
        switch mode {
        case 0b11:
            return false // Manager: no permission check, but the entry must still exist (checked by the caller before this runs).
        case 0b01:
            return true // Client: caller still performs the AP/XN permission check.
        default:
            throw MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: .domainFault(isPage: isPage), isWrite: isWrite)
        }
    }

    /// Table B3-8 (`AP[2:0]` = APX:AP[1:0]): 000 no access; 001 privileged
    /// RW, user none; 010 privileged RW, user RO; 011 RW for both; 101
    /// privileged RO, user none; 110/111 RO for both. `0b100` is reserved
    /// (UNPREDICTABLE) and treated as no access. XN rejects any execute.
    private static func checkPermission(_ ap: UInt8, access: Access, executeNever: Bool, isPage: Bool, privileged: Bool, virtualAddress: UInt32) throws {
        let fault = MemoryAccessError.translationFault(virtualAddress: virtualAddress, reason: .permissionFault(isPage: isPage), isWrite: access == .write)
        if ap == 0b000 || ap == 0b100 {
            throw fault
        }
        if !privileged && (ap == 0b001 || ap == 0b101) {
            throw fault
        }
        if access == .execute && executeNever {
            throw fault
        }
        let readOnly = privileged ? (ap == 0b101 || ap == 0b110 || ap == 0b111) : ap != 0b011
        if access == .write && readOnly {
            throw fault
        }
    }

}
