import CommonCrypto
import Foundation

/// The S5L8930X "CDMA" DMA engine (device tree `cdma`: channels at
/// `0x07000000`, `0x26000`; AES filter contexts at `0x07800000`,
/// `0x9000`) — only its memory-to-memory path, the one `IOAESAccelerator`
/// uses for every hardware AES operation (AppleKeyStore's UID-key
/// derivations among them). With no engine behind these registers the
/// first such operation, a few hundred million instructions into boot,
/// never completes, and every keybag call after it — securityd's
/// `MKBGetDeviceLockState`, and so lockdownd and backboardd behind it —
/// blocks forever.
///
/// Register layout from the kernel's AppleCDMA driver (its own debug
/// strings name them: CSR/DCR/DAR/DBR/MAR/CAR/ERR) and openiBoot's A4
/// `cdma.c`, which drives the same block:
///
/// - Global page: `+0x0`/`+0x4` enable-set and `+0x8`/`+0xC` disable-set,
///   one bit per channel; `+0x10`/`+0x14` read back which are enabled.
/// - Channel `n` at `n << 12`: CSR `+0x0`, DCR `+0x4`, DAR `+0x8`, DBR
///   (bytes remaining) `+0xC`, MAR `+0x10`, CAR (command chain, physical)
///   `+0x14`, ERR `+0x18`. CSR bit 0 starts the channel, writing bit 1
///   aborts it; bits 17:16 read the state (1 = running); bit 18 (error)
///   and bit 19 (done) are write-one-to-clear interrupt status, bit 3
///   enables the channel's interrupt (VIC line `0x30 + n`), bit 7 marks a
///   memory-to-memory channel, and bits 15:8 name the AES context
///   filtering it (0 = none). Memory-to-memory channels pair up odd →
///   even: the kernel reads through channel 1 into channel 2.
/// - Command chain: 32-byte descriptors `{next, command, address,
///   length, …}`; command bits 1:0 = 3 is a data segment, bit 8 the last
///   one, and a zero command ends the chain.
/// - AES context `k` at `0x800000 + (k << 12)`: control `+0x0` (bits
///   15:8 the channel it filters, bit 16 encrypt, bit 17 CBC, bits
///   19:18 key size, bit 20 key from `+0x20…`, bits 24:21 the key
///   otherwise: 0 UID, 1 GID, 0xF the registered key), IV `+0x10…+0x1C`
///   — the kernel stores the IV buffer's words as-is, so register n is
///   little-endian bytes 4n…4n+3, and the key registers are read the
///   same way.
///
/// The real UID key is fused into each device and never leaves the
/// hardware, so UID operations use a fixed stand-in: everything the
/// guest wraps with it is only ever unwrapped by this same engine, which
/// is all consistency requires. GID operations (firmware image
/// decryption) aren't expected at runtime and use the same stand-in.
final class S5L8930XCDMA: MMIODevice {
    static let channelsBase: UInt32 = 0x0700_0000
    static let channelsLength: UInt32 = 0x26000
    static let aesBase: UInt32 = 0x0780_0000
    static let aesLength: UInt32 = 0x9000
    static let firstInterruptLine = 0x30

    private static let csrStart: UInt32 = 1 << 0
    private static let csrAbort: UInt32 = 1 << 1
    private static let csrInterruptEnable: UInt32 = 1 << 3
    private static let csrMemoryToMemory: UInt32 = 1 << 7
    private static let csrStateMask: UInt32 = 3 << 16
    private static let csrStateRunning: UInt32 = 1 << 16
    private static let csrError: UInt32 = 1 << 18
    private static let csrDone: UInt32 = 1 << 19
    private static let csrWriteOneToClear: UInt32 = 7 << 18

    /// Stand-in for the device's fused UID key (see the type comment).
    static let standInHardwareKey: [UInt8] = Array("Podium stand-in A4 UID key 00001".utf8)

    private let memory: () -> MemoryBus
    private let setInterruptLine: (_ line: Int, _ asserted: Bool) -> Void
    private var registers = [UInt32](repeating: 0, count: Int(channelsLength / 4))
    private var enabledChannels: [UInt32] = [0, 0]
    /// Diagnostic hooks: one line per memory-to-memory transfer, and
    /// (when set) one per register access.
    var log: ((String) -> Void)?
    var traceAccess: ((String) -> Void)?

    /// The AES filter contexts' own register window.
    let aes = AESContexts()

    final class AESContexts: MMIODevice {
        fileprivate var registers = [UInt32](repeating: 0, count: Int(S5L8930XCDMA.aesLength / 4))
        func readRegister(at offset: UInt32) -> UInt32 { registers[Int(offset / 4)] }
        func writeRegister(_ value: UInt32, at offset: UInt32) { registers[Int(offset / 4)] = value }
        fileprivate func word(_ context: Int, _ offset: UInt32) -> UInt32 { registers[Int((UInt32(context) << 12 | offset) / 4)] }
    }

    init(memory: @escaping () -> MemoryBus, setInterruptLine: @escaping (_ line: Int, _ asserted: Bool) -> Void) {
        self.memory = memory
        self.setInterruptLine = setInterruptLine
    }

    private func register(_ channel: Int, _ offset: UInt32) -> UInt32 { registers[Int((UInt32(channel) << 12 | offset) / 4)] }
    private func setRegister(_ channel: Int, _ offset: UInt32, _ value: UInt32) { registers[Int((UInt32(channel) << 12 | offset) / 4)] = value }

    func readRegister(at offset: UInt32) -> UInt32 {
        let value: UInt32
        switch offset {
        case 0x10: value = enabledChannels[0]
        case 0x14: value = enabledChannels[1]
        default: value = registers[Int(offset / 4)]
        }
        traceAccess?(String(format: "R %05x = %08x", offset, value))
        return value
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        traceAccess?(String(format: "W %05x = %08x", offset, value))
        let channel = Int(offset >> 12)
        let register = offset & 0xFFF
        if channel == 0 {
            switch offset {
            case 0x0, 0x4: enabledChannels[Int(offset / 4)] |= value
            case 0x8, 0xC: enabledChannels[Int((offset - 8) / 4)] &= ~value
            default: registers[Int(offset / 4)] = value
            }
            return
        }
        guard register == 0 else {
            registers[Int(offset / 4)] = value
            return
        }
        let old = registers[Int(offset / 4)]
        var csr = (value & ~(Self.csrWriteOneToClear | Self.csrStateMask)) | (old & (Self.csrWriteOneToClear | Self.csrStateMask))
        csr &= ~(value & Self.csrWriteOneToClear)
        if value & Self.csrAbort != 0 {
            csr &= ~(Self.csrStateMask | Self.csrStart | Self.csrAbort)
        }
        if value & Self.csrStart != 0, old & Self.csrStateMask == 0 {
            csr = (csr & ~Self.csrStateMask) | Self.csrStateRunning
        }
        registers[Int(offset / 4)] = csr
        if csr & (Self.csrError | Self.csrDone) == 0 { setInterruptLine(Self.firstInterruptLine + channel, false) }
        if value & Self.csrStart != 0 { startIfReady(channel) }
    }

    /// A memory-to-memory pair (odd source, even sink) runs once both
    /// halves have been started.
    private func startIfReady(_ channel: Int) {
        let csr = register(channel, 0)
        guard csr & Self.csrMemoryToMemory != 0 else {
            log?(String(format: "cdma| channel %d started without memory-to-memory mode (csr %08x) — not modeled", channel, csr))
            return
        }
        let source = channel & 1 == 1 ? channel : channel - 1
        let sink = source + 1
        guard source >= 1, sink < Int(Self.channelsLength >> 12) else { return }
        let running = { (c: Int) in self.register(c, 0) & Self.csrStateMask == Self.csrStateRunning }
        guard running(source), running(sink) else { return }
        transfer(from: source, to: sink)
    }

    private struct Segment { let address: UInt32; let length: Int }

    private func segments(ofChainAt start: UInt32) -> [Segment] {
        let bus = memory()
        var result: [Segment] = []
        var descriptor = start
        for _ in 0..<4096 {
            guard let command = try? bus.readWord32(at: descriptor &+ 4), command != 0 else { break }
            if command & 3 == 3, let address = try? bus.readWord32(at: descriptor &+ 8), let length = try? bus.readWord32(at: descriptor &+ 12) {
                result.append(Segment(address: address, length: Int(length)))
            }
            if command & 0x100 != 0 { break }
            guard let next = try? bus.readWord32(at: descriptor) else { break }
            descriptor = next
        }
        return result
    }

    private func transfer(from source: Int, to sink: Int) {
        let bus = memory()
        var input = Data()
        for segment in segments(ofChainAt: register(source, 0x14)) {
            input.append((try? bus.readBytes(segment.length, at: segment.address)) ?? Data(count: segment.length))
        }
        var output = input
        var description = "copy"
        let contextField = { (c: Int) in Int((self.register(c, 0) >> 8) & 0xFF) }
        let context = [contextField(source), contextField(sink)].first { $0 != 0 && $0 < 9 }
        if let context {
            let control = aes.word(context, 0)
            let encrypt = control & (1 << 16) != 0
            let cbc = control & (1 << 17) != 0
            let key: [UInt8]
            let keySelect = (control >> 21) & 0xF
            if control & (1 << 20) != 0 || keySelect == 0xF {
                let words = [4, 6, 8][Int(min((control >> 18) & 3, 2))]
                key = (0..<words).flatMap { i -> [UInt8] in withUnsafeBytes(of: aes.word(context, 0x20 + UInt32(i * 4)).littleEndian, Array.init) }
                description = "custom-\(words * 32)"
            } else {
                key = Self.standInHardwareKey
                description = keySelect == 1 ? "GID(stand-in)" : keySelect == 0 ? "UID(stand-in)" : "key \(keySelect)(stand-in)"
            }
            let iv = (0..<4).flatMap { i -> [UInt8] in withUnsafeBytes(of: aes.word(context, 0x10 + UInt32(i * 4)).littleEndian, Array.init) }
            output = Self.aes(input, key: key, iv: iv, encrypt: encrypt, cbc: cbc)
            description += " \(encrypt ? "encrypt" : "decrypt") \(cbc ? "CBC" : "ECB") ctx \(context)" + String(format: " (control %08x)", control)
        }
        var cursor = 0
        for segment in segments(ofChainAt: register(sink, 0x14)) where cursor < output.count {
            let chunk = output.subdata(in: cursor..<min(cursor + segment.length, output.count))
            try? bus.writeBytes(chunk, at: segment.address)
            cursor += chunk.count
        }
        log?(String(format: "cdma| channels %d->%d: %d bytes, %@", source, sink, input.count, description))
        for channel in [source, sink] {
            let csr = register(channel, 0)
            setRegister(channel, 0, (csr & ~(Self.csrStateMask | Self.csrStart)) | Self.csrDone)
            setRegister(channel, 0xC, 0)
            if csr & Self.csrInterruptEnable != 0 { setInterruptLine(Self.firstInterruptLine + channel, true) }
        }
    }

    /// AES over whole 16-byte blocks, CBC or ECB, no padding.
    static func aes(_ input: Data, key: [UInt8], iv: [UInt8], encrypt: Bool, cbc: Bool) -> Data {
        let length = input.count & ~15
        guard length > 0 else { return input }
        var output = Data(count: length)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(cbc ? 0 : kCCOptionECBMode),
                        key, key.count, iv, inp.baseAddress, length, out.baseAddress, length, &moved)
            }
        }
        guard status == kCCSuccess else { return input }
        return output + input.suffix(from: length)
    }
}
