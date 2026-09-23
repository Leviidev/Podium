import Foundation

/// Execution for `MediaInstruction` — see `MediaInstruction.swift`. The GE
/// flags are CPSR bits [19:16]; Q (sticky saturation) is bit 27.
extension ARMv7CPU {
    private static let geShift: UInt32 = 16
    private static let stickyOverflowBit: UInt32 = 1 << 27

    private func setStickyOverflow() {
        cpsr.rawValue |= Self.stickyOverflowBit
    }

    private func setGE(_ bits: UInt32) {
        cpsr.rawValue = (cpsr.rawValue & ~(0xF << Self.geShift)) | (bits & 0xF) << Self.geShift
    }

    /// Clamps to a signed or unsigned `bits`-bit range; true if clamped.
    private static func saturated(_ value: Int64, bits: Int, signed: Bool) -> (Int64, Bool) {
        if signed {
            let maximum = (Int64(1) << Int64(bits - 1)) - 1, minimum = -(Int64(1) << Int64(bits - 1))
            return value > maximum ? (maximum, true) : value < minimum ? (minimum, true) : (value, false)
        }
        let maximum = bits == 0 ? 0 : (Int64(1) << Int64(bits)) - 1
        return value > maximum ? (maximum, true) : value < 0 ? (0, true) : (value, false)
    }

    func executeMedia(_ instr: MediaInstruction) {
        let n = operandValue(for: instr.n)
        let m = operandValue(for: instr.m)
        var result: UInt32 = 0

        switch instr.operation {
        case .parallel(let op, let kind):
            result = parallel(op, kind, n, m)

        case .extend(let kind, let rotation, let accumulate):
            let rotated = rotation == 0 ? m : (m >> UInt32(rotation)) | (m << UInt32(32 - rotation))
            let base = accumulate ? n : 0
            switch kind {
            case .signedByte: result = base &+ UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: rotated)))
            case .signedHalfword: result = base &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: rotated)))
            case .unsignedByte: result = base &+ (rotated & 0xFF)
            case .unsignedHalfword: result = base &+ (rotated & 0xFFFF)
            case .signedBytePair, .unsignedBytePair:
                let signed = kind == .signedBytePair
                func half(_ byte: UInt32) -> UInt32 { signed ? UInt32(UInt16(bitPattern: Int16(Int8(truncatingIfNeeded: byte)))) : byte & 0xFF }
                let low = ((base & 0xFFFF) &+ half(rotated)) & 0xFFFF
                let high = ((base >> 16) &+ half(rotated >> 16)) & 0xFFFF
                result = high << 16 | low
            }

        case .packHalfword(let top, let shift):
            if top {
                let shifted = shift >= 32 ? UInt32(bitPattern: Int32(bitPattern: m) >> 31) : UInt32(bitPattern: Int32(bitPattern: m) >> Int32(shift))
                result = (n & 0xFFFF_0000) | (shifted & 0xFFFF)
            } else {
                result = (n & 0xFFFF) | ((m << UInt32(shift)) & 0xFFFF_0000)
            }

        case .saturate(let signed, let bits, let arithmeticRight, let shift):
            let operand = arithmeticRight
                ? Int64(Int32(bitPattern: n) >> Int32(Swift.min(shift, 31)))
                : Int64(Int32(bitPattern: n << UInt32(shift)))
            let (value, clamped) = Self.saturated(operand, bits: bits, signed: signed)
            if clamped { setStickyOverflow() }
            result = UInt32(truncatingIfNeeded: value)

        case .saturate16(let signed, let bits):
            var anyClamped = false
            func half(_ h: UInt32) -> UInt32 {
                let (value, clamped) = Self.saturated(Int64(Int16(truncatingIfNeeded: h)), bits: bits, signed: signed)
                anyClamped = anyClamped || clamped
                return UInt32(truncatingIfNeeded: value) & 0xFFFF
            }
            result = half(n >> 16) << 16 | half(n)
            if anyClamped { setStickyOverflow() }

        case .select:
            let ge = (cpsr.rawValue >> Self.geShift) & 0xF
            for byte in 0..<4 {
                let source = ge & (1 << UInt32(byte)) != 0 ? n : m
                result |= source & (0xFF << UInt32(byte * 8))
            }

        case .reverse16:
            result = ((n & 0x00FF_00FF) << 8) | ((n & 0xFF00_FF00) >> 8)
        case .reverseSignedHalfword:
            result = UInt32(bitPattern: Int32(Int16(bitPattern: UInt16((n & 0xFF) << 8 | (n >> 8) & 0xFF))))
        case .reverseBits:
            var value = n
            var reversed: UInt32 = 0
            for _ in 0..<32 { reversed = reversed << 1 | value & 1; value >>= 1 }
            result = reversed

        case .dualMultiply(let subtract, let exchange, let long):
            let operandM = exchange ? (m >> 16 | m << 16) : m
            let low = Int64(Int16(truncatingIfNeeded: n)) * Int64(Int16(truncatingIfNeeded: operandM))
            let high = Int64(Int16(truncatingIfNeeded: n >> 16)) * Int64(Int16(truncatingIfNeeded: operandM >> 16))
            let combined = subtract ? low - high : low + high
            if long {
                // SMLALD/SMLSLD: RdHi:RdLo += combined (64-bit wrap).
                let accumulator = Int64(bitPattern: UInt64(registers[instr.d]) << 32 | UInt64(registers[instr.a]))
                let sum = UInt64(bitPattern: accumulator &+ combined)
                registers[instr.a] = UInt32(truncatingIfNeeded: sum)
                registers[instr.d] = UInt32(truncatingIfNeeded: sum >> 32)
                return
            }
            let total = instr.a == 15 ? combined : combined + Int64(Int32(bitPattern: registers[instr.a]))
            if total != Int64(Int32(truncatingIfNeeded: total)) { setStickyOverflow() }
            result = UInt32(truncatingIfNeeded: total)

        case .mostSignificantMultiply(let subtract, let round):
            let product = Int64(Int32(bitPattern: n)) * Int64(Int32(bitPattern: m))
            var value: Int64
            if instr.a == 15 {
                value = product
            } else {
                let accumulator = Int64(Int32(bitPattern: registers[instr.a])) << 32
                value = subtract ? accumulator &- product : accumulator &+ product
            }
            if round { value = value &+ 0x8000_0000 }
            result = UInt32(truncatingIfNeeded: value >> 32)

        case .sumOfAbsoluteDifferences:
            var sum: UInt32 = instr.a == 15 ? 0 : registers[instr.a]
            for byte in 0..<4 {
                let x = Int((n >> UInt32(byte * 8)) & 0xFF), y = Int((m >> UInt32(byte * 8)) & 0xFF)
                sum = sum &+ UInt32(abs(x - y))
            }
            result = sum

        case .halfwordMultiply(let nTop, let mTop, let wide, let long):
            let y = Int64(Int16(truncatingIfNeeded: mTop ? m >> 16 : m))
            if wide {
                // SMLAWy/SMULWy: (n * y) >> 16, then optional accumulate.
                let product = (Int64(Int32(bitPattern: n)) * y) >> 16
                let total = instr.a == 15 ? product : product + Int64(Int32(bitPattern: registers[instr.a]))
                if total != Int64(Int32(truncatingIfNeeded: total)) { setStickyOverflow() }
                result = UInt32(truncatingIfNeeded: total)
            } else {
                let x = Int64(Int16(truncatingIfNeeded: nTop ? n >> 16 : n))
                let product = x * y
                if long {
                    let accumulator = Int64(bitPattern: UInt64(registers[instr.d]) << 32 | UInt64(registers[instr.a]))
                    let sum = UInt64(bitPattern: accumulator &+ product)
                    registers[instr.a] = UInt32(truncatingIfNeeded: sum)
                    registers[instr.d] = UInt32(truncatingIfNeeded: sum >> 32)
                    return
                }
                let total = instr.a == 15 ? product : product + Int64(Int32(bitPattern: registers[instr.a]))
                if total != Int64(Int32(truncatingIfNeeded: total)) { setStickyOverflow() }
                result = UInt32(truncatingIfNeeded: total)
            }

        case .saturatingAdd(let subtract, let doubling):
            var operandN = Int64(Int32(bitPattern: n))
            if doubling {
                let (doubled, clamped) = Self.saturated(operandN * 2, bits: 32, signed: true)
                if clamped { setStickyOverflow() }
                operandN = doubled
            }
            let raw = subtract ? Int64(Int32(bitPattern: m)) - operandN : Int64(Int32(bitPattern: m)) + operandN
            let (value, clamped) = Self.saturated(raw, bits: 32, signed: true)
            if clamped { setStickyOverflow() }
            result = UInt32(truncatingIfNeeded: value)

        case .signedBitFieldExtract(let lsb, let width):
            let shifted = n >> UInt32(lsb)
            result = width >= 32 ? shifted : UInt32(bitPattern: Int32(bitPattern: shifted << UInt32(32 - width)) >> Int32(32 - width))
        }
        registers[instr.d] = result
    }

    /// Parallel add/subtract on halfword or byte lanes (ARM DDI 0406C A8.8
    /// `SADD16`...`UHSUB8`).
    private func parallel(_ op: MediaInstruction.ParallelOperation, _ kind: MediaInstruction.ParallelKind, _ n: UInt32, _ m: UInt32) -> UInt32 {
        let signed = kind == .signed || kind == .saturating || kind == .halving
        let laneBits = op == .add8 || op == .subtract8 ? 8 : 16
        let lanes = 32 / laneBits
        let laneMask: UInt32 = laneBits == 8 ? 0xFF : 0xFFFF
        func lane(_ value: UInt32, _ i: Int) -> Int64 {
            let raw = (value >> UInt32(i * laneBits)) & laneMask
            return signed ? (laneBits == 8 ? Int64(Int8(truncatingIfNeeded: raw)) : Int64(Int16(truncatingIfNeeded: raw))) : Int64(raw)
        }
        var results = [Int64](repeating: 0, count: lanes)
        switch op {
        case .add16, .add8:
            for i in 0..<lanes { results[i] = lane(n, i) + lane(m, i) }
        case .subtract16, .subtract8:
            for i in 0..<lanes { results[i] = lane(n, i) - lane(m, i) }
        case .addSubtractExchange:
            results[0] = lane(n, 0) - lane(m, 1)
            results[1] = lane(n, 1) + lane(m, 0)
        case .subtractAddExchange:
            results[0] = lane(n, 0) + lane(m, 1)
            results[1] = lane(n, 1) - lane(m, 0)
        }
        var out: UInt32 = 0
        var ge: UInt32 = 0
        for i in 0..<lanes {
            var value = results[i]
            switch kind {
            case .saturating, .unsignedSaturating:
                value = Self.saturated(value, bits: laneBits, signed: kind == .saturating).0
            case .halving, .unsignedHalving:
                value >>= 1
            case .signed:
                if value >= 0 { ge |= laneBits == 8 ? 1 << UInt32(i) : 0b11 << UInt32(2 * i) }
            case .unsigned:
                // Add: carry out; subtract: no borrow.
                let isAdd: Bool
                switch op {
                case .add16, .add8: isAdd = true
                case .subtract16, .subtract8: isAdd = false
                case .addSubtractExchange: isAdd = i == 1
                case .subtractAddExchange: isAdd = i == 0
                }
                let flag = isAdd ? value >= Int64(laneMask) + 1 : value >= 0
                if flag { ge |= laneBits == 8 ? 1 << UInt32(i) : 0b11 << UInt32(2 * i) }
            }
            out |= (UInt32(truncatingIfNeeded: value) & laneMask) << UInt32(i * laneBits)
        }
        if kind == .signed || kind == .unsigned { setGE(ge) }
        return out
    }
}
