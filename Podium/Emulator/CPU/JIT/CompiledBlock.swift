import Foundation

/// A run of guest instructions translated to native AArch64 code, ready
/// to execute directly on the host CPU. Operates purely through a
/// pointer to the guest register array — see `JITTranslator` for the
/// calling convention every generated block follows — so no branches,
/// memory access, or flag updates happen inside a compiled block in this
/// first JIT slice.
final class CompiledBlock {
    /// Matches how a straight-line, non-branching, non-flag-setting
    /// generated block is called: given the guest register array, it
    /// updates it in place and returns.
    typealias EntryPoint = @convention(c) (UnsafeMutablePointer<UInt32>) -> Void

    let instructionCount: Int
    private let entryPoint: EntryPoint
    private let memory: UnsafeMutableRawPointer
    private let byteCount: Int

    init(memory: UnsafeMutableRawPointer, byteCount: Int, instructionCount: Int) {
        self.memory = memory
        self.byteCount = byteCount
        self.instructionCount = instructionCount
        self.entryPoint = unsafeBitCast(memory, to: EntryPoint.self)
    }

    deinit {
        ExecutableMemoryAllocator.deallocate(memory, byteCount: byteCount)
    }

    func run(registers: UnsafeMutablePointer<UInt32>) {
        entryPoint(registers)
    }
}
