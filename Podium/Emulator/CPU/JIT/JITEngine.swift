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

    // Tracks, per cache key, how many *consecutive* times in a row a
    // memory-accessing block has bailed on its very first instruction
    // (`completed == 0` — see `ARMv7CPU.runOneUnit()`). A block whose
    // load/store address is outside the offered fast-path region every
    // single time it's reached (a real case found this session: ARM-state
    // code, e.g. a bcopy/memcpy-style routine, whose target address is
    // often outside RAM — a peripheral or low-SRAM destination) makes
    // strictly *negative* progress on every hit: the caller still pays
    // the full JIT call overhead (region lookup, register marshaling,
    // native call) and then *also* has to run a real interpreted `step()`
    // for the same instruction, since `completed == 0` means the block
    // did nothing. Compiling that address was worse than never touching
    // it — measured as a real regression (0.98x to 0.60x of interpreter
    // speed) when ARM-state load/store JIT coverage was added. Any hit
    // that makes progress (`completed > 0`) resets the counter to 0; only
    // a genuinely chronic bailer accumulates `maxConsecutiveBailsBeforeEviction`
    // in a row and gets its cache entry permanently replaced with a
    // confirmed-ineligible marker, so the interpreter takes over there for
    // the rest of the run with no further JIT overhead at all.
    private var consecutiveBailCounts: [UInt32: Int] = [:]
    private static let maxConsecutiveBailsBeforeEviction = 4

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

    /// Called by `ARMv7CPU.runOneUnit()` after every execution of a
    /// memory-accessing block, reporting whether that call advanced `pc`
    /// at all. See this type's doc comment on `consecutiveBailCounts` for
    /// why a block that never makes progress needs to be evicted rather
    /// than compiled once and trusted forever.
    func reportMemoryBlockOutcome(at address: UInt32, thumbState: Bool, madeProgress: Bool) {
        let key = Self.cacheKey(address: address, thumbState: thumbState)
        if madeProgress {
            if consecutiveBailCounts[key] != nil {
                consecutiveBailCounts.removeValue(forKey: key)
            }
            return
        }

        let count = (consecutiveBailCounts[key] ?? 0) + 1
        if count >= Self.maxConsecutiveBailsBeforeEviction {
            cache[key] = .some(nil)
            consecutiveBailCounts.removeValue(forKey: key)
        } else {
            consecutiveBailCounts[key] = count
        }
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

    /// `address` is physical: the CPU translates the pc before asking
    /// (see `ARMv7CPU.jitPhysicalAddress`), and only asks for code in
    /// physically contiguous memory, so reading straight through `memory`
    /// is correct for the whole run. Blocks are cached by physical
    /// address too, which keeps them valid across address spaces.
    private func discoverEligibleARMRun(startingAt address: UInt32, memory: MemoryBus) -> [ARMJITEligibleInstruction] {
        var instructions: [ARMJITEligibleInstruction] = []
        var cursor = address

        while instructions.count < maxBlockLength {
            guard let word = try? memory.readWord32(at: cursor) else { break }
            switch ARMDecoder.decode(word) {
            case .dataProcessing(let instruction) where JITTranslator.isSupported(instruction):
                instructions.append(.dataProcessing(instruction))
            case .loadStore(let instruction) where JITTranslator.isSupported(instruction):
                instructions.append(.loadStore(instruction))
            default:
                return instructions
            }
            cursor = cursor &+ 4
        }

        return instructions
    }

    /// Same physical-address caveat as `discoverEligibleARMRun`. Thumb
    /// instructions are variable-width (2 or 4 bytes); the width comes
    /// straight from the first halfword's encoding, the only authority on
    /// it, and is carried along to the translator so the cursor and the
    /// compiled block's `pc` advance agree with what was actually decoded.
    private func discoverEligibleThumbRun(startingAt address: UInt32, memory: MemoryBus) -> [(instruction: ThumbInstruction, byteLength: Int)] {
        var instructions: [(instruction: ThumbInstruction, byteLength: Int)] = []
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

            let byteLength = isWide ? 4 : 2
            instructions.append((instruction, byteLength))
            cursor = cursor &+ UInt32(byteLength)
        }

        return instructions
    }
}
