import Foundation

/// Translates already-decoded, JIT-eligible Thumb-state instructions into
/// a `CompiledBlock` — the Thumb-state sibling of `JITTranslator`, which
/// only ever handles ARM-state `DataProcessingInstruction`s.
///
/// Scope, deliberately narrow for the same reasons as `JITTranslator`:
/// - `ThumbDataProcessingShiftedRegisterInstruction` (the Thumb-2 32-bit
///   "data-processing (shifted register)" encoding): `AND`/`BIC`/`ORR`/
///   `EOR`/`ADD`/`SUB`, non-flag-setting (`setFlags == false`), unshifted
///   register operand2 only (`shiftType == .lsl && shiftAmount == 0`) —
///   `ADC`/`SBC` need `cpsr.carry` as an extra input this calling
///   convention doesn't carry, and `RSB`/`ORN` need either operand-order
///   or negation handling not worth the complexity yet. Real, non-shift
///   uses of this instruction (plain register-register ALU ops) are
///   extremely common in this kernel's compiled code — see the
///   `/tmp/podium_profile` instruction-mix sample this was written
///   against.
/// - `ThumbHiRegisterInstruction`'s `ADD`/`MOV` forms only (never `CMP`,
///   which sets flags) — the Thumb16 "hi register operations" format,
///   verified never to set flags for these two (see
///   `ARMv7CPU+Thumb.swift`'s `executeThumbHiRegister`). `rdn == pc` is
///   excluded (a real, if unusual, branch — `writeThumbResult`'s own doc
///   comment covers why writing `pc` this way is a plain, non-
///   interworking jump, which this translator has no way to represent);
///   `rm == pc` is excluded too, since reading `pc` here means the
///   *aligned instruction address + 4* per `thumbOperandValue`, not the
///   raw register file value this translator's calling convention reads.
///
/// Everything else — conditional execution (there is none at the Thumb16
/// level, but `IT`-block predication is a separate, unhandled
/// instruction), flag setting, shifted/rotated operands, `ADC`/`SBC`/
/// `RSB`/`ORN`, branches, memory access — falls back to the interpreter.
enum ThumbJITTranslator {
    private enum Scratch {
        static let a = 1
        static let b = 2
    }

    private static func byteOffset(_ registerIndex: Int) -> Int {
        registerIndex * 4
    }

    /// Whether `instruction` is in the supported subset, without
    /// generating code for it — used to decide how far a basic block
    /// extends before committing to compiling it. `byteLength` is 2 for
    /// `hiRegister` (Thumb16) and 4 for `dataProcessingShiftedRegister`
    /// (Thumb-2, 32-bit) — the caller needs this to know how far to
    /// advance its own discovery cursor even for an ineligible
    /// instruction it's deciding whether to stop at.
    static func isSupported(_ instruction: ThumbInstruction) -> Bool {
        emit(instruction) != nil
    }

    /// Compiles `instructions` (a straight-line run, in order) into a
    /// `CompiledBlock`. Returns `nil` if any instruction isn't
    /// JIT-eligible or if executable memory couldn't be allocated/written
    /// — both ordinary, expected outcomes the caller falls back to
    /// interpretation for.
    static func translate(_ instructions: [ThumbInstruction]) -> CompiledBlock? {
        guard !instructions.isEmpty else { return nil }

        var words: [UInt32] = []
        var totalByteLength = 0
        for instruction in instructions {
            guard let generated = emit(instruction) else { return nil }
            words.append(contentsOf: generated.code)
            totalByteLength += generated.byteLength
        }
        words.append(ARM64Assembler.ret)

        let byteCount = words.count * MemoryLayout<UInt32>.size
        guard let memory = try? ExecutableMemoryAllocator.allocate(byteCount: byteCount) else {
            return nil
        }
        do {
            try ExecutableMemoryAllocator.write(words, to: memory)
        } catch {
            ExecutableMemoryAllocator.deallocate(memory, byteCount: byteCount)
            return nil
        }

        return CompiledBlock(memory: memory, byteCount: byteCount, instructionCount: instructions.count, totalByteLength: totalByteLength)
    }

    /// Real Thumb instruction byte length for `instruction`, regardless
    /// of JIT eligibility — used by the caller's discovery loop to
    /// advance its memory cursor even past ineligible instructions it's
    /// only peeking at to decide where a block ends.
    static func byteLength(of instruction: ThumbInstruction) -> Int {
        switch instruction {
        case .hiRegister:
            return 2
        default:
            // Every other case this translator's `emit` can ever accept
            // (dataProcessingShiftedRegister) is a Thumb-2 wide (32-bit)
            // encoding; anything not in `emit`'s supported set is never
            // asked about its length by `discoverEligibleRun` (which
            // stops discovery at the first ineligible instruction without
            // needing to skip past it).
            return 4
        }
    }

    private static func emit(_ instruction: ThumbInstruction) -> (code: [UInt32], byteLength: Int)? {
        switch instruction {
        case .dataProcessingShiftedRegister(let instr):
            return emitDataProcessingShiftedRegister(instr).map { ($0, 4) }
        case .hiRegister(let instr):
            return emitHiRegister(instr).map { ($0, 2) }
        default:
            return nil
        }
    }

    private static func emitDataProcessingShiftedRegister(_ instr: ThumbDataProcessingShiftedRegisterInstruction) -> [UInt32]? {
        guard !instr.setFlags,
              instr.shiftType == .lsl, instr.shiftAmount == 0,
              instr.rd != Registers.pcIndex, instr.rn != Registers.pcIndex, instr.rm != Registers.pcIndex else {
            return nil
        }

        let combine: (Int, Int, Int) -> UInt32
        switch instr.op {
        case .and: combine = ARM64Assembler.and32
        case .bic: combine = ARM64Assembler.bic32
        case .orr: combine = ARM64Assembler.orr32
        case .eor: combine = ARM64Assembler.eor32
        case .add: combine = ARM64Assembler.add32
        case .sub: combine = ARM64Assembler.sub32
        default: return nil // adc, sbc, rsb, orn: not decoded here — see this file's doc comment.
        }

        return [
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instr.rn)),
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.b, rn: 0, byteOffset: byteOffset(instr.rm)),
            combine(Scratch.a, Scratch.a, Scratch.b),
            ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instr.rd)),
        ]
    }

    private static func emitHiRegister(_ instr: ThumbHiRegisterInstruction) -> [UInt32]? {
        guard instr.rdn != Registers.pcIndex, instr.rm != Registers.pcIndex else {
            return nil
        }

        switch instr.op {
        case .mov:
            return [
                ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instr.rm)),
                ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instr.rdn)),
            ]
        case .add:
            return [
                ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instr.rdn)),
                ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.b, rn: 0, byteOffset: byteOffset(instr.rm)),
                ARM64Assembler.add32(rd: Scratch.a, rn: Scratch.a, rm: Scratch.b),
                ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instr.rdn)),
            ]
        case .cmp:
            return nil // Sets flags — see this file's doc comment.
        }
    }
}
