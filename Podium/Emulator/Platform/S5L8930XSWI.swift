import Foundation

/// The S5L8930X single-wire interface (device tree `swi`, `0x3F600000`) —
/// a one-wire serial link the kernel drives backlight control through.
/// Only the transaction handshake is modeled; there's no device on the
/// other end, and every other register keeps plain-storage semantics.
///
/// Traced from `AppleSamsungSWI`: it writes the data word to `+0x18`,
/// writes 1 to `+0x14` to start a transaction, then polls `+0x14` bit 0
/// until the hardware clears it, panicking ("_waitTransaction timeout")
/// if it's still set past a deadline. Here every transaction completes
/// immediately, so the start/busy bit never reads back set.
final class S5L8930XSWI: MMIODevice {
    static let windowLength: UInt32 = 0x1000
    static let controlRegister: UInt32 = 0x14
    private static let busy: UInt32 = 1 << 0

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))

    func readRegister(at offset: UInt32) -> UInt32 {
        registers[Int(offset / 4)]
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        registers[Int(offset / 4)] = offset == Self.controlRegister ? value & ~Self.busy : value
    }
}
