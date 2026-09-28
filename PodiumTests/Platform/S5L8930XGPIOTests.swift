import XCTest
@testable import Podium

final class S5L8930XGPIOTests: XCTestCase {
    /// AppleM68Buttons' pins as the kernel sets them up (traced): mode
    /// 0xC, either edge, then enabled. Pressing pulls the pin low and
    /// interrupts; the kernel's handler reads the pending block, the
    /// block's status, acknowledges it, and reads the level.
    func testButtonPressAndReleaseInterruptOnBothEdges() {
        var line = false
        let gpio = S5L8930XGPIO { line = $0 }
        let hold = UInt32(S5L8930XGPIO.Pin.hold)
        gpio.writeRegister(0xFFFF_FFFF, at: S5L8930XGPIO.statusBase)
        gpio.writeRegister(0x20C, at: hold * 4)
        gpio.writeRegister(1 << hold, at: S5L8930XGPIO.enableBase)
        XCTAssertEqual(gpio.readRegister(at: hold * 4) & 1, 1, "released reads high")
        XCTAssertFalse(line)

        gpio.setInputLevel(false, pin: Int(hold))
        XCTAssertTrue(line)
        XCTAssertEqual(gpio.readRegister(at: S5L8930XGPIO.pending), 1)
        XCTAssertEqual(gpio.readRegister(at: S5L8930XGPIO.statusBase), 1 << hold)
        gpio.writeRegister(1 << hold, at: S5L8930XGPIO.statusBase)
        XCTAssertFalse(line)
        XCTAssertEqual(gpio.readRegister(at: hold * 4) & 1, 0, "pressed reads low")

        gpio.setInputLevel(true, pin: Int(hold))
        XCTAssertTrue(line, "release interrupts too")
    }

    func testDisabledPinLatchesStatusButDoesNotInterrupt() {
        var line = false
        let gpio = S5L8930XGPIO { line = $0 }
        gpio.writeRegister(0x20C, at: 0)
        gpio.setInputLevel(false, pin: S5L8930XGPIO.Pin.menu)
        XCTAssertFalse(line)
        XCTAssertEqual(gpio.readRegister(at: S5L8930XGPIO.statusBase), 1)
        gpio.writeRegister(1, at: S5L8930XGPIO.enableBase)
        XCTAssertTrue(line)
        gpio.writeRegister(1, at: S5L8930XGPIO.disableBase)
        XCTAssertFalse(line)
    }

    /// The touch controller's line: falling edge only (0x20A).
    func testFallingEdgeModeIgnoresRisingEdge() {
        var line = false
        let gpio = S5L8930XGPIO { line = $0 }
        let pin = UInt32(S5L8930XGPIO.Pin.touchInterrupt)
        gpio.writeRegister(0x20A, at: pin * 4)
        gpio.writeRegister(1 << pin, at: S5L8930XGPIO.enableBase)
        gpio.setInputLevel(false, pin: Int(pin))
        XCTAssertTrue(line)
        gpio.writeRegister(1 << pin, at: S5L8930XGPIO.statusBase)
        gpio.setInputLevel(true, pin: Int(pin))
        XCTAssertFalse(line)
    }

    /// A level-low interrupt stays pending while the level holds, even
    /// after it's acknowledged.
    func testLevelInterruptReassertsUntilLevelChanges() {
        var line = false
        let gpio = S5L8930XGPIO { line = $0 }
        let pin = UInt32(S5L8930XGPIO.Pin.volumeUp)
        gpio.writeRegister(0x206, at: pin * 4)
        gpio.writeRegister(1 << pin, at: S5L8930XGPIO.enableBase)
        gpio.setInputLevel(false, pin: Int(pin))
        gpio.writeRegister(1 << pin, at: S5L8930XGPIO.statusBase)
        XCTAssertTrue(line)
        gpio.setInputLevel(true, pin: Int(pin))
        gpio.writeRegister(1 << pin, at: S5L8930XGPIO.statusBase)
        XCTAssertFalse(line)
    }

    /// Pins nothing drives are storage: output writes read back, and they
    /// never interrupt — the kernel enables level-low interrupts on some.
    func testUndrivenPinsAreStorageAndNeverInterrupt() {
        var line = false
        let gpio = S5L8930XGPIO { line = $0 }
        gpio.writeRegister(0x206, at: 11 * 4)
        gpio.writeRegister(1 << 11, at: S5L8930XGPIO.enableBase)
        XCTAssertFalse(line)
        gpio.writeRegister(0x3, at: 140 * 4)
        XCTAssertEqual(gpio.readRegister(at: 140 * 4), 0x3)
    }
}
