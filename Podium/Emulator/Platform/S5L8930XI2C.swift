import Foundation

/// A device on an I²C bus, addressed by its 7-bit address. Every transfer
/// the A4's controller makes starts with one register-address byte.
protocol I2CDevice: AnyObject {
    /// `count` bytes starting at `register`, or nil to NAK.
    func read(register: UInt8, count: Int) -> [UInt8]?
    /// Returns false to NAK.
    func write(register: UInt8, bytes: [UInt8]) -> Bool
}

/// One S5L8930X I²C controller (device tree `i2c0`, `i2c2`; compatible
/// `i2c,s5l8920x`). Transfers complete the moment they're started.
///
/// Register layout from the kernel's AppleS5L8920XI2CController (its
/// transfer routine and interrupt handler) and openiBoot's A4 `i2c.c`:
///
/// - `+0x00` target address (7-bit), `+0x10` register address (the first
///   byte of every transfer), `+0x18` byte count, `+0x20` data FIFO
///   (written before a write transfer, read after a read).
/// - `+0x24` command: bit 2 starts a transfer, bit 0 makes it a write.
/// - `+0x0C` status: bit 4 transfer done, bit 5 not acknowledged; the
///   interrupt handler writes the value it read back to clear it.
/// - `+0x08` and `+0x14` are configuration, kept as written.
///
/// Without this, the first PMU read (AppleD1815PMU::start) never
/// completed, and everything that waits on the PMU's functions blocked
/// behind it — ApplePinotLCD's `function-lcd_ldo`, so AppleCLCD, so the
/// built-in display.
final class S5L8930XI2C: MMIODevice {
    static let windowLength: UInt32 = 0x1000
    static let statusDone: UInt32 = 1 << 4
    static let statusNotAcknowledged: UInt32 = 1 << 5

    private let setInterruptLine: (Bool) -> Void
    private var devices: [UInt8: I2CDevice] = [:]
    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var transmit: [UInt8] = []
    private var receive: [UInt8] = []
    private var status: UInt32 = 0
    /// Diagnostic hook: one line per transfer.
    var log: ((String) -> Void)?

    init(setInterruptLine: @escaping (Bool) -> Void) {
        self.setInterruptLine = setInterruptLine
    }

    func attach(_ device: I2CDevice, at address: UInt8) {
        devices[address] = device
    }

    func detach(at address: UInt8) {
        devices[address] = nil
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0C: return status
        case 0x20: return receive.isEmpty ? 0 : UInt32(receive.removeFirst())
        default: return registers[Int(offset / 4)]
        }
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        switch offset {
        case 0x0C:
            status &= ~value
            if status == 0 { setInterruptLine(false) }
        case 0x20:
            transmit.append(UInt8(truncatingIfNeeded: value))
        case 0x24:
            registers[Int(offset / 4)] = value
            if value & 4 != 0 { runTransfer(write: value & 1 != 0) }
        default:
            registers[Int(offset / 4)] = value
        }
    }

    private func runTransfer(write: Bool) {
        let address = UInt8(truncatingIfNeeded: registers[0])
        let register = UInt8(truncatingIfNeeded: registers[0x10 / 4])
        let count = Int(registers[0x18 / 4] & 0xFF)
        let device = devices[address]
        var acknowledged = false
        if write {
            let bytes = Array(transmit.prefix(count))
            acknowledged = device?.write(register: register, bytes: bytes) ?? false
            log?(String(format: "i2c| %02x write reg %02x %@%@", address, register, bytes.map { String(format: "%02x", $0) }.joined(separator: " "), acknowledged ? "" : " NAK"))
        } else {
            let bytes = device?.read(register: register, count: count)
            receive = bytes ?? []
            acknowledged = bytes != nil
            log?(String(format: "i2c| %02x read reg %02x x%d -> %@", address, register, count, bytes.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "NAK"))
        }
        transmit.removeAll()
        status |= acknowledged ? Self.statusDone : Self.statusNotAcknowledged
        setInterruptLine(true)
    }
}

/// A plain I²C register file: reads return what was last written (or
/// the initial contents), and multi-byte transfers walk consecutive
/// registers.
class I2CRegisterFile: I2CDevice {
    var registers: [UInt8]

    init(initialContents: [UInt8] = []) {
        registers = [UInt8](repeating: 0, count: 256)
        for (index, value) in initialContents.enumerated() where index < 256 { registers[index] = value }
    }

    func read(register: UInt8, count: Int) -> [UInt8]? {
        (0..<count).map { registers[(Int(register) + $0) & 0xFF] }
    }

    func write(register: UInt8, bytes: [UInt8]) -> Bool {
        for (index, byte) in bytes.enumerated() { registers[(Int(register) + index) & 0xFF] = byte }
        return true
    }
}

/// The Dialog D1815 PMU (device tree `i2c0/pmu`, address 0x74). Only its
/// register file for now: every LDO, buck and GPIO setting the kernel
/// writes reads back, which is all AppleD1815PMU needs to start and to
/// serve the power functions other drivers wait for (`function-lcd_ldo`
/// among them). No events, ADC or charger behavior yet.
final class D1815PMU: I2CRegisterFile {
    static let address: UInt8 = 0x74
}
