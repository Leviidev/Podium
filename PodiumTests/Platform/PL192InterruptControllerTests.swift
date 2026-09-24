import XCTest
@testable import Podium

final class PL192InterruptControllerTests: XCTestCase {
    private var irq = false
    private var vic: PL192InterruptController!

    override func setUp() {
        irq = false
        vic = PL192InterruptController { [unowned self] irq, _ in self.irq = irq }
    }

    /// Programs `line` the way AppleARMPL192VIC does: vector address
    /// `line | 0x80000000` in its VIC's slot, then enabled.
    private func enable(_ line: Int) {
        let base = UInt32(line / 32) * PL192InterruptController.vicStride
        vic.writeRegister(UInt32(line) | 0x8000_0000, at: base + 0x100 + UInt32(line % 32) * 4)
        vic.writeRegister(1 << UInt32(line % 32), at: base + 0x10)
    }

    private func vicAddress(_ index: UInt32) -> UInt32 { vic.readRegister(at: index * PL192InterruptController.vicStride + 0xF00) }
    private func endOfInterrupt(_ index: UInt32) { vic.writeRegister(0, at: index * PL192InterruptController.vicStride + 0xF00) }

    /// The kernel only ever reads VIC0's VICADDRESS to find the line; a
    /// line in VIC1 (the CDMA channels, 0x31/0x32) must come back
    /// through the daisy chain, not as VIC0's stale last vector.
    func testVIC0HandsOutALineFromVIC1ThroughTheDaisyChain() {
        enable(6)
        vic.setLine(6, asserted: true)
        XCTAssertEqual(vicAddress(0), 0x8000_0006)
        endOfInterrupt(0)
        vic.setLine(6, asserted: false)

        enable(0x31)
        vic.setLine(0x31, asserted: true)
        XCTAssertTrue(irq)
        XCTAssertEqual(vicAddress(0), 0x8000_0031)
        endOfInterrupt(1)
        endOfInterrupt(0)
    }

    /// A line in VIC2: the kernel reads VIC0 then VIC1, and both must
    /// agree on the line; ending the interrupt on VIC2, VIC1, VIC0 leaves
    /// nothing in service, so the next interrupt is delivered.
    func testDeeperLineAndEndOfInterruptSequence() {
        enable(0x45)
        vic.setLine(0x45, asserted: true)
        XCTAssertEqual(vicAddress(0), 0x8000_0045)
        XCTAssertEqual(vicAddress(1), 0x8000_0045)
        for index: UInt32 in [2, 1, 0] { endOfInterrupt(index) }
        vic.setLine(0x45, asserted: false)

        enable(0x31)
        vic.setLine(0x31, asserted: true)
        XCTAssertEqual(vicAddress(0), 0x8000_0031)
    }

    /// VIC0's own line wins over the daisy chain at equal priority.
    func testOwnLineOutranksDaisyChainAtEqualPriority() {
        enable(6)
        enable(0x31)
        vic.setLine(0x31, asserted: true)
        vic.setLine(6, asserted: true)
        XCTAssertEqual(vicAddress(0), 0x8000_0006)
    }
}
