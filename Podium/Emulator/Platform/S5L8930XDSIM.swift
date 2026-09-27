import Foundation

/// The Samsung MIPI DSI master (device tree `mipi-dsim`, physical
/// `0x89500000`) that drives the LCD panel's link. AppleSamsungMIPIDSI-
/// Controller powers the link up and down with the display, and after
/// every step it polls `STATUS` (`+0x00`) for the lanes to reach the state
/// it asked for — panicking with "_waitStatus timeout" when they don't.
///
/// Register layout from openiBoot's A4 `mipi_dsim.h`, which drives the same
/// block. `STATUS` is computed from what the kernel has asked for:
///
/// - bit 31, PLL stable, and bit 20, software reset done: always, since the
///   PLL locks and the reset finishes at once.
/// - bit 10, HS clock ready: follows `CLKCTRL` (`+0x08`) bit 31, the
///   request for the high-speed clock.
/// - bit 9 and bits 7:4, clock and data lanes in ULPS: while `ESCMODE`
///   (`+0x14`) requests ULPS (bit 1 clock, bit 3 data) without also
///   requesting the exit (bits 0 and 2).
/// - bit 8 and bits 3:0, clock and data lanes in stop state: whenever
///   they aren't in ULPS. Lane 0 returning to stop is how the kernel knows
///   a command packet has gone out.
///
/// `INTSRC` (`+0x2C`) is write-one-to-clear. A read request written to
/// the packet header FIFO (`+0x34`) is answered at once by `panel`: its
/// response goes into the read FIFO (`+0x3C`), `INTSRC` gets bit 18 (read
/// data done), and `FIFOCTRL` (`+0x44`) bit 24, read FIFO empty, clears
/// until it's drained. Everything else is kept as written.
final class S5L8930XDSIM: MMIODevice {
    static let windowLength: UInt32 = 0x1000

    static let status: UInt32 = 0x00
    static let clockControl: UInt32 = 0x08
    static let escapeMode: UInt32 = 0x14
    static let interruptSource: UInt32 = 0x2C
    static let packetHeader: UInt32 = 0x34
    static let readFIFO: UInt32 = 0x3C
    static let fifoControl: UInt32 = 0x44

    static let pllStable: UInt32 = 1 << 31
    static let resetDone: UInt32 = 1 << 20
    static let highSpeedClockReady: UInt32 = 1 << 10
    static let clockLaneULPS: UInt32 = 1 << 9
    static let clockLaneStop: UInt32 = 1 << 8
    static let dataLanesULPS: UInt32 = 0xF << 4
    static let dataLanesStop: UInt32 = 0xF
    static let readDataDone: UInt32 = 1 << 18
    static let readFIFOEmpty: UInt32 = 1 << 24

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var readResponse: [UInt32] = []
    /// Answers a read request packet: its data type (low 6 bits of the
    /// header) and two parameter bytes, to the response words the panel
    /// sends back.
    var panel: (_ dataType: UInt8, _ data0: UInt8, _ data1: UInt8) -> [UInt32] = S5L8930XDSIM.silentPanel
    /// Diagnostic hook: one line per packet sent.
    var tracePacket: ((String) -> Void)?

    func readRegister(at offset: UInt32) -> UInt32 {
        switch offset {
        case Self.status: return computedStatus
        case Self.readFIFO: return readResponse.isEmpty ? 0 : readResponse.removeFirst()
        case Self.fifoControl: return registers[Int(offset / 4)] | (readResponse.isEmpty ? Self.readFIFOEmpty : 0)
        default: return registers[Int(offset / 4)]
        }
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        switch offset {
        case Self.interruptSource:
            registers[Int(offset / 4)] &= ~value
        case Self.packetHeader:
            registers[Int(offset / 4)] = value
            send(header: value)
        default:
            registers[Int(offset / 4)] = value
        }
    }

    private var computedStatus: UInt32 {
        let escape = registers[Int(Self.escapeMode / 4)]
        let clockULPS = escape & 0b0011 == 0b0010
        let dataULPS = escape & 0b1100 == 0b1000
        var status = Self.pllStable | Self.resetDone
        if registers[Int(Self.clockControl / 4)] & 0x8000_0000 != 0 { status |= Self.highSpeedClockReady }
        status |= clockULPS ? Self.clockLaneULPS : Self.clockLaneStop
        status |= dataULPS ? Self.dataLanesULPS : Self.dataLanesStop
        return status
    }

    private func send(header: UInt32) {
        let dataType = UInt8(header & 0x3F)
        let data0 = UInt8((header >> 8) & 0xFF)
        let data1 = UInt8((header >> 16) & 0xFF)
        tracePacket?(String(format: "DSI packet type %02x data %02x %02x", dataType, data0, data1))
        guard Self.isReadRequest(dataType) else { return }
        readResponse = panel(dataType, data0, data1)
        registers[Int(Self.interruptSource / 4)] |= Self.readDataDone
    }

    /// Generic reads with 0, 1 or 2 parameters, and the DCS read.
    static func isReadRequest(_ dataType: UInt8) -> Bool {
        [0x04, 0x14, 0x24, 0x06].contains(dataType)
    }

    /// A panel that answers every read with a one-byte zero: a DCS short
    /// read response (`0x21`) to a DCS read, a generic one (`0x11`)
    /// otherwise.
    static func silentPanel(_ dataType: UInt8, _ data0: UInt8, _ data1: UInt8) -> [UInt32] {
        [dataType == 0x06 ? 0x21 : 0x11]
    }
}
