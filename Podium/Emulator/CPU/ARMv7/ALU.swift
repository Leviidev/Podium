import Foundation

/// The arithmetic ARM's data-processing instructions share. Real ARM
/// hardware implements subtraction as addition of the bitwise-inverted
/// operand plus a carry-in of 1 (`a - b == a + ~b + 1`) through the same
/// adder used for ADD/ADC — doing the same here means SUB/SBC/CMP get
/// correct carry (as "no borrow occurred") and overflow flags for free,
/// rather than needing separately-reasoned-about subtraction flag logic.
enum ALU {
    struct AddResult {
        let value: UInt32
        /// Unsigned carry out of bit 31.
        let carryOut: Bool
        /// Signed two's-complement overflow.
        let overflow: Bool
    }

    /// ARM's `AddWithCarry()` pseudocode (DDI 0406C A2.2.1), computed at
    /// full width in one step: C is "the unsigned sum doesn't fit in 32
    /// bits", V is "the signed sum doesn't fit in 32 bits". Adding `b` and
    /// the carry-in as two separate 32-bit steps and OR-ing each step's
    /// overflow is *wrong* for V: when `a + b` overflows downward and the
    /// carry-in brings it back into range, both steps report overflow even
    /// though the true result fits — e.g. `CMP r0, #0` with r0 = 0x80000000
    /// set V, flipping every signed branch after it.
    static func addWithCarry(_ a: UInt32, _ b: UInt32, carryIn: Bool) -> AddResult {
        let carry: UInt64 = carryIn ? 1 : 0
        let unsignedSum = UInt64(a) + UInt64(b) + carry
        let signedSum = Int64(Int32(bitPattern: a)) + Int64(Int32(bitPattern: b)) + Int64(carry)
        let value = UInt32(truncatingIfNeeded: unsignedSum)

        return AddResult(
            value: value,
            carryOut: unsignedSum > UInt64(UInt32.max),
            overflow: signedSum != Int64(Int32(bitPattern: value))
        )
    }

    static func add(_ a: UInt32, _ b: UInt32) -> AddResult {
        addWithCarry(a, b, carryIn: false)
    }

    static func subtract(_ a: UInt32, _ b: UInt32) -> AddResult {
        addWithCarry(a, ~b, carryIn: true)
    }

    static func subtractWithCarry(_ a: UInt32, _ b: UInt32, carryIn: Bool) -> AddResult {
        addWithCarry(a, ~b, carryIn: carryIn)
    }
}
