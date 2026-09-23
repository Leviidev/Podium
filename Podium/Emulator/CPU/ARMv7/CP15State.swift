import Foundation

/// The System Control Coprocessor (CP15) register file, as far as
/// `MCR`/`MRC` transfers are concerned.
///
/// The registers the MMU walk reads — SCTLR, TTBR0, TTBR1, TTBCR, DACR —
/// are acted on (see `ARMv7MMU`) and kept in dedicated fields, since
/// they're read on every translated access and instruction fetch. Every
/// other register (cache/TLB maintenance, ID registers, thread IDs, ...)
/// is stored and read back, not acted on.
struct CP15State {
    private struct Key: Hashable {
        let coprocessor: Int
        let opc1: Int
        let crn: Int
        let crm: Int
        let opc2: Int
    }

    private(set) var sctlr: UInt32 = 0
    private(set) var ttbr0: UInt32 = 0
    private(set) var ttbr1: UInt32 = 0
    private(set) var ttbcr: UInt32 = 0
    private(set) var dacr: UInt32 = 0
    /// CONTEXTIDR (c13, opc2 1): its low 8 bits are the ASID XNU tags each
    /// address space with. Kept as a dedicated field, like the others
    /// above, because `ARMv7CPU`'s TLB now reads it on every translated
    /// access, not just on a context switch.
    private(set) var contextID: UInt32 = 0

    private var storage: [Key: UInt32] = [:]

    mutating func write(coprocessor: Int, opc1: Int, crn: Int, crm: Int, opc2: Int, value: UInt32) {
        if coprocessor == 15, opc1 == 0, crm == 0 {
            switch (crn, opc2) {
            case (1, 0): sctlr = value; return
            case (2, 0): ttbr0 = value; return
            case (2, 1): ttbr1 = value; return
            case (2, 2): ttbcr = value; return
            case (3, 0): dacr = value; return
            default: break
            }
        }
        if coprocessor == 15, opc1 == 0, crn == 13, crm == 0, opc2 == 1 {
            contextID = value
            return
        }
        storage[Key(coprocessor: coprocessor, opc1: opc1, crn: crn, crm: crm, opc2: opc2)] = value
    }

    /// Registers Podium has never written default to 0 — an honest
    /// "nothing configured" rather than a value implying real hardware
    /// state (e.g. a populated cache-type or feature-ID register) that
    /// isn't actually backed by anything.
    func read(coprocessor: Int, opc1: Int, crn: Int, crm: Int, opc2: Int) -> UInt32 {
        if coprocessor == 15, opc1 == 0, crm == 0 {
            switch (crn, opc2) {
            case (1, 0): return sctlr
            case (2, 0): return ttbr0
            case (2, 1): return ttbr1
            case (2, 2): return ttbcr
            case (3, 0): return dacr
            default: break
            }
        }
        if coprocessor == 15, opc1 == 0, crn == 13, crm == 0, opc2 == 1 {
            return contextID
        }
        return storage[Key(coprocessor: coprocessor, opc1: opc1, crn: crn, crm: crm, opc2: opc2)] ?? 0
    }
}
