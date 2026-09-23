import XCTest
@testable import Podium

final class S5L8930XSWITests: XCTestCase {
    /// `AppleSamsungSWI::_waitTransaction` polls the start bit until the
    /// hardware clears it; every transaction here completes at once.
    func testTransactionStartBitNeverReadsBackBusy() {
        let swi = S5L8930XSWI()
        swi.writeRegister(0x0000_00A5, at: 0x18)
        swi.writeRegister(1, at: S5L8930XSWI.controlRegister)
        XCTAssertEqual(swi.readRegister(at: S5L8930XSWI.controlRegister) & 1, 0)
        XCTAssertEqual(swi.readRegister(at: 0x18), 0xA5, "data register is plain storage")
    }

    func testOtherControlBitsAreKept() {
        let swi = S5L8930XSWI()
        swi.writeRegister(0x0000_0301, at: S5L8930XSWI.controlRegister)
        XCTAssertEqual(swi.readRegister(at: S5L8930XSWI.controlRegister), 0x300)
    }
}
