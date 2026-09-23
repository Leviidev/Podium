import Foundation

/// Execution for `NEONInstruction` and `NEONStructureLoadStoreInstruction`
/// — see `NEONInstruction.swift`. Everything works on elements pulled out
/// of the `D` registers as zero-extended `UInt64`s and written back; the
/// pseudocode in ARM DDI 0406C A8 is the reference for each operation.
/// Saturation sets FPSCR.QC. Floating-point elements follow the Advanced
/// SIMD "standard FPSCR value": denormals flush to zero, NaN results are
/// the default NaN, rounding is to nearest.
extension ARMv7CPU {
    private static let fpscrSaturationBit: UInt32 = 1 << 27

    // MARK: - Element plumbing

    @inline(__always)
    private static func mask(_ bits: Int) -> UInt64 { bits >= 64 ? .max : (1 << UInt64(bits)) &- 1 }

    @inline(__always)
    private static func signed(_ value: UInt64, _ bits: Int) -> Int64 {
        bits >= 64 ? Int64(bitPattern: value) : Int64(bitPattern: value << UInt64(64 - bits)) >> Int64(64 - bits)
    }

    /// Reads `registers` consecutive `D` registers from `first` as
    /// `esize`-bit elements, lowest first.
    private func elements(_ first: Int, registers: Int, esize: Int) -> [UInt64] {
        let perRegister = 64 / esize
        var out = [UInt64](repeating: 0, count: registers * perRegister)
        let m = Self.mask(esize)
        for r in 0..<registers {
            let value = neon[(first + r) & 31]
            for e in 0..<perRegister {
                out[r * perRegister + e] = (value >> UInt64(e * esize)) & m
            }
        }
        return out
    }

    private func setElements(_ first: Int, _ values: [UInt64], esize: Int) {
        let perRegister = 64 / esize
        let m = Self.mask(esize)
        for r in 0..<(values.count / perRegister) {
            var value: UInt64 = 0
            for e in 0..<perRegister {
                value |= (values[r * perRegister + e] & m) << UInt64(e * esize)
            }
            neon[(first + r) & 31] = value
        }
    }

    private func noteSaturation() {
        fpscr |= Self.fpscrSaturationBit
    }

    /// Clamps `value` to an `esize`-bit signed or unsigned range, noting
    /// saturation.
    private func saturate(_ value: Int64, _ esize: Int, unsigned: Bool) -> UInt64 {
        if unsigned {
            let maximum = esize >= 64 ? Int64.max : Int64((UInt64(1) << UInt64(esize)) - 1)
            if value < 0 { noteSaturation(); return 0 }
            if esize < 64, value > maximum { noteSaturation(); return UInt64(maximum) }
            return UInt64(value)
        }
        let maximum = esize >= 64 ? Int64.max : (Int64(1) << Int64(esize - 1)) - 1
        let minimum = esize >= 64 ? Int64.min : -(Int64(1) << Int64(esize - 1))
        if value > maximum { noteSaturation(); return UInt64(bitPattern: maximum) & Self.mask(esize) }
        if value < minimum { noteSaturation(); return UInt64(bitPattern: minimum) & Self.mask(esize) }
        return UInt64(bitPattern: value) & Self.mask(esize)
    }

    /// Saturating add/subtract of two `esize`-bit elements, 64-bit safe.
    private func saturatingAdd(_ a: UInt64, _ b: UInt64, _ esize: Int, unsigned: Bool, subtract: Bool) -> UInt64 {
        if esize < 64 {
            let x = unsigned ? Int64(a) : Self.signed(a, esize)
            let y = unsigned ? Int64(b) : Self.signed(b, esize)
            return saturate(subtract ? x - y : x + y, esize, unsigned: unsigned)
        }
        if unsigned {
            if subtract {
                if b > a { noteSaturation(); return 0 }
                return a - b
            }
            let (sum, overflow) = a.addingReportingOverflow(b)
            if overflow { noteSaturation(); return .max }
            return sum
        }
        let x = Int64(bitPattern: a), y = Int64(bitPattern: b)
        let (result, overflow) = subtract ? x.subtractingReportingOverflow(y) : x.addingReportingOverflow(y)
        // Overflow only happens away from zero, in x's direction.
        if overflow { noteSaturation(); return UInt64(bitPattern: x >= 0 ? Int64.max : Int64.min) }
        return UInt64(bitPattern: result)
    }

    /// `VSHL`/`VRSHL`/`VQSHL`/`VQRSHL` by register: the shift is the
    /// bottom byte of `shiftElement`, signed; negative shifts go right.
    private func shiftByRegister(_ value: UInt64, by shiftElement: UInt64, _ esize: Int, unsigned: Bool, rounding: Bool, saturating: Bool) -> UInt64 {
        let shift = Int(Int8(truncatingIfNeeded: shiftElement))
        let m = Self.mask(esize)
        if shift >= 0 {
            if !saturating {
                return shift >= esize ? 0 : (value << UInt64(shift)) & m
            }
            if value == 0 { return 0 }
            if unsigned {
                if shift >= esize { noteSaturation(); return m }
                let shifted = (value << UInt64(shift)) & m
                if shifted >> UInt64(shift) != value { noteSaturation(); return m }
                return shifted
            }
            let x = Self.signed(value, esize)
            let maximum = esize >= 64 ? Int64.max : (Int64(1) << Int64(esize - 1)) - 1
            if shift >= esize - 1 {
                if x == 0 { return 0 }
                noteSaturation()
                return x > 0 ? UInt64(maximum) : UInt64(bitPattern: ~maximum) & m
            }
            let shifted = x << Int64(shift)
            if shifted >> Int64(shift) != x || Self.signed(UInt64(bitPattern: shifted) & m, esize) != shifted {
                noteSaturation()
                return x > 0 ? UInt64(maximum) : UInt64(bitPattern: ~maximum) & m
            }
            return UInt64(bitPattern: shifted) & m
        }
        let right = -shift
        if unsigned {
            if right > esize { return 0 }
            if right == esize { return rounding ? (value >> UInt64(esize - 1)) & 1 : 0 }
            let base = value >> UInt64(right)
            return rounding ? (base + ((value >> UInt64(right - 1)) & 1)) & m : base
        }
        let x = Self.signed(value, esize)
        if right >= esize {
            // Rounded, every value lands on 0; truncated, on its sign.
            if rounding { return 0 }
            return x < 0 ? m : 0
        }
        let base = x >> Int64(right)
        let result = rounding ? base + ((x >> Int64(right - 1)) & 1) : base
        return UInt64(bitPattern: result) & m
    }

    // MARK: - Floating point (standard FPSCR)

    @inline(__always)
    private static func neonFloat(_ bits: UInt64) -> Float {
        let value = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
        return value.isSubnormal ? (value.sign == .minus ? -0.0 : 0.0) : value
    }

    @inline(__always)
    private static func neonBits(_ value: Float) -> UInt64 {
        if value.isNaN { return 0x7FC0_0000 }
        if value.isSubnormal { return value.sign == .minus ? 0x8000_0000 : 0 }
        return UInt64(value.bitPattern)
    }

    /// `FPMax`/`FPMin` with the standard FPSCR: any NaN gives the default
    /// NaN; +0 is greater than -0.
    private static func floatMaxMin(_ a: Float, _ b: Float, max: Bool) -> Float {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 {
            let aNegative = a.sign == .minus, bNegative = b.sign == .minus
            return max ? (aNegative && bNegative ? -0.0 : 0.0) : (aNegative || bNegative ? -0.0 : 0.0)
        }
        return max ? Swift.max(a, b) : Swift.min(a, b)
    }

    /// `UnsignedRecipEstimate`/`FPRecipEstimate` (ARM DDI 0406C A2.8.2 and
    /// its pseudocode `RecipEstimate`): an 8-bit-accurate estimate.
    private static func recipEstimate(_ a: Double) -> Double {
        let q = (a * 512).rounded(.down)
        let r = 1.0 / ((q + 0.5) / 512.0)
        let s = (r * 256.0 + 0.5).rounded(.down)
        return s / 256.0
    }

    private static func recipSqrtEstimate(_ a: Double) -> Double {
        let q: Double, r: Double
        if a < 0.5 {
            q = (a * 512).rounded(.down)
            r = 1.0 / ((q + 0.5) / 512.0).squareRoot()
        } else {
            q = (a * 256).rounded(.down)
            r = 1.0 / ((q + 0.5) / 256.0).squareRoot()
        }
        let s = (r * 256.0 + 0.5).rounded(.down)
        return s / 256.0
    }

    private static func floatReciprocalEstimate(_ bits: UInt64) -> UInt64 {
        let value = neonFloat(bits)
        if value.isNaN { return 0x7FC0_0000 }
        if value.isInfinite { return value.sign == .minus ? 0x8000_0000 : 0 }
        if value == 0 { return value.sign == .minus ? 0xFF80_0000 : 0x7F80_0000 }
        let raw = UInt32(truncatingIfNeeded: bits)
        let exponent = Int(raw >> 23 & 0xFF)
        if exponent >= 253 { return UInt64(raw & 0x8000_0000) } // result underflows to zero (flushed)
        // Scale into [0.5, 1): fraction with exponent 126.
        let scaled = Double(Float(bitPattern: (raw & 0x7F_FFFF) | 0x3F00_0000))
        // The estimate is in [1, 2): its fraction bits carry over as is.
        let estimateBits = Float(recipEstimate(scaled)).bitPattern
        return UInt64((raw & 0x8000_0000) | UInt32(253 - exponent) << 23 | (estimateBits & 0x7F_FFFF))
    }

    private static func floatReciprocalSquareRootEstimate(_ bits: UInt64) -> UInt64 {
        let value = neonFloat(bits)
        if value.isNaN || (value < 0 && value != 0) { return 0x7FC0_0000 }
        if value == 0 { return value.sign == .minus ? 0xFF80_0000 : 0x7F80_0000 }
        if value.isInfinite { return 0 }
        let raw = UInt32(truncatingIfNeeded: bits)
        let exponent = Int(raw >> 23 & 0xFF)
        // Scale into [0.25, 1), keeping the exponent's parity: an even
        // exponent maps to [0.5, 1), an odd one to [0.25, 0.5).
        let scaledExponent: UInt32 = exponent & 1 == 0 ? 126 : 125
        let scaled = Double(Float(bitPattern: (raw & 0x7F_FFFF) | scaledExponent << 23))
        let estimateBits = Float(recipSqrtEstimate(scaled)).bitPattern
        return UInt64(UInt32((380 - exponent) / 2) << 23 | (estimateBits & 0x7F_FFFF))
    }

    // MARK: - Data processing

    func executeNEON(_ instr: NEONInstruction) {
        switch instr.operation {
        case .same(let op): executeSameLength(op, instr)
        case .long(let op): executeLong(op, instr)
        case .wide(let op): executeWide(op, instr)
        case .narrowHigh(let op): executeNarrowHigh(op, instr)
        case .byScalar(let op, let index): executeByScalar(op, index: index, instr)
        case .shift(let op, let amount): executeShift(op, amount: amount, instr)
        case .misc(let op): executeMisc(op, instr)
        case .tableLookup(let extends, let length): executeTableLookup(extends: extends, length: length, instr)
        case .duplicateScalar(let index):
            let scalar = elements(instr.m, registers: 1, esize: instr.esize)[index]
            let registers = instr.isQuad ? 2 : 1
            setElements(instr.d, [UInt64](repeating: scalar, count: registers * 64 / instr.esize), esize: instr.esize)
        }
    }

    private func executeSameLength(_ op: NEONInstruction.SameLengthOperation, _ instr: NEONInstruction) {
        let registers = instr.isQuad ? 2 : 1
        let esize = instr.esize
        let a = elements(instr.n, registers: registers, esize: esize)
        let b = elements(instr.m, registers: registers, esize: esize)
        let old = elements(instr.d, registers: registers, esize: esize)
        let m = Self.mask(esize)
        let unsigned = instr.unsigned
        let ones = m
        func ext(_ v: UInt64) -> Int64 { unsigned ? Int64(bitPattern: v) : Self.signed(v, esize) }
        func less(_ x: UInt64, _ y: UInt64) -> Bool { unsigned ? x < y : Self.signed(x, esize) < Self.signed(y, esize) }
        var out = [UInt64](repeating: 0, count: a.count)

        func pairwise(_ f: (UInt64, UInt64) -> UInt64) {
            let half = a.count / 2
            for i in 0..<half {
                out[i] = f(a[2 * i], a[2 * i + 1])
                out[half + i] = f(b[2 * i], b[2 * i + 1])
            }
        }
        func float(_ f: (Float, Float, Float) -> Float) {
            for i in 0..<a.count { out[i] = Self.neonBits(f(Self.neonFloat(a[i]), Self.neonFloat(b[i]), Self.neonFloat(old[i]))) }
        }
        func floatCompare(_ f: (Float, Float) -> Bool) {
            for i in 0..<a.count { out[i] = f(Self.neonFloat(a[i]), Self.neonFloat(b[i])) ? ones : 0 }
        }

        switch op {
        case .halvingAdd:
            for i in 0..<a.count { out[i] = UInt64(bitPattern: (ext(a[i]) + ext(b[i])) >> 1) & m }
        case .roundingHalvingAdd:
            for i in 0..<a.count { out[i] = UInt64(bitPattern: (ext(a[i]) + ext(b[i]) + 1) >> 1) & m }
        case .halvingSubtract:
            for i in 0..<a.count { out[i] = UInt64(bitPattern: (ext(a[i]) - ext(b[i])) >> 1) & m }
        case .saturatingAdd, .saturatingSubtract:
            for i in 0..<a.count { out[i] = saturatingAdd(a[i], b[i], esize, unsigned: unsigned, subtract: op == .saturatingSubtract) }
        case .compareGreater:
            for i in 0..<a.count { out[i] = less(b[i], a[i]) ? ones : 0 }
        case .compareGreaterOrEqual:
            for i in 0..<a.count { out[i] = !less(a[i], b[i]) ? ones : 0 }
        case .shiftLeft, .roundingShiftLeft, .saturatingShiftLeft, .saturatingRoundingShiftLeft:
            // VSHL Dd, Dm, Dn: Dm shifted by Dn.
            let rounding = op == .roundingShiftLeft || op == .saturatingRoundingShiftLeft
            let saturating = op == .saturatingShiftLeft || op == .saturatingRoundingShiftLeft
            for i in 0..<a.count {
                out[i] = saturating && rounding
                    ? saturatingRoundingShift(b[i], by: a[i], esize, unsigned: unsigned)
                    : shiftByRegister(b[i], by: a[i], esize, unsigned: unsigned, rounding: rounding, saturating: saturating)
            }
        case .maximum:
            for i in 0..<a.count { out[i] = less(a[i], b[i]) ? b[i] : a[i] }
        case .minimum:
            for i in 0..<a.count { out[i] = less(a[i], b[i]) ? a[i] : b[i] }
        case .absoluteDifference, .absoluteDifferenceAccumulate:
            for i in 0..<a.count {
                let difference = UInt64(bitPattern: abs(ext(a[i]) - ext(b[i]))) & m
                out[i] = op == .absoluteDifferenceAccumulate ? (old[i] &+ difference) & m : difference
            }
        case .add:
            for i in 0..<a.count { out[i] = (a[i] &+ b[i]) & m }
        case .subtract:
            for i in 0..<a.count { out[i] = (a[i] &- b[i]) & m }
        case .test:
            for i in 0..<a.count { out[i] = a[i] & b[i] != 0 ? ones : 0 }
        case .compareEqual:
            for i in 0..<a.count { out[i] = a[i] == b[i] ? ones : 0 }
        case .multiply:
            for i in 0..<a.count { out[i] = (a[i] &* b[i]) & m }
        case .multiplyAccumulate:
            for i in 0..<a.count { out[i] = (old[i] &+ a[i] &* b[i]) & m }
        case .multiplySubtract:
            for i in 0..<a.count { out[i] = (old[i] &- a[i] &* b[i]) & m }
        case .polynomialMultiply:
            for i in 0..<a.count { out[i] = Self.polynomialMultiply(a[i], b[i], esize) & m }
        case .pairwiseMaximum:
            pairwise { less($0, $1) ? $1 : $0 }
        case .pairwiseMinimum:
            pairwise { less($0, $1) ? $0 : $1 }
        case .pairwiseAdd:
            pairwise { ($0 &+ $1) & m }
        case .saturatingDoublingMultiplyHigh, .saturatingRoundingDoublingMultiplyHigh:
            for i in 0..<a.count {
                out[i] = doublingMultiplyHigh(a[i], b[i], esize, rounding: op == .saturatingRoundingDoublingMultiplyHigh)
            }
        case .and: for i in 0..<a.count { out[i] = a[i] & b[i] }
        case .bitClear: for i in 0..<a.count { out[i] = a[i] & ~b[i] }
        case .or: for i in 0..<a.count { out[i] = a[i] | b[i] }
        case .orNot: for i in 0..<a.count { out[i] = a[i] | ~b[i] }
        case .exclusiveOr: for i in 0..<a.count { out[i] = a[i] ^ b[i] }
        case .bitwiseSelect: for i in 0..<a.count { out[i] = (old[i] & a[i]) | (~old[i] & b[i]) }
        case .bitwiseInsertIfTrue: for i in 0..<a.count { out[i] = (a[i] & b[i]) | (old[i] & ~b[i]) }
        case .bitwiseInsertIfFalse: for i in 0..<a.count { out[i] = (old[i] & b[i]) | (a[i] & ~b[i]) }
        case .floatAdd: float { x, y, _ in x + y }
        case .floatSubtract: float { x, y, _ in x - y }
        case .floatAbsoluteDifference: float { x, y, _ in abs(x - y) }
        case .floatMultiply: float { x, y, _ in x * y }
        case .floatMultiplyAccumulate: float { x, y, acc in acc + Self.neonFloat(Self.neonBits(x * y)) }
        case .floatMultiplySubtract: float { x, y, acc in acc - Self.neonFloat(Self.neonBits(x * y)) }
        case .floatPairwiseAdd:
            pairwise { Self.neonBits(Self.neonFloat($0) + Self.neonFloat($1)) }
        case .floatCompareEqual: floatCompare { $0 == $1 }
        case .floatCompareGreaterOrEqual: floatCompare { $0 >= $1 }
        case .floatCompareGreater: floatCompare { $0 > $1 }
        case .floatAbsoluteCompareGreaterOrEqual: floatCompare { abs($0) >= abs($1) }
        case .floatAbsoluteCompareGreater: floatCompare { abs($0) > abs($1) }
        case .floatMaximum: float { x, y, _ in Self.floatMaxMin(x, y, max: true) }
        case .floatMinimum: float { x, y, _ in Self.floatMaxMin(x, y, max: false) }
        case .floatPairwiseMaximum:
            pairwise { Self.neonBits(Self.floatMaxMin(Self.neonFloat($0), Self.neonFloat($1), max: true)) }
        case .floatPairwiseMinimum:
            pairwise { Self.neonBits(Self.floatMaxMin(Self.neonFloat($0), Self.neonFloat($1), max: false)) }
        case .floatReciprocalStep:
            float { x, y, _ in
                // 2 - x*y, with inf*0 giving exactly 2.
                if (x.isInfinite && y == 0) || (x == 0 && y.isInfinite) { return 2 }
                return 2 - Self.neonFloat(Self.neonBits(x * y))
            }
        case .floatReciprocalSquareRootStep:
            float { x, y, _ in
                if (x.isInfinite && y == 0) || (x == 0 && y.isInfinite) { return 1.5 }
                return (3 - Self.neonFloat(Self.neonBits(x * y))) / 2
            }
        }
        setElements(instr.d, out, esize: esize)
    }

    /// `VQRSHL`: rounding and saturating.
    private func saturatingRoundingShift(_ value: UInt64, by shiftElement: UInt64, _ esize: Int, unsigned: Bool) -> UInt64 {
        let shift = Int(Int8(truncatingIfNeeded: shiftElement))
        if shift >= 0 {
            return shiftByRegister(value, by: shiftElement, esize, unsigned: unsigned, rounding: false, saturating: true)
        }
        return shiftByRegister(value, by: shiftElement, esize, unsigned: unsigned, rounding: true, saturating: false)
    }

    /// `VQDMULH`/`VQRDMULH`: the high half of `2*a*b` (with rounding),
    /// saturating the one overflow case (`a == b == minimum`).
    private func doublingMultiplyHigh(_ a: UInt64, _ b: UInt64, _ esize: Int, rounding: Bool) -> UInt64 {
        let x = Self.signed(a, esize), y = Self.signed(b, esize)
        let minimum = -(Int64(1) << Int64(esize - 1))
        if x == minimum && y == minimum {
            noteSaturation()
            return Self.mask(esize) >> 1
        }
        // |x*y| < 2^62 for esize <= 32, so 2*x*y + round fits.
        var product = 2 * x * y
        if rounding { product += Int64(1) << Int64(esize - 1) }
        return UInt64(bitPattern: product >> Int64(esize)) & Self.mask(esize)
    }

    private static func polynomialMultiply(_ a: UInt64, _ b: UInt64, _ esize: Int) -> UInt64 {
        var result: UInt64 = 0
        for bit in 0..<esize where (b >> UInt64(bit)) & 1 == 1 {
            result ^= a << UInt64(bit)
        }
        return result
    }

    private func executeLong(_ op: NEONInstruction.LongOperation, _ instr: NEONInstruction) {
        let esize = instr.esize, wide = 2 * esize
        let a = elements(instr.n, registers: 1, esize: esize)
        let b = elements(instr.m, registers: 1, esize: esize)
        let old = elements(instr.d, registers: 2, esize: wide)
        let m = Self.mask(wide)
        let unsigned = instr.unsigned
        func ext(_ v: UInt64) -> Int64 { unsigned ? Int64(v) : Self.signed(v, esize) }
        var out = [UInt64](repeating: 0, count: a.count)
        for i in 0..<a.count {
            let x = ext(a[i]), y = ext(b[i])
            switch op {
            case .add: out[i] = UInt64(bitPattern: x &+ y) & m
            case .subtract: out[i] = UInt64(bitPattern: x &- y) & m
            case .absoluteDifference: out[i] = UInt64(bitPattern: abs(x - y)) & m
            case .absoluteDifferenceAccumulate: out[i] = (old[i] &+ UInt64(bitPattern: abs(x - y))) & m
            case .multiply: out[i] = UInt64(bitPattern: x &* y) & m
            case .multiplyAccumulate: out[i] = (old[i] &+ UInt64(bitPattern: x &* y)) & m
            case .multiplySubtract: out[i] = (old[i] &- UInt64(bitPattern: x &* y)) & m
            case .polynomialMultiply: out[i] = Self.polynomialMultiply(a[i], b[i], esize) & m
            case .saturatingDoublingMultiply, .saturatingDoublingMultiplyAccumulate, .saturatingDoublingMultiplySubtract:
                let product = saturatingDoubledProduct(x, y, wide)
                switch op {
                case .saturatingDoublingMultiply: out[i] = product
                case .saturatingDoublingMultiplyAccumulate: out[i] = saturatingAdd(old[i], product, wide, unsigned: false, subtract: false)
                default: out[i] = saturatingAdd(old[i], product, wide, unsigned: false, subtract: true)
                }
            }
        }
        setElements(instr.d, out, esize: wide)
    }

    /// `2*x*y` saturated to `bits` (the one overflow is minimum * minimum).
    private func saturatingDoubledProduct(_ x: Int64, _ y: Int64, _ bits: Int) -> UInt64 {
        let (product, overflow1) = x.multipliedReportingOverflow(by: y)
        let (doubled, overflow2) = product.multipliedReportingOverflow(by: 2)
        if overflow1 || overflow2 { noteSaturation(); return Self.mask(bits) >> 1 }
        return saturate(doubled, bits, unsigned: false)
    }

    private func executeWide(_ op: NEONInstruction.WideOperation, _ instr: NEONInstruction) {
        let esize = instr.esize, wide = 2 * esize
        let a = elements(instr.n, registers: 2, esize: wide)
        let b = elements(instr.m, registers: 1, esize: esize)
        let m = Self.mask(wide)
        var out = [UInt64](repeating: 0, count: a.count)
        for i in 0..<a.count {
            let y = UInt64(bitPattern: instr.unsigned ? Int64(b[i]) : Self.signed(b[i], esize))
            out[i] = (op == .add ? a[i] &+ y : a[i] &- y) & m
        }
        setElements(instr.d, out, esize: wide)
    }

    private func executeNarrowHigh(_ op: NEONInstruction.NarrowHighOperation, _ instr: NEONInstruction) {
        let esize = instr.esize, wide = 2 * esize
        let a = elements(instr.n, registers: 2, esize: wide)
        let b = elements(instr.m, registers: 2, esize: wide)
        let round: UInt64 = op == .roundingAdd || op == .roundingSubtract ? 1 << UInt64(esize - 1) : 0
        var out = [UInt64](repeating: 0, count: a.count)
        for i in 0..<a.count {
            let result = op == .add || op == .roundingAdd ? a[i] &+ b[i] : a[i] &- b[i]
            out[i] = ((result &+ round) & Self.mask(wide)) >> UInt64(esize)
        }
        setElements(instr.d, out, esize: esize)
    }

    private func executeByScalar(_ op: NEONInstruction.ByScalarOperation, index: Int, _ instr: NEONInstruction) {
        let esize = instr.esize
        let scalar = elements(instr.m, registers: 1, esize: esize)[index]
        let m = Self.mask(esize)
        switch op {
        case .multiplyAccumulate, .multiplySubtract, .multiply,
             .floatMultiplyAccumulate, .floatMultiplySubtract, .floatMultiply,
             .saturatingDoublingMultiplyHigh, .saturatingRoundingDoublingMultiplyHigh:
            let registers = instr.isQuad ? 2 : 1
            let a = elements(instr.n, registers: registers, esize: esize)
            let old = elements(instr.d, registers: registers, esize: esize)
            var out = [UInt64](repeating: 0, count: a.count)
            let s = Self.neonFloat(scalar)
            for i in 0..<a.count {
                switch op {
                case .multiply: out[i] = (a[i] &* scalar) & m
                case .multiplyAccumulate: out[i] = (old[i] &+ a[i] &* scalar) & m
                case .multiplySubtract: out[i] = (old[i] &- a[i] &* scalar) & m
                case .floatMultiply: out[i] = Self.neonBits(Self.neonFloat(a[i]) * s)
                case .floatMultiplyAccumulate:
                    out[i] = Self.neonBits(Self.neonFloat(old[i]) + Self.neonFloat(Self.neonBits(Self.neonFloat(a[i]) * s)))
                case .floatMultiplySubtract:
                    out[i] = Self.neonBits(Self.neonFloat(old[i]) - Self.neonFloat(Self.neonBits(Self.neonFloat(a[i]) * s)))
                default:
                    out[i] = doublingMultiplyHigh(a[i], scalar, esize, rounding: op == .saturatingRoundingDoublingMultiplyHigh)
                }
            }
            setElements(instr.d, out, esize: esize)
        default:
            let wide = 2 * esize
            let a = elements(instr.n, registers: 1, esize: esize)
            let old = elements(instr.d, registers: 2, esize: wide)
            let unsigned = instr.unsigned
            func ext(_ v: UInt64) -> Int64 { unsigned ? Int64(v) : Self.signed(v, esize) }
            let y = ext(scalar)
            let wm = Self.mask(wide)
            var out = [UInt64](repeating: 0, count: a.count)
            for i in 0..<a.count {
                let product = ext(a[i]) &* y
                switch op {
                case .multiplyLong: out[i] = UInt64(bitPattern: product) & wm
                case .multiplyAccumulateLong: out[i] = (old[i] &+ UInt64(bitPattern: product)) & wm
                case .multiplySubtractLong: out[i] = (old[i] &- UInt64(bitPattern: product)) & wm
                case .saturatingDoublingMultiplyLong: out[i] = saturatingDoubledProduct(ext(a[i]), y, wide)
                case .saturatingDoublingMultiplyAccumulateLong:
                    out[i] = saturatingAdd(old[i], saturatingDoubledProduct(ext(a[i]), y, wide), wide, unsigned: false, subtract: false)
                default:
                    out[i] = saturatingAdd(old[i], saturatingDoubledProduct(ext(a[i]), y, wide), wide, unsigned: false, subtract: true)
                }
            }
            setElements(instr.d, out, esize: wide)
        }
    }

    private func executeShift(_ op: NEONInstruction.ShiftOperation, amount: Int, _ instr: NEONInstruction) {
        let esize = instr.esize
        let unsigned = instr.unsigned
        switch op {
        case .shiftRightNarrow, .roundingShiftRightNarrow, .saturatingShiftRightNarrow, .saturatingRoundingShiftRightNarrow,
             .saturatingShiftRightUnsignedNarrow, .saturatingRoundingShiftRightUnsignedNarrow:
            let wide = 2 * esize
            let source = elements(instr.m, registers: 2, esize: wide)
            let rounding = op == .roundingShiftRightNarrow || op == .saturatingRoundingShiftRightNarrow || op == .saturatingRoundingShiftRightUnsignedNarrow
            // The unsigned-result forms take signed input; VQSHRN.U takes unsigned.
            let signedInput = op == .saturatingShiftRightUnsignedNarrow || op == .saturatingRoundingShiftRightUnsignedNarrow || !unsigned
            var out = [UInt64](repeating: 0, count: source.count)
            for i in 0..<source.count {
                let value: Int64
                if signedInput {
                    let x = Self.signed(source[i], wide)
                    value = rounding ? (x >> Int64(amount - 1) &+ 1) >> 1 : x >> Int64(amount)
                } else {
                    let x = source[i]
                    value = Int64(bitPattern: rounding ? ((x >> UInt64(amount - 1)) &+ 1) >> 1 : x >> UInt64(amount))
                }
                switch op {
                case .shiftRightNarrow, .roundingShiftRightNarrow:
                    out[i] = UInt64(bitPattern: value) & Self.mask(esize)
                case .saturatingShiftRightUnsignedNarrow, .saturatingRoundingShiftRightUnsignedNarrow:
                    out[i] = saturate(value, esize, unsigned: true)
                default:
                    out[i] = saturate(value, esize, unsigned: unsigned)
                }
            }
            setElements(instr.d, out, esize: esize)
            return
        case .shiftLeftLong:
            let wide = 2 * esize
            let source = elements(instr.m, registers: 1, esize: esize)
            let out = source.map { value -> UInt64 in
                let extended = unsigned ? value : UInt64(bitPattern: Self.signed(value, esize))
                return (extended << UInt64(amount)) & Self.mask(wide)
            }
            setElements(instr.d, out, esize: wide)
            return
        default:
            break
        }

        let registers = instr.isQuad ? 2 : 1
        let source = elements(instr.m, registers: registers, esize: esize)
        let old = elements(instr.d, registers: registers, esize: esize)
        let m = Self.mask(esize)
        var out = [UInt64](repeating: 0, count: source.count)
        for i in 0..<source.count {
            let x = source[i]
            switch op {
            case .shiftRight, .shiftRightAccumulate, .roundingShiftRight, .roundingShiftRightAccumulate:
                let rounding = op == .roundingShiftRight || op == .roundingShiftRightAccumulate
                let shifted = shiftByRegister(x, by: UInt64(bitPattern: Int64(-amount)), esize, unsigned: unsigned, rounding: rounding, saturating: false)
                out[i] = op == .shiftRightAccumulate || op == .roundingShiftRightAccumulate ? (old[i] &+ shifted) & m : shifted
            case .shiftRightInsert:
                let insertMask = amount >= esize ? 0 : m >> UInt64(amount)
                out[i] = (old[i] & ~insertMask & m) | (amount >= esize ? 0 : x >> UInt64(amount))
            case .shiftLeft:
                out[i] = amount >= esize ? 0 : (x << UInt64(amount)) & m
            case .shiftLeftInsert:
                let insertMask = (m << UInt64(amount)) & m
                out[i] = (old[i] & ~insertMask & m) | ((x << UInt64(amount)) & m)
            case .saturatingShiftLeft:
                out[i] = shiftByRegister(x, by: UInt64(amount), esize, unsigned: unsigned, rounding: false, saturating: true)
            case .saturatingShiftLeftUnsigned:
                // Signed input, unsigned saturated result.
                let value = Self.signed(x, esize)
                if value < 0 {
                    noteSaturation()
                    out[i] = 0
                } else {
                    out[i] = shiftByRegister(UInt64(value), by: UInt64(amount), esize, unsigned: true, rounding: false, saturating: true)
                }
            default:
                break
            }
        }
        setElements(instr.d, out, esize: esize)
    }

    private func executeMisc(_ op: NEONInstruction.MiscOperation, _ instr: NEONInstruction) {
        let esize = instr.esize
        let registers = instr.isQuad ? 2 : 1
        let m = Self.mask(esize)
        let unsigned = instr.unsigned

        switch op {
        case .swap:
            for r in 0..<registers {
                let t = neon[instr.d + r]
                neon[instr.d + r] = neon[instr.m + r]
                neon[instr.m + r] = t
            }
            return
        case .transpose:
            var x = elements(instr.d, registers: registers, esize: esize)
            var y = elements(instr.m, registers: registers, esize: esize)
            for e in stride(from: 0, to: x.count, by: 2) {
                let t = x[e + 1]
                x[e + 1] = y[e]
                y[e] = t
            }
            setElements(instr.d, x, esize: esize)
            setElements(instr.m, y, esize: esize)
            return
        case .unzip, .zip:
            let x = elements(instr.d, registers: registers, esize: esize)
            let y = elements(instr.m, registers: registers, esize: esize)
            let count = x.count
            var newX = [UInt64](repeating: 0, count: count), newY = newX
            if op == .unzip {
                let joined = x + y
                for e in 0..<count {
                    newX[e] = joined[2 * e]
                    newY[e] = joined[2 * e + 1]
                }
            } else {
                var interleaved: [UInt64] = []
                for e in 0..<count { interleaved.append(x[e]); interleaved.append(y[e]) }
                newX = Array(interleaved[0..<count])
                newY = Array(interleaved[count..<2 * count])
            }
            setElements(instr.d, newX, esize: esize)
            setElements(instr.m, newY, esize: esize)
            return
        case .moveNarrow, .saturatingMoveNarrow, .saturatingMoveUnsignedNarrow:
            let wide = 2 * esize
            let source = elements(instr.m, registers: 2, esize: wide)
            let out = source.map { value -> UInt64 in
                switch op {
                case .moveNarrow: return value & m
                case .saturatingMoveUnsignedNarrow: return saturate(Self.signed(value, wide), esize, unsigned: true)
                default:
                    guard unsigned else { return saturate(Self.signed(value, wide), esize, unsigned: false) }
                    if value > m { noteSaturation(); return m }
                    return value
                }
            }
            setElements(instr.d, out, esize: esize)
            return
        case .shiftLeftLongByElementSize:
            let wide = 2 * esize
            let out = elements(instr.m, registers: 1, esize: esize).map { ($0 << UInt64(esize)) & Self.mask(wide) }
            setElements(instr.d, out, esize: wide)
            return
        case .pairwiseAddLong, .pairwiseAddAccumulateLong:
            let wide = 2 * esize
            let source = elements(instr.m, registers: registers, esize: esize)
            var out = elements(instr.d, registers: registers, esize: wide)
            for i in 0..<out.count {
                let x = unsigned ? Int64(source[2 * i]) : Self.signed(source[2 * i], esize)
                let y = unsigned ? Int64(source[2 * i + 1]) : Self.signed(source[2 * i + 1], esize)
                let sum = UInt64(bitPattern: x + y)
                out[i] = (op == .pairwiseAddAccumulateLong ? out[i] &+ sum : sum) & Self.mask(wide)
            }
            setElements(instr.d, out, esize: wide)
            return
        default:
            break
        }

        let source = elements(instr.m, registers: registers, esize: esize)
        var out = [UInt64](repeating: 0, count: source.count)
        for i in 0..<source.count {
            let x = source[i]
            let s = Self.signed(x, esize)
            let f = Self.neonFloat(x)
            switch op {
            case .reverse64, .reverse32, .reverse16:
                let group = op == .reverse64 ? 64 : op == .reverse32 ? 32 : 16
                let perGroup = group / esize
                let groupStart = (i / perGroup) * perGroup
                out[i] = source[groupStart + perGroup - 1 - (i - groupStart)]
            case .countLeadingSignBits:
                let shifted = x << UInt64(64 - esize)
                let value = Int64(bitPattern: shifted) >= 0 ? shifted : ~shifted
                out[i] = UInt64(Swift.min(value.leadingZeroBitCount, esize) - 1)
            case .countLeadingZeros:
                out[i] = UInt64(x == 0 ? esize : x.leadingZeroBitCount - (64 - esize))
            case .countOnes:
                out[i] = UInt64(x.nonzeroBitCount)
            case .not:
                out[i] = ~x & m
            case .saturatingAbsolute:
                out[i] = saturate(abs(s), esize, unsigned: false)
            case .saturatingNegate:
                out[i] = saturate(-s, esize, unsigned: false)
            case .compareGreaterThanZero(let float): out[i] = (float ? f > 0 : s > 0) ? m : 0
            case .compareGreaterOrEqualZero(let float): out[i] = (float ? f >= 0 : s >= 0) ? m : 0
            case .compareEqualZero(let float): out[i] = (float ? f == 0 : s == 0) ? m : 0
            case .compareLessOrEqualZero(let float): out[i] = (float ? f <= 0 : s <= 0) ? m : 0
            case .compareLessThanZero(let float): out[i] = (float ? f < 0 : s < 0) ? m : 0
            case .absolute(let float):
                out[i] = float ? x & 0x7FFF_FFFF : UInt64(bitPattern: s < 0 ? 0 &- s : s) & m
            case .negate(let float):
                out[i] = float ? x ^ 0x8000_0000 : UInt64(bitPattern: 0 &- s) & m
            case .reciprocalEstimate(let float):
                if float {
                    out[i] = Self.floatReciprocalEstimate(x)
                } else if x & 0x8000_0000 == 0 {
                    out[i] = 0xFFFF_FFFF
                } else {
                    let estimate = Self.recipEstimate(Double(x >> 23) / 512)
                    out[i] = UInt64(estimate * 256).clampedToUInt32 << 23 & 0xFFFF_FFFF
                }
            case .reciprocalSquareRootEstimate(let float):
                if float {
                    out[i] = Self.floatReciprocalSquareRootEstimate(x)
                } else if x & 0xC000_0000 == 0 {
                    out[i] = 0xFFFF_FFFF
                } else {
                    let estimate = Self.recipSqrtEstimate(Double(x >> 23) / 512)
                    out[i] = UInt64(estimate * 256).clampedToUInt32 << 23 & 0xFFFF_FFFF
                }
            case .convertToFloat:
                let value: Float = unsigned ? Float(UInt32(truncatingIfNeeded: x)) : Float(Int32(truncatingIfNeeded: x))
                out[i] = Self.neonBits(value)
            case .convertFromFloat:
                if f.isNaN {
                    out[i] = 0
                } else if unsigned {
                    out[i] = f <= 0 ? 0 : f >= 4_294_967_296 ? 0xFFFF_FFFF : UInt64(UInt32(f))
                } else {
                    out[i] = f >= 2_147_483_648 ? 0x7FFF_FFFF : f < -2_147_483_648 ? 0x8000_0000 : UInt64(UInt32(bitPattern: Int32(f)))
                }
            default:
                break
            }
        }
        setElements(instr.d, out, esize: esize)
    }

    private func executeTableLookup(extends: Bool, length: Int, _ instr: NEONInstruction) {
        let table = elements(instr.n, registers: length, esize: 8)
        let indices = elements(instr.m, registers: 1, esize: 8)
        let old = elements(instr.d, registers: 1, esize: 8)
        var out = [UInt64](repeating: 0, count: 8)
        for i in 0..<8 {
            let index = Int(indices[i])
            out[i] = index < table.count ? table[index] : (extends ? old[i] : 0)
        }
        setElements(instr.d, out, esize: 8)
    }

    // MARK: - Element and structure loads/stores

    func executeNEONStructureLoadStore(_ instr: NEONStructureLoadStoreInstruction) {
        let base = registers[instr.rn]
        let ebytes = instr.esize / 8
        var address = base
        var transferred = 0

        func loadElement(_ at: UInt32) throws -> UInt64 {
            var value: UInt64 = 0
            for byte in 0..<ebytes {
                value |= UInt64(try memory.readByte(at: try translatedAddress(at &+ UInt32(byte), access: .read))) << UInt64(byte * 8)
            }
            return value
        }
        func storeElement(_ value: UInt64, at: UInt32) throws {
            for byte in 0..<ebytes {
                try memory.writeByte(UInt8(truncatingIfNeeded: value >> UInt64(byte * 8)), at: try translatedAddress(at &+ UInt32(byte), access: .write))
            }
        }
        func setLane(_ register: Int, _ lane: Int, _ value: UInt64) {
            let shift = UInt64(lane * instr.esize)
            let m = Self.mask(instr.esize) << shift
            neon[register & 31] = (neon[register & 31] & ~m) | ((value << shift) & m)
        }
        func lane(_ register: Int, _ lane: Int) -> UInt64 {
            (neon[register & 31] >> UInt64(lane * instr.esize)) & Self.mask(instr.esize)
        }

        do {
            switch instr.form {
            case .multiple(let registerGroups, let spacing):
                let lanes = 64 / instr.esize
                for r in 0..<registerGroups {
                    for e in 0..<lanes {
                        for k in 0..<instr.elements {
                            let register = instr.d + r + k * spacing
                            if instr.isLoad {
                                setLane(register, e, try loadElement(address))
                            } else {
                                try storeElement(lane(register, e), at: address)
                            }
                            address = address &+ UInt32(ebytes)
                            transferred += ebytes
                        }
                    }
                }
            case .singleLane(let index, let spacing):
                for k in 0..<instr.elements {
                    let register = instr.d + k * spacing
                    if instr.isLoad {
                        setLane(register, index, try loadElement(address))
                    } else {
                        try storeElement(lane(register, index), at: address)
                    }
                    address = address &+ UInt32(ebytes)
                    transferred += ebytes
                }
            case .allLanes(let spacing, let registerCount):
                let lanes = 64 / instr.esize
                for k in 0..<instr.elements {
                    let value = try loadElement(address)
                    var replicated: UInt64 = 0
                    for e in 0..<lanes { replicated |= value << UInt64(e * instr.esize) }
                    for r in 0..<registerCount {
                        neon[(instr.d + k * spacing + r) & 31] = replicated
                    }
                    address = address &+ UInt32(ebytes)
                    transferred += ebytes
                }
            }
        } catch {
            let memoryError = error as? MemoryAccessError ?? .unmappedAddress(address)
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
            return
        }

        switch instr.rm {
        case 15: break
        case 13: registers[instr.rn] = base &+ UInt32(transferred)
        default: registers[instr.rn] = base &+ registers[instr.rm]
        }
    }
}

private extension UInt64 {
    var clampedToUInt32: UInt64 { Swift.min(self, 0xFFFF_FFFF) }
}
