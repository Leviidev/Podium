import XCTest
@testable import Podium

final class S5L8930XIOPTests: XCTestCase {
    /// The real driver writes the stop bit and panics ("ARM7M not stopped
    /// for some reason") unless the read-back shows "stopped"; writing
    /// run afterwards clears it.
    func testStopThenRunHandshake() {
        let iop = S5L8930XIOP()
        let control = S5L8930XIOP.controlRegister
        iop.writeRegister(1 << 4, at: control)
        XCTAssertEqual(iop.readRegister(at: control) & (1 << 1), 1 << 1, "stopped after a stop request")

        iop.writeRegister(1 << 0, at: control)
        XCTAssertEqual(iop.readRegister(at: control) & (1 << 1), 0, "running after a run request")
        XCTAssertEqual(iop.readRegister(at: control) & 1, 1, "the written bits read back")
    }

    func testOtherRegistersArePlainStorage() {
        let iop = S5L8930XIOP()
        iop.writeRegister(0x4012_3000, at: 0x110)
        XCTAssertEqual(iop.readRegister(at: 0x110), 0x4012_3000)
    }
}
