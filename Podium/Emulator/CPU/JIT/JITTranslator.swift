import Foundation

/// Translates already-decoded, JIT-eligible `DataProcessingInstruction`s
/// and `LoadStoreInstruction`s into a `CompiledBlock` of real AArch64
/// machine code — the ARM-state sibling of `ThumbJITTranslator`, which
/// has the fuller explanation of the load/store bounds-check and
/// partial-completion scheme this file reuses verbatim.
///
/// Scope, deliberately: unconditional (`AL`), non-flag-setting (`S==0`)
/// MOV (immediate ≤ 16 bits, or a plain unshifted register copy), ADD,
/// SUB, AND, ORR, EOR, BIC, and MVN (all register-register, unshifted);
/// plus `LDR`/`STR`/`LDRB`/`STRB` with a pre-indexed, non-writeback
/// immediate offset. Nothing touches r15. Everything else this decoder
/// can produce — conditional execution, flag setting, wider immediates,
/// shifted operands, branches, register-offset/writeback addressing —
/// falls back to the interpreter. That's a narrow slice of the
/// interpreter's own coverage, which is itself a narrow slice of ARMv7;
/// extending it means adding another case to `emit`, not redesigning
/// anything here.
///
/// Calling convention (see `CompiledBlock.EntryPoint`): identical to
/// `ThumbJITTranslator`'s — `x0` the guest register array, `x1`/`w2`/`w3`
/// a fast-path memory region a load/store range-checks against, `w2`/`w3`
/// reserved for the whole block so a register-only instruction elsewhere
/// in the same block can't clobber them. That's why the scratch registers
/// below are `w4`/`w5`, not `w1`/`w2` — ARM state didn't need to care
/// about this before load/store existed here, since nothing read `w2`/
/// `w3` at all, but a mixed block now can.
enum JITTranslator {
    private static var epilogue: [UInt32] {
        [
            ARM64Assembler.mrs_nzcv(xt: 12),
            ARM64Assembler.ldrWordUnsignedOffset(rt: 13, rn: 4, byteOffset: 0),
            ARM64Assembler.movz32(rd: 14, imm16: 0x0FFF, shiftBy16: true),
            ARM64Assembler.movk32(rd: 14, imm16: 0xFFFF, shiftBy16: false),
            ARM64Assembler.and32(rd: 13, rn: 13, rm: 14),
            ARM64Assembler.orr32(rd: 13, rn: 13, rm: 12),
            ARM64Assembler.strWordUnsignedOffset(rt: 13, rn: 4, byteOffset: 0)
        ]
    }

    private enum Scratch {
        static let a = 9
        static let b = 10
    }

    /// Extra scratch for load/store address-range checking — see
    /// `ThumbJITTranslator`'s identically-purposed `relativeOffsetScratch`.
    private static let relativeOffsetScratch = 11

    private static func byteOffset(_ registerIndex: Int) -> Int {
        registerIndex * 4
    }

    /// Whether `instruction` is in the supported subset, without
    /// generating code for it — used to decide how far a basic block
    /// extends before committing to compiling it.
    static func isSupported(_ instruction: DataProcessingInstruction) -> Bool {
        emit(instruction) != nil
    }

    static func isSupported(_ instruction: LoadStoreInstruction) -> Bool {
        emitLoadStore(instruction, completedInstructionsIfBail: 0) != nil
    }

    /// Compiles a straight-line run of `DataProcessingInstruction`s
    /// and/or `LoadStoreInstruction`s (in order) into a `CompiledBlock`.
    /// Returns `nil` if any instruction isn't JIT-eligible or if
    /// executable memory couldn't be allocated/written (most likely on
    /// iOS: no dynamic-codesigning right without a debugger attached) —
    /// both are ordinary, expected outcomes the caller falls back to
    /// interpretation for.
    static func translate(_ instructions: [ARMJITEligibleInstruction]) -> CompiledBlock? {
        guard !instructions.isEmpty else { return nil }

        
        var words: [UInt32] = [
            ARM64Assembler.ldrWordUnsignedOffset(rt: 12, rn: 4, byteOffset: 0),
            ARM64Assembler.movz32(rd: 13, imm16: 0xF000, shiftBy16: true),
            ARM64Assembler.and32(rd: 12, rn: 12, rm: 13),
            ARM64Assembler.msr_nzcv(xt: 12)
        ]

        var containsMemoryAccess = false
        for (index, instruction) in instructions.enumerated() {
            let generated: [UInt32]?
            switch instruction {
            case .dataProcessing(let instr):
                generated = emit(instr)
            case .loadStore(let instr):
                generated = emitLoadStore(instr, completedInstructionsIfBail: index)
                if generated != nil { containsMemoryAccess = true }
            }
            guard let generated else { return nil }
            words.append(contentsOf: generated)
        }
        // Reached only if every instruction's memory access (if any) was
        // in bounds — the whole block completed.
        words.append(contentsOf: epilogue)
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

        // Every ARM-state instruction is a fixed 4 bytes.
        return CompiledBlock(
            memory: memory, byteCount: byteCount, instructionCount: instructions.count,
            cumulativeByteLengths: (0...instructions.count).map { $0 * 4 },
            containsMemoryAccess: containsMemoryAccess
        )
    }

    private static func emit(_ instruction: DataProcessingInstruction) -> [UInt32]? {
        guard instruction.condition == .always,
              !instruction.setFlags,
              instruction.rd != Registers.pcIndex,
              instruction.rn != Registers.pcIndex else {
            return nil
        }

        switch instruction.op {
        case .mov:
            return emitMov(instruction)
        case .add, .sub:
            return emitAddOrSub(instruction)
        case .and, .orr, .eor, .bic:
            return emitLogical(instruction)
        case .mvn:
            return emitMvn(instruction)
        default:
            return nil
        }
    }

    private static func emitMov(_ instruction: DataProcessingInstruction) -> [UInt32]? {
        switch instruction.operand2 {
        case .immediate(let value, _) where value <= UInt32(UInt16.max):
            return [
                ARM64Assembler.movz32(rd: Scratch.a, imm16: UInt16(value)),
                ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rd)),
            ]

        case .shiftedRegister(let rm, let shiftType, let shiftAmount)
            where shiftType == .lsl && shiftAmount == 0 && rm != Registers.pcIndex:
            return [
                ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(rm)),
                ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rd)),
            ]

        default:
            return nil
        }
    }

    private static func emitAddOrSub(_ instruction: DataProcessingInstruction) -> [UInt32]? {
        guard case .shiftedRegister(let rm, let shiftType, let shiftAmount) = instruction.operand2,
              shiftType == .lsl, shiftAmount == 0, rm != Registers.pcIndex else {
            return nil
        }

        let combine = instruction.op == .add ? ARM64Assembler.add32 : ARM64Assembler.sub32
        return [
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rn)),
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.b, rn: 0, byteOffset: byteOffset(rm)),
            combine(Scratch.a, Scratch.a, Scratch.b),
            ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rd)),
        ]
    }

    /// `AND`/`ORR`/`EOR`/`BIC`, unshifted register operand2 only (same
    /// restriction as `emitAddOrSub`).
    private static func emitLogical(_ instruction: DataProcessingInstruction) -> [UInt32]? {
        guard case .shiftedRegister(let rm, let shiftType, let shiftAmount) = instruction.operand2,
              shiftType == .lsl, shiftAmount == 0, rm != Registers.pcIndex else {
            return nil
        }

        let combine: (Int, Int, Int) -> UInt32
        switch instruction.op {
        case .and: combine = ARM64Assembler.and32
        case .orr: combine = ARM64Assembler.orr32
        case .eor: combine = ARM64Assembler.eor32
        case .bic: combine = ARM64Assembler.bic32
        default: return nil
        }

        return [
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rn)),
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.b, rn: 0, byteOffset: byteOffset(rm)),
            combine(Scratch.a, Scratch.a, Scratch.b),
            ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rd)),
        ]
    }

    /// `MVN Rd, Rm` (unshifted register operand2 only). `Rn` is unused by
    /// `MVN` (it's a unary op) so, unlike `emitLogical`, there's no `Rn`
    /// read here.
    private static func emitMvn(_ instruction: DataProcessingInstruction) -> [UInt32]? {
        guard case .shiftedRegister(let rm, let shiftType, let shiftAmount) = instruction.operand2,
              shiftType == .lsl, shiftAmount == 0, rm != Registers.pcIndex else {
            return nil
        }

        return [
            ARM64Assembler.ldrWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(rm)),
            ARM64Assembler.mvn32(rd: Scratch.a, rm: Scratch.a),
            ARM64Assembler.strWordUnsignedOffset(rt: Scratch.a, rn: 0, byteOffset: byteOffset(instruction.rd)),
        ]
    }

    /// `LDR`/`STR`/`LDRB`/`STRB Rd, [Rn, #imm]` — pre-indexed, no
    /// writeback, immediate offset only (register-offset and writeback
    /// addressing modes aren't decoded here). Same bounds-check-then-
    /// access-then-skip-the-bail-sequence shape as
    /// `ThumbJITTranslator.emitLoadStoreImmediate` — see its doc comment
    /// for the full reasoning; this is its ARM-state twin, differing only
    /// in which guest instruction fields feed it (no halfword form exists
    /// in ARM state's plain `LDR`/`STR`, unlike Thumb's).
    private static func emitLoadStore(_ instruction: LoadStoreInstruction, completedInstructionsIfBail: Int) -> [UInt32]? {
        guard instruction.condition == .always,
              instruction.preIndexed, !instruction.writeback, instruction.addOffset,
              instruction.rn != Registers.pcIndex, instruction.rd != Registers.pcIndex,
              case .immediate(let offset) = instruction.offset, offset <= 0xFFF else {
            return nil
        }

        let addr = Scratch.a
        let rel = relativeOffsetScratch
        let value = Scratch.a

        var code: [UInt32] = [
            ARM64Assembler.ldrWordUnsignedOffset(rt: addr, rn: 0, byteOffset: byteOffset(instruction.rn)),
        ]
        if offset != 0 {
            code.append(ARM64Assembler.addImmediate32(rd: addr, rn: addr, imm12: offset))
        }
        code.append(ARM64Assembler.sub32(rd: rel, rn: addr, rm: 2)) // rel = addr - ramGuestBase(w2)
        // Save guest flags before bounds check cmp!
        code.append(ARM64Assembler.mrs_nzcv(xt: 8))
        code.append(ARM64Assembler.cmp32(rn: rel, rm: 3)) // compare against ramGuestLength(w3)
        code.append(ARM64Assembler.branchIfLO(instructionsForward: 3)) // in bounds -> skip to in-bounds restore
        
        // --- Out of bounds path ---
        code.append(ARM64Assembler.msr_nzcv(xt: 8)) // Restore guest flags before bailing out
        code.append(ARM64Assembler.branch(instructionsForward: 5)) // Jump to the bailout sequence below (epilogue)
        
        // --- In bounds path ---
        code.append(ARM64Assembler.msr_nzcv(xt: 8)) // Restore guest flags for the rest of the block

        if instruction.isByte {
            if instruction.isLoad {
                code.append(ARM64Assembler.ldrbRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
                code.append(ARM64Assembler.strWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instruction.rd)))
            } else {
                code.append(ARM64Assembler.ldrWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instruction.rd)))
                code.append(ARM64Assembler.strbRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
            }
        } else {
            if instruction.isLoad {
                code.append(ARM64Assembler.ldrWordRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
                code.append(ARM64Assembler.strWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instruction.rd)))
            } else {
                code.append(ARM64Assembler.ldrWordUnsignedOffset(rt: value, rn: 0, byteOffset: byteOffset(instruction.rd)))
                code.append(ARM64Assembler.strWordRegisterOffsetUXTW(rt: value, rn: 1, rm: rel))
            }
        }

        
        code.append(ARM64Assembler.branch(instructionsForward: epilogue.count + 3)) // success -> skip the bail sequence below
        code.append(contentsOf: epilogue)
        code.append(ARM64Assembler.movz32(rd: 0, imm16: UInt16(completedInstructionsIfBail)))

        code.append(ARM64Assembler.ret)

        return code
    }
}

/// The union `JITEngine`'s ARM-state discovery actually walks — a
/// straight-line run can mix `DataProcessingInstruction`s and
/// `LoadStoreInstruction`s freely, same as `ThumbInstruction` already
/// does for the Thumb-state side (there, every case lives in one enum
/// already; ARM state's decoder instead produces `ARMInstruction`, whose
/// other cases — branches, block transfers, and everything else —
/// `JITTranslator` was never going to support, so this is the minimal
/// two-case subset worth discovery bothering to look for, not a
/// reflection of `ARMInstruction`'s full shape).
enum ARMJITEligibleInstruction {
    case dataProcessing(DataProcessingInstruction)
    case loadStore(LoadStoreInstruction)
}
