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
    /// Inline, not an `Array`: every register write through an array
    /// checks its buffer is uniquely referenced first, and at one or more
    /// writes per guest instruction that check alone was measured at ~7%
    /// of the emulator's time.
    private var storage: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                          UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    static let pcIndex = 15
    static let lrIndex = 14
    static let spIndex = 13

    subscript(index: Int) -> UInt32 {
        get {
            precondition((0..<16).contains(index), "Register index out of range: \(index)")
            return withUnsafeBytes(of: storage) { $0.load(fromByteOffset: index &* 4, as: UInt32.self) }
        }
        set {
            precondition((0..<16).contains(index), "Register index out of range: \(index)")
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: newValue, toByteOffset: index &* 4, as: UInt32.self) }
        }
    }

    var pc: UInt32 {
        get { storage.15 }
        set { storage.15 = newValue }
    }

    var lr: UInt32 {
        get { storage.14 }
        set { storage.14 = newValue }
    }

    var sp: UInt32 {
        get { storage.13 }
        set { storage.13 = newValue }
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
        storage = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// Exposes the register file as a raw pointer for exactly the
    /// duration of `body` — used to hand a JIT-compiled block direct
    /// access to guest registers via the AArch64 calling convention
    /// (see `JITTranslator`), without copying 16 words in and back out
    /// for every native call.
    mutating func withUnsafeMutableStorage<T>(_ body: (UnsafeMutablePointer<UInt32>) -> T) -> T {
        withUnsafeMutableBytes(of: &storage) { body($0.baseAddress!.assumingMemoryBound(to: UInt32.self)) }
    }
}
