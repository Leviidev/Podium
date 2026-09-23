import Foundation

/// The ARMv6 "media" and DSP integer instructions (ARM DDI 0406C A5.4 and
/// the halfword-multiply/saturating-add corner of A5.2.12), in one type
/// for both instruction sets: ARM encodings decode here directly, and the
/// Thumb-2 encodings of the same operations decode into this ARM form
/// (`ThumbInstruction.armEquivalent`). The kernel's own ARM code needed
/// `uxth` to exec launchd, and user-space libraries use the whole family
/// (parallel arithmetic, saturation, packing, the dual multiplies).
///
/// Register roles follow the ARM encodings: `d` the destination (RdHi for
/// the long forms), `a` the accumulator (RdLo for the long forms; 15 when
/// there is none), `n` and `m` the operands.
struct MediaInstruction: Equatable {
    enum ParallelOperation: Equatable { case add16, addSubtractExchange, subtractAddExchange, subtract16, add8, subtract8 }
    /// `S`/`U` set the GE flags; `Q`/`UQ` saturate; `SH`/`UH` halve.
    enum ParallelKind: Equatable { case signed, saturating, halving, unsigned, unsignedSaturating, unsignedHalving }
    enum ExtendKind: Equatable { case signedByte, signedHalfword, signedBytePair, unsignedByte, unsignedHalfword, unsignedBytePair }

    enum Operation: Equatable {
        case parallel(ParallelOperation, ParallelKind)
        /// `d = (accumulate ? n : 0) + extend(m ROR rotation)`.
        case extend(ExtendKind, rotation: Int, accumulate: Bool)
        /// `PKHBT` (`top` false: low half of `n`, high half of `m << shift`)
        /// or `PKHTB` (high half of `n`, low half of `m ASR shift`).
        case packHalfword(top: Bool, shift: Int)
        /// `SSAT`/`USAT`: `n` shifted (LSL, or ASR when `arithmeticRight`),
        /// saturated to `bits`.
        case saturate(signed: Bool, bits: Int, arithmeticRight: Bool, shift: Int)
        case saturate16(signed: Bool, bits: Int)
        case select
        case reverse16, reverseSignedHalfword, reverseBits
        /// `SMLAD`/`SMUAD`/`SMLSD`/`SMUSD`, and with `long` `SMLALD`/`SMLSLD`.
        case dualMultiply(subtract: Bool, exchange: Bool, long: Bool)
        /// `SMMUL`/`SMMLA`/`SMMLS` (+`R` rounding).
        case mostSignificantMultiply(subtract: Bool, round: Bool)
        case sumOfAbsoluteDifferences
        /// `SMLAxy`/`SMULxy` (`nTop`/`mTop` pick halves), `SMLAWy`/`SMULWy`
        /// (`wide`: 32 x 16 >> 16), `SMLALxy` (`long`).
        case halfwordMultiply(nTop: Bool, mTop: Bool, wide: Bool, long: Bool)
        /// `QADD`/`QSUB`/`QDADD`/`QDSUB`: `d = sat(m ± sat(2*n) or n)`.
        case saturatingAdd(subtract: Bool, doubling: Bool)
        case signedBitFieldExtract(lsb: Int, width: Int)
    }

    let condition: ARMCondition
    let operation: Operation
    let d: Int
    let a: Int
    let n: Int
    let m: Int
}

enum MediaDecoder {
    private static func make(_ op: MediaInstruction.Operation, _ c: ARMCondition, d: Int, a: Int = 15, n: Int, m: Int) -> ARMInstruction {
        .media(MediaInstruction(condition: c, operation: op, d: d, a: a, n: n, m: m))
    }

    /// The media space proper: bits[27:25] == 011, bit4 == 1.
    static func decode(_ w: UInt32, condition c: ARMCondition) -> ARMInstruction? {
        let rn = Int(w.bitField(19, 16)), rd = Int(w.bitField(15, 12)), rs = Int(w.bitField(11, 8)), rm = Int(w.bitField(3, 0))
        let op1 = w.bitField(24, 20), op2 = w.bitField(7, 5)
        switch op1 >> 3 {
        case 0b00:
            // Parallel addition and subtraction: op1 = 00 kind(3).
            // Bits[11:8] are should-be-one; anything else is UNPREDICTABLE.
            guard let kind = parallelKind(op1 & 0b111), let op = parallelOperation(op2), rs == 15 else { return nil }
            return make(.parallel(op, kind), c, d: rd, n: rn, m: rm)
        case 0b01:
            return decodePackingSaturationReversal(w, c, rn: rn, rd: rd, rm: rm)
        case 0b10:
            // Signed multiplies: Rd = [19:16], Ra = [15:12], Rm = [11:8], Rn = [3:0].
            let d = rn, a = rd, m = rs, n = rm
            switch (op1 & 0b111, op2 >> 1) {
            case (0b000, 0b00): return make(.dualMultiply(subtract: false, exchange: w.bit(5), long: false), c, d: d, a: a, n: n, m: m)
            case (0b000, 0b01): return make(.dualMultiply(subtract: true, exchange: w.bit(5), long: false), c, d: d, a: a, n: n, m: m)
            case (0b100, 0b00): return make(.dualMultiply(subtract: false, exchange: w.bit(5), long: true), c, d: d, a: a, n: n, m: m)
            case (0b100, 0b01): return make(.dualMultiply(subtract: true, exchange: w.bit(5), long: true), c, d: d, a: a, n: n, m: m)
            case (0b101, 0b00): return make(.mostSignificantMultiply(subtract: false, round: w.bit(5)), c, d: d, a: a, n: n, m: m)
            case (0b101, 0b11):
                guard a != 15 else { return nil }
                return make(.mostSignificantMultiply(subtract: true, round: w.bit(5)), c, d: d, a: a, n: n, m: m)
            default: return nil // SDIV/UDIV aren't on the Cortex-A8
            }
        default:
            if op1 == 0b11000, op2 == 0b000 {
                // USAD8/USADA8: Rd = [19:16], Ra = [15:12], Rm = [11:8], Rn = [3:0].
                return make(.sumOfAbsoluteDifferences, c, d: rn, a: rd, n: rm, m: rs)
            }
            if op1 & 0b11110 == 0b11010, op2 & 0b11 == 0b10 {
                let lsb = Int(w.bitField(11, 7)), width = Int(w.bitField(20, 16)) + 1
                guard lsb + width <= 32 else { return nil }
                return make(.signedBitFieldExtract(lsb: lsb, width: width), c, d: rd, n: rm, m: 0)
            }
            return nil
        }
    }

    private static func decodePackingSaturationReversal(_ w: UInt32, _ c: ARMCondition, rn: Int, rd: Int, rm: Int) -> ARMInstruction? {
        let op1 = w.bitField(22, 20), op2 = w.bitField(7, 5)
        let imm5 = Int(w.bitField(11, 7))
        if op1 == 0b000, op2 & 0b001 == 0 {
            // PKHBT/PKHTB (tb = bit6); PKHTB's ASR #0 means 32.
            let top = w.bit(6)
            return make(.packHalfword(top: top, shift: top && imm5 == 0 ? 32 : imm5), c, d: rd, n: rn, m: rm)
        }
        if op2 == 0b011 {
            // Extends: op1 000 SXTB16, 010 SXTB, 011 SXTH, 100 UXTB16, 110 UXTB, 111 UXTH.
            guard let kind = extendKind(op1), w.bitField(9, 8) == 0 else { return nil }
            return make(.extend(kind, rotation: Int(w.bitField(11, 10)) * 8, accumulate: rn != 15), c, d: rd, n: rn, m: rm)
        }
        if op1 == 0b000, op2 == 0b101, w.bitField(11, 8) == 0b1111 {
            return make(.select, c, d: rd, n: rn, m: rm)
        }
        if op1 & 0b010 == 0b010, op2 & 0b001 == 0 {
            // SSAT (op1 01x) / USAT (op1 11x): sat_imm [20:16], source [3:0].
            let signed = op1 & 0b100 == 0
            let satImm = Int(w.bitField(20, 16))
            let asr = w.bit(6)
            return make(.saturate(signed: signed, bits: signed ? satImm + 1 : satImm, arithmeticRight: asr, shift: asr && imm5 == 0 ? 32 : imm5), c, d: rd, n: rm, m: 0)
        }
        if (op1 == 0b010 || op1 == 0b110), op2 == 0b001 {
            let signed = op1 == 0b010
            let satImm = Int(w.bitField(19, 16))
            return make(.saturate16(signed: signed, bits: signed ? satImm + 1 : satImm), c, d: rd, n: rm, m: 0)
        }
        switch (op1, op2) {
        case (0b011, 0b101): return make(.reverse16, c, d: rd, n: rm, m: 0)
        case (0b111, 0b001): return make(.reverseBits, c, d: rd, n: rm, m: 0)
        case (0b111, 0b101): return make(.reverseSignedHalfword, c, d: rd, n: rm, m: 0)
        default: return nil
        }
    }

    /// ARM's parallel `op1` low bits and `op2` field.
    static func parallelKind(_ bits: UInt32) -> MediaInstruction.ParallelKind? {
        switch bits {
        case 0b001: return .signed
        case 0b010: return .saturating
        case 0b011: return .halving
        case 0b101: return .unsigned
        case 0b110: return .unsignedSaturating
        case 0b111: return .unsignedHalving
        default: return nil
        }
    }

    static func parallelOperation(_ bits: UInt32) -> MediaInstruction.ParallelOperation? {
        switch bits {
        case 0b000: return .add16
        case 0b001: return .addSubtractExchange
        case 0b010: return .subtractAddExchange
        case 0b011: return .subtract16
        case 0b100: return .add8
        case 0b111: return .subtract8
        default: return nil
        }
    }

    /// ARM's extend `op1`: 000 SXTB16, 010 SXTB, 011 SXTH, 100 UXTB16,
    /// 110 UXTB, 111 UXTH.
    static func extendKind(_ bits: UInt32) -> MediaInstruction.ExtendKind? {
        switch bits {
        case 0b000: return .signedBytePair
        case 0b010: return .signedByte
        case 0b011: return .signedHalfword
        case 0b100: return .unsignedBytePair
        case 0b110: return .unsignedByte
        case 0b111: return .unsignedHalfword
        default: return nil
        }
    }

    /// The halfword multiplies and saturating add/subtract, in the
    /// data-processing "miscellaneous" corner: bits[27:23] == 00010,
    /// bit20 == 0 (checked by the caller).
    static func decodeMiscellaneous(_ w: UInt32, condition c: ARMCondition) -> ARMInstruction? {
        let op = w.bitField(22, 21)
        let rn = Int(w.bitField(19, 16)), rd = Int(w.bitField(15, 12)), rs = Int(w.bitField(11, 8)), rm = Int(w.bitField(3, 0))
        if w.bit(7), !w.bit(4) {
            // Rd = [19:16], Ra = [15:12], Rm = [11:8], Rn = [3:0]; N = bit5, M = bit6.
            let nTop = w.bit(5), mTop = w.bit(6)
            switch op {
            case 0b00: return make(.halfwordMultiply(nTop: nTop, mTop: mTop, wide: false, long: false), c, d: rn, a: rd, n: rm, m: rs)
            case 0b01:
                // SMLAWy (bit5 clear, with Ra) / SMULWy (bit5 set; Ra field SBZ).
                if nTop && rd != 0 { return nil }
                return make(.halfwordMultiply(nTop: false, mTop: mTop, wide: true, long: false), c, d: rn, a: nTop ? 15 : rd, n: rm, m: rs)
            case 0b10: return make(.halfwordMultiply(nTop: nTop, mTop: mTop, wide: false, long: true), c, d: rn, a: rd, n: rm, m: rs)
            default:
                // SMULxy: Ra field SBZ.
                guard rd == 0 else { return nil }
                return make(.halfwordMultiply(nTop: nTop, mTop: mTop, wide: false, long: false), c, d: rn, a: 15, n: rm, m: rs)
            }
        }
        if w.bitField(7, 4) == 0b0101, rs == 0 {
            // QADD Rd, Rm, Rn: d = sat(m ± n'), n' = n or sat(2n).
            return make(.saturatingAdd(subtract: op & 0b01 != 0, doubling: op & 0b10 != 0), c, d: rd, n: rn, m: rm)
        }
        return nil
    }
}

extension MediaDecoder {
    /// The Thumb-2 encodings of the media/DSP operations (ARM DDI 0406C
    /// A6.3.3, A6.3.12–17), as their ARM forms. Consulted only for words
    /// the Thumb decoder doesn't otherwise decode.
    static func decodeThumb(_ hw0: UInt16, _ hw1: UInt16) -> ARMInstruction? {
        let rn = Int(hw0 & 0xF), rd = Int(hw1 >> 8 & 0xF), ra = Int(hw1 >> 12), rm = Int(hw1 & 0xF)
        let c = ARMCondition.always
        switch hw0 >> 4 {
        case 0xFA8...0xFAF where hw1 >> 12 == 0xF:
            let op1 = UInt32(hw0 >> 4 & 0b111), op2 = hw1 >> 4 & 0b1111
            if op2 >> 3 == 0 {
                // Parallel add/subtract: op2 0 U H? — 00xx signed, 01xx unsigned; low bits S/Q/H.
                let unsigned = op2 & 0b0100 != 0
                let variant = op2 & 0b11
                let kind: MediaInstruction.ParallelKind
                switch (unsigned, variant) {
                case (false, 0): kind = .signed
                case (false, 1): kind = .saturating
                case (false, 2): kind = .halving
                case (true, 0): kind = .unsigned
                case (true, 1): kind = .unsignedSaturating
                case (true, 2): kind = .unsignedHalving
                default: return nil
                }
                let op: MediaInstruction.ParallelOperation
                switch op1 {
                case 0b001: op = .add16
                case 0b010: op = .addSubtractExchange
                case 0b110: op = .subtractAddExchange
                case 0b101: op = .subtract16
                case 0b000: op = .add8
                case 0b100: op = .subtract8
                default: return nil
                }
                return make(.parallel(op, kind), c, d: rd, n: rn, m: rm)
            }
            if op2 >> 2 == 0b10, hw0 >> 4 & 0b1100 == 0b1000 {
                // Miscellaneous: op1 (hw0 bits 5:4) 00 = QADD family, 10 = SEL.
                switch (hw0 >> 4 & 0b11, op2 & 0b11) {
                case (0b00, let q):
                    // 00 QADD, 01 QDADD, 10 QSUB, 11 QDSUB: d = sat(Rm ± Rn').
                    return make(.saturatingAdd(subtract: q & 0b10 != 0, doubling: q & 0b01 != 0), c, d: rd, n: rn, m: rm)
                case (0b10, 0b00):
                    return make(.select, c, d: rd, n: rn, m: rm)
                default:
                    return nil
                }
            }
            return nil
        case 0xF30, 0xF32, 0xF38, 0xF3A:
            // SSAT/USAT (and the 16-bit forms): hw1 = 0 imm3 Rd imm2 0 sat_imm.
            guard hw1 & 0x8020 == 0 else { return nil }
            let signed = hw0 & 0x0080 == 0
            let asr = hw0 & 0x0020 != 0
            let shift = Int(hw1 >> 12 & 0b111) << 2 | Int(hw1 >> 6 & 0b11)
            if asr && shift == 0 {
                guard hw1 & 0b1_0000 == 0 else { return nil }
                let satImm = Int(hw1 & 0xF)
                return make(.saturate16(signed: signed, bits: signed ? satImm + 1 : satImm), c, d: rd, n: rn, m: 0)
            }
            let satImm = Int(hw1 & 0x1F)
            return make(.saturate(signed: signed, bits: signed ? satImm + 1 : satImm, arithmeticRight: asr, shift: shift), c, d: rd, n: rn, m: 0)
        case 0xFB1...0xFB7:
            // Multiply: hw1 = Ra Rd 00 op2 Rm.
            guard hw1 & 0x00C0 == 0 else { return nil }
            let bit5 = hw1 & 0x20 != 0, bit4 = hw1 & 0x10 != 0
            switch hw0 >> 4 & 0b111 {
            case 0b001:
                return make(.halfwordMultiply(nTop: bit5, mTop: bit4, wide: false, long: false), c, d: rd, a: ra, n: rn, m: rm)
            case 0b010 where !bit5:
                return make(.dualMultiply(subtract: false, exchange: bit4, long: false), c, d: rd, a: ra, n: rn, m: rm)
            case 0b011 where !bit5:
                return make(.halfwordMultiply(nTop: false, mTop: bit4, wide: true, long: false), c, d: rd, a: ra, n: rn, m: rm)
            case 0b100 where !bit5:
                return make(.dualMultiply(subtract: true, exchange: bit4, long: false), c, d: rd, a: ra, n: rn, m: rm)
            case 0b101 where !bit5:
                return make(.mostSignificantMultiply(subtract: false, round: bit4), c, d: rd, a: ra, n: rn, m: rm)
            case 0b110 where !bit5:
                guard ra != 15 else { return nil }
                return make(.mostSignificantMultiply(subtract: true, round: bit4), c, d: rd, a: ra, n: rn, m: rm)
            case 0b111 where !bit5 && !bit4:
                return make(.sumOfAbsoluteDifferences, c, d: rd, a: ra, n: rn, m: rm)
            default:
                return nil
            }
        case 0xFB8...0xFBF:
            // Long multiply: hw1 = RdLo RdHi op2 Rm.
            let rdLo = ra, rdHi = rd
            let op2 = hw1 >> 4 & 0xF
            func long(_ kind: MultiplyInstruction.Kind) -> ARMInstruction {
                .multiply(MultiplyInstruction(condition: c, kind: kind, setFlags: false, rd: rdHi, ra: rdLo, rm: rn, rs: rm))
            }
            switch (hw0 >> 4 & 0b111, op2) {
            case (0b000, 0b0000): return long(.smull)
            case (0b010, 0b0000): return long(.umull)
            case (0b100, 0b0000): return long(.smlal)
            case (0b110, 0b0000): return long(.umlal)
            case (0b110, 0b0110): return long(.umaal)
            case (0b100, 0b1000...0b1011):
                return make(.halfwordMultiply(nTop: op2 & 0b10 != 0, mTop: op2 & 0b01 != 0, wide: false, long: true), c, d: rdHi, a: rdLo, n: rn, m: rm)
            case (0b100, 0b1100...0b1101):
                return make(.dualMultiply(subtract: false, exchange: op2 & 1 != 0, long: true), c, d: rdHi, a: rdLo, n: rn, m: rm)
            case (0b101, 0b1100...0b1101):
                return make(.dualMultiply(subtract: true, exchange: op2 & 1 != 0, long: true), c, d: rdHi, a: rdLo, n: rn, m: rm)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
