import Foundation

/// Discovers and caches compiled blocks so `ARMv7CPU.run()` can execute
/// eligible straight-line code natively instead of one interpreted
/// instruction at a time.
///
/// This is deliberately observable rather than a black box: `stats`
/// reports exactly how many blocks are running natively versus how many
/// times execution fell back to the interpreter, and `isAvailable`
/// reports the truth about whether JIT compilation could happen on this
/// run at all (see `ExecutableMemoryAllocator`'s doc comment for why
/// that's expected to be `false` on a plain sideloaded iOS build).
final class JITEngine {
    struct Stats: Equatable {
        var compiledBlockCount = 0
        var cacheHitCount = 0
        var interpreterFallbackCount = 0
    }

    private(set) var isAvailable = true
    private(set) var stats = Stats()

    private var cache: [UInt32: CompiledBlock] = [:]
    private let maxBlockLength: Int

    init(maxBlockLength: Int = 32) {
        self.maxBlockLength = maxBlockLength
    }

    /// Returns a compiled block starting at `address`, compiling and
    /// caching one by decoding forward through `memory` if needed.
    /// Returns `nil` when the instruction at `address` isn't JIT-eligible
    /// (or JIT has been disabled after an earlier allocation failure) —
    /// callers should interpret a single instruction in that case, then
    /// ask again at the next address.
    func block(at address: UInt32, memory: MemoryBus) -> CompiledBlock? {
        guard isAvailable else { return nil }

        if let cached = cache[address] {
            stats.cacheHitCount += 1
            return cached
        }

        let candidates = discoverEligibleRun(startingAt: address, memory: memory)
        guard !candidates.isEmpty else {
            stats.interpreterFallbackCount += 1
            return nil
        }

        guard let compiled = JITTranslator.translate(candidates) else {
            // Translation only fails here if executable-memory allocation
            // or writing failed — that outcome won't change on retry, so
            // stop attempting rather than paying the discovery cost on
            // every subsequent instruction.
            isAvailable = false
            stats.interpreterFallbackCount += 1
            return nil
        }

        cache[address] = compiled
        stats.compiledBlockCount += 1
        return compiled
    }

    /// Reads directly through `memory` (physical addresses), not through
    /// the CPU's MMU translation — `JITEngine` only has a `MemoryBus`,
    /// not the CPU's CP15/MMU state needed to translate. Only safe while
    /// `pc` is identity-mapped (virtBase==physBase), which holds for this
    /// kernel's early boot; a future caller running after the guest
    /// enables a non-identity mapping would need this reworked to route
    /// through the CPU's own translation instead.
    private func discoverEligibleRun(startingAt address: UInt32, memory: MemoryBus) -> [DataProcessingInstruction] {
        var instructions: [DataProcessingInstruction] = []
        var cursor = address

        while instructions.count < maxBlockLength {
            guard let word = try? memory.readWord32(at: cursor) else { break }
            guard case .dataProcessing(let instruction) = ARMDecoder.decode(word),
                  JITTranslator.isSupported(instruction) else {
                break
            }
            instructions.append(instruction)
            cursor = cursor &+ 4
        }

        return instructions
    }
}
