import Foundation

/// The System Control Coprocessor (CP15) register file, as far as
/// `MCR`/`MRC` transfers are concerned.
///
/// Real CP15 registers configure and control cache behavior, the MMU/TLB,
/// and other low-level hardware state — none of which this CPU
/// implements (no MMU, no cache model). This type exists so guest code
/// that reads/writes CP15 registers (which real ARM boot code does
/// almost immediately — cache maintenance, barrier-adjacent operations)
/// gets a real, addressable place to write to and read back from,
/// instead of Podium refusing to execute the instruction at all. It is
/// explicitly *not* a claim that cache/MMU behavior is emulated: writes
/// are stored, not acted on.
struct CP15State {
    private struct Key: Hashable {
        let coprocessor: Int
        let opc1: Int
        let crn: Int
        let crm: Int
        let opc2: Int
    }

    private var storage: [Key: UInt32] = [:]

    mutating func write(coprocessor: Int, opc1: Int, crn: Int, crm: Int, opc2: Int, value: UInt32) {
        storage[Key(coprocessor: coprocessor, opc1: opc1, crn: crn, crm: crm, opc2: opc2)] = value
    }

    /// Registers Podium has never written default to 0 — an honest
    /// "nothing configured" rather than a value implying real hardware
    /// state (e.g. a populated cache-type or feature-ID register) that
    /// isn't actually backed by anything.
    func read(coprocessor: Int, opc1: Int, crn: Int, crm: Int, opc2: Int) -> UInt32 {
        storage[Key(coprocessor: coprocessor, opc1: opc1, crn: crn, crm: crm, opc2: opc2)] ?? 0
    }
}
