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
    /// The 16 words, in heap storage the CPU owns for its whole life:
    /// translated code (`DBTEngine`) reads and writes guest registers at
    /// fixed offsets from this pointer, while the interpreter goes
    /// through the accessors below. A copy of `Registers` refers to the
    /// same storage.
    let storage: UnsafeMutablePointer<UInt32>

    static let pcIndex = 15
    static let lrIndex = 14
    static let spIndex = 13

    /// The same block holds the VFP/Advanced SIMD state after the 16
    /// words, so translated code reaches all of it from one base
    /// register: `D0`...`D31` from `extensionOffset` (`Sn` and `Qn` alias
    /// them, as on the hardware: little-endian halves and pairs), then
    /// FPSCR and FPEXC.
    static let extensionOffset = 64
    static let fpscrOffset = 320
    static let fpexcOffset = 324
    private static let byteCount = 384

    init() {
        let block = UnsafeMutableRawPointer.allocate(byteCount: Self.byteCount, alignment: 64)
        block.initializeMemory(as: UInt8.self, repeating: 0, count: Self.byteCount)
        storage = block.bindMemory(to: UInt32.self, capacity: 16)
        (block + Self.extensionOffset).bindMemory(to: UInt64.self, capacity: 32)
        (block + Self.fpscrOffset).bindMemory(to: UInt32.self, capacity: 2)
    }

    /// `D0`...`D31`.
    var extensionRegisters: UnsafeMutablePointer<UInt64> {
        (UnsafeMutableRawPointer(storage) + Self.extensionOffset).assumingMemoryBound(to: UInt64.self)
    }

    var fpscr: UInt32 {
        get { (UnsafeMutableRawPointer(storage) + Self.fpscrOffset).load(as: UInt32.self) }
        nonmutating set { (UnsafeMutableRawPointer(storage) + Self.fpscrOffset).storeBytes(of: newValue, as: UInt32.self) }
    }

    var fpexc: UInt32 {
        get { (UnsafeMutableRawPointer(storage) + Self.fpexcOffset).load(as: UInt32.self) }
        nonmutating set { (UnsafeMutableRawPointer(storage) + Self.fpexcOffset).storeBytes(of: newValue, as: UInt32.self) }
    }

    subscript(index: Int) -> UInt32 {
        get {
            precondition((0..<16).contains(index), "Register index out of range: \(index)")
            return storage[index]
        }
        nonmutating set {
            precondition((0..<16).contains(index), "Register index out of range: \(index)")
            storage[index] = newValue
        }
    }

    var pc: UInt32 {
        get { storage[15] }
        nonmutating set { storage[15] = newValue }
    }

    var lr: UInt32 {
        get { storage[14] }
        nonmutating set { storage[14] = newValue }
    }

    var sp: UInt32 {
        get { storage[13] }
        nonmutating set { storage[13] = newValue }
    }

    /// The value an instruction sees when it reads r15 as an operand:
    /// the address of the instruction currently executing, plus 8 —
    /// ARM's fetch/decode/execute pipeline convention, not a bug.
    /// `pc` itself always holds the address of the *next* instruction to
    /// fetch, which is what `pcForOperandRead` is derived from.
    var pcForOperandRead: UInt32 {
        pc &+ 4
    }

    func reset() {
        storage.update(repeating: 0, count: 16)
    }

    /// Frees the storage; for the owning CPU's `deinit` only.
    func deallocate() {
        UnsafeMutableRawPointer(storage).deallocate()
    }

    /// The register file as a raw pointer, for the old JIT's blocks.
    func withUnsafeMutableStorage<T>(_ body: (UnsafeMutablePointer<UInt32>) -> T) -> T {
        body(storage)
    }
}
