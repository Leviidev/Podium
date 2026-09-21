import Foundation

/// Decodes Thumb instructions — both the classic 16-bit Thumb-1 formats
/// and the 32-bit Thumb-2 extensions — the same way `ARMDecoder` decodes
/// ARM-state words: pure, stateless, and every case added here verified
/// against real, disassembled halfwords from the actual iPod4,1 6.1.6
/// kernel's Thumb-compiled code (confirmed present via a real `BLX` this
/// CPU used to be unable to follow — see `ARMv7CPU`'s doc comment).
///
/// Covers (16-bit): `LSL`/`LSR`/`ASR` by immediate (format 1),
/// `ADD`/`SUB` register or 3-bit immediate (format 2), immediate
/// `MOV`/`CMP`/`ADD`/`SUB` (format 3), the two-register ALU family
/// (format 4), hi-register `ADD`/`CMP`/`MOV` and `BX`/`BLX` (format 5),
/// register-offset `STR`/`STRH`/`STRB`/`LDRSB`/`LDR`/`LDRH`/`LDRB`/
/// `LDRSH` (formats 7 and 8, which share one contiguous 3-bit opcode
/// field and so are decoded together), word/byte load-store with a
/// 5-bit immediate (format 9), halfword load-store with a 5-bit
/// immediate (format 10), SP-relative (format
/// 11), `ADD Rd,PC/SP,#imm` (format 12), SP adjustment (format 13),
/// `PUSH`/`POP` (format 14), `LDMIA` (format 15 — the load form only;
/// `STMIA`, same top-level shape with the load bit clear, isn't
/// decoded since no real word has confirmed it), `SXTH`/`SXTB`/`UXTH`/
/// `UXTB`, conditional and unconditional branch (formats 16/18),
/// `CBZ`/`CBNZ`, and `IT`.
/// Covers (32-bit): `MOVW`/`MOVT`, `UBFX`, `ADDW`, `BFI`/`BFC`, and
/// `ADR` (`ADDW`'s `Rn==1111` alias; all sharing the same "data-
/// processing plain binary immediate" op field), the data-processing
/// modified-immediate family, the data-processing
/// shifted-register family (sharing the same op table), `BL`, `BLX`
/// (immediate), `B.W` (both the unconditional T4 form and the
/// conditional T3 form, which carries its own condition field the same
/// way 16-bit `Bcond` does), `LDR`/`STR`/
/// `LDRB`/`STRB` (immediate, T3 and T4, and register-offset), `LDRSB`
/// (immediate, T3 and T4), `LDM`/
/// `STM` (T2, both IA and DB), `TBB`/`TBH` (table branch), `LDRD`/
/// `STRD` (immediate), `UMULL`, `MLA`, `MUL`'s Thumb-2 wide form (the
/// `Ra==1111` alias of `MLA`'s own encoding), `UXTB.W` (the `0xFA`-prefixed
/// wide form of the 16-bit `UXTB` above, no-accumulate shape only —
/// see `decode32ExtendOrShift`'s doc comment), `LSL`/`LSR`/`ASR`/`ROR`
/// (Thumb-2 register-controlled-shift form, sharing that same `0xFA`
/// space), `CLZ` (Thumb-2 form, also sharing `0xFA` — a different
/// encoding from ARM state's own `CLZ`), `DSB`/`DMB`/`ISB` (Thumb-2
/// forms, real no-ops exactly like ARM state's own barriers), and
/// `MCR`/`MRC` (reusing ARM state's exact field layout — see
/// `decode32Coprocessor`'s doc comment).
/// Everything else — PC-relative `LDR` (format 6),
/// `REV`/`REV16`/`REVSH`, `MLS` (`MLA`'s
/// sibling), `SMULL`/`UMLAL`/`SMLAL`/`SDIV`/`UDIV` (`UMULL`'s
/// siblings), `LDREX`/`STREX` (Thumb-2 forms — `LDRD`/`STRD`'s
/// siblings in that same space), the rest of the "plain binary
/// immediate" op table (`SUBW`, its own `Rn==1111` `ADR` alias, `SSAT`/
/// `SBFX`/`USAT`), `SXTH.W`/`UXTH.W`/`SXTB.W` and the accumulate
/// (`UXTAB`/etc.) extend forms sharing `0xFA` with `UXTB.W`, the rest
/// of the coprocessor space (`CDP`/`LDC`/`STC`), SIMD/VFP — decodes to
/// `.unsupported`.
enum ThumbDecoder {
    /// Whether `firstHalfword` opens a 32-bit Thumb-2 instruction (in
    /// which case the caller must fetch a second halfword before
    /// calling `decode`) or is itself a complete 16-bit instruction.
    static func isThirtyTwoBitFirstHalfword(_ firstHalfword: UInt16) -> Bool {
        let top5 = firstHalfword >> 11
        return top5 == 0b11101 || top5 == 0b11110 || top5 == 0b11111
    }

    static func decode(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        if isThirtyTwoBitFirstHalfword(hw0) {
            return decode32(hw0, hw1)
        }
        return decode16(hw0)
    }

    // MARK: - 16-bit

    private static func decode16(_ hw0: UInt16) -> ThumbInstruction {
        let top5 = hw0.bitField16(15, 11)

        // Format 1: LSL/LSR/ASR Rd, Rm, #imm5. bits[15:13] == 000, with
        // op (bits[12:11]) != 11 — that combination is format 2
        // (ADD/SUB), not decoded here.
        if hw0.bitField16(15, 13) == 0b000, hw0.bitField16(12, 11) != 0b11 {
            let shiftType: ShiftType = hw0.bitField16(12, 11) == 0b00 ? .lsl : (hw0.bitField16(12, 11) == 0b01 ? .lsr : .asr)
            return .shiftImmediate(ThumbShiftImmediateInstruction(
                shiftType: shiftType, rd: Int(hw0.bitField16(2, 0)), rm: Int(hw0.bitField16(5, 3)),
                imm5: UInt8(hw0.bitField16(10, 6))
            ))
        }

        // Format 2: ADD/SUB Rd, Rn, Rm (register) or Rd, Rn, #imm3 —
        // bits[15:11] == 00011 (the marker format 1's guard above
        // steers around), bit[10] selects immediate vs register, bit[9]
        // selects SUB vs ADD. Verified against a real
        // `subs r4, r7, #4` word from the actual kernel.
        if hw0.bitField16(15, 11) == 0b00011 {
            let rd = Int(hw0.bitField16(2, 0))
            let rn = Int(hw0.bitField16(5, 3))
            let operand2: ThumbAddSubInstruction.Operand2 = hw0.bit16(10)
                ? .immediate(UInt32(hw0.bitField16(8, 6)))
                : .register(Int(hw0.bitField16(8, 6)))
            return .addSub(ThumbAddSubInstruction(isSub: hw0.bit16(9), rd: rd, rn: rn, operand2: operand2))
        }

        // Format 3: MOV/CMP/ADD/SUB Rd, #imm8.
        if hw0.bitField16(15, 13) == 0b001 {
            guard let op = ThumbImmediateInstruction.Op(rawValue: UInt8(hw0.bitField16(12, 11))) else {
                return .undefined(rawHalfword: hw0, secondHalfword: nil)
            }
            return .immediate(ThumbImmediateInstruction(
                op: op, rdn: Int(hw0.bitField16(10, 8)), imm8: UInt32(hw0.bitField16(7, 0))
            ))
        }

        // Format 4: two-register ALU ops.
        if hw0.bitField16(15, 10) == 0b010000 {
            let op = ThumbDataProcessingOp(rawValue: UInt8(hw0.bitField16(9, 6)))!
            return .alu(ThumbAluInstruction(op: op, rdn: Int(hw0.bitField16(2, 0)), rm: Int(hw0.bitField16(5, 3))))
        }

        // Format 5: hi-register ADD/CMP/MOV, and BX/BLX (register).
        if hw0.bitField16(15, 10) == 0b010001 {
            let opBits = hw0.bitField16(9, 8)
            let h1 = hw0.bit16(7)
            let rm = Int(hw0.bitField16(6, 3))
            if opBits == 0b11 {
                return .branchExchange(ThumbBranchExchangeInstruction(rm: rm, link: h1))
            }
            guard let op = ThumbHiRegisterInstruction.Op(rawValue: UInt8(opBits)) else {
                return .undefined(rawHalfword: hw0, secondHalfword: nil)
            }
            let rdn = (h1 ? 8 : 0) + Int(hw0.bitField16(2, 0))
            return .hiRegister(ThumbHiRegisterInstruction(op: op, rdn: rdn, rm: rm))
        }

        // Formats 7/8: register-offset STR/STRH/STRB/LDRSB/LDR/LDRH/
        // LDRB/LDRSH Rd, [Rn, Rm]. bits[15:12] == 0101 (fixed),
        // bits[11:9] select the 8-way opcode. Verified against a real
        // `ldrb r0, [r1, r0]` word from the actual kernel.
        if hw0.bitField16(15, 12) == 0b0101 {
            let op = ThumbLoadStoreRegisterOffsetInstruction.Op(rawValue: UInt8(hw0.bitField16(11, 9)))!
            return .loadStoreRegisterOffset(ThumbLoadStoreRegisterOffsetInstruction(
                op: op, rd: Int(hw0.bitField16(2, 0)), rn: Int(hw0.bitField16(5, 3)), rm: Int(hw0.bitField16(8, 6))
            ))
        }

        // Format 9: word/byte LDR/STR Rd, [Rn, #imm5] (word: ×4; byte: ×1).
        if hw0.bitField16(15, 13) == 0b011 {
            let isByte = hw0.bit16(12)
            let isLoad = hw0.bit16(11)
            let imm5 = UInt32(hw0.bitField16(10, 6))
            return .loadStoreImmediate(ThumbLoadStoreImmediateInstruction(
                isLoad: isLoad, size: isByte ? .byte : .word,
                rn: Int(hw0.bitField16(5, 3)), rt: Int(hw0.bitField16(2, 0)),
                offset: isByte ? imm5 : imm5 * 4
            ))
        }

        // Format 10: halfword LDRH/STRH Rd, [Rn, #imm5] (×2).
        if hw0.bitField16(15, 12) == 0b1000 {
            return .loadStoreImmediate(ThumbLoadStoreImmediateInstruction(
                isLoad: hw0.bit16(11), size: .halfword,
                rn: Int(hw0.bitField16(5, 3)), rt: Int(hw0.bitField16(2, 0)),
                offset: UInt32(hw0.bitField16(10, 6)) * 2
            ))
        }

        // Format 11: SP-relative LDR/STR Rd, [SP, #imm8*4].
        if hw0.bitField16(15, 12) == 0b1001 {
            return .loadStoreImmediate(ThumbLoadStoreImmediateInstruction(
                isLoad: hw0.bit16(11), size: .word,
                rn: Registers.spIndex, rt: Int(hw0.bitField16(10, 8)),
                offset: UInt32(hw0.bitField16(7, 0)) * 4
            ))
        }

        // Format 12: ADD Rd, PC/SP, #imm8*4.
        if hw0.bitField16(15, 12) == 0b1010 {
            return .address(ThumbAddressInstruction(
                usesSP: hw0.bit16(11), rd: Int(hw0.bitField16(10, 8)), imm8: UInt32(hw0.bitField16(7, 0))
            ))
        }

        // Format 15: LDMIA/STMIA Rn!, {reglist} (16-bit, low registers
        // only). Real ARM ARM quirk for the load form: if `Rn` is
        // itself in `reglist`, the loaded value overwrites it, so no
        // separate writeback happens (unlike the store form, which
        // always writes back regardless of whether `Rn` is listed) —
        // `ThumbBlockDataTransferInstruction`'s `writeback` flag
        // already models this generically (shared with `PUSH`/`POP`
        // and the 32-bit T2 form), this just has to compute it
        // correctly at decode time. Verified against a real
        // `ldm r6, {r2, r3, r6}` word from the actual kernel.
        if hw0.bitField16(15, 11) == 0b11001 {
            let rn = Int(hw0.bitField16(10, 8))
            let registerList = UInt16(hw0.bitField16(7, 0))
            return .blockDataTransfer(ThumbBlockDataTransferInstruction(
                isLoad: true, isIncrement: true, writeback: !registerList.bit16(rn), rn: rn, registerList: registerList
            ))
        }

        // The whole 1011-prefixed "miscellaneous" space: format 13 (SP
        // adjust), format 14 (PUSH/POP), CBZ/CBNZ, IT. Disambiguated by
        // bits[11:8], each value used by exactly one of these (verified
        // against real words for SP-adjust, PUSH, and CBZ; POP and IT
        // follow the same documented, symmetric encoding).
        if top5 == 0b10110 || top5 == 0b10111 {
            let selector = hw0.bitField16(11, 8)
            switch selector {
            case 0b0000: // Format 13: ADD/SUB SP, #imm7*4.
                return .adjustStack(ThumbAdjustStackInstruction(subtract: hw0.bit16(7), imm7: UInt32(hw0.bitField16(6, 0))))
            case 0b0001, 0b0011, 0b1001, 0b1011: // CBZ (0bx0xx) / CBNZ (0bx1xx) — bit11 selects, bit9 is imm5's top bit.
                let branchIfNonZero = hw0.bit16(11)
                let i = hw0.bit16(9) ? UInt32(1) : 0
                let imm5 = UInt32(hw0.bitField16(7, 3))
                return .compareBranch(ThumbCompareBranchInstruction(
                    branchIfNonZero: branchIfNonZero, rn: Int(hw0.bitField16(2, 0)), offset: (i << 6) | (imm5 << 1)
                ))
            case 0b0010: // SXTH/SXTB/UXTH/UXTB.
                guard let kind = ThumbExtendKind(rawValue: UInt8(hw0.bitField16(7, 6))) else {
                    return .unsupported(rawHalfword: hw0, secondHalfword: nil)
                }
                return .extend(ThumbExtendInstruction(kind: kind, rm: Int(hw0.bitField16(5, 3)), rd: Int(hw0.bitField16(2, 0))))
            case 0b0100, 0b0101: // Format 14: PUSH.
                let includeLR = hw0.bit16(8)
                var list = UInt16(hw0.bitField16(7, 0))
                if includeLR { list |= 1 << Registers.lrIndex }
                return .pushPop(ThumbPushPopInstruction(isLoad: false, registerList: list))
            case 0b1100, 0b1101: // Format 14: POP.
                let includePC = hw0.bit16(8)
                var list = UInt16(hw0.bitField16(7, 0))
                if includePC { list |= 1 << Registers.pcIndex }
                return .pushPop(ThumbPushPopInstruction(isLoad: true, registerList: list))
            case 0b1111: // IT, or a NOP-compatible hint when mask == 0.
                let mask = hw0.bitField16(3, 0)
                guard mask != 0 else {
                    return .unsupported(rawHalfword: hw0, secondHalfword: nil)
                }
                return .it(ThumbItInstruction(firstCondition: UInt8(hw0.bitField16(7, 4)), mask: UInt8(mask)))
            default:
                return .unsupported(rawHalfword: hw0, secondHalfword: nil)
            }
        }

        // Format 16: conditional branch.
        if hw0.bitField16(15, 12) == 0b1101 {
            let condBits = hw0.bitField16(11, 8)
            guard condBits != 0b1110, condBits != 0b1111 else { // UDF / SWI space.
                return .unsupported(rawHalfword: hw0, secondHalfword: nil)
            }
            let imm8 = hw0.bitField16(7, 0)
            let signExtended = Int32(bitPattern: (imm8 & 0x80) != 0 ? (UInt32(imm8) | 0xFFFF_FF00) : UInt32(imm8))
            return .conditionalBranch(ThumbConditionalBranchInstruction(
                condition: ARMCondition(rawBits: UInt32(condBits)), signedOffset: signExtended << 1
            ))
        }

        // Format 18: unconditional branch.
        if top5 == 0b11100 {
            let imm11 = hw0.bitField16(10, 0)
            let signExtended = Int32(bitPattern: (imm11 & 0x400) != 0 ? (UInt32(imm11) | 0xFFFF_F800) : UInt32(imm11))
            return .branch(ThumbBranchInstruction(signedOffset: signExtended << 1))
        }

        return .unsupported(rawHalfword: hw0, secondHalfword: nil)
    }

    // MARK: - 32-bit

    private static func decode32(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        switch hw0.bitField16(15, 11) {
        case 0b11101:
            // bits[10:9] split this class four ways — verified against
            // one real kernel word from each confirmed branch: `00`
            // load/store multiple, `01` data-processing (shifted
            // register), `11` coprocessor (bits[11:8] fixed at 0b1110
            // with hw1 bit[4] set for MCR/MRC specifically; other
            // coprocessor instructions like CDP/LDC/STC aren't
            // decoded). `10` (load/store dual/exclusive, table branch)
            // isn't decoded — no real word has confirmed it.
            switch hw0.bitField16(10, 9) {
            case 0b00:
                return decode32LoadStoreMultiple(hw0, hw1)
            case 0b01:
                return decode32DataProcessingShiftedRegister(hw0, hw1)
            case 0b11:
                if hw0.bitField16(11, 8) == 0b1110, hw1.bit16(4) {
                    return decode32Coprocessor(hw0, hw1)
                }
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            default:
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            }
        case 0b11110:
            return decode32DataProcessingOrBranch(hw0, hw1)
        case 0b11111:
            // bits[9:8] split this class further — verified against
            // real words from each confirmed branch: `00` plain byte/
            // word/register load-store (`0xF8` prefix), `01` the
            // signed-load family (`0xF9` prefix), `10` (`0xFA`)
            // register-controlled-shift and sign/zero-extend
            // instructions (of which only the extend forms' no-
            // accumulate shape is decoded — see
            // `decode32ExtendOrShift`'s doc comment), `11` long
            // multiply/multiply-accumulate/divide (`0xFB` prefix, of
            // which only `UMULL`'s exact bits[7:4] pattern is decoded).
            switch hw0.bitField16(9, 8) {
            case 0b00:
                return decode32LoadStoreSingle(hw0, hw1)
            case 0b01:
                return decode32LoadStoreSignedByte(hw0, hw1)
            case 0b10:
                return decode32ExtendOrShift(hw0, hw1)
            case 0b11:
                return decode32LongMultiply(hw0, hw1)
            default:
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            }
        default:
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
    }

    /// `MCR`/`MRC`: verified against a real `mrc p15, #0, r0, c13, c0, #4`
    /// word from the actual kernel to share ARM state's exact field
    /// layout (see `ThumbInstruction.coprocessorRegisterTransfer`'s doc
    /// comment) — the fixed `1110` at bits[31:28] and `1110` at
    /// bits[27:24] (this function's own bits[11:8] check, having
    /// already matched at the call site) plus bit4 of the low halfword
    /// distinguish it from `CDP`/`LDC`/`STC`, which aren't decoded.
    private static func decode32Coprocessor(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        return .coprocessorRegisterTransfer(CoprocessorRegisterTransferInstruction(
            condition: .always,
            isLoad: hw0.bit16(4),
            coprocessor: Int(hw1.bitField16(11, 8)),
            opc1: Int(hw0.bitField16(7, 5)),
            rt: Int(hw1.bitField16(15, 12)),
            crn: Int(hw0.bitField16(3, 0)),
            crm: Int(hw1.bitField16(3, 0)),
            opc2: Int(hw1.bitField16(7, 5))
        ))
    }

    /// Data-processing (shifted register) — verified against a real
    /// `sub.w r1, r3, sb` word from the actual kernel. Shares
    /// `ThumbModifiedImmediateOp`'s table with the modified-immediate
    /// family (see `ThumbDataProcessingShiftedRegisterInstruction`'s
    /// doc comment); the shift amount is `imm3:imm2` (bits[14:12] of
    /// hw1, bits[7:6] of hw1), same split as ARM state's immediate
    /// shifts.
    private static func decode32DataProcessingShiftedRegister(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        guard let op = ThumbModifiedImmediateOp(rawValue: UInt8(hw0.bitField16(8, 5))) else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        let imm3 = hw1.bitField16(14, 12)
        let imm2 = hw1.bitField16(7, 6)
        let shiftAmount = UInt8((imm3 << 2) | imm2)
        guard let shiftType = ShiftType(rawValue: UInt8(hw1.bitField16(5, 4))) else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        return .dataProcessingShiftedRegister(ThumbDataProcessingShiftedRegisterInstruction(
            op: op, setFlags: hw0.bit16(4), rn: Int(hw0.bitField16(3, 0)), rd: Int(hw1.bitField16(11, 8)),
            rm: Int(hw1.bitField16(3, 0)), shiftType: shiftType, shiftAmount: shiftAmount
        ))
    }

    /// `LDM`/`STM` (T2): verified against real `pop.w` (load, IA),
    /// `stm.w` (store, IA), and `push.w` (store, DB) words from the
    /// actual kernel. bits[15:9] (`1110100`) and bit6 (`0`) are truly
    /// fixed; bits[8:7] is a 2-bit direction selector this codebase
    /// originally (incorrectly) folded into what looked like one long
    /// fixed prefix, having only ever seen the IA case — `01` selects
    /// IA, `10` selects DB; `00`/`11` (`RFE`/`SRS`/reserved) aren't
    /// decoded.
    private static func decode32LoadStoreMultiple(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        // bit[6] == 1 within this same bits[15:9] prefix is architecturally
        // a different sub-family: load/store dual/exclusive and table
        // branch (`TBB`/`TBH`) — try that first since LDM/STM never sets
        // bit[6].
        if hw0.bit16(6) {
            return decode32TableBranch(hw0, hw1)
        }
        guard hw0.bitField16(15, 9) == 0b111_0100 else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        let isIncrement: Bool
        switch hw0.bitField16(8, 7) {
        case 0b01: isIncrement = true
        case 0b10: isIncrement = false
        default: return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        return .blockDataTransfer(ThumbBlockDataTransferInstruction(
            isLoad: hw0.bit16(4), isIncrement: isIncrement, writeback: hw0.bit16(5),
            rn: Int(hw0.bitField16(3, 0)), registerList: hw1
        ))
    }

    /// `TBB`/`TBH` (table branch, verified against a real
    /// `tbh [pc, r1, lsl #1]` word) and `LDRD`/`STRD` (immediate,
    /// verified against a real `strd r0, r1, [r8]` word) — both live in
    /// this bit[6]==1 sub-family (bits[15:9] == `1110100`, guaranteed
    /// by the caller). `LDREX`/`STREX` (the third member of this space)
    /// aren't decoded, since no real word has confirmed either.
    private static func decode32TableBranch(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        if hw0.bitField16(15, 4) == 0b1110_1000_1101, hw1.bitField16(15, 5) == 0b111_1000_0000 {
            return .tableBranch(ThumbTableBranchInstruction(
                rn: Int(hw0.bitField16(3, 0)), rm: Int(hw1.bitField16(3, 0)), isHalfword: hw1.bit16(4)
            ))
        }
        // LDRD/STRD (immediate): P (bit8), U (bit7), fixed 1 (bit6,
        // already known true here), W (bit5), L (bit4, 1 = LDRD).
        // P==0 && W==0 is reserved for the exclusive-access/TBB/TBH
        // shape within this same space (TBB/TBH already handled above;
        // LDREX/STREX aren't decoded, since no real word has confirmed
        // either) — refused here rather than misread as a bogus,
        // never-pre-indexed-and-never-written-back LDRD/STRD.
        guard hw0.bit16(8) || hw0.bit16(5) else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        return .loadStoreDual(ThumbLoadStoreDualInstruction(
            isLoad: hw0.bit16(4),
            rn: Int(hw0.bitField16(3, 0)),
            rt: Int(hw1.bitField16(15, 12)),
            rt2: Int(hw1.bitField16(11, 8)),
            preIndexed: hw0.bit16(8),
            addOffset: hw0.bit16(7),
            writeback: hw0.bit16(5),
            offset: UInt32(hw1.bitField16(7, 0)) * 4
        ))
    }

    /// `LDR`/`STR`/`LDRB`/`STRB` (immediate) — T3 (12-bit unsigned
    /// offset, always pre-indexed, no writeback), T4 (8-bit signed
    /// offset, pre/post-indexed, optional writeback), and the
    /// register-offset form (`Rm LSL imm2`, always pre-indexed, never
    /// writeback — verified against a real `ldr.w r3, [r5, r0, lsl #3]`
    /// word). bits[6:5] select size: `10` word, `00` byte (verified
    /// against real `str.w`/`ldr.w`/`str ...!`/`ldr ...,#4`/`strb`
    /// words from the actual kernel); `01` (halfword) isn't decoded
    /// yet, since no real word has confirmed it. Within the bit[7]==0
    /// half, the fixed `1` at hw1 bit[11] distinguishes T4's immediate
    /// form from the register-offset form's fixed `000000` at
    /// hw1 bits[11:6].
    private static func decode32LoadStoreSingle(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        guard hw0.bitField16(15, 8) == 0b1111_1000 else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        let isByte: Bool
        let isHalfword: Bool
        switch hw0.bitField16(6, 5) {
        case 0b10: isByte = false; isHalfword = false
        case 0b00: isByte = true; isHalfword = false
        case 0b01: isByte = false; isHalfword = true
        default: return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        let isLoad = hw0.bit16(4)
        let rn = Int(hw0.bitField16(3, 0))
        let rt = Int(hw1.bitField16(15, 12))
        if hw0.bit16(7) {
            // T3: 12-bit unsigned immediate, always add, never writeback.
            return .loadStoreWide(ThumbLoadStoreWideInstruction(
                isLoad: isLoad, isByte: isByte, isHalfword: isHalfword, isSigned: false, rn: rn, rt: rt,
                preIndexed: true, addOffset: true, writeback: false,
                offset: UInt32(hw1.bitField16(11, 0))
            ))
        }
        // T4 (8-bit signed immediate, explicit P/U/W bits, fixed marker
        // bit[11]==1) vs register-offset form (bits[11:6]==000000,
        // verified against a real `ldr.w r3, [r5, r0, lsl #3]` word).
        if hw1.bit16(11) {
            return .loadStoreWide(ThumbLoadStoreWideInstruction(
                isLoad: isLoad, isByte: isByte, isHalfword: isHalfword, isSigned: false, rn: rn, rt: rt,
                preIndexed: hw1.bit16(10), addOffset: hw1.bit16(9), writeback: hw1.bit16(8),
                offset: UInt32(hw1.bitField16(7, 0))
            ))
        }
        guard hw1.bitField16(11, 6) == 0, !isHalfword else {
            // Register-offset halfword form isn't decoded — no real
            // word has confirmed it yet, unlike byte/word above.
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        return .loadStoreRegister(ThumbLoadStoreRegisterInstruction(
            isLoad: isLoad, isByte: isByte, rn: rn, rt: rt,
            rm: Int(hw1.bitField16(3, 0)), shiftAmount: Int(hw1.bitField16(5, 4))
        ))
    }

    /// `LDRSB` (immediate) — the sign-extending sibling of the T3/T4
    /// forms above, sharing their exact hw1 (Rt/P/U/W/imm) layout and
    /// the same bit[7] T3-vs-T4 selector role, but with a different
    /// fixed hw0 prefix: bits[15:8] `0xF9` (bits[15:9] `1111100`, same
    /// as every single load/store, with bit[8] `1` marking the
    /// signed-load family vs `0` for the plain byte/word forms above),
    /// and bits[6:5] `00` (byte size, mirroring the plain family's
    /// scheme — `01`/halfword, `LDRSH`, isn't decoded, since no real
    /// word has confirmed it). Verified against a real
    /// `ldrsb r0, [r5, #1]!` word from the actual kernel.
    private static func decode32LoadStoreSignedByte(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        guard hw0.bitField16(15, 8) == 0b1111_1001, hw0.bitField16(6, 5) == 0 else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        let rn = Int(hw0.bitField16(3, 0))
        let rt = Int(hw1.bitField16(15, 12))
        if hw0.bit16(7) {
            return .loadStoreWide(ThumbLoadStoreWideInstruction(
                isLoad: true, isByte: true, isHalfword: false, isSigned: true, rn: rn, rt: rt,
                preIndexed: true, addOffset: true, writeback: false,
                offset: UInt32(hw1.bitField16(11, 0))
            ))
        }
        guard hw1.bit16(11) else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        return .loadStoreWide(ThumbLoadStoreWideInstruction(
            isLoad: true, isByte: true, isHalfword: false, isSigned: true, rn: rn, rt: rt,
            preIndexed: hw1.bit16(10), addOffset: hw1.bit16(9), writeback: hw1.bit16(8),
            offset: UInt32(hw1.bitField16(7, 0))
        ))
    }

    /// `UMULL`/`MLA` — bits[7:4] splits the shared `0xFB` prefix
    /// between the "multiply, multiply accumulate" table (`0000`,
    /// `MLA`) and the "long multiply" table (`1010`, `UMULL`); see
    /// `ThumbMlaInstruction`/`ThumbUmullInstruction`'s doc comments for
    /// the exact bit splits and their sibling instructions that aren't
    /// decoded.
    /// The `0xFA`-prefixed space: register-controlled shift
    /// instructions (`ASR`/`LSL`/`LSR`/`ROR` register form, hw0
    /// bits[7:4] top bit clear) and sign/zero-extend instructions
    /// (bits[7:4] top bit set). Only the extend forms' no-accumulate
    /// shape (`Rn == 1111`, `hw0` bits[7:4] ∈ {0000=SXTH, 0001=UXTH,
    /// 0100=SXTB, 0101=UXTB}) are decoded — the register-shift
    /// instructions and the accumulate (`Rn != 1111`) extend forms
    /// aren't, since no real word has confirmed either yet. Verified
    /// against a real `uxtb.w r1, r10` word from the actual kernel.
    private static func decode32ExtendOrShift(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        // hw0's op nibble (bits[7:4]) splits this space into (at
        // least) three real sub-families by its own top two bits,
        // bits[7:6] — confirmed by three real words landing on three
        // different values: `lsl.w` (bits[7:4]==0b0000, bits[7:6]==00,
        // register-controlled shift), `uxtb.w` (bits[7:4]==0b0101,
        // bits[7:6]==01, sign/zero-extend), and `clz` (Thumb-2 form,
        // bits[7:4]==0b1011, bits[7:6]==10, alongside — per the real
        // ARM ARM, though unconfirmed here — `REV`/`REV16`/`RBIT`/
        // `REVSH`). An earlier version of this function used just bit6
        // as the discriminator, which happened to route `lsl.w`
        // correctly but let a *different* bit6==0 op value (`clz`'s
        // 0b1011) fall into the shift-register branch instead of being
        // recognized — its own `hw1` fixed-marker guard rejected it
        // there as unsupported rather than misdecoding it, but the fix
        // is branching on the full 2-bit field. That same earlier
        // version also guessed at three more extend op values
        // (0b0000/0b0001/0b0100) by pattern-completing the ARM ARM's
        // table from `uxtb.w` alone — wrong, since 0b0000 is actually
        // `lsl.w`'s op; only the one value a real word has actually
        // confirmed for each sub-family stays decoded.
        if hw0.bitField16(7, 6) == 0b00 {
            // Register-controlled shift: bits[7:6]==00, bits[5:4] is
            // the `ShiftType` (matching its raw values directly).
            // Verified against a real `lsl.w r2, r5, r2` word from the
            // actual kernel.
            guard hw1.bitField16(15, 12) == 0b1111, hw1.bitField16(7, 4) == 0, let shiftType = ShiftType(rawValue: UInt8(hw0.bitField16(5, 4))) else {
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            }
            return .shiftRegister(ThumbShiftRegisterInstruction(
                shiftType: shiftType, rd: Int(hw1.bitField16(11, 8)), rn: Int(hw0.bitField16(3, 0)), rm: Int(hw1.bitField16(3, 0))
            ))
        }
        guard hw1.bitField16(15, 12) == 0b1111, hw1.bitField16(7, 4) == 0b1000 else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        switch hw0.bitField16(7, 4) {
        case 0b0101 where hw0.bitField16(3, 0) == 0b1111:
            return .extendWide(ThumbExtendWideInstruction(
                kind: .unsignedByte, rd: Int(hw1.bitField16(11, 8)), rm: Int(hw1.bitField16(3, 0)), rotate: Int(hw1.bitField16(5, 4))
            ))
        case 0b1011:
            return .clz(ThumbClzInstruction(rd: Int(hw1.bitField16(11, 8)), rm: Int(hw1.bitField16(3, 0))))
        default:
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
    }

    private static func decode32LongMultiply(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        guard hw0.bitField16(15, 8) == 0b1111_1011, hw1.bitField16(7, 4) == 0 else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        switch hw0.bitField16(7, 4) {
        case 0b1010:
            return .umull(ThumbUmullInstruction(
                rdLo: Int(hw1.bitField16(15, 12)), rdHi: Int(hw1.bitField16(11, 8)),
                rn: Int(hw0.bitField16(3, 0)), rm: Int(hw1.bitField16(3, 0))
            ))
        case 0b0000:
            if hw1.bitField16(15, 12) == 0b1111 {
                // MUL alias (Ra == 1111): verified against a real
                // `mul r1, r0, r2` word from the actual kernel.
                return .mul(ThumbMulInstruction(
                    rd: Int(hw1.bitField16(11, 8)), rn: Int(hw0.bitField16(3, 0)), rm: Int(hw1.bitField16(3, 0))
                ))
            }
            return .mla(ThumbMlaInstruction(
                rd: Int(hw1.bitField16(11, 8)), rn: Int(hw0.bitField16(3, 0)),
                rm: Int(hw1.bitField16(3, 0)), ra: Int(hw1.bitField16(15, 12))
            ))
        default:
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
    }

    private static func decode32DataProcessingOrBranch(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        let isBranchOrMisc = hw1.bit16(15)

        if !isBranchOrMisc {
            // Data-processing: modified-immediate (bit9==0) vs plain
            // binary immediate (bit9==1) — the latter is a whole real
            // ARM ARM sub-table (ADDW/MOVW/SUBW/MOVT/SSAT/SBFX/BFI/
            // USAT/UBFX/…) keyed on the 6-bit field hw0.bits[9:4], of
            // which MOVW/MOVT (0b10T100), UBFX (0b111100, verified
            // against a real `ubfx r0, r0, #1, #1` word: hw0=0xF3C0,
            // hw1=0x0040), and ADDW (0b100000 with Rn!=1111, verified
            // against a real `addw r0, r4, #0x4d4` word: hw0=0xF204,
            // hw1=0x40D4) are decoded.
            if hw0.bit16(9) {
                let opField = hw0.bitField16(9, 4)
                if opField & 0b110111 == 0b100100 {
                    // MOVW/MOVT: bits[9:4] == 0b10T100 (T selects MOVT).
                    let isTop = hw0.bit16(7)
                    let imm4 = hw0.bitField16(3, 0)
                    let i = hw0.bit16(10) ? UInt32(1) : 0
                    let imm3 = hw1.bitField16(14, 12)
                    let imm8 = hw1.bitField16(7, 0)
                    let imm16 = (UInt32(imm4) << 12) | (i << 11) | (UInt32(imm3) << 8) | UInt32(imm8)
                    return .movWide(ThumbMovWideInstruction(isTop: isTop, rd: Int(hw1.bitField16(11, 8)), imm16: UInt16(imm16)))
                }
                if opField == 0b111100 {
                    // UBFX: lsb = imm3:imm2, width = widthm1 + 1.
                    let imm3 = Int(hw1.bitField16(14, 12))
                    let imm2 = Int(hw1.bitField16(7, 6))
                    let lsb = (imm3 << 2) | imm2
                    let widthMinus1 = Int(hw1.bitField16(4, 0))
                    return .bitFieldExtract(ThumbUbfxInstruction(
                        rd: Int(hw1.bitField16(11, 8)), rn: Int(hw0.bitField16(3, 0)), lsb: lsb, width: widthMinus1 + 1
                    ))
                }
                if opField == 0b100000 {
                    // ADDW; Rn == 1111 is ADR (see ThumbAdrInstruction's
                    // doc comment).
                    let rn = hw0.bitField16(3, 0)
                    let i = hw0.bit16(10) ? UInt32(1) : 0
                    let imm3 = hw1.bitField16(14, 12)
                    let imm8 = hw1.bitField16(7, 0)
                    let imm12 = (i << 11) | (UInt32(imm3) << 8) | UInt32(imm8)
                    if rn == 0b1111 {
                        return .adr(ThumbAdrInstruction(rd: Int(hw1.bitField16(11, 8)), imm12: UInt16(imm12)))
                    }
                    return .addWide(ThumbAddWideInstruction(
                        rd: Int(hw1.bitField16(11, 8)), rn: Int(rn), imm12: UInt16(imm12)
                    ))
                }
                if opField == 0b110110 {
                    // BFI/BFC (see ThumbBitFieldInsertInstruction's doc
                    // comment).
                    let msb = Int(hw1.bitField16(4, 0))
                    let lsb = (Int(hw1.bitField16(14, 12)) << 2) | Int(hw1.bitField16(7, 6))
                    guard msb >= lsb else {
                        return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
                    }
                    let rn = hw0.bitField16(3, 0)
                    return .bitFieldInsert(ThumbBitFieldInsertInstruction(
                        rd: Int(hw1.bitField16(11, 8)),
                        sourceRegister: rn == 0b1111 ? nil : Int(rn),
                        lsb: lsb,
                        width: msb - lsb + 1
                    ))
                }
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            }

            guard let op = ThumbModifiedImmediateOp(rawValue: UInt8(hw0.bitField16(8, 5))) else {
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            }
            let i = hw0.bit16(10) ? UInt32(1) : 0
            let imm3 = hw1.bitField16(14, 12)
            let imm8 = hw1.bitField16(7, 0)
            let imm32 = expandModifiedImmediate(i: i, imm3: UInt32(imm3), imm8: UInt32(imm8))
            return .dataProcessingImmediate(ThumbDataProcessingImmediateInstruction(
                op: op, setFlags: hw0.bit16(4), rn: Int(hw0.bitField16(3, 0)), rd: Int(hw1.bitField16(11, 8)), imm32: imm32
            ))
        }

        // Branch/misc family: hw1[15:14] distinguishes BL/BLX ("11")
        // from B.W ("10"); everything else here (table branch, misc
        // control, exception-return) is unsupported.
        let branchKind = hw1.bitField16(15, 14)
        if branchKind == 0b11 {
            let switchesToARM = !hw1.bit16(12) // bit12: 1 = BL (stays Thumb), 0 = BLX (switches to ARM).
            let offset = decodeBLOffset(hw0, hw1)
            return .branchLink(ThumbBranchLinkInstruction(switchesToARM: switchesToARM, signedOffset: offset))
        }
        if branchKind == 0b10, hw1.bit16(12) {
            // B.W (T4, unconditional).
            let offset = decodeBLOffset(hw0, hw1)
            return .branchWide(ThumbBranchWideInstruction(condition: .always, signedOffset: offset))
        }
        if branchKind == 0b10, !hw1.bit16(12) {
            // B.W (T3, conditional) — a real, but shorter-range, cond
            // field (bits[9:6]) is available here, so cond==1110/1111
            // (AL/never) aren't valid encodings (those go through T4 or
            // the unconditional space instead); reserved rather than
            // guessed at. Verified against a real "beq.w" word from the
            // actual kernel.
            let condBits = hw0.bitField16(9, 6)
            guard condBits != 0b1110, condBits != 0b1111 else {
                // cond==1110/1111 (this space's reserved values) is
                // actually the "miscellaneous control instructions"
                // sub-table, of which only DSB/DMB/ISB (fixed
                // hw0==0xF3BF, hw1 bits[15:8]==0x8F, bits[7:4] one of
                // 0100/0101/0110) are decoded — a real no-op here, same
                // as ARM state's memoryBarrier. Verified against a real
                // `dsb sy` word from the actual kernel.
                if hw0 == 0xF3BF, hw1.bitField16(15, 8) == 0x8F, (0b0100...0b0110).contains(hw1.bitField16(7, 4)) {
                    return .memoryBarrier
                }
                return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
            }
            let offset = decodeConditionalBWOffset(hw0, hw1)
            return .branchWide(ThumbBranchWideInstruction(condition: ARMCondition(rawBits: UInt32(condBits)), signedOffset: offset))
        }

        return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
    }

    /// The `S:I1:I2:imm10:imm11:0` offset shared by `BL`, `BLX`
    /// (immediate), and unconditional `B.W` — verified against real
    /// `bl`/`blx`/`b.w` words from the actual kernel.
    private static func decodeBLOffset(_ hw0: UInt16, _ hw1: UInt16) -> Int32 {
        let s = hw0.bit16(10) ? UInt32(1) : 0
        let imm10 = UInt32(hw0.bitField16(9, 0))
        let j1 = hw1.bit16(13) ? UInt32(1) : 0
        let j2 = hw1.bit16(11) ? UInt32(1) : 0
        let imm11 = UInt32(hw1.bitField16(10, 0))
        let i1 = 1 - (j1 ^ s)
        let i2 = 1 - (j2 ^ s)
        var imm25 = (s << 24) | (i1 << 23) | (i2 << 22) | (imm10 << 12) | (imm11 << 1)
        if s != 0 {
            imm25 = imm25 &- (1 << 25)
        }
        return Int32(bitPattern: imm25)
    }

    /// The shorter-range `S:J2:J1:imm6:imm11:0` offset used only by
    /// conditional `B.W` (T3) — a plain concatenation, unlike
    /// `decodeBLOffset`'s `I1`/`I2` `NOT`-XOR scheme for `BL`/`BLX`/
    /// unconditional `B.W`. Verified against a real `beq.w` word from
    /// the actual kernel.
    private static func decodeConditionalBWOffset(_ hw0: UInt16, _ hw1: UInt16) -> Int32 {
        let s = hw0.bit16(10) ? UInt32(1) : 0
        let imm6 = UInt32(hw0.bitField16(5, 0))
        let j1 = hw1.bit16(13) ? UInt32(1) : 0
        let j2 = hw1.bit16(11) ? UInt32(1) : 0
        let imm11 = UInt32(hw1.bitField16(10, 0))
        var imm21 = (s << 20) | (j2 << 19) | (j1 << 18) | (imm6 << 12) | (imm11 << 1)
        if s != 0 {
            imm21 = imm21 &- (1 << 21)
        }
        return Int32(bitPattern: imm21)
    }

    /// Thumb-2's "modified immediate" 12-bit encoding (`i:imm3:imm8`) —
    /// either a simple repeated-byte pattern (top 2 bits `00`) or an
    /// 8-bit value with an implicit leading 1, rotated right by the top
    /// 5 bits — per ARM DDI 0406C A5.3.2 (`ThumbExpandImm`). Verified
    /// against real `bic`/`orr`/`add.w` words from the actual kernel.
    static func expandModifiedImmediate(i: UInt32, imm3: UInt32, imm8: UInt32) -> UInt32 {
        let top2 = (i << 1) | (imm3 >> 2)
        if top2 == 0 {
            let selector = imm3 & 0b11
            switch selector {
            case 0b00: return imm8
            case 0b01: return (imm8 << 16) | imm8
            case 0b10: return (imm8 << 24) | (imm8 << 8)
            default: return (imm8 << 24) | (imm8 << 16) | (imm8 << 8) | imm8
            }
        }
        let rotateAmount = (i << 4) | (imm3 << 1) | (imm8 >> 7)
        let unrotated: UInt32 = 0x80 | (imm8 & 0x7F)
        return ShifterOperand.rotateRight(unrotated, by: rotateAmount)
    }
}

extension UInt16 {
    func bitField16(_ high: Int, _ low: Int) -> UInt16 {
        let width = high - low + 1
        let mask: UInt16 = width >= 16 ? 0xFFFF : ((1 << width) - 1)
        return (self >> low) & mask
    }

    func bit16(_ index: Int) -> Bool {
        (self >> index) & 1 != 0
    }
}
