import XCTest
@testable import Podium

final class S5L8930XDisplayTests: XCTestCase {
    /// AppleDisplayPipe's filter: read the status, act on the enabled
    /// bits, write them back to acknowledge. The line only asserts for
    /// enabled bits.
    func testPipeVblankInterruptIsGatedByEnableAndClearedByWriteBack() {
        var line = false
        let pipe = S5L8930XDisplayPipe { line = $0 }

        pipe.frameEnded()
        XCTAssertFalse(line, "interrupt disabled")
        pipe.writeRegister(1, at: S5L8930XDisplayPipe.interruptEnable)
        XCTAssertTrue(line, "pending vblank raises the line once enabled")

        XCTAssertEqual(pipe.readRegister(at: S5L8930XDisplayPipe.interruptStatus), S5L8930XDisplayPipe.vblank)
        pipe.writeRegister(S5L8930XDisplayPipe.vblank, at: S5L8930XDisplayPipe.interruptStatus)
        XCTAssertFalse(line)

        pipe.frameEnded()
        XCTAssertTrue(line)
    }

    /// The swap sequence traced from AppleDisplayPipe: a header with the
    /// word count and ID, then register groups. Nothing changes until the
    /// frame ends; then the registers, the completed ID and bit 8.
    func testCommandFIFOAppliesAtFrameEndWithItsID() {
        let pipe = S5L8930XDisplayPipe { _ in }
        let words: [UInt32] = [0x0002_4044, 0x1234_0000, 0x0000_0A00, 0x0001_2040, 0x00FF_0002]
        pipe.writeRegister(0xA000_0000 | UInt32(words.count) << 16 | 9, at: S5L8930XDisplayPipe.commandFIFO)
        for word in words { pipe.writeRegister(word, at: S5L8930XDisplayPipe.commandFIFO) }
        XCTAssertEqual(pipe.readRegister(at: 0x4044), 0)

        pipe.frameEnded()
        XCTAssertEqual(pipe.readRegister(at: 0x4044), 0x1234_0000)
        XCTAssertEqual(pipe.readRegister(at: 0x4048), 0x0000_0A00)
        XCTAssertEqual(pipe.readRegister(at: 0x2040), 0x00FF_0002)
        XCTAssertEqual(pipe.readRegister(at: S5L8930XDisplayPipe.completedCommandID), 9)
        XCTAssertEqual(pipe.readRegister(at: S5L8930XDisplayPipe.interruptStatus), S5L8930XDisplayPipe.vblank | S5L8930XDisplayPipe.commandDone)
    }

    /// AppleCLCD's filter checks status bit 2 and acknowledges it; the
    /// iBoot-state registers it reads at start are plain storage.
    func testCLCDVsyncStatusAndPlainRegisters() {
        var line = false
        let clcd = S5L8930XCLCD { line = $0 }
        clcd.writeRegister(0x03C0_0280, at: 0x60)
        XCTAssertEqual(clcd.readRegister(at: 0x60), 0x03C0_0280)

        clcd.frameEnded()
        XCTAssertTrue(line)
        XCTAssertEqual(clcd.readRegister(at: S5L8930XCLCD.interruptStatus) & S5L8930XCLCD.vsync, S5L8930XCLCD.vsync)
        clcd.writeRegister(S5L8930XCLCD.vsync, at: S5L8930XCLCD.interruptStatus)
        XCTAssertFalse(line)
    }
}
