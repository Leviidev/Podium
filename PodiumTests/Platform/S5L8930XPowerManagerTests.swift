import XCTest
@testable import Podium

final class S5L8930XPowerManagerTests: XCTestCase {
    /// The real PMGR driver writes a requested state into bits [3:0] and
    /// spins until bits [7:4] (actual state) match — they must follow.
    func testPowerStateRegisterReportsRequestedStateAsActual() {
        let pmgr = S5L8930XPowerManager()
        let offset: UInt32 = 0x1010 + 5 * 4
        pmgr.writeRegister(0x0000_010F, at: offset)
        let value = pmgr.readRegister(at: offset)
        XCTAssertEqual(value & 0xF, 0xF)
        XCTAssertEqual((value >> 4) & 0xF, 0xF, "actual state follows the request")
        XCTAssertEqual((value ^ (value >> 4)) & 0xF, 0, "the driver's own wait condition is satisfied")

        pmgr.writeRegister(0x0000_0004, at: offset)
        XCTAssertEqual(pmgr.readRegister(at: offset) & 0xFF, 0x44)
    }

    func testOtherRegistersArePlainStorage() {
        let pmgr = S5L8930XPowerManager()
        pmgr.writeRegister(0xDEAD_BEEF, at: 0x40)
        XCTAssertEqual(pmgr.readRegister(at: 0x40), 0xDEAD_BEEF)
    }
}
