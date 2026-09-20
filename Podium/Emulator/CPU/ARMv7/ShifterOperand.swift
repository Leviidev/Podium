import Foundation

enum ShiftType: UInt8 {
    case lsl = 0b00
    case lsr = 0b01
    case asr = 0b10
    case ror = 0b11
}

/// Operand2 of a data-processing instruction: describes *how* to get the
/// value without depending on register state, so decoding stays a pure
/// function. `resolve(registers:currentCarry:)` does the state-dependent
/// part at execute time.
enum ShifterOperand {
    /// Fully resolved at decode time — the 8-bit immediate rotated right
    /// by the encoded amount is independent of any register. Per the ARM
    /// ARM, a zero rotate leaves the carry flag unchanged (`forcedCarryOut
    /// == nil`); a nonzero rotate sets it to bit 31 of the result.
    case immediate(value: UInt32, forcedCarryOut: Bool?)
    /// A register shifted by an immediate amount. Register-specified
    /// shift amounts (the `Rs` form) share bit patterns with the
    /// multiply/extension instruction space and aren't decoded by this
    /// CPU slice yet.
    case shiftedRegister(rm: Int, shiftType: ShiftType, shiftAmount: UInt8)

    struct Resolved {
        let value: UInt32
        let carryOut: Bool
    }

    func resolve(registers: Registers, currentCarry: Bool) -> Resolved {
        switch self {
        case .immediate(let value, let forcedCarryOut):
            return Resolved(value: value, carryOut: forcedCarryOut ?? currentCarry)

        case .shiftedRegister(let rm, let shiftType, let shiftAmount):
            let value = (rm == Registers.pcIndex) ? registers.pcForOperandRead : registers[rm]
            return Self.applyShift(shiftType, to: value, amount: shiftAmount, currentCarry: currentCarry)
        }
    }

    static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        let amount = amount % 32
        guard amount != 0 else { return value }
        return (value >> amount) | (value << (32 - amount))
    }

    /// Not `private`: `ARMv7CPU+Thumb.swift`'s format-1 shift-by-
    /// immediate (`LSL`/`LSR`/`ASR Rd, Rm, #imm5`) uses the exact same
    /// immediate-shift conventions as ARM state (an encoded `LSR`/`ASR`
    /// `#0` means `#32`), so it reuses this directly rather than
    /// duplicating it.
    static func applyShift(_ type: ShiftType, to value: UInt32, amount: UInt8, currentCarry: Bool) -> Resolved {
        switch type {
        case .lsl:
            guard amount != 0 else {
                return Resolved(value: value, carryOut: currentCarry)
            }
            if amount >= 32 {
                let carryOut = amount == 32 && (value & 1 != 0)
                return Resolved(value: 0, carryOut: carryOut)
            }
            let carryOut = (value >> (32 - UInt32(amount))) & 1 != 0
            return Resolved(value: value << UInt32(amount), carryOut: carryOut)

        case .lsr:
            // An encoded shift_imm of 0 means LSR #32 (shift the whole register out).
            let effectiveAmount: UInt32 = amount == 0 ? 32 : UInt32(amount)
            if effectiveAmount >= 32 {
                let carryOut = effectiveAmount == 32 && (value & 0x8000_0000 != 0)
                return Resolved(value: 0, carryOut: carryOut)
            }
            let carryOut = (value >> (effectiveAmount - 1)) & 1 != 0
            return Resolved(value: value >> effectiveAmount, carryOut: carryOut)

        case .asr:
            let effectiveAmount: UInt32 = amount == 0 ? 32 : UInt32(amount)
            let signed = Int32(bitPattern: value)
            if effectiveAmount >= 32 {
                let allOnes = signed < 0
                return Resolved(value: allOnes ? 0xFFFF_FFFF : 0, carryOut: allOnes)
            }
            let carryOut = (value >> (effectiveAmount - 1)) & 1 != 0
            let shifted = signed >> effectiveAmount
            return Resolved(value: UInt32(bitPattern: shifted), carryOut: carryOut)

        case .ror:
            guard amount != 0 else {
                // An encoded shift_imm of 0 with ROR means RRX: rotate
                // right through the carry flag by exactly 1.
                let carryOut = value & 1 != 0
                let newValue = (value >> 1) | (currentCarry ? 0x8000_0000 : 0)
                return Resolved(value: newValue, carryOut: carryOut)
            }
            let rotated = rotateRight(value, by: UInt32(amount))
            return Resolved(value: rotated, carryOut: rotated & 0x8000_0000 != 0)
        }
    }
}
