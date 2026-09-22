import XCTest
@testable import Podium

final class ALUTests: XCTestCase {
    func testSimpleAdditionNoFlags() {
        let r = ALU.add(5, 3)
        XCTAssertEqual(r.value, 8)
        XCTAssertFalse(r.carryOut)
        XCTAssertFalse(r.overflow)
    }

    func testAdditionUnsignedCarryOutNoSignedOverflow() {
        // 0xFFFFFFFF + 1 wraps to 0 with an unsigned carry; as signed
        // values that's -1 + 1 == 0, which does not overflow.
        let r = ALU.add(0xFFFF_FFFF, 1)
        XCTAssertEqual(r.value, 0)
        XCTAssertTrue(r.carryOut)
        XCTAssertFalse(r.overflow)
    }

    func testAdditionSignedOverflowNoUnsignedCarry() {
        // INT32_MAX + 1: fits fine unsigned (no carry out of bit 31),
        // but overflows as a signed value.
        let r = ALU.add(0x7FFF_FFFF, 1)
        XCTAssertEqual(r.value, 0x8000_0000)
        XCTAssertFalse(r.carryOut)
        XCTAssertTrue(r.overflow)
    }

    func testSubtractionNoBorrowSetsCarry() {
        // ARM's C flag after SUB means "no borrow occurred".
        let r = ALU.subtract(5, 3)
        XCTAssertEqual(r.value, 2)
        XCTAssertTrue(r.carryOut)
        XCTAssertFalse(r.overflow)
    }

    func testSubtractionWithBorrowClearsCarry() {
        let r = ALU.subtract(3, 5)
        XCTAssertEqual(r.value, UInt32(bitPattern: -2))
        XCTAssertFalse(r.carryOut)
        XCTAssertFalse(r.overflow)
    }

    func testSubtractionSignedOverflow() {
        // INT32_MIN - 1 underflows the signed range.
        let r = ALU.subtract(0x8000_0000, 1)
        XCTAssertEqual(r.value, 0x7FFF_FFFF)
        XCTAssertTrue(r.carryOut) // 0x80000000 >= 1 unsigned, so no borrow.
        XCTAssertTrue(r.overflow)
    }

    func testAddWithCarryInPropagates() {
        let r = ALU.addWithCarry(1, 1, carryIn: true)
        XCTAssertEqual(r.value, 3)
    }

    func testSubtractWithCarryInAsBorrowIn() {
        // ARM's SBC uses carryIn as "NOT borrow", matching subtract()'s
        // own carryIn: true convention for a plain subtract.
        let r = ALU.subtractWithCarry(5, 3, carryIn: true)
        XCTAssertEqual(r.value, ALU.subtract(5, 3).value)
    }

    /// `CMP r0, #0` with r0 = 0x80000000 (this kernel's own base address):
    /// INT_MIN - 0 is INT_MIN exactly, no overflow. Computing `a + ~b` and
    /// then `+ carryIn` as two separate steps overflows downward then back
    /// up, and OR-ing those two overflows wrongly reported V=1 — found by
    /// lockstep-comparing the JIT (whose host `SUBS` got it right) against
    /// this interpreter on the real kernel.
    func testSubtractionWhoseTrueResultIsIntMinDoesNotOverflow() {
        let r = ALU.subtract(0x8000_0000, 0)
        XCTAssertEqual(r.value, 0x8000_0000)
        XCTAssertTrue(r.carryOut, "no borrow")
        XCTAssertFalse(r.overflow)

        let r2 = ALU.subtract(0x8000_0005, 5)
        XCTAssertEqual(r2.value, 0x8000_0000)
        XCTAssertFalse(r2.overflow)
    }

    func testSubtractionPastIntMinOverflows() {
        let r = ALU.subtract(0x8000_0000, 1)
        XCTAssertEqual(r.value, 0x7FFF_FFFF)
        XCTAssertTrue(r.carryOut)
        XCTAssertTrue(r.overflow)
    }

    func testAddWithCarryIntoIntMaxBoundary() {
        let overflowing = ALU.addWithCarry(0x7FFF_FFFF, 0, carryIn: true)
        XCTAssertEqual(overflowing.value, 0x8000_0000)
        XCTAssertTrue(overflowing.overflow)
        XCTAssertFalse(overflowing.carryOut)

        let unsignedWrapOnlyViaCarry = ALU.addWithCarry(0xFFFF_FFFF, 0, carryIn: true)
        XCTAssertEqual(unsignedWrapOnlyViaCarry.value, 0)
        XCTAssertTrue(unsignedWrapOnlyViaCarry.carryOut)
        XCTAssertFalse(unsignedWrapOnlyViaCarry.overflow)
    }
}
