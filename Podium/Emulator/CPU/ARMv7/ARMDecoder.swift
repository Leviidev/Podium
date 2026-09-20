import Foundation

/// Decodes a 32-bit ARM (not Thumb) instruction word into an
/// `ARMInstruction`. Pure and stateless — decoding never touches
/// register or memory state, only the instruction word itself, which is
/// what makes it independently unit-testable and, eventually, reusable
/// by a JIT front end without dragging CPU state along.
///
/// Covers data-processing (all three operand2 forms, including
/// register-shifted-by-register — `.shiftedRegisterByRegister`, resolved
/// at execute time since the shift amount is a runtime register value),
/// `MOVW`/`MOVT`, branch (B/BL), `BX`, `BLX` (immediate — a real,
/// executable interworking branch to Thumb now that
/// `ARMv7CPU+Thumb.swift` exists), single-register load/store
/// (immediate *and* register offset), the halfword/signed-byte "extra
/// load/store" instructions (`LDRH`/`STRH`/`LDRSB`/`LDRSH`), block data
/// transfer (`LDM`/`STM`, ordinary form only), `MRS`/`MSR` (CPSR only),
/// `MCR`/`MRC`, `CPS`, `PLD` (immediate), and the `DSB`/`DMB`/`ISB`
/// barriers. Everything else — multiply, the `S`-bit block-transfer
/// form, register-shifted-by-register *addressing* (load/store's own
/// register-offset form still only decodes an immediate shift amount,
/// unlike data-processing's operand2), SPSR access, most of the
/// coprocessor and unconditional-instruction-extension spaces, SWI —
/// decodes to `.unsupported` rather than being misinterpreted. Every
/// case added here so far was verified against real, disassembled
/// instruction words from the actual iPod4,1 6.1.6 kernel, not written
/// from specification alone.
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
        // BX Rm: bits[27:4] are a fixed pattern (0x12FFF1) that would
        // otherwise misdecode as a malformed MSR (op TEQ, bit21 set) —
        // its own guard already rejects that shape as `.unsupported`
        // rather than misinterpreting it, but checking for the real,
        // fixed BX encoding explicitly here decodes it correctly instead.
        if word.bitField(27, 4) == 0x12_FFF1 {
            return .branchExchange(BranchExchangeInstruction(condition: condition, rm: Int(word.bitField(3, 0))))
        }

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
            // bits[7]==1 && bits[4]==1 with I(bit25)==0 signals the
            // multiply / extra-load-store space, not a shifted-register
            // operand2. bits[6:5] (SH) further distinguishes: 00 is the
            // multiply/SWP space (still unsupported), and 01/10/11 are
            // the halfword/signed-byte "extra load/store" instructions —
            // confirmed against a real word from the actual kernel
            // ("strh r1, [r0, #2]" at 0x8007d3e4).
            let sh = word.bitField(6, 5)
            guard sh != 0 else {
                return .unsupported(rawWord: word)
            }
            let isLoad = word.bit(20)
            let kind: HalfwordTransferKind = sh == 0b01 ? .unsignedHalfword : (sh == 0b10 ? .signedByte : .signedHalfword)
            guard isLoad || kind == .unsignedHalfword else {
                // STRSB/STRSH don't exist — SH==10/11 with L==0 is a
                // reserved/undefined encoding, not silently treated as
                // an ordinary halfword store.
                return .unsupported(rawWord: word)
            }

            let offset: HalfwordTransferOffset
            if word.bit(22) {
                offset = .immediate((word.bitField(11, 8) << 4) | word.bitField(3, 0))
            } else {
                guard word.bitField(11, 8) == 0 else { return .unsupported(rawWord: word) }
                offset = .register(Int(word.bitField(3, 0)))
            }

            return .halfwordDataTransfer(HalfwordDataTransferInstruction(
                condition: condition,
                isLoad: isLoad,
                kind: kind,
                preIndexed: word.bit(24),
                addOffset: word.bit(23),
                writeback: word.bit(21),
                rn: Int(word.bitField(19, 16)),
                rd: Int(word.bitField(15, 12)),
                offset: offset
            ))
        }

        guard let op = DataProcessingOp(rawValue: UInt8(word.bitField(24, 21))) else {
            return .undefined(rawWord: word)
        }

        let setFlags = word.bit(20)
        let rn = Int(word.bitField(19, 16))
        let rd = Int(word.bitField(15, 12))

        if !setFlags && op.isComparison {
            // TST/TEQ/CMP/CMN with S==0 isn't that comparison — this
            // encoding (bits[24:23]=="10", true for all four of those
            // opcodes) is where MRS/MSR (status register access) live.
            // bit22 (R) selects CPSR/SPSR; bit21 selects MRS/MSR within
            // that — both confirmed against real instruction words from
            // the actual iPod4,1 6.1.6 kernel ("mrs r11, apsr" and
            // "msr CPSR_x, r11").
            guard !word.bit(22) else {
                return .unsupported(rawWord: word) // SPSR access — not modeled.
            }

            if word.bit(21) {
                let fieldMask = UInt8(word.bitField(19, 16))
                let source: MSRSource
                if immediateOperand {
                    let rotateAmount = word.bitField(11, 8) * 2
                    let imm8 = word.bitField(7, 0)
                    source = .immediate(ShifterOperand.rotateRight(imm8, by: rotateAmount))
                } else {
                    guard word.bitField(11, 4) == 0 else { return .unsupported(rawWord: word) }
                    source = .register(Int(word.bitField(3, 0)))
                }
                return .moveToStatusRegister(MSRInstruction(condition: condition, fieldMask: fieldMask, source: source))
            } else {
                guard !immediateOperand, word.bitField(19, 16) == 0b1111, word.bitField(11, 0) == 0 else {
                    return .unsupported(rawWord: word)
                }
                return .moveFromStatusRegister(MRSInstruction(condition: condition, rd: rd))
            }
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
            // register-specified shift amount (1, the `Rs` form). The
            // multiply-space check above only ruled out bit4==1
            // *combined with* bit7==1, so bit4==1 with bit7==0 (a valid
            // Rs-shift data-processing instruction) still needs its own
            // handling here rather than falling through to have its Rs
            // field misread as a shift-immediate — confirmed against a
            // real word from the actual kernel ("orr r1, r1, r3, lsr r2").
            if word.bit(4) {
                guard !word.bit(7), let shiftType = ShiftType(rawValue: UInt8(word.bitField(6, 5))) else {
                    return .unsupported(rawWord: word)
                }
                operand2 = .shiftedRegisterByRegister(
                    rm: Int(word.bitField(3, 0)), shiftType: shiftType, rs: Int(word.bitField(11, 8))
                )
                return .dataProcessing(DataProcessingInstruction(
                    condition: condition, op: op, setFlags: setFlags, rn: rn, rd: rd, operand2: operand2
                ))
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
            // Block data transfer (LDM/STM). The `S` bit (bit22) selects
            // user-bank/exception-return semantics this CPU doesn't model
            // (see `BlockDataTransferInstruction`'s doc comment) — refused
            // rather than silently treated as the ordinary form.
            guard !word.bit(22) else {
                return .unsupported(rawWord: word)
            }
            return .blockDataTransfer(BlockDataTransferInstruction(
                condition: condition,
                isLoad: word.bit(20),
                preIndexed: word.bit(24),
                addOffset: word.bit(23),
                writeback: word.bit(21),
                rn: Int(word.bitField(19, 16)),
                registerList: UInt16(word.bitField(15, 0))
            ))
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
    /// `CPS`, the `DSB`/`DMB`/`ISB` barriers, `PLD` (immediate), and
    /// `BLX` (immediate) are recognized; everything else there (`PLI`,
    /// `PLD` register-offset, `SETEND`, ...) decodes to `.unsupported`.
    private static func decodeUnconditionalSpace(_ word: UInt32) -> ARMInstruction {
        // PLD (immediate): bits[27:24] == 0101, bit21 == 0, bit20 == 1,
        // bits[15:12] == 1111 (all fixed) — confirmed against a real
        // word from the actual kernel ("pld [r1, #32]" at 0x80089798).
        // A pure cache-prefetch hint: exactly like the DSB/DMB/ISB
        // barriers below, correctly implementing it *is* treating it as
        // a no-op, since this CPU has no cache model for it to hint to.
        if word.bitField(27, 24) == 0b0101, !word.bit(21), word.bit(20), word.bitField(15, 12) == 0b1111 {
            return .memoryBarrier
        }

        // BLX (immediate): bits[27:25] == 0b101 (fixed) — always an
        // unconditional switch to Thumb state, confirmed against a real
        // word from the actual kernel at 0x802b985c ("blx 0x802b8268",
        // a target that disassembles as garbage under ARM decoding,
        // confirming it's genuine Thumb code this CPU can't decode).
        if word.bitField(27, 25) == 0b101 {
            let h = word.bit(24)
            let imm24 = word.bitField(23, 0)
            let signExtended = Int32(bitPattern: imm24.bit(23) ? (imm24 | 0xFF00_0000) : imm24)
            let signedOffset = (signExtended << 2) | Int32(h ? 2 : 0)
            return .branchLinkExchangeImmediate(BranchLinkExchangeImmediateInstruction(signedOffset: signedOffset))
        }

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
