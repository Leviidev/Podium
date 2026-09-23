import Foundation

/// The S5L8930X IOP: a small ARM7 coprocessor the kernel loads firmware
/// onto (device tree `iop`, registers at child `0x06300000`, physical
/// `0x86300000`). Only the control handshake the driver depends on is
/// modeled — the ARM7 core itself isn't emulated — and every other
/// register keeps plain-storage semantics.
///
/// Control, `+0x100` (traced from the real driver): writing bit 4 stops
/// the ARM7, and the driver panics ("ARM7M not stopped for some reason")
/// unless the read-back then shows bit 1, "stopped". It then programs the
/// firmware address/size registers (`+0x110`–`+0x118`) and writes bit 0
/// to set it running, which clears "stopped".
final class S5L8930XIOP: MMIODevice {
    static let windowLength: UInt32 = 0x1000
    static let controlRegister: UInt32 = 0x100
    private static let stopRequest: UInt32 = 1 << 4
    private static let runRequest: UInt32 = 1 << 0
    private static let stoppedStatus: UInt32 = 1 << 1

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var stopped = true

    func readRegister(at offset: UInt32) -> UInt32 {
        let value = registers[Int(offset / 4)]
        guard offset == Self.controlRegister else { return value }
        return (value & ~Self.stoppedStatus) | (stopped ? Self.stoppedStatus : 0)
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        registers[Int(offset / 4)] = value
        guard offset == Self.controlRegister else { return }
        if value & Self.stopRequest != 0 {
            stopped = true
        } else if value & Self.runRequest != 0 {
            stopped = false
        }
    }
}
