import Foundation

/// Decodes a 32-bit ARM (not Thumb) instruction word into an
/// `ARMInstruction`. Pure and stateless — decoding never touches
/// register or memory state, only the instruction word itself, which is
/// what makes it independently unit-testable and, eventually, reusable
/// by a JIT front end without dragging CPU state along.
///
/// Covers data-processing (both operand2 forms), branch (B/BL), and
/// single-register load/store with an immediate offset. Everything else
/// — multiply, block transfer (LDM/STM), register-offset load/store,
/// MSR/MRS, coprocessor, SWI, Thumb — decodes to `.unsupported` rather
/// than being misinterpreted.
enum ARMDecoder {
    static func decode(_ word: UInt32) -> ARMInstruction {
        let condition = ARMCondition(rawBits: word.bitField(31, 28))
        if condition == .never {
            return .undefined(rawWord: word)
        }

        switch word.bitField(27, 26) {
        case 0b00:
            return decodeDataProcessingBlock(word, condition: condition)
        case 0b01:
            return decodeLoadStoreBlock(word, condition: condition)
        case 0b10:
            return decodeBranchOrBlockTransfer(word, condition: condition)
        default:
            return .unsupported(rawWord: word) // Coprocessor / SWI space.
        }
    }

    private static func decodeDataProcessingBlock(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        let immediateOperand = word.bit(25)

        if !immediateOperand && word.bit(4) && word.bit(7) {
            // bits[7]==1 && bits[4]==1 with I==0 signals the multiply /
            // extra-load-store space, not a shifted-register operand2.
            return .unsupported(rawWord: word)
        }

        guard let op = DataProcessingOp(rawValue: UInt8(word.bitField(24, 21))) else {
            return .undefined(rawWord: word)
        }

        let setFlags = word.bit(20)
        let rn = Int(word.bitField(19, 16))
        let rd = Int(word.bitField(15, 12))

        if !setFlags && op.isComparison {
            // TST/TEQ/CMP/CMN with S==0 isn't that comparison — this
            // encoding is where MSR/MRS (status register access) live.
            return .unsupported(rawWord: word)
        }

        let operand2: ShifterOperand
        if immediateOperand {
            let rotateAmount = word.bitField(11, 8) * 2
            let imm8 = word.bitField(7, 0)
            let rotated = ShifterOperand.rotateRight(imm8, by: rotateAmount)
            let forcedCarryOut: Bool? = rotateAmount == 0 ? nil : (rotated.bit(31))
            operand2 = .immediate(value: rotated, forcedCarryOut: forcedCarryOut)
        } else {
            // bit4 distinguishes immediate shift amount (0) from
            // register-specified shift amount (1, the `Rs` form). Only
            // the immediate form is decoded — the multiply-space check
            // above only ruled out bit4==1 *combined with* bit7==1, so
            // bit4==1 with bit7==0 (a valid but unimplemented Rs-shift
            // data-processing instruction) still needs its own check
            // here. Without this, its Rs field would silently get
            // misread as a shift-immediate instead of being refused.
            if word.bit(4) {
                return .unsupported(rawWord: word)
            }
            guard let shiftType = ShiftType(rawValue: UInt8(word.bitField(6, 5))) else {
                return .unsupported(rawWord: word)
            }
            operand2 = .shiftedRegister(
                rm: Int(word.bitField(3, 0)),
                shiftType: shiftType,
                shiftAmount: UInt8(word.bitField(11, 7))
            )
        }

        return .dataProcessing(DataProcessingInstruction(
            condition: condition, op: op, setFlags: setFlags, rn: rn, rd: rd, operand2: operand2
        ))
    }

    private static func decodeLoadStoreBlock(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        // For load/store (unlike data-processing), bit 25 == 1 means a
        // *register* offset — the opposite convention from the I bit
        // above. That form isn't decoded yet.
        if word.bit(25) {
            return .unsupported(rawWord: word)
        }

        return .loadStore(LoadStoreInstruction(
            condition: condition,
            isLoad: word.bit(20),
            isByte: word.bit(22),
            preIndexed: word.bit(24),
            addOffset: word.bit(23),
            writeback: word.bit(21),
            rn: Int(word.bitField(19, 16)),
            rd: Int(word.bitField(15, 12)),
            immediateOffset: word.bitField(11, 0)
        ))
    }

    private static func decodeBranchOrBlockTransfer(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        guard word.bit(25) else {
            return .unsupported(rawWord: word) // Block data transfer (LDM/STM).
        }

        let imm24 = word.bitField(23, 0)
        let signExtended = Int32(bitPattern: imm24.bit(23) ? (imm24 | 0xFF00_0000) : imm24)
        let signedOffset = signExtended << 2

        return .branch(BranchInstruction(condition: condition, link: word.bit(24), signedOffset: signedOffset))
    }
}
