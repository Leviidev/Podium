import Foundation

/// Decodes a 32-bit ARM (not Thumb) instruction word into an
/// `ARMInstruction`. Pure and stateless — decoding never touches
/// register or memory state, only the instruction word itself, which is
/// what makes it independently unit-testable and, eventually, reusable
/// by a JIT front end without dragging CPU state along.
///
/// Covers data-processing (both operand2 forms), `MOVW`/`MOVT`, branch
/// (B/BL), single-register load/store (immediate *and* register
/// offset), `MCR`/`MRC`, `CPS`, and the `DSB`/`DMB`/`ISB` barriers.
/// Everything else — multiply, block transfer (LDM/STM), register-
/// shifted-by-register operand2, MSR/MRS, most of the coprocessor and
/// unconditional-instruction-extension spaces, SWI, Thumb — decodes to
/// `.unsupported` rather than being misinterpreted. Every case added
/// here so far was verified against real, disassembled instruction
/// words from the actual iPod4,1 6.1.6 kernel, not written from
/// specification alone.
enum ARMDecoder {
    static func decode(_ word: UInt32) -> ARMInstruction {
        let condBits = word.bitField(31, 28)
        guard condBits != 0b1111 else {
            // Not "never execute" — ARMv6+ repurposes this as a whole
            // separate "unconditional instruction extension" space
            // (CPS, barriers, PLD/PLI, SETEND, BLX-immediate, ...),
            // always executed regardless of flags. Conflating it with
            // the reserved NV condition would make CPS/barrier
            // instructions (which real boot code uses almost
            // immediately) look "undefined" instead of "not decoded
            // yet" — a materially different, less honest status.
            return decodeUnconditionalSpace(word)
        }
        let condition = ARMCondition(rawBits: condBits)

        switch word.bitField(27, 26) {
        case 0b00:
            return decodeDataProcessingBlock(word, condition: condition)
        case 0b01:
            return decodeLoadStoreBlock(word, condition: condition)
        case 0b10:
            return decodeBranchOrBlockTransfer(word, condition: condition)
        default:
            return decodeCoprocessorBlock(word, condition: condition)
        }
    }

    private static func decodeDataProcessingBlock(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        // MOVW/MOVT (ARMv6T2+) share the data-processing block but are a
        // structurally different instruction — a 16-bit immediate with
        // no rotation, no Rn, no shifter carry-out — so they're checked
        // before falling through to the classic opcode/operand2 logic
        // that would otherwise misread their imm4/imm12 fields as an
        // opcode and shift amount.
        if word.bitField(27, 20) == 0b0011_0000 || word.bitField(27, 20) == 0b0011_0100 {
            let imm16 = UInt16((word.bitField(19, 16) << 12) | word.bitField(11, 0))
            return .movWide(MovWideInstruction(
                condition: condition,
                isTop: word.bit(22),
                rd: Int(word.bitField(15, 12)),
                imm16: imm16
            ))
        }

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
        let offset: LoadStoreOffset
        if word.bit(25) {
            // Register offset — the *opposite* convention from data-
            // processing's I bit, but the same bits[11:4] shift encoding.
            // bit4==1 here is the same "register-specified shift amount"
            // form data-processing doesn't decode either, for the same
            // reason: it isn't safe to reinterpret Rs as a shift-immediate.
            if word.bit(4) {
                return .unsupported(rawWord: word)
            }
            guard let shiftType = ShiftType(rawValue: UInt8(word.bitField(6, 5))) else {
                return .unsupported(rawWord: word)
            }
            offset = .register(
                rm: Int(word.bitField(3, 0)),
                shiftType: shiftType,
                shiftAmount: UInt8(word.bitField(11, 7))
            )
        } else {
            offset = .immediate(word.bitField(11, 0))
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
            offset: offset
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

    /// `MCR`/`MRC` (coprocessor register transfer) — the one coprocessor
    /// instruction shape decoded so far. Identified by bits[27:24]==1110
    /// and bit4==1 (the same "1" that also distinguishes MCR/MRC from
    /// CDP within this space); everything else in the coprocessor block
    /// (CDP, LDC/STC, MCRR/MRRC) stays `.unsupported`.
    private static func decodeCoprocessorBlock(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        guard word.bitField(27, 24) == 0b1110, word.bit(4) else {
            return .unsupported(rawWord: word)
        }

        return .coprocessorRegisterTransfer(CoprocessorRegisterTransferInstruction(
            condition: condition,
            isLoad: word.bit(20),
            coprocessor: Int(word.bitField(11, 8)),
            opc1: Int(word.bitField(23, 21)),
            rt: Int(word.bitField(15, 12)),
            crn: Int(word.bitField(19, 16)),
            crm: Int(word.bitField(3, 0)),
            opc2: Int(word.bitField(7, 5))
        ))
    }

    /// The `cond == 1111` "unconditional instruction extension" space.
    /// Only `CPS` and the `DSB`/`DMB`/`ISB` barriers are recognized;
    /// everything else there (PLD/PLI, SETEND, BLX-immediate, ...)
    /// decodes to `.unsupported`.
    private static func decodeUnconditionalSpace(_ word: UInt32) -> ARMInstruction {
        // CPS: bits[27:20] == 0b0001_0000 (fixed).
        if word.bitField(27, 20) == 0b0001_0000 {
            let imod = word.bitField(19, 18)
            // imod == 0b10/0b11 select enable/disable; 0b00/0b01 are
            // reserved for a form (changing mode without touching masks)
            // this CPU doesn't model.
            guard imod == 0b10 || imod == 0b11 else {
                return .unsupported(rawWord: word)
            }
            return .changeProcessorState(ChangeProcessorStateInstruction(
                enable: imod == 0b10,
                affectsAbort: word.bit(8),
                affectsIRQ: word.bit(7),
                affectsFIQ: word.bit(6)
            ))
        }

        // DSB/DMB/ISB: bits[27:8] fixed at 0x57FF0, with bits[7:4]
        // selecting which barrier (0100/0101/0110) — a distinction this
        // CPU doesn't need since all three are no-ops for a strictly-
        // in-order interpreter with no cache model. bits[3:0] (the
        // "option", typically 0b1111 = SY) aren't checked at all.
        if word.bitField(27, 8) == 0x5_7FF0 {
            let barrierKind = word.bitField(7, 4)
            guard (0b0100...0b0110).contains(barrierKind) else {
                return .unsupported(rawWord: word)
            }
            return .memoryBarrier
        }

        return .unsupported(rawWord: word)
    }
}
