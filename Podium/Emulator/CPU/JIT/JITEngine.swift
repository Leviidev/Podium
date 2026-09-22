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
/// that's expected to be `false` on a plain sideloaded iOS build without
/// a debugger-granted dynamic-codesigning right).
final class JITEngine {
    struct Stats: Equatable {
        var compiledBlockCount = 0
        var cacheHitCount = 0
        var interpreterFallbackCount = 0
    }

    private(set) var isAvailable = true
    private(set) var stats = Stats()

    // Keyed by address with the CPU's Thumb-state folded into bit 0 (real
    // instruction addresses are always at least 2-byte aligned in either
    // state, so bit 0 is otherwise unused) — the *same* address is, in
    // principle, reachable in either state at different times via
    // interworking, and an ARM-state block compiled from one interpretation
    // of those bytes must never be handed back for a Thumb-state call at
    // that same address, or vice versa.
    //
    // The value is a *double* Optional (`CompiledBlock??`, `.some(nil)`
    // distinct from a missing key): a confirmed-ineligible address caches
    // `.some(nil)`, not just "absent". Without that, every future visit to
    // an address whose instruction was never JIT-eligible in the first
    // place — a branch, almost any instruction type this engine doesn't
    // cover yet — re-ran full discovery (decode, then ask
    // `isSupported`/`byteLength` for each candidate) from scratch, forever,
    // since only a *successful* compile got cached. Real code re-visits
    // ordinary (ineligible) instructions constantly — every branch target,
    // every loop body's non-eligible instructions — so this was measured
    // to cost more than the JIT saved overall on a real kernel trace
    // (interpreterFallbackCount running into the hundreds of millions
    // while compiledBlockCount stayed in the thousands) before this cache
    // was added.
    private var cache: [UInt32: CompiledBlock?] = [:]
    private let maxBlockLength: Int

    init(maxBlockLength: Int = 32) {
        self.maxBlockLength = maxBlockLength
    }

    private static func cacheKey(address: UInt32, thumbState: Bool) -> UInt32 {
        thumbState ? (address | 1) : address
    }

    /// Returns a compiled block starting at `address` for the CPU's
    /// current `thumbState`, compiling and caching one by decoding
    /// forward through `memory` if needed. Returns `nil` when the
    /// instruction at `address` isn't JIT-eligible (or JIT has been
    /// disabled after an earlier allocation failure) — callers should
    /// interpret a single instruction in that case, then ask again at the
    /// next address. A `nil` result is itself cached (see this type's own
    /// doc comment on `cache`), so asking again at the *same* address is
    /// cheap, not a repeat of full discovery.
    func block(at address: UInt32, thumbState: Bool, memory: MemoryBus) -> CompiledBlock? {
        guard isAvailable else { return nil }

        let key = Self.cacheKey(address: address, thumbState: thumbState)
        if let cached = cache[key] {
            if let block = cached {
                stats.cacheHitCount += 1
                return block
            } else {
                stats.interpreterFallbackCount += 1
                return nil
            }
        }

        let compiled = thumbState
            ? compileThumb(startingAt: address, memory: memory)
            : compileARM(startingAt: address, memory: memory)

        cache[key] = compiled

        guard let compiled else {
            stats.interpreterFallbackCount += 1
            return nil
        }

        stats.compiledBlockCount += 1
        return compiled
    }

    private func compileARM(startingAt address: UInt32, memory: MemoryBus) -> CompiledBlock? {
        let candidates = discoverEligibleARMRun(startingAt: address, memory: memory)
        guard !candidates.isEmpty else { return nil }

        guard let compiled = JITTranslator.translate(candidates) else {
            // Translation only fails here if executable-memory allocation
            // or writing failed — that outcome won't change on retry, so
            // stop attempting rather than paying the discovery cost on
            // every subsequent instruction.
            isAvailable = false
            return nil
        }
        return compiled
    }

    private func compileThumb(startingAt address: UInt32, memory: MemoryBus) -> CompiledBlock? {
        let candidates = discoverEligibleThumbRun(startingAt: address, memory: memory)
        guard !candidates.isEmpty else { return nil }

        guard let compiled = ThumbJITTranslator.translate(candidates) else {
            isAvailable = false
            return nil
        }
        return compiled
    }

    /// Reads directly through `memory` (physical addresses), not through
    /// the CPU's MMU translation — `JITEngine` only has a `MemoryBus`,
    /// not the CPU's CP15/MMU state needed to translate. Only safe while
    /// `pc` is identity-mapped (virtBase==physBase), which holds for this
    /// kernel's early boot; a future caller running after the guest
    /// enables a non-identity mapping would need this reworked to route
    /// through the CPU's own translation instead.
    private func discoverEligibleARMRun(startingAt address: UInt32, memory: MemoryBus) -> [DataProcessingInstruction] {
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

    /// Same physical-address caveat as `discoverEligibleARMRun`. Thumb
    /// instructions are variable-width (2 or 4 bytes), so the cursor
    /// advances by each decoded instruction's own real length, not a
    /// fixed stride.
    private func discoverEligibleThumbRun(startingAt address: UInt32, memory: MemoryBus) -> [ThumbInstruction] {
        var instructions: [ThumbInstruction] = []
        var cursor = address

        while instructions.count < maxBlockLength {
            guard let hw0 = try? memory.readWord16(at: cursor) else { break }
            let isWide = ThumbDecoder.isThirtyTwoBitFirstHalfword(hw0)
            let hw1: UInt16
            if isWide {
                guard let secondHalfword = try? memory.readWord16(at: cursor &+ 2) else { break }
                hw1 = secondHalfword
            } else {
                hw1 = 0
            }

            let instruction = ThumbDecoder.decode(hw0, hw1)
            guard ThumbJITTranslator.isSupported(instruction) else { break }

            instructions.append(instruction)
            cursor = cursor &+ UInt32(ThumbJITTranslator.byteLength(of: instruction))
        }

        return instructions
    }
}
