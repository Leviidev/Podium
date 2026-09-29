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
    /// TPIDRURW, TPIDRURO and TPIDRPRW (c13, opc2 2...4): the thread ID
    /// registers, which translated code reads directly (see `DBTEngine`).
    private(set) var threadIDs: (UInt32, UInt32, UInt32) = (0, 0, 0)

    private var storage: [Key: UInt32] = [:]

    /// The c7 cache and branch-predictor maintenance operations (and the
    /// CP15 barriers): write-only, and nothing to do with no caches
    /// modeled. Not stored, so translated code can skip them.
    static func isCacheMaintenance(coprocessor: Int, opc1: Int, crn: Int, crm: Int) -> Bool {
        coprocessor == 15 && opc1 == 0 && crn == 7 && [1, 5, 6, 10, 11, 13, 14].contains(crm)
    }

    mutating func write(coprocessor: Int, opc1: Int, crn: Int, crm: Int, opc2: Int, value: UInt32) {
        if Self.isCacheMaintenance(coprocessor: coprocessor, opc1: opc1, crn: crn, crm: crm) { return }
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
        if coprocessor == 15, opc1 == 0, crn == 13, crm == 0 {
            switch opc2 {
            case 1: contextID = value; return
            case 2: threadIDs.0 = value; return
            case 3: threadIDs.1 = value; return
            case 4: threadIDs.2 = value; return
            default: break
            }
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
        if coprocessor == 15, opc1 == 0, crn == 13, crm == 0 {
            switch opc2 {
            case 1: return contextID
            case 2: return threadIDs.0
            case 3: return threadIDs.1
            case 4: return threadIDs.2
            default: break
            }
        }
        return storage[Key(coprocessor: coprocessor, opc1: opc1, crn: crn, crm: crm, opc2: opc2)] ?? 0
    }
}
