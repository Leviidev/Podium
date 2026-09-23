import Foundation

/// The Advanced SIMD (NEON) data-processing space, decoded generically by
/// encoding family (ARM DDI 0406C A7.4) rather than one instruction at a
/// time: three registers of the same length, three registers of different
/// lengths, two registers and a scalar, two registers and a shift amount,
/// two registers miscellaneous, and the permutes (`VTBL`/`VTBX`, `VDUP`
/// scalar). User space leans on NEON everywhere — libSystem's string and
/// memory routines, CoreGraphics, image and audio code — and the kernel's
/// own zlib `adler32` needs `vmull`/`vpadal`-class instructions to exec a
/// compressed launchd, so covering families is the only approach that
/// scales. The handful of instructions decoded individually before this
/// existed (`VRSHL`, `VEOR`, `VORR`, `VADD`, `VEXT`, `VSHL`/`VSHR`, `VREV`,
/// the modified-immediate group) keep their own paths; this decodes
/// everything they don't.
///
/// Register fields are raw 5-bit `D` indices (`D:Vd`, `N:Vn`, `M:Vm`); a
/// `Q` operand is the even `D` register of its pair. `esize` is the element
/// size in bits — for widening and narrowing operations, the *narrow* size.
struct NEONInstruction: Equatable {
    enum SameLengthOperation: Equatable {
        case halvingAdd, roundingHalvingAdd, saturatingAdd, halvingSubtract, saturatingSubtract
        case compareGreater, compareGreaterOrEqual
        case shiftLeft, saturatingShiftLeft, roundingShiftLeft, saturatingRoundingShiftLeft
        case maximum, minimum, absoluteDifference, absoluteDifferenceAccumulate
        case add, subtract, test, compareEqual
        case multiplyAccumulate, multiplySubtract, multiply, polynomialMultiply
        case pairwiseMaximum, pairwiseMinimum, pairwiseAdd
        case saturatingDoublingMultiplyHigh, saturatingRoundingDoublingMultiplyHigh
        case and, bitClear, or, orNot, exclusiveOr, bitwiseSelect, bitwiseInsertIfTrue, bitwiseInsertIfFalse
        case floatAdd, floatSubtract, floatPairwiseAdd, floatAbsoluteDifference
        case floatMultiplyAccumulate, floatMultiplySubtract, floatMultiply
        case floatCompareEqual, floatCompareGreaterOrEqual, floatCompareGreater
        case floatAbsoluteCompareGreaterOrEqual, floatAbsoluteCompareGreater
        case floatMaximum, floatMinimum, floatPairwiseMaximum, floatPairwiseMinimum
        case floatReciprocalStep, floatReciprocalSquareRootStep
    }

    /// `Qd = op(Dn, Dm)`, elements widened to `2 * esize`.
    enum LongOperation: Equatable {
        case add, subtract, absoluteDifferenceAccumulate, absoluteDifference
        case multiplyAccumulate, multiplySubtract, multiply, polynomialMultiply
        case saturatingDoublingMultiply, saturatingDoublingMultiplyAccumulate, saturatingDoublingMultiplySubtract
    }

    /// `Qd = op(Qn, Dm)`: `Dm`'s elements widened.
    enum WideOperation: Equatable { case add, subtract }

    /// `Dd = high half of op(Qn, Qm)`.
    enum NarrowHighOperation: Equatable { case add, roundingAdd, subtract, roundingSubtract }

    enum ByScalarOperation: Equatable {
        case multiplyAccumulate, multiplySubtract, multiply
        case floatMultiplyAccumulate, floatMultiplySubtract, floatMultiply
        case multiplyAccumulateLong, multiplySubtractLong, multiplyLong
        case saturatingDoublingMultiplyAccumulateLong, saturatingDoublingMultiplySubtractLong, saturatingDoublingMultiplyLong
        case saturatingDoublingMultiplyHigh, saturatingRoundingDoublingMultiplyHigh
    }

    enum ShiftOperation: Equatable {
        case shiftRight, shiftRightAccumulate, roundingShiftRight, roundingShiftRightAccumulate
        case shiftRightInsert, shiftLeft, shiftLeftInsert
        case saturatingShiftLeft, saturatingShiftLeftUnsigned
        /// Narrowing: `Dd = Qm >> amount`, elements narrowed to `esize`.
        case shiftRightNarrow, roundingShiftRightNarrow
        case saturatingShiftRightNarrow, saturatingRoundingShiftRightNarrow
        case saturatingShiftRightUnsignedNarrow, saturatingRoundingShiftRightUnsignedNarrow
        /// Widening: `Qd = Dm << amount` (`VMOVL` when the amount is 0).
        case shiftLeftLong
    }

    enum MiscOperation: Equatable {
        case reverse64, reverse32, reverse16
        case pairwiseAddLong, pairwiseAddAccumulateLong
        case countLeadingSignBits, countLeadingZeros, countOnes, not
        case saturatingAbsolute, saturatingNegate
        case compareGreaterThanZero(float: Bool), compareGreaterOrEqualZero(float: Bool), compareEqualZero(float: Bool)
        case compareLessOrEqualZero(float: Bool), compareLessThanZero(float: Bool)
        case absolute(float: Bool), negate(float: Bool)
        case swap, transpose, unzip, zip
        /// `Dd = narrow(Qm)`.
        case moveNarrow, saturatingMoveNarrow, saturatingMoveUnsignedNarrow
        /// `VSHLL` by the element size.
        case shiftLeftLongByElementSize
        case reciprocalEstimate(float: Bool), reciprocalSquareRootEstimate(float: Bool)
        case convertToFloat, convertFromFloat
    }

    enum Operation: Equatable {
        case same(SameLengthOperation)
        case long(LongOperation)
        case wide(WideOperation)
        case narrowHigh(NarrowHighOperation)
        case byScalar(ByScalarOperation, index: Int)
        case shift(ShiftOperation, amount: Int)
        case misc(MiscOperation)
        /// `VTBL`/`VTBX` with a `length`-register table starting at `n`.
        case tableLookup(extends: Bool, length: Int)
        case duplicateScalar(index: Int)
    }

    let operation: Operation
    let esize: Int
    let unsigned: Bool
    let isQuad: Bool
    let d: Int
    let n: Int
    let m: Int
}

/// `VLDn`/`VSTn` (ARM DDI 0406C A7.7): multiple `n`-element structures, a
/// single structure to one lane, or (loads only) a single structure to
/// all lanes, with `n` from 1 to 4.
struct NEONStructureLoadStoreInstruction: Equatable {
    enum Form: Equatable {
        /// `registers` groups, each of `elements` registers spaced by
        /// `spacing` (`VLD1` with up to four registers is 1 element, n
        /// groups).
        case multiple(registers: Int, spacing: Int)
        case singleLane(index: Int, spacing: Int)
        /// `registers` is 2 only for `VLD1` with `T` set.
        case allLanes(spacing: Int, registers: Int)
    }

    let isLoad: Bool
    /// `n`: the structure's element count.
    let elements: Int
    let esize: Int
    let form: Form
    let d: Int
    let rn: Int
    /// 15: no writeback; 13: add the transfer size; otherwise add `Rm`.
    let rm: Int
}

enum NEONDecoder {
    /// A data-processing word (`1111 001U ...` in ARM form). Returns
    /// `.undefined` for encodings the architecture reserves, and
    /// `.unsupported` for real instructions not implemented (VFPv4 fused
    /// multiply-add, half-precision and fixed-point conversions).
    static func decodeDataProcessing(_ w: UInt32) -> ARMInstruction {
        let u = w.bit(24)
        let d = (w.bit(22) ? 16 : 0) | Int(w.bitField(15, 12))
        let n = (w.bit(7) ? 16 : 0) | Int(w.bitField(19, 16))
        let m = (w.bit(5) ? 16 : 0) | Int(w.bitField(3, 0))
        let q = w.bit(6)
        let size = Int(w.bitField(21, 20))

        if !w.bit(23) {
            return decodeThreeSame(w, u: u, q: q, size: size, d: d, n: n, m: m)
        }
        if w.bit(4) {
            return decodeShift(w, u: u, d: d, m: m)
        }
        if size != 0b11 {
            return q ? decodeByScalar(w, u: u, size: size, d: d, n: n) : decodeDifferentLengths(w, u: u, size: size, d: d, n: n, m: m)
        }
        guard u else {
            // VEXT has its own decoder; anything reaching here is reserved.
            return .undefined(rawWord: w)
        }
        if !w.bit(11) {
            return decodeMisc(w, q: q, d: d, m: m)
        }
        if w.bitField(11, 10) == 0b10 {
            let length = Int(w.bitField(9, 8)) + 1
            guard n + length <= 32 else { return .undefined(rawWord: w) }
            return make(.tableLookup(extends: w.bit(6), length: length), esize: 8, unsigned: true, q: false, d: d, n: n, m: m)
        }
        if w.bitField(11, 7) == 0b11000 {
            let imm4 = Int(w.bitField(19, 16))
            let esize: Int, index: Int
            if imm4 & 1 != 0 {
                esize = 8; index = imm4 >> 1
            } else if imm4 & 0b10 != 0 {
                esize = 16; index = imm4 >> 2
            } else if imm4 & 0b100 != 0 {
                esize = 32; index = imm4 >> 3
            } else {
                return .undefined(rawWord: w)
            }
            guard !q || d & 1 == 0 else { return .undefined(rawWord: w) }
            return make(.duplicateScalar(index: index), esize: esize, unsigned: true, q: q, d: d, n: 0, m: m)
        }
        return .undefined(rawWord: w)
    }

    private static func make(_ operation: NEONInstruction.Operation, esize: Int, unsigned: Bool, q: Bool, d: Int, n: Int, m: Int) -> ARMInstruction {
        .neon(NEONInstruction(operation: operation, esize: esize, unsigned: unsigned, isQuad: q, d: d, n: n, m: m))
    }

    private static func decodeThreeSame(_ w: UInt32, u: Bool, q: Bool, size: Int, d: Int, n: Int, m: Int) -> ARMInstruction {
        guard !q || (d | n | m) & 1 == 0 else { return .undefined(rawWord: w) }
        let b = w.bit(4)
        let isFloatSize = size & 0b10 == 0
        typealias Op = NEONInstruction.SameLengthOperation
        var operation: Op
        var esize = 8 << size
        var allows64 = false
        switch (w.bitField(11, 8), b) {
        case (0b0000, false): operation = .halvingAdd
        case (0b0000, true): operation = .saturatingAdd; allows64 = true
        case (0b0001, false): operation = .roundingHalvingAdd
        case (0b0001, true):
            let bitwise: [Op] = u ? [.exclusiveOr, .bitwiseSelect, .bitwiseInsertIfTrue, .bitwiseInsertIfFalse] : [.and, .bitClear, .or, .orNot]
            operation = bitwise[size]
            esize = 64; allows64 = true
        case (0b0010, false): operation = .halvingSubtract
        case (0b0010, true): operation = .saturatingSubtract; allows64 = true
        case (0b0011, false): operation = .compareGreater
        case (0b0011, true): operation = .compareGreaterOrEqual
        case (0b0100, false): operation = .shiftLeft; allows64 = true
        case (0b0100, true): operation = .saturatingShiftLeft; allows64 = true
        case (0b0101, false): operation = .roundingShiftLeft; allows64 = true
        case (0b0101, true): operation = .saturatingRoundingShiftLeft; allows64 = true
        case (0b0110, false): operation = .maximum
        case (0b0110, true): operation = .minimum
        case (0b0111, false): operation = .absoluteDifference
        case (0b0111, true): operation = .absoluteDifferenceAccumulate
        case (0b1000, false): operation = u ? .subtract : .add; allows64 = true
        case (0b1000, true): operation = u ? .compareEqual : .test
        case (0b1001, false): operation = u ? .multiplySubtract : .multiplyAccumulate
        case (0b1001, true):
            operation = u ? .polynomialMultiply : .multiply
            if u && size != 0 { return .undefined(rawWord: w) }
        case (0b1010, _):
            operation = b ? .pairwiseMinimum : .pairwiseMaximum
            if q { return .undefined(rawWord: w) }
        case (0b1011, false):
            operation = u ? .saturatingRoundingDoublingMultiplyHigh : .saturatingDoublingMultiplyHigh
            if size == 0 || size == 3 { return .undefined(rawWord: w) }
        case (0b1011, true):
            guard !u, !q else { return .undefined(rawWord: w) }
            operation = .pairwiseAdd
        case (0b1100, _):
            return .undefined(rawWord: w) // VFMA/VFMS: VFPv4, not on the Cortex-A8
        case (0b1101, false):
            operation = isFloatSize ? (u ? .floatPairwiseAdd : .floatAdd) : (u ? .floatAbsoluteDifference : .floatSubtract)
            if operation == .floatPairwiseAdd && q { return .undefined(rawWord: w) }
            esize = 32
        case (0b1101, true):
            if !u {
                operation = isFloatSize ? .floatMultiplyAccumulate : .floatMultiplySubtract
            } else if isFloatSize {
                operation = .floatMultiply
            } else {
                return .undefined(rawWord: w)
            }
            esize = 32
        case (0b1110, false):
            if !u {
                guard isFloatSize else { return .undefined(rawWord: w) }
                operation = .floatCompareEqual
            } else {
                operation = isFloatSize ? .floatCompareGreaterOrEqual : .floatCompareGreater
            }
            esize = 32
        case (0b1110, true):
            guard u else { return .undefined(rawWord: w) }
            operation = isFloatSize ? .floatAbsoluteCompareGreaterOrEqual : .floatAbsoluteCompareGreater
            esize = 32
        case (0b1111, false):
            operation = u ? (isFloatSize ? .floatPairwiseMaximum : .floatPairwiseMinimum) : (isFloatSize ? .floatMaximum : .floatMinimum)
            if u && q { return .undefined(rawWord: w) }
            esize = 32
        case (0b1111, true):
            guard !u else { return .undefined(rawWord: w) }
            operation = isFloatSize ? .floatReciprocalStep : .floatReciprocalSquareRootStep
            esize = 32
        default:
            return .undefined(rawWord: w)
        }
        if esize == 64 && size == 3 && !allows64 { return .undefined(rawWord: w) }
        if size == 3 && !allows64 { return .undefined(rawWord: w) }
        if [.floatAdd, .floatSubtract, .floatPairwiseAdd, .floatAbsoluteDifference, .floatMultiplyAccumulate,
            .floatMultiplySubtract, .floatMultiply, .floatCompareEqual, .floatCompareGreaterOrEqual,
            .floatCompareGreater, .floatAbsoluteCompareGreaterOrEqual, .floatAbsoluteCompareGreater,
            .floatMaximum, .floatMinimum, .floatPairwiseMaximum, .floatPairwiseMinimum,
            .floatReciprocalStep, .floatReciprocalSquareRootStep].contains(operation), size & 1 != 0 {
            // sz = 1 (double-precision vectors) is reserved.
            return .undefined(rawWord: w)
        }
        return make(.same(operation), esize: esize, unsigned: u, q: q, d: d, n: n, m: m)
    }

    private static func decodeDifferentLengths(_ w: UInt32, u: Bool, size: Int, d: Int, n: Int, m: Int) -> ARMInstruction {
        let esize = 8 << size
        let op: NEONInstruction.Operation
        switch w.bitField(11, 8) {
        case 0b0000: op = .long(.add)
        case 0b0001: op = .wide(.add)
        case 0b0010: op = .long(.subtract)
        case 0b0011: op = .wide(.subtract)
        case 0b0100: op = .narrowHigh(u ? .roundingAdd : .add)
        case 0b0101: op = .long(.absoluteDifferenceAccumulate)
        case 0b0110: op = .narrowHigh(u ? .roundingSubtract : .subtract)
        case 0b0111: op = .long(.absoluteDifference)
        case 0b1000: op = .long(.multiplyAccumulate)
        case 0b1001: op = .long(.saturatingDoublingMultiplyAccumulate)
        case 0b1010: op = .long(.multiplySubtract)
        case 0b1011: op = .long(.saturatingDoublingMultiplySubtract)
        case 0b1100: op = .long(.multiply)
        case 0b1101: op = .long(.saturatingDoublingMultiply)
        case 0b1110:
            guard !u, size == 0 else { return .undefined(rawWord: w) }
            op = .long(.polynomialMultiply)
        default: return .undefined(rawWord: w)
        }
        if case .long(let long) = op,
           [.saturatingDoublingMultiply, .saturatingDoublingMultiplyAccumulate, .saturatingDoublingMultiplySubtract].contains(long),
           u || size == 0 {
            return .undefined(rawWord: w)
        }
        // Q destinations (and Q sources of wide/narrow forms) must be even.
        switch op {
        case .narrowHigh: if (n | m) & 1 != 0 { return .undefined(rawWord: w) }
        case .wide: if (d | n) & 1 != 0 { return .undefined(rawWord: w) }
        default: if d & 1 != 0 { return .undefined(rawWord: w) }
        }
        return make(op, esize: esize, unsigned: u, q: false, d: d, n: n, m: m)
    }

    private static func decodeByScalar(_ w: UInt32, u: Bool, size: Int, d: Int, n: Int) -> ARMInstruction {
        guard size == 1 || size == 2 else { return .undefined(rawWord: w) }
        let vm = Int(w.bitField(3, 0)), mBit = w.bit(5) ? 1 : 0
        let m = size == 1 ? vm & 0b111 : vm
        let index = size == 1 ? (mBit << 1 | vm >> 3) : mBit
        typealias Op = NEONInstruction.ByScalarOperation
        let op: Op
        var long = false
        switch w.bitField(11, 8) {
        case 0b0000: op = .multiplyAccumulate
        case 0b0001: op = .floatMultiplyAccumulate
        case 0b0010: op = .multiplyAccumulateLong; long = true
        case 0b0011: op = .saturatingDoublingMultiplyAccumulateLong; long = true
        case 0b0100: op = .multiplySubtract
        case 0b0101: op = .floatMultiplySubtract
        case 0b0110: op = .multiplySubtractLong; long = true
        case 0b0111: op = .saturatingDoublingMultiplySubtractLong; long = true
        case 0b1000: op = .multiply
        case 0b1001: op = .floatMultiply
        case 0b1010: op = .multiplyLong; long = true
        case 0b1011: op = .saturatingDoublingMultiplyLong; long = true
        case 0b1100: op = .saturatingDoublingMultiplyHigh
        case 0b1101: op = .saturatingRoundingDoublingMultiplyHigh
        default: return .undefined(rawWord: w)
        }
        if [.floatMultiplyAccumulate, .floatMultiplySubtract, .floatMultiply].contains(op), size != 2 {
            return .undefined(rawWord: w)
        }
        // For the non-long forms, bit24 is Q; for the long forms it's U.
        let q = long ? false : u
        let unsigned = long ? u : false
        if [.saturatingDoublingMultiplyAccumulateLong, .saturatingDoublingMultiplySubtractLong, .saturatingDoublingMultiplyLong].contains(op), u {
            return .undefined(rawWord: w)
        }
        if long ? d & 1 != 0 : (q && (d | n) & 1 != 0) { return .undefined(rawWord: w) }
        return make(.byScalar(op, index: index), esize: 8 << size, unsigned: unsigned, q: q, d: d, n: n, m: m)
    }

    private static func decodeShift(_ w: UInt32, u: Bool, d: Int, m: Int) -> ARMInstruction {
        let l = w.bit(7)
        let imm6 = Int(w.bitField(21, 16))
        let q = w.bit(6)
        let esize: Int
        if l {
            esize = 64
        } else if imm6 & 0b10_0000 != 0 {
            esize = 32
        } else if imm6 & 0b01_0000 != 0 {
            esize = 16
        } else if imm6 & 0b00_1000 != 0 {
            esize = 8
        } else {
            // One register and a modified immediate — decoded elsewhere.
            return .undefined(rawWord: w)
        }
        let right = (l ? 64 : 2 * esize) - imm6
        let left = imm6 - (l ? 0 : esize)
        typealias Op = NEONInstruction.ShiftOperation
        let op: Op, amount: Int
        var narrow = false, widen = false
        switch w.bitField(11, 8) {
        case 0b0000: op = .shiftRight; amount = right
        case 0b0001: op = .shiftRightAccumulate; amount = right
        case 0b0010: op = .roundingShiftRight; amount = right
        case 0b0011: op = .roundingShiftRightAccumulate; amount = right
        case 0b0100:
            guard u else { return .undefined(rawWord: w) }
            op = .shiftRightInsert; amount = right
        case 0b0101: op = u ? .shiftLeftInsert : .shiftLeft; amount = left
        case 0b0110:
            guard u else { return .undefined(rawWord: w) }
            op = .saturatingShiftLeftUnsigned; amount = left
        case 0b0111: op = .saturatingShiftLeft; amount = left
        case 0b1000:
            guard !l else { return .undefined(rawWord: w) }
            op = u ? (q ? .saturatingRoundingShiftRightUnsignedNarrow : .saturatingShiftRightUnsignedNarrow)
                   : (q ? .roundingShiftRightNarrow : .shiftRightNarrow)
            amount = right; narrow = true
        case 0b1001:
            guard !l else { return .undefined(rawWord: w) }
            op = q ? .saturatingRoundingShiftRightNarrow : .saturatingShiftRightNarrow
            amount = right; narrow = true
        case 0b1010:
            guard !l, !q else { return .undefined(rawWord: w) }
            op = .shiftLeftLong; amount = left; widen = true
        case 0b1110, 0b1111:
            return .unsupported(rawWord: w) // VCVT fixed-point
        default:
            return .undefined(rawWord: w)
        }
        if narrow {
            guard m & 1 == 0 else { return .undefined(rawWord: w) }
            return make(.shift(op, amount: amount), esize: esize, unsigned: u, q: false, d: d, n: 0, m: m)
        }
        if widen {
            guard d & 1 == 0 else { return .undefined(rawWord: w) }
            return make(.shift(op, amount: amount), esize: esize, unsigned: u, q: false, d: d, n: 0, m: m)
        }
        guard !q || (d | m) & 1 == 0 else { return .undefined(rawWord: w) }
        return make(.shift(op, amount: amount), esize: esize, unsigned: u, q: q, d: d, n: 0, m: m)
    }

    private static func decodeMisc(_ w: UInt32, q: Bool, d: Int, m: Int) -> ARMInstruction {
        let size = Int(w.bitField(19, 18))
        let esize = 8 << size
        let b = Int(w.bitField(10, 6)) // B<4:0>; B<0> is Q for most
        typealias Op = NEONInstruction.MiscOperation
        func same(_ op: Op, esize: Int = esize, unsigned: Bool = false) -> ARMInstruction {
            guard !q || (d | m) & 1 == 0 else { return .undefined(rawWord: w) }
            return make(.misc(op), esize: esize, unsigned: unsigned, q: q, d: d, n: 0, m: m)
        }
        switch w.bitField(17, 16) {
        case 0b00:
            switch b >> 1 {
            case 0b0000: return size == 3 ? .undefined(rawWord: w) : same(.reverse64)
            case 0b0001: return size >= 2 ? .undefined(rawWord: w) : same(.reverse32)
            case 0b0010: return size != 0 ? .undefined(rawWord: w) : same(.reverse16)
            case 0b0100, 0b0101:
                return size == 3 ? .undefined(rawWord: w) : same(.pairwiseAddLong, unsigned: w.bit(7))
            case 0b1000: return size == 3 ? .undefined(rawWord: w) : same(.countLeadingSignBits)
            case 0b1001: return size == 3 ? .undefined(rawWord: w) : same(.countLeadingZeros)
            case 0b1010: return size != 0 ? .undefined(rawWord: w) : same(.countOnes)
            case 0b1011: return size != 0 ? .undefined(rawWord: w) : same(.not, esize: 64)
            case 0b1100, 0b1101:
                return size == 3 ? .undefined(rawWord: w) : same(.pairwiseAddAccumulateLong, unsigned: w.bit(7))
            case 0b1110: return size == 3 ? .undefined(rawWord: w) : same(.saturatingAbsolute)
            case 0b1111: return size == 3 ? .undefined(rawWord: w) : same(.saturatingNegate)
            default: return .undefined(rawWord: w)
            }
        case 0b01:
            let float = w.bit(10)
            if size == 3 || (float && size != 2) { return .undefined(rawWord: w) }
            let e = float ? 32 : esize
            switch w.bitField(9, 7) {
            case 0b000: return same(.compareGreaterThanZero(float: float), esize: e)
            case 0b001: return same(.compareGreaterOrEqualZero(float: float), esize: e)
            case 0b010: return same(.compareEqualZero(float: float), esize: e)
            case 0b011: return same(.compareLessOrEqualZero(float: float), esize: e)
            case 0b100: return same(.compareLessThanZero(float: float), esize: e)
            case 0b110: return same(.absolute(float: float), esize: e)
            case 0b111: return same(.negate(float: float), esize: e)
            default: return .undefined(rawWord: w)
            }
        case 0b10:
            switch b >> 1 {
            case 0b0000: return size != 0 ? .undefined(rawWord: w) : same(.swap, esize: 64)
            case 0b0001: return size == 3 ? .undefined(rawWord: w) : same(.transpose)
            case 0b0010: return size == 3 || (!q && size == 2) ? .undefined(rawWord: w) : same(.unzip)
            case 0b0011: return size == 3 || (!q && size == 2) ? .undefined(rawWord: w) : same(.zip)
            case 0b0100, 0b0101:
                // B = 01000 VMOVN, 01001 VQMOVUN, 0101x VQMOVN (op = B<0>).
                guard size != 3, m & 1 == 0 else { return .undefined(rawWord: w) }
                let op: Op
                switch b {
                case 0b01000: op = .moveNarrow
                case 0b01001: op = .saturatingMoveUnsignedNarrow
                default: op = .saturatingMoveNarrow
                }
                return make(.misc(op), esize: esize, unsigned: b == 0b01011, q: false, d: d, n: 0, m: m)
            case 0b0110:
                guard b & 1 == 0, size != 3, d & 1 == 0 else { return .undefined(rawWord: w) }
                return make(.misc(.shiftLeftLongByElementSize), esize: esize, unsigned: false, q: false, d: d, n: 0, m: m)
            default:
                return .undefined(rawWord: w) // half-precision conversions: not on the Cortex-A8
            }
        default:
            guard size == 2 else { return .undefined(rawWord: w) }
            switch b >> 1 {
            case 0b1000, 0b1010: return same(.reciprocalEstimate(float: w.bit(8)), esize: 32)
            case 0b1001, 0b1011: return same(.reciprocalSquareRootEstimate(float: w.bit(8)), esize: 32)
            case 0b1100, 0b1101: return same(.convertToFloat, esize: 32, unsigned: w.bit(7))
            case 0b1110, 0b1111: return same(.convertFromFloat, esize: 32, unsigned: w.bit(7))
            default: return .undefined(rawWord: w)
            }
        }
    }

    /// An element/structure load/store word (`1111 0100 A.L0 ...` in ARM
    /// form).
    static func decodeStructureLoadStore(_ w: UInt32) -> ARMInstruction {
        let isLoad = w.bit(21)
        let d = (w.bit(22) ? 16 : 0) | Int(w.bitField(15, 12))
        let rn = Int(w.bitField(19, 16))
        let rm = Int(w.bitField(3, 0))
        guard rn != 15 else { return .undefined(rawWord: w) }

        func make(_ elements: Int, _ esize: Int, _ form: NEONStructureLoadStoreInstruction.Form, lastRegister: Int) -> ARMInstruction {
            guard lastRegister < 32 else { return .undefined(rawWord: w) }
            return .neonStructureLoadStore(NEONStructureLoadStoreInstruction(
                isLoad: isLoad, elements: elements, esize: esize, form: form, d: d, rn: rn, rm: rm
            ))
        }

        if !w.bit(23) {
            let size = Int(w.bitField(7, 6))
            let esize = 8 << size
            let elements: Int, registers: Int, spacing: Int
            switch w.bitField(11, 8) {
            case 0b0111: elements = 1; registers = 1; spacing = 1
            case 0b1010: elements = 1; registers = 2; spacing = 1
            case 0b0110: elements = 1; registers = 3; spacing = 1
            case 0b0010: elements = 1; registers = 4; spacing = 1
            case 0b1000: elements = 2; registers = 1; spacing = 1
            case 0b1001: elements = 2; registers = 1; spacing = 2
            case 0b0011: elements = 2; registers = 2; spacing = 2
            case 0b0100: elements = 3; registers = 1; spacing = 1
            case 0b0101: elements = 3; registers = 1; spacing = 2
            case 0b0000: elements = 4; registers = 1; spacing = 1
            case 0b0001: elements = 4; registers = 1; spacing = 2
            default: return .undefined(rawWord: w)
            }
            if size == 3 && elements != 1 { return .undefined(rawWord: w) }
            let last = elements == 1 ? d + registers - 1 : d + (registers - 1) + (elements - 1) * spacing
            return make(elements, esize, .multiple(registers: registers, spacing: spacing), lastRegister: last)
        }

        let elements = Int(w.bitField(9, 8)) + 1
        if w.bitField(11, 10) == 0b11 {
            guard isLoad else { return .undefined(rawWord: w) }
            let size = Int(w.bitField(7, 6))
            let t = w.bit(5)
            let esize = size == 3 ? (elements == 4 ? 32 : 0) : 8 << size
            guard esize != 0 else { return .undefined(rawWord: w) }
            if elements == 1 {
                let registers = t ? 2 : 1
                return make(1, esize, .allLanes(spacing: 1, registers: registers), lastRegister: d + registers - 1)
            }
            let spacing = t ? 2 : 1
            return make(elements, esize, .allLanes(spacing: spacing, registers: 1), lastRegister: d + (elements - 1) * spacing)
        }
        let size = Int(w.bitField(11, 10))
        let indexAlign = Int(w.bitField(7, 4))
        let esize = 8 << size
        let index: Int, spacing: Int
        switch size {
        case 0: index = indexAlign >> 1; spacing = 1
        case 1: index = indexAlign >> 2; spacing = elements > 1 && indexAlign & 0b10 != 0 ? 2 : 1
        default: index = indexAlign >> 3; spacing = elements > 1 && indexAlign & 0b100 != 0 ? 2 : 1
        }
        return make(elements, esize, .singleLane(index: index, spacing: spacing), lastRegister: d + (elements - 1) * spacing)
    }
}
