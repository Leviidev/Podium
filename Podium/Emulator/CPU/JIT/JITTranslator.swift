import Foundation

/// Translates already-decoded, JIT-eligible `DataProcessingInstruction`s
/// into a `CompiledBlock` of real AArch64 machine code.
///
/// Scope, deliberately: unconditional (`AL`), non-flag-setting (`S==0`)
/// MOV (immediate ≤ 16 bits, or a plain unshifted register copy), ADD,
/// and SUB (both register-register, unshifted). Nothing touches r15.
/// Everything else this decoder can produce — conditional execution,
/// flag setting, wider immediates, shifted operands, branches, memory
/// access — falls back to the interpreter. That's a narrow slice of the
/// interpreter's own coverage, which is itself a narrow slice of ARMv7;
/// extending it means adding another case to `emit`, not redesigning
/// anything here.
///
/// Every generated block follows one calling convention: given a pointer
/// to the 16-word guest register array (`x0`), read/modify/write through
/// that pointer using two scratch registers (`w1`, `w2`), touch nothing
/// else, and `ret`. The caller (`JITEngine`/`ARMv7CPU`) is responsible
/// for advancing the guest PC by `4 * instructionCount` afterward, since
/// nothing in this instruction subset changes control flow.
enum JITTranslator {
    private enum Scratch {
        static let a = 1
        static let b = 2
    }

    private static func byteOffset(_ registerIndex: Int) -> Int {
        registerIndex * 4
    }

    /// Whether `instruction` is in the supported subset, without
    /// generating code for it — used to decide how far a basic block
    /// extends before committing to compiling it.
    static func isSupported(_ instruction: DataProcessingInstruction) -> Bool {
        emit(instruction) != nil
    }

    /// Compiles `instructions` (a straight-line run, in order) into a
    /// `CompiledBlock`. Returns `nil` if any instruction isn't
    /// JIT-eligible or if executable memory couldn't be allocated/written
    /// (most likely on iOS: no dynamic-codesigning right without a
    /// debugger attached) — both are ordinary, expected outcomes the
    /// caller falls back to interpretation for.
    static func translate(_ instructions: [DataProcessingInstruction]) -> CompiledBlock? {
        guard !instructions.isEmpty else { return nil }

        var words: [UInt32] = []
        for instruction in instructions {
            guard let generated = emit(instruction) else { return nil }
            words.append(contentsOf: generated)
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

        return CompiledBlock(memory: memory, byteCount: byteCount, instructionCount: instructions.count)
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
}
