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
/// load/store" instructions (`LDRH`/`STRH`/`LDRSB`/`LDRSH`) and their
/// `LDRD`/`STRD` sibling sharing that same space (see
/// `LoadStoreDualInstruction`'s doc comment for the L-bit quirk that
/// distinguishes them), `LDREX`/`STREX`/`CLREX`, the multiply family
/// (`MUL`/`MLA`/`MLS`/`UMULL`/`UMLAL`/`SMULL`/`SMLAL`/`UMAAL`), block data transfer
/// (`LDM`/`STM`, ordinary form only), `MRS`/`MSR` (CPSR only), `MCR`/
/// `MRC`, `CPS`, `PLD` (immediate), `CLZ`, `UQSUB8`/`REV`/`BFI`/`BFC`/
/// `UBFX` (decoded from ARMv6's much larger "media instructions" space
/// — see `decodeMediaInstructions`'s doc comment), and the `DSB`/`DMB`/
/// `ISB` barriers. Everything else — the `S`-bit block-transfer form, the rest of the media-instructions
/// space (including `REV`'s own `REV16`/`REVSH` siblings), SPSR access,
/// most of the coprocessor and unconditional-instruction-extension
/// spaces, SWI — decodes to `.unsupported` rather than being
/// misinterpreted. Every case added here so far was verified against
/// real, disassembled instruction words from the actual iPod4,1 6.1.6
/// kernel, not written from specification alone.
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
        // BX Rm / BLX Rm: bits[27:4] are a fixed pattern (0x12FFF1 for
        // BX, 0x12FFF3 for BLX — see BranchExchangeInstruction's doc
        // comment) that would otherwise misdecode as a malformed MSR
        // (op TEQ, bit21 set) — its own guard already rejects that
        // shape as `.unsupported` rather than misinterpreting it, but
        // checking for these real, fixed encodings explicitly here
        // decodes them correctly instead.
        if word.bitField(27, 4) == 0x12_FFF1 || word.bitField(27, 4) == 0x12_FFF3 {
            return .branchExchange(BranchExchangeInstruction(
                condition: condition, link: word.bitField(27, 4) == 0x12_FFF3, rm: Int(word.bitField(3, 0))
            ))
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
                // Synchronization primitives (SWP/LDREX/STREX family) —
                // only LDREX's and STREX's exact bit patterns are
                // decoded so far, not the rest (SWP, LDREXB/H/D, etc).
                if word.bitField(27, 20) == 0b0001_1001, word.bitField(11, 8) == 0b1111, word.bitField(3, 0) == 0b1111 {
                    return .loadExclusive(LoadExclusiveInstruction(
                        condition: condition, rt: Int(word.bitField(15, 12)), rn: Int(word.bitField(19, 16))
                    ))
                }
                if word.bitField(27, 20) == 0b0001_1011, word.bitField(11, 8) == 0b1111, word.bitField(3, 0) == 0b1111 {
                    return .loadExclusiveDouble(LoadExclusiveDoubleInstruction(
                        condition: condition, rt: Int(word.bitField(15, 12)), rn: Int(word.bitField(19, 16))
                    ))
                }
                if word.bitField(27, 20) == 0b0001_1000, word.bitField(11, 4) == 0b1111_1001 {
                    return .storeExclusive(StoreExclusiveInstruction(
                        condition: condition, rd: Int(word.bitField(15, 12)),
                        rt: Int(word.bitField(3, 0)), rn: Int(word.bitField(19, 16))
                    ))
                }
                if word.bitField(27, 20) == 0b0001_1010, word.bitField(11, 4) == 0b1111_1001 {
                    return .storeExclusiveDouble(StoreExclusiveDoubleInstruction(
                        condition: condition, rd: Int(word.bitField(15, 12)),
                        rt: Int(word.bitField(3, 0)), rn: Int(word.bitField(19, 16))
                    ))
                }
                if word.bitField(27, 24) == 0, word.bitField(7, 4) == 0b1001 {
                    // See MultiplyInstruction's doc comment.
                    let op = word.bitField(23, 20)
                    let kind: MultiplyInstruction.Kind
                    switch op {
                    case 0b0000, 0b0001: kind = .mul
                    case 0b0010, 0b0011: kind = .mla
                    case 0b0100: kind = .umaal
                    case 0b0110: kind = .mls
                    case 0b1000, 0b1001: kind = .umull
                    case 0b1010, 0b1011: kind = .umlal
                    case 0b1100, 0b1101: kind = .smull
                    case 0b1110, 0b1111: kind = .smlal
                    default: return .undefined(rawWord: word)
                    }
                    return .multiply(MultiplyInstruction(
                        condition: condition, kind: kind, setFlags: op & 1 == 1 && kind != .umaal,
                        rd: Int(word.bitField(19, 16)), ra: Int(word.bitField(15, 12)),
                        rm: Int(word.bitField(3, 0)), rs: Int(word.bitField(11, 8))
                    ))
                }
                return .unsupported(rawWord: word)
            }
            let isLoad = word.bit(20)

            let offset: HalfwordTransferOffset
            if word.bit(22) {
                offset = .immediate((word.bitField(11, 8) << 4) | word.bitField(3, 0))
            } else {
                guard word.bitField(11, 8) == 0 else { return .unsupported(rawWord: word) }
                offset = .register(Int(word.bitField(3, 0)))
            }

            if !isLoad, sh == 0b10 || sh == 0b11 {
                // LDRD (sh==10) / STRD (sh==11) — see
                // LoadStoreDualInstruction's doc comment on this L-bit
                // quirk.
                return .loadStoreDual(LoadStoreDualInstruction(
                    condition: condition,
                    isLoad: sh == 0b10,
                    preIndexed: word.bit(24), addOffset: word.bit(23), writeback: word.bit(21),
                    rn: Int(word.bitField(19, 16)), rt: Int(word.bitField(15, 12)), offset: offset
                ))
            }

            let kind: HalfwordTransferKind = sh == 0b01 ? .unsignedHalfword : (sh == 0b10 ? .signedByte : .signedHalfword)
            guard isLoad || kind == .unsignedHalfword else {
                // STRSB/STRSH don't exist — SH==10/11 with L==0 is
                // handled as LDRD/STRD above; any other reserved
                // combination isn't silently treated as an ordinary
                // halfword store.
                return .unsupported(rawWord: word)
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
            // CLZ (fixed bits[27:20]==0x16, [19:16]==[11:4]=="all 1s"
            // except the low nibble of [11:4], which is 0001) shares
            // this same "op is a comparison with S==0" shape but is a
            // completely different instruction — confirmed against a
            // real word from the actual kernel via Capstone. Checked
            // before the MRS/MSR logic below, which would otherwise
            // treat this word as an (incorrectly) refused SPSR access.
            if word.bitField(27, 20) == 0x16, word.bitField(19, 16) == 0b1111, word.bitField(11, 4) == 0b1111_0001 {
                return .clz(ClzInstruction(condition: condition, rd: rd, rm: Int(word.bitField(3, 0))))
            }

            // TST/TEQ/CMP/CMN with S==0 isn't that comparison — this
            // encoding (bits[24:23]=="10", true for all four of those
            // opcodes) is where MRS/MSR (status register access) live.
            // bit22 (R) selects CPSR/SPSR; bit21 selects MRS/MSR within
            // that — both confirmed against real instruction words from
            // the actual iPod4,1 6.1.6 kernel ("mrs r11, apsr" and
            // "msr CPSR_x, r11"), and the SPSR (R==1) form against a real
            // word from that same kernel's Data Abort handler prologue
            // ("mrs sp, spsr").
            let isSPSR = word.bit(22)

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
                return .moveToStatusRegister(MSRInstruction(condition: condition, isSPSR: isSPSR, fieldMask: fieldMask, source: source))
            } else {
                guard !immediateOperand, word.bitField(19, 16) == 0b1111, word.bitField(11, 0) == 0 else {
                    return .unsupported(rawWord: word)
                }
                return .moveFromStatusRegister(MRSInstruction(condition: condition, isSPSR: isSPSR, rd: rd))
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
            // processing's I bit, but the same bits[11:4] shift encoding
            // *when bit4==0*. bit4==1 here doesn't mean a register-
            // specified shift amount at all (load/store's register
            // offset has no such form) — it means this word isn't a
            // load/store instruction, it's ARMv6's separate "media
            // instructions" extension space (confirmed against a real
            // `uqsub8` word from the actual kernel via Capstone, since
            // this space's encoding table isn't one this codebase had
            // reasoned through carefully before).
            if word.bit(4) {
                return decodeMediaInstructions(word, condition: condition)
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

    /// ARMv6's "media instructions" space (bits[27:25]==011, bit4==1).
    /// `UQSUB8`, `REV`, `BFI`/`BFC`, and `UBFX` are decoded — see their
    /// doc comments — via bits[27:20] == 0b01100110 (parallel add/sub,
    /// unsigned, saturating) with bits[7:5] == 0b111 (the SUB8 op2) for
    /// `UQSUB8`, bits[27:20] == 0b01101011 with bits[7:4] == 0b0011 for
    /// `REV`, bits[27:21] == 0b0111110 for `BFI`/`BFC`, or bits[27:21]
    /// == 0b0111111 with bits[6:4] == 0b101 for `UBFX`; everything else
    /// in this large space is `.unsupported`.
    private static func decodeMediaInstructions(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        if word.bitField(27, 20) == 0b0110_0110, word.bitField(7, 5) == 0b111, word.bitField(11, 8) == 0b1111 {
            return .uqsub8(UQSub8Instruction(
                condition: condition, rd: Int(word.bitField(15, 12)), rn: Int(word.bitField(19, 16)), rm: Int(word.bitField(3, 0))
            ))
        }
        if word.bitField(27, 20) == 0b0110_1011, word.bitField(11, 8) == 0b1111, word.bitField(7, 4) == 0b0011,
           word.bitField(19, 16) == 0b1111 {
            return .rev(RevInstruction(condition: condition, rd: Int(word.bitField(15, 12)), rm: Int(word.bitField(3, 0))))
        }
        if word.bitField(27, 21) == 0b0111110 {
            // BFI/BFC: verified against a real `bfi r0, r2, #0x10, #4`
            // word from the actual kernel (see `BitFieldInsertInstruction`'s
            // doc comment).
            let msb = word.bitField(20, 16)
            let lsb = word.bitField(11, 7)
            guard msb >= lsb else {
                return .unsupported(rawWord: word)
            }
            let rn = word.bitField(3, 0)
            return .bitFieldInsert(BitFieldInsertInstruction(
                condition: condition,
                rd: Int(word.bitField(15, 12)),
                sourceRegister: rn == 0b1111 ? nil : Int(rn),
                lsb: Int(lsb),
                width: Int(msb - lsb + 1)
            ))
        }
        if word.bitField(27, 21) == 0b0111111, word.bitField(6, 4) == 0b101 {
            // UBFX (ARM state): verified against a real `ubfx r3, r0,
            // #3, #0xa` word from the actual kernel (see
            // `BitFieldExtractInstruction`'s doc comment).
            let widthMinus1 = word.bitField(20, 16)
            return .bitFieldExtract(BitFieldExtractInstruction(
                condition: condition,
                rd: Int(word.bitField(15, 12)),
                rn: Int(word.bitField(3, 0)),
                lsb: Int(word.bitField(11, 7)),
                width: Int(widthMinus1 + 1)
            ))
        }
        return .unsupported(rawWord: word)
    }

    /// `MCR`/`MRC` (coprocessor register transfer) — the one coprocessor
    /// instruction shape decoded so far. Identified by bits[27:24]==1110
    /// and bit4==1 (the same "1" that also distinguishes MCR/MRC from
    /// CDP within this space); everything else in the coprocessor block
    /// (CDP, LDC/STC, MCRR/MRRC) stays `.unsupported`.
    private static func decodeCoprocessorBlock(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        // VSTM/VLDM/VPUSH/VPOP (double-precision extension registers):
        // bits[27:25]==110 (fixed for this "extension register load/
        // store" family, distinguishing it from MCR/MRC's bits[27:24]==
        // 1110 below), bits[11:8]==0b1011 selects double-precision width
        // (vs. 0b1010 for single, not decoded). W (bit21) distinguishes
        // this "multiple" form from VSTR/VLDR's single-register form
        // (which always has W==0) — see
        // `ExtensionRegisterLoadStoreMultipleInstruction`'s doc comment.
        if word.bitField(27, 25) == 0b110, word.bitField(11, 8) == 0b1011, word.bit(21) {
            let p = word.bit(24)
            let u = word.bit(23)
            guard p != u else {
                // P==U (both increment-after-without-writeback-shape or
                // both decrement-before-without-U) isn't a valid VSTM/
                // VLDM addressing mode.
                return .unsupported(rawWord: word)
            }
            let d = word.bit(22) ? 1 << 4 : 0
            return .extensionRegisterLoadStoreMultiple(ExtensionRegisterLoadStoreMultipleInstruction(
                condition: condition,
                isLoad: word.bit(20),
                addOffset: u,
                rn: Int(word.bitField(19, 16)),
                firstRegister: d | Int(word.bitField(15, 12)),
                registerCount: Int(word.bitField(7, 0)) / 2
            ))
        }

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

        // CPS: bits[27:20] == 0b0001_0000 (fixed). bit17 (mmod/M) and
        // bits[4:0] (mode) carry an independent mode change that applies
        // regardless of imod — confirmed against a real word from the
        // actual kernel's Data Abort handler setup ("cpsid if, #0x17",
        // entering Abort mode with IRQ/FIQ masked in one instruction).
        // imod==0b00 with mmod set is real boot code's per-mode-stack-setup
        // idiom (`CPS #<mode>`, no IE/ID prefix — mode change only, no mask
        // change); only mmod==0 with imod==0b00/0b01 is genuinely
        // UNPREDICTABLE (asks for neither a mask change nor a mode change).
        if word.bitField(27, 20) == 0b0001_0000 {
            let imod = word.bitField(19, 18)
            let mmod = word.bit(17)
            guard imod == 0b10 || imod == 0b11 || mmod else {
                return .unsupported(rawWord: word)
            }
            return .changeProcessorState(ChangeProcessorStateInstruction(
                enable: imod == 0b10,
                affectsAbort: word.bit(8),
                affectsIRQ: word.bit(7),
                affectsFIQ: word.bit(6),
                changesMode: mmod,
                mode: word.bitField(4, 0)
            ))
        }

        // DSB/DMB/ISB: bits[27:8] fixed at 0x57FF0, with bits[7:4]
        // selecting which barrier (0100/0101/0110) — a distinction this
        // CPU doesn't need since all three are no-ops for a strictly-
        // in-order interpreter with no cache model. bits[3:0] (the
        // "option", typically 0b1111 = SY) aren't checked at all.
        if word.bitField(27, 8) == 0x5_7FF0 {
            let barrierKind = word.bitField(7, 4)
            if barrierKind == 0b0001, word.bitField(3, 0) == 0xF {
                return .clearExclusive
            }
            guard (0b0100...0b0110).contains(barrierKind) else {
                return .unsupported(rawWord: word)
            }
            return .memoryBarrier
        }

        // VRSHL (NEON "three registers of the same length" family,
        // bits[31:25]==0b1111001, opc bits[11:8]==0b0101): field layout
        // (U/D/size/Vn/Vd/N/Q/M/Vm, and which disassembly operand each
        // maps to) empirically confirmed by varying each field one at a
        // time through Capstone against the real halting word
        // (0xF3450500 = "vrshl.u8 d16, d0, d5"), not read off a manual
        // table from memory. Only opc==0b0101 (VRSHL) and Q==0 (D-register
        // width) are decoded; every other opcode/width in this same shape
        // stays `.unsupported` until a real word confirms one is needed.
        // VLD1/VST1 (multiple single elements): bits[27:23]==0b01000 and
        // bit20==0 (fixed for this "Advanced SIMD element or structure
        // load/store" sub-family), bit21 selects load(1)/store(0). See
        // `ElementLoadStoreInstruction`'s doc comment — verified against
        // a real `vld1.32 {d30,d31}, [r3:0x80]!` word from the actual
        // kernel.
        if word.bitField(27, 23) == 0b01000, !word.bit(20) {
            let registerCount: Int
            switch word.bitField(11, 8) {
            case 0b0111: registerCount = 1
            case 0b1010: registerCount = 2
            case 0b0110: registerCount = 3
            case 0b0010: registerCount = 4
            default: return .unsupported(rawWord: word)
            }
            let rm = word.bitField(3, 0)
            let writeback: ElementLoadStoreInstruction.Writeback
            switch rm {
            case 0b1111: writeback = .none
            case 0b1101: writeback = .byTransferSize
            default: writeback = .register(Int(rm))
            }
            let d = word.bit(22) ? 1 << 4 : 0
            return .elementLoadStore(ElementLoadStoreInstruction(
                isLoad: word.bit(21),
                rn: Int(word.bitField(19, 16)),
                firstRegister: d | Int(word.bitField(15, 12)),
                registerCount: registerCount,
                writeback: writeback
            ))
        }

        // VREV16/VREV32/VREV64: "two registers, miscellaneous" NEON
        // space — bits[31:23]==0b111100111 (fixed prefix), bits[21:20]==
        // 0b11 (fixed), bits[17:16]==0b00 (selects the VREV op-group
        // specifically, as opposed to this space's many other opcodes —
        // everything else in "two registers, miscellaneous" stays
        // `.unsupported`), bits[11:9]==0b000 and bit4==0 (also fixed for
        // this op-group). See `VREVInstruction`'s doc comment — verified
        // against a real `vrev32.8 q4, q12` word from the actual kernel.
        if word.bitField(31, 23) == 0b1_1110_0111, word.bitField(21, 20) == 0b11, word.bitField(17, 16) == 0b00,
           word.bitField(11, 9) == 0b000, !word.bit(4) {
            guard let groupSize = VREVInstruction.GroupSize(rawValue: UInt8(word.bitField(8, 7))) else {
                return .unsupported(rawWord: word)
            }
            let sizeField = word.bitField(19, 18)
            guard sizeField != 0b11 else {
                return .unsupported(rawWord: word)
            }
            let isQuad = word.bit(6)
            let dField = Int((word.bit(22) ? 1 << 4 : 0) | word.bitField(15, 12))
            let mField = Int((word.bit(5) ? 1 << 4 : 0) | word.bitField(3, 0))
            return .reverseElements(VREVInstruction(
                groupSize: groupSize,
                elementBits: 8 << Int(sizeField),
                vd: isQuad ? dField >> 1 : dField,
                vm: isQuad ? mField >> 1 : mField,
                isQuad: isQuad
            ))
        }

        if word.bitField(31, 25) == 0b1111_001, !word.bit(23), word.bitField(11, 8) == 0b0101, !word.bit(6) {
            guard let size = VRSHLInstruction.ElementSize(rawValue: UInt8(word.bitField(21, 20))) else {
                return .unsupported(rawWord: word)
            }
            let vd = Int((word.bit(22) ? 1 << 4 : 0) | word.bitField(15, 12))
            let vm = Int((word.bit(5) ? 1 << 4 : 0) | word.bitField(3, 0))
            let vn = Int((word.bit(7) ? 1 << 4 : 0) | word.bitField(19, 16))
            return .vectorRoundingShiftLeft(VRSHLInstruction(unsigned: word.bit(24), size: size, vd: vd, vm: vm, vn: vn))
        }

        // VEOR/VORR: same "three registers of the same length" outer
        // shape as VRSHL above, but from the "bitwise operations" sub-
        // space (opc==0b0001) — see VEORInstruction's/VORRInstruction's
        // doc comments. Q (bit6) selects 128-bit width, in which case the
        // raw 5-bit D-style register fields address Q registers (D-pair
        // index >> 1). U(bit24)+size(bits[21:20]) select which sibling:
        // only VEOR (U=1,size=00) and VORR (U=0,size=10) are decoded so
        // far, not VAND/VBIC/VORN/VBSL/VBIT/VBIF. bit23==0 (empirically
        // confirmed fixed for the whole "three registers of the same
        // length" family — every real word seen so far, VRSHL/VEOR/VADD
        // alike, has it clear) disambiguates this from VEXT/the shift-
        // immediate family below, which both fix that same bit at 1 —
        // without this check, a real `vext.64 ...` word (imm4==0b1000)
        // would misdecode as VADD, since imm4 and VADD's opc share the
        // same bit position and can coincide.
        if word.bitField(31, 25) == 0b1111_001, !word.bit(23), word.bitField(11, 8) == 0b0001 {
            let isQuad = word.bit(6)
            let dField = Int((word.bit(22) ? 1 << 4 : 0) | word.bitField(15, 12))
            let nField = Int((word.bit(7) ? 1 << 4 : 0) | word.bitField(19, 16))
            let mField = Int((word.bit(5) ? 1 << 4 : 0) | word.bitField(3, 0))
            let vd = isQuad ? dField >> 1 : dField
            let vn = isQuad ? nField >> 1 : nField
            let vm = isQuad ? mField >> 1 : mField
            if word.bit(24), word.bitField(21, 20) == 0b00 {
                return .bitwiseExclusiveOr(VEORInstruction(vd: vd, vn: vn, vm: vm, isQuad: isQuad))
            }
            if !word.bit(24), word.bitField(21, 20) == 0b10 {
                return .bitwiseOr(VORRInstruction(vd: vd, vn: vn, vm: vm, isQuad: isQuad))
            }
            return .unsupported(rawWord: word)
        }

        // VADD.I<size>: same "three registers of the same length" outer
        // shape, opc(bits[11:8])==0b1000 with U(bit24)==0 selects integer
        // add (U==1 would be VSUB, not decoded) — see VADDInstruction's
        // doc comment. Unlike VRSHL/VEOR/VORR above, Q (128-bit) width is
        // supported here since the real halting word needs it. bit23==0
        // required — see the VEOR/VORR comment above on why (this is the
        // exact collision that motivated adding the check).
        if word.bitField(31, 25) == 0b1111_001, !word.bit(23), word.bitField(11, 8) == 0b1000, !word.bit(24) {
            guard let size = VADDInstruction.ElementSize(rawValue: UInt8(word.bitField(21, 20))) else {
                return .unsupported(rawWord: word)
            }
            let isQuad = word.bit(6)
            let dField = Int((word.bit(22) ? 1 << 4 : 0) | word.bitField(15, 12))
            let nField = Int((word.bit(7) ? 1 << 4 : 0) | word.bitField(19, 16))
            let mField = Int((word.bit(5) ? 1 << 4 : 0) | word.bitField(3, 0))
            return .integerAdd(VADDInstruction(
                size: size,
                vd: isQuad ? dField >> 1 : dField,
                vn: isQuad ? nField >> 1 : nField,
                vm: isQuad ? mField >> 1 : mField,
                isQuad: isQuad
            ))
        }

        // VEXT: bits[31:24]==0b11110010 (fixed prefix, distinct from the
        // "three registers of the same length" family above), bit23==1
        // and bits[21:20]==0b11 (also fixed), bit4==0 disambiguates it
        // from the "two registers and a shift amount" family below (which
        // fixes that same bit at 1) even though both share this same
        // bits[31:24]/bit23 prefix. See VEXTInstruction's doc comment.
        if word.bitField(31, 24) == 0b1111_0010, word.bit(23), word.bitField(21, 20) == 0b11, !word.bit(4) {
            let isQuad = word.bit(6)
            let dField = Int((word.bit(22) ? 1 << 4 : 0) | word.bitField(15, 12))
            let nField = Int((word.bit(7) ? 1 << 4 : 0) | word.bitField(19, 16))
            let mField = Int((word.bit(5) ? 1 << 4 : 0) | word.bitField(3, 0))
            return .vectorExtract(VEXTInstruction(
                vd: isQuad ? dField >> 1 : dField,
                vn: isQuad ? nField >> 1 : nField,
                vm: isQuad ? mField >> 1 : mField,
                isQuad: isQuad,
                byteOffset: Int(word.bitField(11, 8))
            ))
        }

        // VSHL/VSHR (immediate): "two registers and a shift amount" NEON
        // space — bits[31:25]==0b1111001, bit23==1, bit4==1 (fixed; see
        // VEXT's doc comment on the bit4 disambiguation). See
        // VectorShiftImmediateInstruction's doc comment for the opc/imm6
        // decoding.
        if word.bitField(31, 25) == 0b1111_001, word.bit(23), word.bit(4) {
            let opc = word.bitField(11, 8)
            let unsigned = word.bit(24)
            let direction: VectorShiftImmediateInstruction.Direction
            if opc == 0b0101, !unsigned {
                direction = .left
            } else if opc == 0b0000 {
                direction = .right
            } else {
                return .unsupported(rawWord: word)
            }
            let imm6 = Int(word.bitField(21, 16))
            let elementBits: Int
            if imm6 & 0b10_0000 != 0 {
                elementBits = 32
            } else if imm6 & 0b01_0000 != 0 {
                elementBits = 16
            } else if imm6 & 0b00_1000 != 0 {
                elementBits = 8
            } else {
                // size==64 (the L-bit encoding) isn't decoded yet.
                return .unsupported(rawWord: word)
            }
            let shiftAmount = direction == .left ? imm6 - elementBits : 2 * elementBits - imm6
            let isQuad = word.bit(6)
            let dField = Int((word.bit(22) ? 1 << 4 : 0) | word.bitField(15, 12))
            let mField = Int((word.bit(5) ? 1 << 4 : 0) | word.bitField(3, 0))
            return .vectorShiftImmediate(VectorShiftImmediateInstruction(
                direction: direction,
                unsigned: unsigned,
                elementBits: elementBits,
                shiftAmount: shiftAmount,
                vd: isQuad ? dField >> 1 : dField,
                vm: isQuad ? mField >> 1 : mField,
                isQuad: isQuad
            ))
        }

        return .unsupported(rawWord: word)
    }
}
