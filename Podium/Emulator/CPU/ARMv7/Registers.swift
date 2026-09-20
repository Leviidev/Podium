import Foundation

/// The 16 architectural registers ARM code addresses directly: r0–r12
/// general purpose, r13 (SP) stack pointer, r14 (LR) link register, r15
/// (PC) program counter.
///
/// Real ARMv7 banks several of these per processor mode (a different SP/LR
/// for IRQ, FIQ, SVC, etc., and FIQ additionally banks r8–r12), swapped in
/// automatically on exception entry/exit. This first CPU slice runs
/// everything unbanked, as if permanently in User/System mode — there is
/// no exception handling yet for banking to matter for, and pretending to
/// bank registers with nothing to trigger a mode switch would just be
/// unexercised complexity. This is documented here so it isn't mistaken
/// for an oversight when exception support is added later.
struct Registers {
    private var storage: [UInt32] = Array(repeating: 0, count: 16)

    static let pcIndex = 15
    static let lrIndex = 14
    static let spIndex = 13

    subscript(index: Int) -> UInt32 {
        get {
            precondition((0..<16).contains(index), "Register index out of range: \(index)")
            return storage[index]
        }
        set {
            precondition((0..<16).contains(index), "Register index out of range: \(index)")
            storage[index] = newValue
        }
    }

    var pc: UInt32 {
        get { storage[Self.pcIndex] }
        set { storage[Self.pcIndex] = newValue }
    }

    var lr: UInt32 {
        get { storage[Self.lrIndex] }
        set { storage[Self.lrIndex] = newValue }
    }

    var sp: UInt32 {
        get { storage[Self.spIndex] }
        set { storage[Self.spIndex] = newValue }
    }

    /// The value an instruction sees when it reads r15 as an operand:
    /// the address of the instruction currently executing, plus 8 —
    /// ARM's fetch/decode/execute pipeline convention, not a bug.
    /// `pc` itself always holds the address of the *next* instruction to
    /// fetch, which is what `pcForOperandRead` is derived from.
    var pcForOperandRead: UInt32 {
        pc &+ 4
    }

    mutating func reset() {
        storage = Array(repeating: 0, count: 16)
    }
}
