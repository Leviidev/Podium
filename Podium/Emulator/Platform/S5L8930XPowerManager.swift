import Foundation

/// The S5L8930X power manager (`pmgr`, main window at `0x3F100000`,
/// 24 KB). Only the behavior the kernel has been observed to depend on is
/// modeled; every other register keeps plain-storage semantics, same as
/// the generic peripheral backing this replaces for this window.
///
/// Device power-state registers, `0x1010 + 4·index` for 64 devices: the
/// PMGR driver writes a requested state into bits [3:0] (e.g. `0xF` on),
/// then spins until the actual-state field in bits [7:4] matches — traced
/// from the real driver's power-up loop, which reads the register back
/// and waits for `(value ^ (value >> 4)) & 0xF == 0`. Real hardware
/// transitions the device and updates [7:4]; here the transition is
/// immediate, so the actual state simply follows every write.
///
/// The system timer lives inside this window too (`+0x2000`); its
/// `MMIORegion` is placed ahead of this one on the bus, so it keeps its
/// own registers.
final class S5L8930XPowerManager: MMIODevice {
    static let windowLength: UInt32 = 0x6000
    static let powerStateRegisters: Range<UInt32> = 0x1010..<(0x1010 + 64 * 4)

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))

    func readRegister(at offset: UInt32) -> UInt32 {
        registers[Int(offset / 4)]
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        var stored = value
        if Self.powerStateRegisters.contains(offset) {
            stored = (value & ~0xF0) | ((value & 0xF) << 4)
        }
        registers[Int(offset / 4)] = stored
    }
}
