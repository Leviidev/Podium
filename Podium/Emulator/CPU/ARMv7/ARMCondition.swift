import Foundation

/// The 4-bit condition field every ARM (non-Thumb) instruction word
/// carries in bits [31:28]. Every ARM instruction is conditionally
/// executed — there is no separate family of "branch instructions only"
/// conditionality.
enum ARMCondition: UInt8 {
    case equal = 0b0000              // EQ: Z == 1
    case notEqual = 0b0001           // NE: Z == 0
    case carrySet = 0b0010           // CS/HS: C == 1
    case carryClear = 0b0011         // CC/LO: C == 0
    case negative = 0b0100           // MI: N == 1
    case positiveOrZero = 0b0101     // PL: N == 0
    case overflow = 0b0110           // VS: V == 1
    case noOverflow = 0b0111         // VC: V == 0
    case unsignedHigher = 0b1000     // HI: C == 1 && Z == 0
    case unsignedLowerOrSame = 0b1001 // LS: C == 0 || Z == 1
    case greaterOrEqual = 0b1010     // GE: N == V
    case lessThan = 0b1011           // LT: N != V
    case greaterThan = 0b1100        // GT: Z == 0 && N == V
    case lessOrEqual = 0b1101        // LE: Z == 1 || N != V
    case always = 0b1110             // AL
    case never = 0b1111              // NV — reserved/unpredictable pre-ARMv5; treated as never-execute here.

    init(rawBits: UInt32) {
        self = ARMCondition(rawValue: UInt8(rawBits & 0xF)) ?? .never
    }
}
