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

    static func addWithCarry(_ a: UInt32, _ b: UInt32, carryIn: Bool) -> AddResult {
        let (unsignedPartial, unsignedOverflow1) = a.addingReportingOverflow(b)
        let (unsignedTotal, unsignedOverflow2) = unsignedPartial.addingReportingOverflow(carryIn ? 1 : 0)

        let signedA = Int32(bitPattern: a)
        let signedB = Int32(bitPattern: b)
        let (signedPartial, signedOverflow1) = signedA.addingReportingOverflow(signedB)
        let (_, signedOverflow2) = signedPartial.addingReportingOverflow(carryIn ? 1 : 0)

        return AddResult(
            value: unsignedTotal,
            carryOut: unsignedOverflow1 || unsignedOverflow2,
            overflow: signedOverflow1 || signedOverflow2
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
