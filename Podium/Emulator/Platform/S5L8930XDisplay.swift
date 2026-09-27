import Foundation

/// The LCD's display pipe (device tree `clcd` `reg` index 0, physical
/// `0x89000000`, interrupt `0x2a`): its interrupt status, and the command
/// FIFO the kernel programs layers through. Register layout from
/// AppleDisplayPipe's interrupt filter and handler and its swap path.
///
/// - `+0x1028` interrupt enable, `+0x102c` status (write-one-to-clear).
///   Bit 0 is the frame's vblank; the filter only runs the handler for
///   status bits that are enabled, and the kernel enables bit 0 while
///   anyone listens for vblank — CoreAnimation's render server does, and
///   only draws when one arrives. Bit 8 says a command finished.
/// - `+0x103c` command FIFO. A swap is written as a header (bit 31 set,
///   bits 25:16 the number of words that follow, bits 15:0 its ID), then
///   groups of `count << 16 | register offset` each followed by `count`
///   values for consecutive registers. The hardware applies a command at
///   the next vblank, sets `+0x1048` to its ID, and raises bit 8, which
///   is how the kernel knows the swap is on screen.
///
/// Every other register is kept as written; the layer registers the
/// commands set are what `DisplayScanout` reads.
final class S5L8930XDisplayPipe: MMIODevice {
    static let windowLength: UInt32 = 0x7000
    static let interruptEnable: UInt32 = 0x1028
    static let interruptStatus: UInt32 = 0x102C
    static let commandFIFO: UInt32 = 0x103C
    static let completedCommandID: UInt32 = 0x1048
    static let vblank: UInt32 = 1 << 0
    static let commandDone: UInt32 = 1 << 8

    private let setInterruptLine: (Bool) -> Void
    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    private var command: (id: UInt32, remaining: Int, words: [UInt32])?
    private var pendingCommands: [(id: UInt32, words: [UInt32])] = []
    /// Diagnostic hook: one line per register write.
    var traceWrite: ((String) -> Void)?

    init(setInterruptLine: @escaping (Bool) -> Void) {
        self.setInterruptLine = setInterruptLine
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        registers[Int(offset / 4)]
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        traceWrite?(String(format: "W %04x = %08x", offset, value))
        switch offset {
        case Self.interruptStatus: registers[Int(offset / 4)] &= ~value
        case Self.commandFIFO: receiveCommandWord(value)
        default: registers[Int(offset / 4)] = value
        }
        updateInterruptLine()
    }

    /// The end of a frame: commands written since the last one take
    /// effect.
    func frameEnded() {
        var status = Self.vblank
        for pending in pendingCommands {
            apply(pending.words)
            registers[Int(Self.completedCommandID / 4)] = pending.id
            status |= Self.commandDone
        }
        pendingCommands.removeAll()
        registers[Int(Self.interruptStatus / 4)] |= status
        updateInterruptLine()
    }

    private func receiveCommandWord(_ word: UInt32) {
        if var current = command {
            current.words.append(word)
            current.remaining -= 1
            command = current.remaining > 0 ? current : nil
            if current.remaining == 0 { pendingCommands.append((current.id, current.words)) }
        } else if word & 0x8000_0000 != 0 {
            let count = Int((word >> 16) & 0x3FF)
            if count == 0 {
                pendingCommands.append((word & 0xFFFF, []))
            } else {
                command = (word & 0xFFFF, count, [])
            }
        }
    }

    private func apply(_ words: [UInt32]) {
        var index = 0
        while index < words.count {
            let count = Int((words[index] >> 16) & 0xFF)
            let start = words[index] & 0xFFFF
            for n in 0..<count where index + 1 + n < words.count {
                let offset = start &+ UInt32(n * 4)
                if offset < Self.windowLength { registers[Int(offset / 4)] = words[index + 1 + n] }
            }
            index += 1 + count
        }
    }

    private func updateInterruptLine() {
        setInterruptLine(registers[Int(Self.interruptStatus / 4)] & registers[Int(Self.interruptEnable / 4)] != 0)
    }
}

/// The CLCD block itself (device tree `clcd` `reg` index 1, physical
/// `0x89200000`, interrupt `0x29`): AppleCLCD arms its own interrupt while
/// a swap or a table update waits for the next frame, and its filter
/// treats status bit 2 at `+0x68` as that frame's vsync, acknowledging it
/// by writing the bit back. The rest is kept as written — including the
/// enable and panel-size registers `KernelBootstrap` leaves as iBoot would.
final class S5L8930XCLCD: MMIODevice {
    static let windowLength: UInt32 = 0x1000
    static let interruptStatus: UInt32 = 0x68
    static let vsync: UInt32 = 1 << 2

    private let setInterruptLine: (Bool) -> Void
    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))

    init(setInterruptLine: @escaping (Bool) -> Void) {
        self.setInterruptLine = setInterruptLine
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        registers[Int(offset / 4)]
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        if offset == Self.interruptStatus {
            registers[Int(offset / 4)] &= ~value
            updateInterruptLine()
        } else {
            registers[Int(offset / 4)] = value
        }
    }

    /// The end of a frame.
    func frameEnded() {
        registers[Int(Self.interruptStatus / 4)] |= Self.vsync
        updateInterruptLine()
    }

    private func updateInterruptLine() {
        setInterruptLine(registers[Int(Self.interruptStatus / 4)] & 0xF != 0)
    }
}
