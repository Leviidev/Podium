import Foundation

/// Translates already-decoded, JIT-eligible Thumb-state instructions into
/// a `CompiledBlock` — the Thumb-state sibling of `JITTranslator`, which
/// only ever handles ARM-state `DataProcessingInstruction`s.
///
/// Calling convention (see `CompiledBlock.EntryPoint`): `x0` is the guest
/// register array (as in `JITTranslator`); `x1`/`w2`/`w3` are a fast-path
/// memory region (`x1` a host pointer, `w2` its guest base address, `w3`
/// its guest length) that load/store instructions range-check against
/// before touching. `w2`/`w3` are **reserved for the whole block**, not
/// just the instruction that needs them — every register-only emitter
/// here uses `w4`/`w5`/`w6` as scratch specifically so a memory
/// instruction elsewhere in the same block can still trust `w2`/`w3`
/// after a register-only instruction has run (using `w1`/`w2` the way
/// `JITTranslator`'s ARM-state scratch does would silently corrupt the
/// region bounds for every later memory instruction in a mixed block —
/// this only matters once a block can mix the two kinds, which is why
/// `JITTranslator` itself doesn't need to care).
///
/// Scope, deliberately narrow for the same reasons as `JITTranslator`:
/// - `ThumbDataProcessingShiftedRegisterInstruction` (the Thumb-2 32-bit
///   "data-processing (shifted register)" encoding): `AND`/`BIC`/`ORR`/
///   `EOR`/`ADD`/`SUB`, non-flag-setting (`setFlags == false`), unshifted
///   register operand2 only (`shiftType == .lsl && shiftAmount == 0`) —
///   `ADC`/`SBC` need `cpsr.carry` as an extra input this calling
///   convention doesn't carry, and `RSB`/`ORN` need either operand-order
///   or negation handling not worth the complexity yet.
/// - `ThumbHiRegisterInstruction`'s `ADD`/`MOV` forms only (never `CMP`,
///   which sets flags). `rdn == pc` and `rm == pc` are excluded — see
///   `writeThumbResult`'s/`thumbOperandValue`'s doc comments.
/// - `ThumbLoadStoreImmediateInstruction` (Thumb16 formats 9/10/11:
///   `LDR`/`STR`/`LDRB`/`STRB`/`LDRH`/`STRH`, 5-bit immediate offset,
///   `Rn` any register including `SP`): the guest address is range-
///   checked against `[w2, w2+w3)` at runtime (the caller only offers a
///   fast-path region when it's the identity-mapped main RAM window —
///   see `ARMv7CPU.runOneUnit()`); on a hit, the access goes straight to
///   host memory via `x1`. On a miss (or when no fast-path region was
///   offered at all, signaled by `w3 == 0`, which makes the unsigned
///   bounds check fail for every address without a separate null check),
///   the compiled code stops *at that instruction* and reports how many
///   *earlier* instructions in the block already completed — see
///   `CompiledBlock.byteLength(afterCompleting:)`. Every instruction
///   before the failing one has already fully committed its effects (to
///   the register array, and for a completed store, to memory), so nothing
///   needs to be undone; the caller just resumes via the interpreter at
///   the failing instruction's own address, which correctly performs (or
///   properly faults) the access this fast path declined to risk.
///
/// Everything else — conditional execution (`IT`-block predication is a
/// separate, unhandled instruction, and `ARMv7CPU.runOneUnit()` refuses
/// the JIT outright whenever an IT block is active — see its own doc
/// comment for why), flag setting, shifted/rotated operands, `ADC`/`SBC`/
/// `RSB`/`ORN`, branches, the Thumb-2 wide load/store forms, writeback —
/// falls back to the interpreter.
enum ThumbJITTranslator {
    /// Scratch registers for register-only work — `w2`/`w3` are off
    /// limits (reserved for the fast-path region's bounds for the whole
    /// block; see this type's doc comment), and `w0`/`w1` are the
    /// entry point's own first two arguments.
    private enum Scratch {
        static let a = 4
        static let b = 5
    }

    /// The extra scratch register load/store instructions need beyond
    /// `Scratch.a` (which they reuse to hold the resolved guest address,
    /// then the loaded/stored value, since those two uses never overlap
    /// within one instruction) — the address-minus-region-base offset,
    /// kept alive across the bounds check and into the actual access.
    private static let relativeOffsetScratch = 6

    private static func byteOffset(_ registerIndex: Int) -> Int {
        registerIndex * 4
    }

    /// Whether `instruction` is in the supported subset, without
    /// generating code for it — used to decide how far a basic block
    /// extends before committing to compiling it.
    static func isSupported(_ instruction: ThumbInstruction) -> Bool {
        emit(instruction, completedInstructionsIfBail: 0) != nil
    }

    /// Compiles `instructions` (a straight-line run, in order) into a
    /// `CompiledBlock`. Returns `nil` if any instruction isn't
    /// JIT-eligible or if executable memory couldn't be allocated/written
    /// — both ordinary, expected outcomes the caller falls back to
    /// interpretation for.
    static func translate(_ instructions: [ThumbInstruction]) -> CompiledBlock? {
        guard !instructions.isEmpty else { return nil }

        var words: [UInt32] = []
        var instructionByteLengths: [Int] = []
        var containsMemoryAccess = false
        for (index, instruction) in instructions.enumerated() {
            guard let generated = emit(instruction, completedInstructionsIfBail: index) else { return nil }
            words.append(contentsOf: generated.code)
            instructionByteLengths.append(generated.byteLength)
            if case .loadStoreImmediate = instruction { containsMemoryAccess = true }
        }
        // Reached only if every instruction's memory access (if any) was
        // in bounds — the whole block completed.
        words.append(ARM64Assembler.movz32(rd: 0, imm16: UInt16(instructions.count)))
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

        var cumulative = [0]
        for length in instructionByteLengths {
            cumulative.append(cumulative[cumulative.count - 1] + length)
        }
        return CompiledBlock(memory: memory, byteCount: byteCount, instructionCount: instructions.count, cumulativeByteLengths: cumulative, containsMemoryAccess: containsMemoryAccess)
    }

    /// Real Thumb instruction byte length for `instruction`, regardless
    /// of JIT eligibility — used by the caller's discovery loop to
    /// advance its memory cursor even past ineligible instructions it's
    /// only peeking at to decide where a block ends.
    static func byteLength(of instruction: ThumbInstruction) -> Int {
        switch instruction {
        case .hiRegister, .loadStoreImmediate:
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

    private static func emit(_ instruction: ThumbInstruction, completedInstructionsIfBail: Int) -> (code: [UInt32], byteLength: Int)? {
        switch instruction {
        case .dataProcessingShiftedRegister(let instr):
            return emitDataProcessingShiftedRegister(instr).map { ($0, 4) }
        case .hiRegister(let instr):
            return emitHiRegister(instr).map { ($0, 2) }
        case .loadStoreImmediate(let instr):
            return emitLoadStoreImmediate(instr, completedInstructionsIfBail: completedInstructionsIfBail).map { ($0, 2) }
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

    /// `LDR`/`STR`/`LDRB`/`STRB`/`LDRH`/`STRH Rt, [Rn, #imm]` (Thumb16
    /// formats 9/10/11). See this file's doc comment for the bounds-check
    /// and partial-completion scheme.
    private static func emitLoadStoreImmediate(_ instr: ThumbLoadStoreImmediateInstruction, completedInstructionsIfBail: Int) -> [UInt32]? {
        guard instr.rn != Registers.pcIndex, instr.rt != Registers.pcIndex, instr.offset <= 0xFFF else {
            return nil
        }

        let addr = Scratch.a
        let rel = relativeOffsetScratch
        let value = Scratch.a // Safe to reuse: `addr`'s value is fully consumed by the `SUB` below before `value` is ever written.

        var code: [UInt32] = [
            ARM64Assembler.ldrWordUnsignedOffset(rt: addr, rn: 0, byteOffset: byteOffset(instr.rn)),
        ]
        if instr.offset != 0 {
            code.append(ARM64Assembler.addImmediate32(rd: addr, rn: addr, imm12: instr.offset))
        }
        code.append(ARM64Assembler.sub32(rd: rel, rn: addr, rm: 2)) // rel = addr - ramGuestBase(w2)
        code.append(ARM64Assembler.cmp32(rn: rel, rm: 3)) // compare against ramGuestLength(w3)
        code.append(ARM64Assembler.branchIfHS(instructionsForward: 4)) // out of bounds -> bail (4 words ahead: the 2-word access, the skip-branch, then bail)

        switch instr.size {
        case .word:
            if instr.isLoad {
                code.append(ARM64Assembler.ldrWordRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
                code.append(ARM64Assembler.strWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instr.rt)))
            } else {
                code.append(ARM64Assembler.ldrWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instr.rt)))
                code.append(ARM64Assembler.strWordRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
            }
        case .byte:
            if instr.isLoad {
                code.append(ARM64Assembler.ldrbRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
                code.append(ARM64Assembler.strWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instr.rt)))
            } else {
                code.append(ARM64Assembler.ldrWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instr.rt)))
                code.append(ARM64Assembler.strbRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
            }
        case .halfword:
            if instr.isLoad {
                code.append(ARM64Assembler.ldrhRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
                code.append(ARM64Assembler.strWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instr.rt)))
            } else {
                code.append(ARM64Assembler.ldrWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instr.rt)))
                code.append(ARM64Assembler.strhRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
            }
        }

        code.append(ARM64Assembler.branch(instructionsForward: 3)) // success -> skip the bail sequence below
        code.append(ARM64Assembler.movz32(rd: 0, imm16: UInt16(completedInstructionsIfBail)))
        code.append(ARM64Assembler.ret)

        return code
    }
}
