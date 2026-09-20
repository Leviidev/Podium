import Foundation

/// Decodes Thumb instructions — both the classic 16-bit Thumb-1 formats
/// and the 32-bit Thumb-2 extensions — the same way `ARMDecoder` decodes
/// ARM-state words: pure, stateless, and every case added here verified
/// against real, disassembled halfwords from the actual iPod4,1 6.1.6
/// kernel's Thumb-compiled code (confirmed present via a real `BLX` this
/// CPU used to be unable to follow — see `ARMv7CPU`'s doc comment).
///
/// Covers (16-bit): `LSL`/`LSR`/`ASR` by immediate (format 1), immediate
/// `MOV`/`CMP`/`ADD`/`SUB` (format 3), the two-register ALU family
/// (format 4), hi-register `ADD`/`CMP`/`MOV` and `BX`/`BLX` (format 5),
/// word/byte load-store with a 5-bit immediate (format 9), halfword
/// load-store with a 5-bit immediate (format 10), SP-relative (format
/// 11), `ADD Rd,PC/SP,#imm` (format 12), SP adjustment (format 13),
/// `PUSH`/`POP` (format 14), `SXTH`/`SXTB`/`UXTH`/`UXTB`, conditional
/// and unconditional branch (formats 16/18), `CBZ`/`CBNZ`, and `IT`.
/// Covers (32-bit): `MOVW`/`MOVT`, the data-processing modified-
/// immediate family, `BL`, `BLX` (immediate), `B.W` (both the
/// unconditional T4 form and the conditional T3 form, which carries its
/// own condition field the same way 16-bit `Bcond` does), `LDR`/`STR`/
/// `LDRB`/`STRB` (immediate, T3 and T4, and register-offset), `LDM`/
/// `STM` (T2, both IA and DB), and `MCR`/`MRC` (reusing ARM state's
/// exact field layout — see `decode32Coprocessor`'s doc comment).
/// Everything else — `ADD`/`SUB` (format 2, register or 3-bit
/// immediate), signed-byte/halfword loads (format 8), PC-relative `LDR`
/// (format 6), 16-bit register-offset load/store (format 7),
/// `REV`/`REV16`/`REVSH`, multiply/multiply-accumulate
/// beyond 16-bit `MUL`, table branches, the rest of the coprocessor
/// space (`CDP`/`LDC`/`STC`), SIMD/VFP — decodes to `.unsupported`.
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
            // This class covers both load/store multiple/dual/exclusive
            // (bits[11:8] fixed at 0b0100 for the LDM/STM shape this
            // codebase already decodes) and coprocessor instructions
            // (bits[11:8] fixed at 0b1110 for MCR/MRC) — try coprocessor
            // first since its marker is unambiguous.
            if hw0.bitField16(11, 8) == 0b1110, hw1.bit16(4) {
                return decode32Coprocessor(hw0, hw1)
            }
            return decode32LoadStoreMultiple(hw0, hw1)
        case 0b11110:
            return decode32DataProcessingOrBranch(hw0, hw1)
        case 0b11111:
            return decode32LoadStoreSingle(hw0, hw1)
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

    /// `LDM`/`STM` (T2): verified against real `pop.w` (load, IA),
    /// `stm.w` (store, IA), and `push.w` (store, DB) words from the
    /// actual kernel. bits[15:9] (`1110100`) and bit6 (`0`) are truly
    /// fixed; bits[8:7] is a 2-bit direction selector this codebase
    /// originally (incorrectly) folded into what looked like one long
    /// fixed prefix, having only ever seen the IA case — `01` selects
    /// IA, `10` selects DB; `00`/`11` (`RFE`/`SRS`/reserved) aren't
    /// decoded.
    private static func decode32LoadStoreMultiple(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        guard hw0.bitField16(15, 9) == 0b111_0100, !hw0.bit16(6) else {
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
        switch hw0.bitField16(6, 5) {
        case 0b10: isByte = false
        case 0b00: isByte = true
        default: return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        let isLoad = hw0.bit16(4)
        let rn = Int(hw0.bitField16(3, 0))
        let rt = Int(hw1.bitField16(15, 12))
        if hw0.bit16(7) {
            // T3: 12-bit unsigned immediate, always add, never writeback.
            return .loadStoreWide(ThumbLoadStoreWideInstruction(
                isLoad: isLoad, isByte: isByte, rn: rn, rt: rt, preIndexed: true, addOffset: true, writeback: false,
                offset: UInt32(hw1.bitField16(11, 0))
            ))
        }
        // T4 (8-bit signed immediate, explicit P/U/W bits, fixed marker
        // bit[11]==1) vs register-offset form (bits[11:6]==000000,
        // verified against a real `ldr.w r3, [r5, r0, lsl #3]` word).
        if hw1.bit16(11) {
            return .loadStoreWide(ThumbLoadStoreWideInstruction(
                isLoad: isLoad, isByte: isByte, rn: rn, rt: rt,
                preIndexed: hw1.bit16(10), addOffset: hw1.bit16(9), writeback: hw1.bit16(8),
                offset: UInt32(hw1.bitField16(7, 0))
            ))
        }
        guard hw1.bitField16(11, 6) == 0 else {
            return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
        }
        return .loadStoreRegister(ThumbLoadStoreRegisterInstruction(
            isLoad: isLoad, isByte: isByte, rn: rn, rt: rt,
            rm: Int(hw1.bitField16(3, 0)), shiftAmount: Int(hw1.bitField16(5, 4))
        ))
    }

    private static func decode32DataProcessingOrBranch(_ hw0: UInt16, _ hw1: UInt16) -> ThumbInstruction {
        let isBranchOrMisc = hw1.bit16(15)

        if !isBranchOrMisc {
            // Data-processing: modified-immediate (bit9==0) vs plain
            // 12-bit immediate (bit9==1, MOVW/MOVT only, so far).
            if hw0.bit16(9) {
                // MOVW/MOVT: bits[9:4] == 0b10T100 (T selects MOVT).
                guard hw0.bitField16(9, 4) & 0b110111 == 0b100100 else {
                    return .unsupported(rawHalfword: hw0, secondHalfword: hw1)
                }
                let isTop = hw0.bit16(7)
                let imm4 = hw0.bitField16(3, 0)
                let i = hw0.bit16(10) ? UInt32(1) : 0
                let imm3 = hw1.bitField16(14, 12)
                let imm8 = hw1.bitField16(7, 0)
                let imm16 = (UInt32(imm4) << 12) | (i << 11) | (UInt32(imm3) << 8) | UInt32(imm8)
                return .movWide(ThumbMovWideInstruction(isTop: isTop, rd: Int(hw1.bitField16(11, 8)), imm16: UInt16(imm16)))
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
