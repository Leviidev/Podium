import XCTest
@testable import Podium

final class CPSRTests: XCTestCase {
    func testFlagBitsRoundTrip() {
        var cpsr = CPSR(rawValue: 0)
        cpsr.negative = true
        cpsr.zero = true
        cpsr.carry = true
        cpsr.overflow = true
        XCTAssertEqual(cpsr.rawValue, 0xF000_0000)

        cpsr.negative = false
        XCTAssertEqual(cpsr.rawValue, 0x7000_0000)
        XCTAssertTrue(cpsr.zero)
        XCTAssertTrue(cpsr.carry)
        XCTAssertTrue(cpsr.overflow)
    }

    func testEqualCondition() {
        var cpsr = CPSR(rawValue: 0)
        cpsr.zero = true
        XCTAssertTrue(cpsr.isSatisfied(.equal))
        cpsr.zero = false
        XCTAssertFalse(cpsr.isSatisfied(.equal))
        XCTAssertTrue(cpsr.isSatisfied(.notEqual))
    }

    func testSignedComparisonConditions() {
        var cpsr = CPSR(rawValue: 0)
        // N == V (both false): GE true, LT false.
        XCTAssertTrue(cpsr.isSatisfied(.greaterOrEqual))
        XCTAssertFalse(cpsr.isSatisfied(.lessThan))

        cpsr.negative = true // N != V now.
        XCTAssertFalse(cpsr.isSatisfied(.greaterOrEqual))
        XCTAssertTrue(cpsr.isSatisfied(.lessThan))

        cpsr.zero = true
        // GT requires Z==0, so this is not GT even though N==V would need checking;
        // LE requires Z==1 OR N!=V — true either way here.
        XCTAssertFalse(cpsr.isSatisfied(.greaterThan))
        XCTAssertTrue(cpsr.isSatisfied(.lessOrEqual))
    }

    func testUnsignedHigherAndLowerOrSame() {
        var cpsr = CPSR(rawValue: 0)
        cpsr.carry = true
        cpsr.zero = false
        XCTAssertTrue(cpsr.isSatisfied(.unsignedHigher))
        XCTAssertFalse(cpsr.isSatisfied(.unsignedLowerOrSame))

        cpsr.zero = true
        XCTAssertFalse(cpsr.isSatisfied(.unsignedHigher))
        XCTAssertTrue(cpsr.isSatisfied(.unsignedLowerOrSame))
    }

    func testAlwaysAndNever() {
        let cpsr = CPSR(rawValue: 0)
        XCTAssertTrue(cpsr.isSatisfied(.always))
        XCTAssertFalse(cpsr.isSatisfied(.never))
    }

    func testResetProducesSystemMode() {
        var cpsr = CPSR(rawValue: 0xFFFF_FFFF)
        cpsr.reset()
        XCTAssertEqual(cpsr.rawValue, CPSR.resetValue)
    }
}
