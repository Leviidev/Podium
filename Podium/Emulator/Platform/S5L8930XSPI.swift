import Foundation

/// A device on an SPI bus: full duplex, one byte in for one byte out,
/// framed by its chip select.
protocol SPISlave: AnyObject {
    func chipSelectChanged(_ selected: Bool)
    func exchange(_ byte: UInt8) -> UInt8
}

/// The S5L8930X's Samsung SPI controller (device tree `spi-1,samsung`,
/// `spi-version` 1), as AppleSamsungSPIController drives it for
/// programmed I/O:
///
/// - `+0x00` control: bit 0 enables the controller; bits 2 and 3 clear the
///   transmit and receive FIFOs.
/// - `+0x04` config: bit 5 interrupts, bit 7 receive, bit 8 transmit,
///   bit 21 counted transfer (`+0x4C` bytes); the rest is clocking and
///   mode, kept as written.
/// - `+0x08` status: transmit FIFO level in bits 10:6 and receive FIFO
///   level in bits 15:11, 16 deep each. The driver writes back what it
///   read to acknowledge; the levels are read-only.
/// - `+0x10` transmit FIFO, `+0x20` receive FIFO; `+0x34` and `+0x4C` the
///   transfer's byte count (the larger of what's sent and received).
///
/// A transfer: the driver fills the transmit FIFO, sets the count, then
/// sets bits 5, 7, 8 and 21. Each byte clocked out comes back from the
/// slave into the receive FIFO; the interrupt stays asserted while there
/// are received bytes to drain or the count needs more bytes to send, and
/// the driver's handler drains and refills until the count is done.
/// Bytes move at once — no host time passes on the wire.
final class S5L8930XSPI: MMIODevice, DMAEndpoint {
    static let windowLength: UInt32 = 0x1000
    static let fifoDepth = 16

    static let control: UInt32 = 0x00
    static let config: UInt32 = 0x04
    static let status: UInt32 = 0x08
    static let transmitData: UInt32 = 0x10
    static let receiveData: UInt32 = 0x20
    static let receiveCount: UInt32 = 0x34
    static let transmitCount: UInt32 = 0x4C

    static let configInterrupt: UInt32 = 1 << 5
    static let configDMA: UInt32 = 1 << 6
    static let configReceive: UInt32 = 1 << 7
    static let configTransmit: UInt32 = 1 << 8
    static let configCounted: UInt32 = 1 << 21

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var transmitFIFO: [UInt8] = []
    private var receiveFIFO: [UInt8] = []
    private var remaining = 0
    private let setInterruptLine: (Bool) -> Void
    weak var slave: SPISlave?
    /// Diagnostic hook: every byte exchanged, as (sent, received).
    var traceExchange: ((UInt8, UInt8) -> Void)?
    /// Called when the FIFOs change, so DMA channels feeding or draining
    /// them can move more bytes.
    var dmaRequest: (() -> Void)?

    // MARK: DMA

    /// DMA feeds the transmit FIFO and drains the receive FIFO through the
    /// same flow control a CPU would use.
    var dmaSpace: Int { Self.fifoDepth - transmitFIFO.count }
    func dmaPush(_ byte: UInt8) {
        transmitFIFO.append(byte)
        run()
    }
    var dmaAvailable: Int { receiveFIFO.count }
    func dmaPop() -> UInt8 {
        let byte = receiveFIFO.removeFirst()
        run()
        return byte
    }

    init(setInterruptLine: @escaping (Bool) -> Void) {
        self.setInterruptLine = setInterruptLine
    }

    private var configValue: UInt32 { registers[Int(Self.config / 4)] }
    private var enabled: Bool { registers[Int(Self.control / 4)] & 1 != 0 }
    /// Clocking bytes: transmit enabled for programmed I/O, or DMA mode.
    private var transferring: Bool { enabled && configValue & (Self.configTransmit | Self.configDMA) != 0 }
    private var counted: Bool { configValue & Self.configCounted != 0 }

    func readRegister(at offset: UInt32) -> UInt32 {
        switch offset {
        case Self.status:
            return (registers[Int(offset / 4)] & ~0xFFC0) | UInt32(transmitFIFO.count) << 6 | UInt32(receiveFIFO.count) << 11
        case Self.receiveData:
            let byte = receiveFIFO.isEmpty ? 0 : receiveFIFO.removeFirst()
            run()
            return UInt32(byte)
        default:
            return registers[Int(offset / 4)]
        }
    }

    /// Diagnostic hook: register writes other than the data FIFO.
    var traceWrite: ((String) -> Void)?

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        if offset != Self.transmitData { traceWrite?(String(format: "W %02x = %08x (tx %d rx %d remaining %d)", offset, value, transmitFIFO.count, receiveFIFO.count, remaining)) }
        switch offset {
        case Self.control:
            if value & (1 << 2) != 0 { transmitFIFO.removeAll() }
            if value & (1 << 3) != 0 { receiveFIFO.removeAll() }
            registers[Int(offset / 4)] = value & ~0xC
        case Self.transmitData:
            if transmitFIFO.count < Self.fifoDepth { transmitFIFO.append(UInt8(truncatingIfNeeded: value)) }
        case Self.transmitCount:
            registers[Int(offset / 4)] = value
            remaining = Int(value)
        case Self.status:
            break
        case Self.config:
            registers[Int(offset / 4)] = value
        default:
            registers[Int(offset / 4)] = value
        }
        run()
    }

    /// Clocks bytes while there's something to send, room to receive it,
    /// and count left.
    private func run() {
        while transferring, !counted || remaining > 0, !transmitFIFO.isEmpty, receiveFIFO.count < Self.fifoDepth {
            let sent = transmitFIFO.removeFirst()
            let received = slave?.exchange(sent) ?? 0xFF
            traceExchange?(sent, received)
            if configValue & Self.configReceive != 0 { receiveFIFO.append(received) }
            if counted { remaining -= 1 }
        }
        updateInterruptLine()
        dmaRequest?()
    }

    private func updateInterruptLine() {
        let wantsService = !receiveFIFO.isEmpty || (transferring && counted && remaining > 0 && transmitFIFO.count < Self.fifoDepth)
        setInterruptLine(configValue & Self.configInterrupt != 0 && enabled && wantsService)
    }
}
