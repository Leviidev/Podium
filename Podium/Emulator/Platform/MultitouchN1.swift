import Foundation

/// The touchscreen controller on SPI1 (device tree `multi-touch,n18`,
/// driven by AppleMultitouchN1SPI), modeled at its SPI protocol, with its
/// interrupt ("ATN") on GPIO pin 21 (active low), chip select on GPIO pin
/// 49 and reset on GPIO pin 20. openiBoot's `multitouch-z2.c` documents the protocol; the
/// kernel driver's own trace messages and checks fill in the N1 parts.
///
/// Each transaction is one chip-select frame, and replies are pipelined:
/// what the controller clocks out during a frame is what it loaded after
/// the previous one — its answer to it, or, when it has nothing to
/// answer, whatever it wants to say unprompted. The driver works with
/// that: it sends each query twice and reads the second reply.
///
/// It powers up in its bootloader ("HBPP"). The driver checks for it —
/// the reply's first two 16-bit words must be bootloader status codes —
/// then downloads the firmware from `N81.mtprops` as a stream of `30 01`
/// data packets, reads and writes a few registers (`1C 73` / `1E 33`),
/// calibrates (`1F 01`) and executes it (`1D 53`). Each command but the
/// last is answered by pulling ATN low; the driver then sends an ATN
/// acknowledgement (`1A A1`, or `1A A1 18 E1 …` for a register read)
/// and reads the status (`0x4BC1` OK, `0x4AD1` for register writes) or
/// the value from its reply.
///
/// Running firmware speaks the Zephyr2 command set: 16-byte packets with
/// a 16-bit little-endian byte sum over bytes 0...13 in bytes 14...15,
/// answered in kind —
///
/// - `E2` interface version (byte 2) and maximum packet size (3...4).
/// - `E3 id` a report's error flag (byte 2) and length (3...4).
/// - `E6 id s len` / `E7 id s len` read a report: stage `s` 0 asks, stage
///   1 collects `E6 id 0 data… sum` (padded to 16 bytes) or, for longer
///   reports, `E7 id 0 data… sum` sized to fit.
/// - `E4 id …` / `E5 id s len …` write a report; the driver then reads
///   the command status with a single `E1` packet, so the status (byte 8,
///   0 for success) is loaded as soon as the write lands.
/// - `EA`/`EB` read a frame: with byte 2 = 0 the driver collects the
///   frame's length (bytes 1...2), which must already be loaded — the
///   controller loads it when it pulls ATN low to announce the frame —
///   then with byte 2 = 1 it collects the frame: `EA 00 len len pad`
///   (the five bytes summing to 0 mod 256), the frame, and the frame's
///   16-bit byte sum.
///
/// Reports and frames follow the iPod touch controllers' Zephyr2 layout
/// that MultitouchSupport expects: family 81 (0x51, one of the iPhone and
/// iPod touch families, whose sensor surface is 5000 × 7500), 15 rows ×
/// 10 columns. A frame is a 24-byte path header (type 0x44) and a 28-byte
/// record per finger, positions in hundredths of a millimeter with the
/// origin at the bottom left.
final class MultitouchN1: SPISlave {
    static let chipSelectPin = 49
    /// The device tree's `function-reset` (GPIO bank 2, pin 4). Any change
    /// on it resets the controller: a reset pulse leaves it in its
    /// bootloader whichever way the line settles, as after power-up — the
    /// driver resets it that way when the device wakes, and downloads the
    /// firmware again.
    static let resetPin = 20

    private enum Mode { case bootloader, firmware }
    private var mode = Mode.bootloader
    private var selected = false
    private var command: [UInt8] = []
    private var reply: [UInt8]
    private var replyIndex = 0
    private var sentThisFrame: [UInt8] = []
    private var bootloaderRegisters: [UInt32: UInt32] = [:]

    static let interfaceVersion: UInt8 = 1
    static let maxPacketSize = 0x294
    static let familyID: UInt8 = 81
    static let sensorRows: UInt8 = 15
    static let sensorColumns: UInt8 = 10
    /// The sensor surface in hundredths of a millimeter — the iPod touch
    /// 4's 3.5" panel — and finger positions span it exactly.
    static let surfaceWidth: UInt16 = 5000
    static let surfaceHeight: UInt16 = 7500

    /// Reports by ID, as the firmware answers them. Besides the ones the
    /// kernel reads to describe the sensor (0xD0...0xD9), these are the
    /// settings MultitouchSupport reads and writes (and 0x7E, power
    /// statistics the kernel reads), at the lengths they
    /// uses; they start out zero.
    private(set) var reports: [UInt8: [UInt8]] = {
        var reports: [UInt8: [UInt8]] = [
            0xD0: [0],
            0xA1: [0],
            0xD1: [familyID],
            // Endianness, rows, columns, BCD version (big-endian).
            0xD3: [1, sensorRows, sensorColumns, 51, 0],
            0xD7: [0],
            // Surface size, then the range finger positions cover (x min,
            // y min, x max, y max) — MultitouchSupport normalizes positions
            // by it, and reads it from exactly these 16 bytes.
            0xD9: le32(UInt32(surfaceWidth)) + le32(UInt32(surfaceHeight)) + le16(0) + le16(0) + le16(Int(surfaceWidth)) + le16(Int(surfaceHeight)),
        ]
        let settings: [UInt8: Int] = [0x40: 1, 0x41: 1, 0x47: 1, 0x4F: 1, 0x70: 1, 0x7E: 8, 0x7F: 4, 0xA0: 1, 0xA3: 1, 0xA4: 1, 0xA5: 1,
                                      0xAF: 1, 0xB0: 1, 0xB2: 32, 0xB4: 40, 0xB6: 32, 0xBF: 4, 0xCB: 4, 0xCC: 1]
        for (id, length) in settings { reports[id] = Array(repeating: 0, count: length) }
        return reports
    }()
    /// Drives the ATN line (true = asserted, i.e. pulled low).
    var setAttention: ((Bool) -> Void)?
    /// Diagnostic hook: one line per transaction.
    var traceTransaction: ((String) -> Void)?

    private static let statusOK: [UInt8] = [0x4B, 0xC1]
    private static let statusRegisterWritten: [UInt8] = [0x4A, 0xD1]

    // MARK: Touch state

    enum Phase { case began, moved, ended }
    private struct Finger {
        var x: Double
        var y: Double
        var velocityX = 0.0
        var velocityY = 0.0
        var state: UInt8
    }
    private var finger: Finger?
    /// Frames waiting to be read, oldest first.
    private var frames: [[UInt8]] = []
    /// A frame's length is loaded and ATN is pulled low for it.
    private var announcing = false
    /// The host has asked for something whose answer is loaded and not
    /// yet collected; a frame mustn't displace it.
    private var answerPending = false
    private var lastPacket: [UInt8] = []
    private var frameNumber: UInt8 = 0
    private var lastFrameTime: UInt32 = 0

    init() {
        reply = Self.repeated(Self.statusOK)
    }

    /// Back to the bootloader, as after a reset.
    func reset() {
        mode = .bootloader
        reply = Self.repeated(Self.statusOK)
        finger = nil
        frames.removeAll()
        announcing = false
        answerPending = false
        setAttention?(false)
    }

    func chipSelectChanged(_ selected: Bool) {
        if self.selected, !selected {
            if !command.isEmpty {
                let preview = command.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
                    + (command.count > 24 ? " … (\(command.count) bytes)" : "")
                traceTransaction?("tx " + preview + " | rx " + sentThisFrame.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
                respond(to: command)
            }
            command.removeAll()
            sentThisFrame.removeAll()
            replyIndex = 0
        }
        self.selected = selected
    }

    func exchange(_ byte: UInt8) -> UInt8 {
        command.append(byte)
        let out = replyIndex < reply.count ? reply[replyIndex] : 0
        replyIndex += 1
        if sentThisFrame.count < 16 { sentThisFrame.append(out) }
        return out
    }

    // MARK: Touches

    /// A finger landing on, moving across or leaving the screen, at
    /// `x`, `y` as fractions of its width and height from the top left.
    /// `time` is the guest's clock in milliseconds.
    func touch(_ phase: Phase, x: Double, y: Double, time: UInt32) {
        let sensorX = x.clamped * Double(Self.surfaceWidth)
        let sensorY = (1 - y.clamped) * Double(Self.surfaceHeight)
        switch phase {
        case .began:
            finger = Finger(x: sensorX, y: sensorY, state: 3) // MakeTouch
        case .moved:
            guard var current = finger else { return }
            let elapsed = Double(max(1, time &- lastFrameTime)) / 1000
            current.velocityX = (sensorX - current.x) / elapsed
            current.velocityY = (sensorY - current.y) / elapsed
            current.x = sensorX
            current.y = sensorY
            current.state = 4 // Touching
            finger = current
        case .ended:
            guard var current = finger else { return }
            current.x = sensorX
            current.y = sensorY
            current.velocityX = 0
            current.velocityY = 0
            current.state = 5 // BreakTouch: lifted, still in range
            finger = current
        }
        emitFrame(time: time)
    }

    /// The controller's scan: while a finger is down it reports every
    /// sample; once it lifts, the path leaves range (OutOfRange) and a
    /// frame with no fingers ends the gesture — a lift, where going out of
    /// range while still touching would read as a cancel.
    func scan(time: UInt32) {
        guard finger != nil, frames.isEmpty else { return }
        emitFrame(time: time)
    }

    private func emitFrame(time: UInt32) {
        guard mode == .firmware else { return }
        var fingers: [[UInt8]] = []
        if let current = finger {
            if current.state != 0 { fingers.append(Self.fingerRecord(current)) }
            switch current.state {
            case 3: finger?.state = 4 // MakeTouch, then Touching
            case 5: finger?.state = 7 // BreakTouch, then OutOfRange
            case 7: finger?.state = 0 // then an empty frame
            case 0: finger = nil
            default: break
            }
        }
        var header = [UInt8](repeating: 0, count: 24)
        header[0] = 0x44 // path frame
        header[1] = frameNumber
        header[2] = 24
        header.replaceSubrange(4..<8, with: Self.le32(time))
        header[16] = UInt8(fingers.count)
        header[17] = 28
        frameNumber &+= 1
        lastFrameTime = time
        frames.append(header + fingers.flatMap { $0 })
        announceIfIdle()
    }

    private static func fingerRecord(_ finger: Finger) -> [UInt8] {
        let touching = finger.state == 3 || finger.state == 4
        var record = [UInt8](repeating: 0, count: 28)
        record[0] = 1 // path ID
        record[1] = finger.state
        record[2] = 2
        record[3] = 1
        record.replaceSubrange(4..<8, with: le16(Int(finger.x)) + le16(Int(finger.y)))
        record.replaceSubrange(8..<12, with: le16(Int(finger.velocityX)) + le16(Int(finger.velocityY)))
        // Contact ellipse and density of an ordinary fingertip press.
        record.replaceSubrange(12..<22, with: le16(touching ? 660 : 0) + le16(touching ? 580 : 0) + le16(19317)
                                   + le16(touching ? 100 : 0) + le16(touching ? 150 : 0))
        return record
    }

    /// Loads the next frame's length and pulls ATN low for it, unless the
    /// host is between asking something and collecting the answer.
    private func announceIfIdle() {
        guard mode == .firmware, !announcing, !answerPending, let frame = frames.first else { return }
        let length = frame.count + 2
        reply = Self.packet([0xEA, UInt8(length & 0xFF), UInt8(length >> 8)])
        announcing = true
        setAttention?(true)
    }

    // MARK: Protocol

    private func respond(to packet: [UInt8]) {
        switch mode {
        case .bootloader: respondInBootloader(to: packet)
        case .firmware: respondInFirmware(to: packet)
        }
    }

    private func respondInBootloader(to packet: [UInt8]) {
        let opcode = packet.count >= 2 ? UInt16(packet[0]) << 8 | UInt16(packet[1]) : 0
        switch opcode {
        case 0x1AA1: // ATN acknowledgement: the status went out with it
            setAttention?(false)
            reply = Self.repeated(Self.statusOK)
        case 0x1C73 where packet.count >= 6: // register read
            let value = bootloaderRegisters[Self.hbppAddress(packet, at: 2)] ?? 0
            reply = Self.statusOK + [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF), UInt8(value >> 24), UInt8(value >> 16 & 0xFF)]
            reply += Self.repeated(Self.statusOK)
            setAttention?(true)
        case 0x1E33 where packet.count >= 14: // register write
            let address = Self.hbppAddress(packet, at: 2)
            let mask = Self.hbppAddress(packet, at: 6)
            let value = Self.hbppAddress(packet, at: 10)
            bootloaderRegisters[address] = (bootloaderRegisters[address] ?? 0) & ~mask | value & mask
            reply = Self.repeated(Self.statusRegisterWritten)
            setAttention?(true)
        case 0x1D53: // execute the downloaded firmware
            mode = .firmware
            reply = Self.idleReply
        case 0x19C1: // wake request
            reply = Self.repeated(Self.statusOK)
        default: // firmware data packets, calibration, anything else
            reply = Self.repeated(Self.statusOK)
            setAttention?(true)
        }
    }

    private func respondInFirmware(to packet: [UInt8]) {
        defer { lastPacket = packet }
        guard let opcode = packet.first else { return }
        let stage = packet.count > 2 ? packet[2] : 0
        // A query sent the second time round has had its answer collected.
        let repeated = packet == lastPacket
        switch opcode {
        case 0xE1: // command status, collected with this very packet
            reply = Self.idleReply
            answerPending = false
        case 0xE2:
            reply = Self.packet([0xE2, 0, Self.interfaceVersion, UInt8(Self.maxPacketSize & 0xFF), UInt8(Self.maxPacketSize >> 8)])
            answerPending = !repeated
        case 0xE3 where packet.count > 1:
            let id = packet[1]
            let length = reports[id]?.count ?? 0
            reply = Self.packet([0xE3, id, reports[id] == nil ? 1 : 0, UInt8(length & 0xFF), UInt8(length >> 8)])
            answerPending = !repeated
        case 0xE6 where packet.count > 4, 0xE7 where packet.count > 4:
            // Stage 1 collects what stage 0 asked for; nothing follows it.
            guard stage == 0 else {
                reply = Self.idleReply
                answerPending = false
                break
            }
            let id = packet[1]
            let size = Int(packet[3]) | Int(packet[4]) << 8
            var data = reports[id] ?? []
            data += Array(repeating: 0, count: max(0, size - data.count))
            data = Array(data.prefix(size))
            if opcode == 0xE6 {
                reply = Self.packet([0xE6, id, 0] + data)
            } else {
                let body = [0xE7, id, 0] + data
                let sum = body.reduce(0) { $0 + Int($1) }
                reply = body + [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]
            }
            answerPending = true
        case 0xE4 where packet.count > 2:
            // E4 id length data… (a short report, in one packet).
            store(report: packet[1], from: packet, length: Int(packet[2]))
            reply = Self.commandStatus
            answerPending = true
        case 0xE5 where packet.count > 4:
            // E5 id 0 length, then E5 id 1 data… sum.
            if stage == 1 {
                store(report: packet[1], from: packet, length: packet.count - 5)
                reply = Self.commandStatus
                answerPending = true
            } else {
                reply = Self.idleReply
                answerPending = false
            }
        case 0xEA, 0xEB:
            if stage == 0, announcing, let frame = frames.first {
                // The length went out with this packet; the frame goes next.
                let length = frame.count + 2
                var header: [UInt8] = [0xEA, 0, UInt8(length & 0xFF), UInt8(length >> 8)]
                header.append(UInt8((256 - header.reduce(0) { $0 + Int($1) } % 256) % 256))
                let sum = frame.reduce(0) { $0 + Int($1) }
                reply = header + frame + [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]
                answerPending = true
            } else {
                if stage == 1, announcing {
                    frames.removeFirst()
                    announcing = false
                    setAttention?(false)
                }
                reply = Self.idleReply
                answerPending = false
            }
        default:
            reply = Self.idleReply
            answerPending = false
        }
        announceIfIdle()
    }

    private func store(report id: UInt8, from packet: [UInt8], length: Int) {
        guard length > 0, packet.count >= 3 + length else { return }
        reports[id] = Array(packet[3..<(3 + length)])
    }

    /// With nothing to say: a frame length of zero.
    private static let idleReply = packet([0xEA])
    private static let commandStatus = packet([0xE1])

    /// HBPP's word order: bytes 2...5 are bits 15:8, 7:0, 31:24, 23:16.
    private static func hbppAddress(_ packet: [UInt8], at offset: Int) -> UInt32 {
        UInt32(packet[offset]) << 8 | UInt32(packet[offset + 1]) | UInt32(packet[offset + 2]) << 24 | UInt32(packet[offset + 3]) << 16
    }

    private static func repeated(_ word: [UInt8]) -> [UInt8] {
        Array(repeating: word, count: 8).flatMap { $0 }
    }

    private static func le16(_ value: Int) -> [UInt8] {
        let bits = UInt16(truncatingIfNeeded: value)
        return [UInt8(bits & 0xFF), UInt8(bits >> 8)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }

    /// Pads `body` to 14 bytes and appends its checksum.
    static func packet(_ body: [UInt8]) -> [UInt8] {
        var bytes = Array((body + Array(repeating: 0, count: 14)).prefix(14))
        let sum = bytes.reduce(0) { $0 + Int($1) }
        bytes += [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]
        return bytes
    }
}

private extension Double {
    var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}
