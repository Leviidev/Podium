import Foundation

/// The S5L8930X watchdog (device tree `wdt`, `pmgr + 0x2020`), as the
/// kernel's AppleS5L8930XWatchDogTimer drives it:
///
/// - `+0x0` the counter, which the kernel zeroes to restart the count;
/// - `+0x4` the count that resets the system, `+0x8` the count that
///   interrupts first (half of it, as the driver arms it);
/// - `+0xC` control: bit 2 enables the reset, bit 3 the interrupt, bit 1
///   acknowledges the interrupt.
///
/// iOS ends every shutdown and restart the same way: with the reset
/// enabled it sets the reset count to zero, zeroes the counter and spins
/// until the reset lands. That is the only use modeled — the counter
/// doesn't run, so a watchdog the kernel keeps restarting never fires,
/// and one programmed to fire at once does, immediately.
final class S5L8930XWatchdog: MMIODevice {
    static let windowOffsetInPMGR: UInt32 = 0x2020
    static let windowLength: UInt32 = 0x10

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    /// Called once the watchdog resets the system.
    var onReset: (() -> Void)?

    func readRegister(at offset: UInt32) -> UInt32 {
        registers[Int(offset / 4)]
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        registers[Int(offset / 4)] = offset == 0xC ? value & ~2 : value
        let resetEnabled = registers[3] & 4 != 0
        if resetEnabled, registers[0] >= registers[1] { onReset?() }
    }
}
