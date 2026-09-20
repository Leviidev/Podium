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
}
