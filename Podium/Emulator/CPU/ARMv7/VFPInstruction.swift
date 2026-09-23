import Foundation

/// A VFPv3 data-processing instruction (ARM DDI 0406C A7.5): coprocessor
/// 10/11 space, `cond 1110 opc1 opc2 Vd 101 sz opc3 M 0 opc4`. Thumb-2's
/// encoding is the same word with cond AL. The real kernel's kexts use
/// these for power-management and HID arithmetic (`vadd.f64`, `vmul.f64`,
/// `vdiv.f64`, `vcmpe.f64`, `vcvt.f64.s32`, ... — about a thousand
/// sites).
///
/// `d`, `n` and `m` are resolved register numbers: an `S` index or a `D`
/// index, whichever that operand is for this operation — the precision
/// conversions and integer conversions mix the two (see `Operation`).
struct VFPDataProcessingInstruction: Equatable {
    enum Operation: Equatable {
        /// `VMLA`/`VMLS`/`VNMLA`/`VNMLS`: `d = ±d ± n*m`, the product
        /// rounded before the add (not fused).
        case multiplyAccumulate(negateProduct: Bool, negateAccumulator: Bool)
        case multiply
        /// `VNMUL`: `d = -(n*m)`.
        case negatedMultiply
        case add
        case subtract
        case divide
        /// `VMOV` (immediate): the value's raw bits at the operation's
        /// precision (`VFPExpandImm`).
        case moveImmediate(UInt64)
        case move
        case absolute
        case negate
        case squareRoot
        /// `VCMP`/`VCMPE` (`E` also signals on quiet NaNs — the exception
        /// flags aren't modeled, so they behave the same here). With
        /// `withZero` the second operand is +0.0.
        case compare(withZero: Bool)
        /// `VCVT` between single and double: `isDouble` is the *source*
        /// precision (`d` is the other one).
        case convertPrecision
        /// `VCVT` from a 32-bit integer in `S[m]` to `d` at the
        /// operation's precision.
        case convertFromInteger(signed: Bool)
        /// `VCVT`/`VCVTR` to a 32-bit integer in `S[d]` from `m` at the
        /// operation's precision.
        case convertToInteger(signed: Bool, roundTowardZero: Bool)
    }

    let condition: ARMCondition
    let operation: Operation
    /// `sz`: double precision (`D` registers) when set.
    let isDouble: Bool
    let d: Int
    let n: Int
    let m: Int
}

enum VFPDecoder {
    /// Decodes the VFP data-processing space; `word` has bits[27:24] ==
    /// 1110, bit4 == 0 and bits[11:9] == 101 (checked by the caller).
    static func decodeDataProcessing(_ word: UInt32, condition: ARMCondition) -> ARMInstruction {
        let isDouble = word.bit(8)
        let vd = Int(word.bitField(15, 12)), dBit = word.bit(22) ? 1 : 0
        let vn = Int(word.bitField(19, 16)), nBit = word.bit(7) ? 1 : 0
        let vm = Int(word.bitField(3, 0)), mBit = word.bit(5) ? 1 : 0
        let singleD = vd << 1 | dBit, doubleD = dBit << 4 | vd
        let singleM = vm << 1 | mBit, doubleM = mBit << 4 | vm
        let d = isDouble ? doubleD : singleD
        let n = isDouble ? (nBit << 4 | vn) : (vn << 1 | nBit)
        let m = isDouble ? doubleM : singleM
        let op = word.bit(6)

        func make(_ operation: VFPDataProcessingInstruction.Operation, d: Int, n: Int = 0, m: Int) -> ARMInstruction {
            .vfpDataProcessing(VFPDataProcessingInstruction(condition: condition, operation: operation, isDouble: isDouble, d: d, n: n, m: m))
        }

        // opc1 without its D bit: bits 23, 21, 20.
        switch (word.bit(23), word.bit(21), word.bit(20)) {
        case (false, false, false):
            return make(.multiplyAccumulate(negateProduct: op, negateAccumulator: false), d: d, n: n, m: m)
        case (false, false, true):
            // VNMLS (op 0): d = -d + n*m; VNMLA (op 1): d = -d - n*m.
            return make(.multiplyAccumulate(negateProduct: op, negateAccumulator: true), d: d, n: n, m: m)
        case (false, true, false):
            return make(op ? .negatedMultiply : .multiply, d: d, n: n, m: m)
        case (false, true, true):
            return make(op ? .subtract : .add, d: d, n: n, m: m)
        case (true, false, false):
            guard !op else { return .undefined(rawWord: word) }
            return make(.divide, d: d, n: n, m: m)
        case (true, true, true):
            break
        default:
            // VFNMA/VFNMS/VFMA/VFMS are VFPv4 — not on the A4's Cortex-A8,
            // where they're UNDEFINED.
            return .undefined(rawWord: word)
        }

        // "Other" data-processing: opc2 = bits[19:16], opc3 = bits[7:6].
        guard word.bit(6) else {
            let imm8 = word.bitField(19, 16) << 4 | word.bitField(3, 0)
            guard word.bitField(7, 4) == 0 else { return .undefined(rawWord: word) }
            return make(.moveImmediate(expandImmediate(imm8, isDouble: isDouble)), d: d, m: 0)
        }
        let opc2 = word.bitField(19, 16)
        let top = word.bit(7)
        switch opc2 {
        case 0b0000:
            return make(top ? .absolute : .move, d: d, m: m)
        case 0b0001:
            return make(top ? .squareRoot : .negate, d: d, m: m)
        case 0b0100:
            return make(.compare(withZero: false), d: d, m: m)
        case 0b0101:
            guard word.bitField(5, 0) == 0 else { return .undefined(rawWord: word) }
            return make(.compare(withZero: true), d: d, m: 0)
        case 0b0111:
            guard top else { return .undefined(rawWord: word) }
            // Double -> single writes an S register, single -> double a D.
            return make(.convertPrecision, d: isDouble ? singleD : doubleD, m: m)
        case 0b1000:
            return make(.convertFromInteger(signed: top), d: d, m: singleM)
        case 0b1100, 0b1101:
            return make(.convertToInteger(signed: opc2 == 0b1101, roundTowardZero: top), d: singleD, m: m)
        case 0b0010, 0b0011:
            // VCVTB/VCVTT need the half-precision extension the A8 lacks.
            return .undefined(rawWord: word)
        default:
            // Fixed-point VCVT (and ARMv8's VRINT*, reserved here).
            return opc2 & 0b1010 == 0b1010 ? .unsupported(rawWord: word) : .undefined(rawWord: word)
        }
    }

    /// `VFPExpandImm` (ARM DDI 0406C A7.5.1): `imm8 = a:b:cdefgh` becomes
    /// sign `a`, exponent `NOT(b):b...b:cd`, fraction `efgh:0...0`.
    static func expandImmediate(_ imm8: UInt32, isDouble: Bool) -> UInt64 {
        let sign = UInt64(imm8 >> 7 & 1)
        let b = UInt64(imm8 >> 6 & 1)
        let cd = UInt64(imm8 >> 4 & 0b11)
        let efgh = UInt64(imm8 & 0xF)
        if isDouble {
            let exponent = (b ^ 1) << 10 | (b == 1 ? 0xFF : 0) << 2 | cd
            return sign << 63 | exponent << 52 | efgh << 48
        }
        let exponent = (b ^ 1) << 7 | (b == 1 ? 0x1F : 0) << 2 | cd
        return sign << 31 | exponent << 23 | efgh << 19
    }
}
