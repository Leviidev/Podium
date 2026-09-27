import XCTest
@testable import Podium

final class S5L8930XDSIMTests: XCTestCase {
    /// AppleSamsungMIPIDSIController's power-up waits: PLL stable and
    /// reset done after programming the PLL, then the lanes in stop state
    /// once ESCMODE's force-stop is released.
    func testLinkComesUpStableAndStopped() {
        let dsim = S5L8930XDSIM()
        dsim.writeRegister(0x0010_0080, at: S5L8930XDSIM.escapeMode)
        dsim.writeRegister(0x80, at: S5L8930XDSIM.escapeMode)
        let status = dsim.readRegister(at: S5L8930XDSIM.status)
        XCTAssertEqual(status & S5L8930XDSIM.pllStable, S5L8930XDSIM.pllStable)
        XCTAssertEqual(status & S5L8930XDSIM.resetDone, S5L8930XDSIM.resetDone)
        XCTAssertEqual(status & 0x10F, 0x10F, "clock and data lanes stopped")
        XCTAssertEqual(status & 0x2F0, 0, "not in ULPS")
    }

    /// The kernel's ULPS enter/exit, as traced: `0x8a` requests ULPS on
    /// clock and data lanes, `0x8f` adds both exits, and `0x80` drops them.
    func testULPSFollowsEscapeModeRequests() {
        let dsim = S5L8930XDSIM()
        dsim.writeRegister(0x8A, at: S5L8930XDSIM.escapeMode)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.status) & 0x3FF, 0x2F0)
        dsim.writeRegister(0x8F, at: S5L8930XDSIM.escapeMode)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.status) & 0x2F0, 0)
        dsim.writeRegister(0x80, at: S5L8930XDSIM.escapeMode)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.status) & 0x10F, 0x10F)
    }

    /// Turning the HS clock on waits for bit 10 to set; turning it off,
    /// for it to clear.
    func testHighSpeedClockReadyFollowsClockControl() {
        let dsim = S5L8930XDSIM()
        dsim.writeRegister(0x9100_0000, at: S5L8930XDSIM.clockControl)
        XCTAssertNotEqual(dsim.readRegister(at: S5L8930XDSIM.status) & S5L8930XDSIM.highSpeedClockReady, 0)
        dsim.writeRegister(0x1100_0000, at: S5L8930XDSIM.clockControl)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.status) & S5L8930XDSIM.highSpeedClockReady, 0)
    }

    /// The kernel's read path: clear INTSRC, send the request, wait for
    /// read-data-done, then drain the read FIFO while it isn't empty.
    func testReadRequestIsAnsweredThroughTheReadFIFO() {
        let dsim = S5L8930XDSIM()
        dsim.panel = { dataType, data0, _ in
            XCTAssertEqual(dataType, 0x06)
            XCTAssertEqual(data0, 0x0A)
            return [0x0000_9C21]
        }
        dsim.writeRegister(0xFFFF_FFFF, at: S5L8930XDSIM.interruptSource)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.interruptSource), 0)
        dsim.writeRegister(0x0A06, at: S5L8930XDSIM.packetHeader)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.interruptSource) & S5L8930XDSIM.readDataDone, S5L8930XDSIM.readDataDone)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.fifoControl) & S5L8930XDSIM.readFIFOEmpty, 0)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.readFIFO), 0x0000_9C21)
        XCTAssertNotEqual(dsim.readRegister(at: S5L8930XDSIM.fifoControl) & S5L8930XDSIM.readFIFOEmpty, 0)
    }

    /// A write packet (a DCS short write, here) gets no response.
    func testWritePacketRaisesNothing() {
        let dsim = S5L8930XDSIM()
        dsim.writeRegister(0x2905, at: S5L8930XDSIM.packetHeader)
        XCTAssertEqual(dsim.readRegister(at: S5L8930XDSIM.interruptSource), 0)
        XCTAssertNotEqual(dsim.readRegister(at: S5L8930XDSIM.fifoControl) & S5L8930XDSIM.readFIFOEmpty, 0)
    }
}
