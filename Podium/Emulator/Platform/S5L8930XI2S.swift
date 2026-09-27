import Foundation

/// The S5L8930X I²S controller (device tree `i2s0`, compatible
/// `i2s-1,samsung`) as far as AppleSamsungI2S needs it with no audio ever
/// playing: registers keep what's written, except that control register
/// bit 1 — the channel-idle status — always reads 1.
///
/// Stopping a channel, the driver writes the control register at `+0x0`
/// and then spins, `IODelay(10)` at a time, until that bit comes up
/// (it's the only place the driver polls it). As plain storage the bit
/// never did, and the spin, from a high-priority audio work loop, starved
/// every other thread — pid 1 included, so launchd never started.
final class S5L8930XI2S: MMIODevice {
    static let windowLength: UInt32 = 0xC00
    static let controlChannelIdle: UInt32 = 1 << 1

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))

    func readRegister(at offset: UInt32) -> UInt32 {
        let value = registers[Int(offset / 4)]
        return offset == 0 ? value | Self.controlChannelIdle : value
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        registers[Int(offset / 4)] = value
    }
}
