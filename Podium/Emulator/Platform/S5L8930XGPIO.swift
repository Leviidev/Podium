import Foundation

/// The S5L8930X GPIO block and its interrupt controller (device tree
/// `gpio`, physical `0x3FA00000`, interrupt `0x74`) — what the buttons and
/// the touchscreen's interrupt line are wired to.
///
/// Layout, from openiBoot's A4 `gpio.c` and the kernel's
/// AppleS5L8930XGPIOIC, which agree:
///
/// - `+0x000 + 4 * pin`: each pin's configuration. Bit 0 is the pin's
///   level — for an input, what the outside world drives it to — and bits
///   3:1 its interrupt mode: `0x4`/`0x6` level high/low, `0x8`/`0xA`
///   rising/falling edge, `0xC` either edge. The kernel keeps its own copy
///   of these and treats mode `0x4`/`0x6` as level (acknowledged after the
///   handler runs) and the rest as edges (acknowledged before).
/// - `+0x800 + 4 * block` disables and `+0x840 + 4 * block` enables
///   interrupts, one bit per pin in 32-pin blocks (write one to change);
///   `+0x880 + 4 * block` is each block's latched status (write one to
///   clear); `+0xC00` has a bit per block with an enabled interrupt
///   pending, and the interrupt line follows it.
///
/// Only pins something outside drives — the buttons, the touch
/// controller's interrupt — raise interrupts; the rest are plain storage,
/// so their level is whatever was last written.
final class S5L8930XGPIO: MMIODevice {
    static let windowLength: UInt32 = 0x1000
    static let pinCount = 192
    static let blockCount = pinCount / 32
    static let disableBase: UInt32 = 0x800
    static let enableBase: UInt32 = 0x840
    static let statusBase: UInt32 = 0x880
    static let pending: UInt32 = 0xC00

    /// Pins, from the device tree's `buttons` and `multi-touch` nodes.
    enum Pin {
        static let menu = 0
        static let hold = 1
        static let volumeUp = 2
        static let volumeDown = 3
        static let touchInterrupt = 21
    }

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var enabled = [UInt32](repeating: 0, count: blockCount)
    private var status = [UInt32](repeating: 0, count: blockCount)
    /// Levels of the pins driven from outside.
    private var inputLevels: [Int: Bool] = [:]
    private let setInterruptLine: (Bool) -> Void
    /// Called when software changes an undriven pin's level (bit 0) — an
    /// output, such as a chip select.
    var onOutputChanged: ((_ pin: Int, _ level: Bool) -> Void)?

    init(setInterruptLine: @escaping (Bool) -> Void) {
        self.setInterruptLine = setInterruptLine
        // Buttons pull their pins low while pressed; the touch
        // controller's interrupt line idles high.
        for pin in [Pin.menu, Pin.hold, Pin.volumeUp, Pin.volumeDown, Pin.touchInterrupt] {
            inputLevels[pin] = true
        }
    }

    /// Drives an input pin, raising its interrupt if its mode says so.
    func setInputLevel(_ level: Bool, pin: Int) {
        let previous = inputLevels[pin]
        inputLevels[pin] = level
        guard previous != level else { return }
        let mode = registers[pin] & 0xE
        let triggered: Bool
        switch mode {
        case 0xC: triggered = true
        case 0x8: triggered = level
        case 0xA: triggered = !level
        case 0x4: triggered = level
        case 0x6: triggered = !level
        default: triggered = false
        }
        if triggered { status[pin / 32] |= 1 << UInt32(pin % 32) }
        updateInterruptLine()
    }

    func level(ofPin pin: Int) -> Bool {
        inputLevels[pin] ?? (registers[pin] & 1 != 0)
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        switch offset {
        case 0..<UInt32(Self.pinCount * 4):
            let pin = Int(offset / 4)
            guard let level = inputLevels[pin] else { return registers[pin] }
            return (registers[pin] & ~1) | (level ? 1 : 0)
        case Self.disableBase..<Self.disableBase + UInt32(Self.blockCount * 4),
             Self.enableBase..<Self.enableBase + UInt32(Self.blockCount * 4):
            return enabled[Int((offset & 0x3F) / 4)]
        case Self.statusBase..<Self.statusBase + UInt32(Self.blockCount * 4):
            return status[Int((offset - Self.statusBase) / 4)]
        case Self.pending:
            return pendingBlocks
        default:
            return registers[Int(offset / 4)]
        }
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        switch offset {
        case 0..<UInt32(Self.pinCount * 4):
            let pin = Int(offset / 4)
            let previous = registers[pin]
            registers[pin] = value
            reassertLevelInterrupt(pin)
            if inputLevels[pin] == nil, (previous ^ value) & 1 != 0 { onOutputChanged?(pin, value & 1 != 0) }
        case Self.disableBase..<Self.disableBase + UInt32(Self.blockCount * 4):
            enabled[Int((offset - Self.disableBase) / 4)] &= ~value
        case Self.enableBase..<Self.enableBase + UInt32(Self.blockCount * 4):
            enabled[Int((offset - Self.enableBase) / 4)] |= value
        case Self.statusBase..<Self.statusBase + UInt32(Self.blockCount * 4):
            let block = Int((offset - Self.statusBase) / 4)
            status[block] &= ~value
            for bit in 0..<32 where value & (1 << UInt32(bit)) != 0 { reassertLevelInterrupt(block * 32 + bit) }
        case Self.pending:
            break
        default:
            registers[Int(offset / 4)] = value
        }
        updateInterruptLine()
    }

    /// A level-triggered interrupt stays pending while its level holds.
    private func reassertLevelInterrupt(_ pin: Int) {
        guard let level = inputLevels[pin] else { return }
        let mode = registers[pin] & 0xE
        if (mode == 0x4 && level) || (mode == 0x6 && !level) {
            status[pin / 32] |= 1 << UInt32(pin % 32)
        }
    }

    private var pendingBlocks: UInt32 {
        var bits: UInt32 = 0
        for block in 0..<Self.blockCount where status[block] & enabled[block] != 0 { bits |= 1 << UInt32(block) }
        return bits
    }

    private func updateInterruptLine() {
        setInterruptLine(pendingBlocks != 0)
    }
}
