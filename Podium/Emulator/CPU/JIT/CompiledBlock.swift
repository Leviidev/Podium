import Foundation

/// A run of guest instructions translated to native AArch64 code, ready
/// to execute directly on the host CPU. Operates through a pointer to
/// the guest register array plus, for blocks that include a load/store,
/// an optional raw host pointer to a fast-path memory region — see
/// `JITTranslator`/`ThumbJITTranslator` for the calling convention every
/// generated block follows.
final class CompiledBlock {
    /// `(registers, ramHostPointer, ramGuestBase, accessBound, cpsr) ->
    /// instructionsCompleted`, i.e. `x0`–`x4`. `ramHostPointer` may be null
    /// (no fast-path region at all); `accessBound == 0` has the same effect
    /// — every load/store's range check fails immediately — so generated
    /// code only ever needs one check, not a separate null-pointer guard.
    /// `accessBound` is *not* the region's length: generated code checks
    /// only the access's start offset (`addr - ramGuestBase < accessBound`),
    /// so `run` passes the number of offsets at which even a 4-byte access
    /// still ends inside the region. `cpsr` is the guest CPSR word; a block
    /// loads its NZCV into the host flags on entry and merges them back on
    /// every exit. A block with no load/store instructions ignores the
    /// three memory arguments and always returns `instructionCount`.
    typealias EntryPoint = @convention(c) (UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32

    let instructionCount: Int
    /// How far the guest `pc` advances if the block runs to completion —
    /// `cumulativeByteLengths[instructionCount]`. Thumb instructions are
    /// 2 or 4 bytes each (not a fixed width like ARM's 4), so this is
    /// tracked per-instruction, not derived from a single stride.
    let totalByteLength: Int
    /// `cumulativeByteLengths[k]` is how far `pc` should advance if only
    /// the first `k` instructions actually completed — index 0 is always
    /// 0, index `instructionCount` is `totalByteLength`. A load/store
    /// whose runtime address fails its bounds check stops the block
    /// there; every earlier instruction's effect is already committed to
    /// the register array (and any completed stores, to memory) by then,
    /// so the caller only needs to know how far to advance `pc` before
    /// falling back to the interpreter for the rest.
    private let cumulativeByteLengths: [Int]
    private let entryPoint: EntryPoint
    private let memory: UnsafeMutableRawPointer
    private let byteCount: Int
    /// Whether this block contains any load/store instruction — if not,
    /// its generated code never reads `x1`/`w2`/`w3` at all, so the
    /// caller can skip resolving a fast-path memory region before
    /// calling it (a real, measured cost when paid on every unit
    /// regardless of whether the block could ever use it — see
    /// `ARMv7CPU.runOneUnit()`'s doc comment on this property).
    let containsMemoryAccess: Bool

    init(memory: UnsafeMutableRawPointer, byteCount: Int, instructionCount: Int, cumulativeByteLengths: [Int], containsMemoryAccess: Bool) {
        precondition(cumulativeByteLengths.count == instructionCount + 1 && cumulativeByteLengths.first == 0,
                     "cumulativeByteLengths must have one entry per instruction boundary, starting at 0")
        self.memory = memory
        self.byteCount = byteCount
        self.instructionCount = instructionCount
        self.cumulativeByteLengths = cumulativeByteLengths
        self.totalByteLength = cumulativeByteLengths[instructionCount]
        self.entryPoint = unsafeBitCast(memory, to: EntryPoint.self)
        self.containsMemoryAccess = containsMemoryAccess
    }

    /// Convenience initializer for a block with no load/store
    /// instructions, where every instruction's width is already known
    /// and `cumulativeByteLengths` would just be their running sum.
    convenience init(memory: UnsafeMutableRawPointer, byteCount: Int, instructionByteLengths: [Int]) {
        var cumulative = [0]
        for length in instructionByteLengths {
            cumulative.append(cumulative[cumulative.count - 1] + length)
        }
        self.init(memory: memory, byteCount: byteCount, instructionCount: instructionByteLengths.count, cumulativeByteLengths: cumulative, containsMemoryAccess: false)
    }

    deinit {
        ExecutableMemoryAllocator.deallocate(memory, byteCount: byteCount)
    }

    /// How far `pc` should advance given that only the first
    /// `completedInstructions` instructions actually ran.
    func byteLength(afterCompleting completedInstructions: Int) -> Int {
        cumulativeByteLengths[completedInstructions]
    }

    /// Runs this block with a fast-path memory region available for any
    /// load/store instructions it contains. Returns how many
    /// instructions actually completed — `instructionCount` means the
    /// whole block ran; anything less means a load/store's guest address
    /// fell outside `[ramGuestBase, ramGuestBase + ramGuestLength)` and
    /// the block stopped there (see `byteLength(afterCompleting:)`).
    func run(registers: UnsafeMutablePointer<UInt32>, ramHostPointer: UnsafeMutableRawPointer?, ramGuestBase: UInt32, ramGuestLength: UInt32, cpsr: UnsafeMutablePointer<UInt32>) -> Int {
        let widestAccess: UInt32 = 4
        let accessBound = ramHostPointer == nil || ramGuestLength < widestAccess ? 0 : ramGuestLength - (widestAccess - 1)
        return Int(entryPoint(registers, ramHostPointer, ramGuestBase, accessBound, cpsr))
    }

    /// Convenience for a block known to have no load/store instructions
    /// (or when the caller has no fast-path region to offer) — equivalent
    /// to calling the full form with no memory access available.
    @discardableResult
    func run(registers: UnsafeMutablePointer<UInt32>, cpsr: UnsafeMutablePointer<UInt32>) -> Int {
        run(registers: registers, ramHostPointer: nil, ramGuestBase: 0, ramGuestLength: 0, cpsr: cpsr)
    }
}
