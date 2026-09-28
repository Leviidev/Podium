import Foundation

/// Fetching and decoding without redoing either for every instruction.
///
/// Decoding an instruction the interpreter ran a moment ago, and walking
/// the TLB for every fetch from the same page, measured at about a third
/// of the emulator's time. Two caches take that away:
///
/// - The fetch page: the virtual page the CPU last fetched from, in the
///   context (ASID, privilege, MMU on or off) it was translated in, and
///   where its bytes are in host RAM. Instructions on it are read straight
///   from there. It's forgotten whenever the TLB is flushed, which is how
///   the guest announces a changed mapping.
/// - Decoded instructions, direct-mapped by physical address. Each entry
///   keeps the instruction's raw bits and is only used when the bits just
///   fetched match, so code the guest rewrites (pages recycled, code
///   loaded) is decoded afresh — nothing has to watch memory for writes.
final class InstructionCache {
    private static let entries = 1 << 16

    private struct ThumbEntry {
        var address: UInt32
        var bits: UInt32
        var instruction: ThumbInstruction
    }

    private struct ARMEntry {
        var address: UInt32
        var bits: UInt32
        var instruction: ARMInstruction
    }

    private let thumb = UnsafeMutablePointer<ThumbEntry>.allocate(capacity: entries)
    private let arm = UnsafeMutablePointer<ARMEntry>.allocate(capacity: entries)

    // The fetch page. `pageVirtual` is page-aligned when valid.
    private(set) var pageVirtual: UInt32 = 1
    private(set) var pageContext: UInt32 = 0
    private(set) var pagePhysical: UInt32 = 0
    private(set) var pageHost: UnsafeMutableRawPointer?

    init() {
        // Address 1 is never an instruction's (both states align to 2).
        thumb.initialize(repeating: ThumbEntry(address: 1, bits: 0, instruction: ThumbDecoder.decode(0, 0)), count: Self.entries)
        arm.initialize(repeating: ARMEntry(address: 1, bits: 0, instruction: ARMDecoder.decode(0)), count: Self.entries)
    }

    deinit {
        thumb.deinitialize(count: Self.entries)
        thumb.deallocate()
        arm.deinitialize(count: Self.entries)
        arm.deallocate()
    }

    func forgetPage() {
        pageVirtual = 1
        pageHost = nil
    }

    func setPage(virtual: UInt32, context: UInt32, physical: UInt32, host: UnsafeMutableRawPointer?) {
        pageVirtual = virtual
        pageContext = context
        pagePhysical = physical
        pageHost = host
    }

    @inline(__always)
    func thumbInstruction(at physical: UInt32, hw0: UInt16, hw1: UInt16) -> ThumbInstruction {
        let bits = UInt32(hw0) | UInt32(hw1) << 16
        let entry = thumb + Int((physical >> 1) & UInt32(Self.entries - 1))
        if entry.pointee.address == physical, entry.pointee.bits == bits { return entry.pointee.instruction }
        let instruction = ThumbDecoder.decode(hw0, hw1)
        entry.pointee = ThumbEntry(address: physical, bits: bits, instruction: instruction)
        return instruction
    }

    @inline(__always)
    func armInstruction(at physical: UInt32, word: UInt32) -> ARMInstruction {
        let entry = arm + Int((physical >> 2) & UInt32(Self.entries - 1))
        if entry.pointee.address == physical, entry.pointee.bits == word { return entry.pointee.instruction }
        let instruction = ARMDecoder.decode(word)
        entry.pointee = ARMEntry(address: physical, bits: word, instruction: instruction)
        return instruction
    }
}
