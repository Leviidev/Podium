import Foundation

/// The inner loops of QuartzCore's software renderer, run natively.
///
/// With no GPU modeled, iOS composites every frame on the CPU: backboardd
/// (the render server) spent two thirds of all guest time during the
/// unlock animation, 94% of it in four span functions — a bilinear and
/// two nearest-neighbour texture samplers, and a source-over blend. A
/// full-screen bilinear layer is about 70 interpreted instructions a
/// pixel, over 40 million a frame. Done here instead, each call costs the
/// guest one instruction's worth of time.
///
/// Each is a transliteration of the ARM code, operation for operation in
/// 32-bit wrapping arithmetic (packed 16-bit lanes included), so the
/// pixels are exactly the ones the guest would have produced. The
/// functions are pure — they read their sources and write only their
/// destination span — so if a page turns out not to be reachable without
/// the guest's own fault handling, the call is handed back to the guest's
/// code, which redoes it from the start.
///
/// Addresses are in the 10B500 dyld shared cache as the file has them;
/// the cache is slid by a per-boot amount, the same in every process.
/// Before a function is first replaced, its first 32 bytes are compared
/// with the code it's meant to be — a mismatch leaves the guest's own.
final class QuartzCoreAcceleration {
    private unowned(unsafe) let cpu: ARMv7CPU
    private let memory: GuestPageCache

    private init(cpu: ARMv7CPU) {
        self.cpu = cpu
        memory = GuestPageCache(cpu: cpu)
    }

    private struct Function {
        let unslidAddress: UInt32
        let signature: [UInt8]
        let body: (QuartzCoreAcceleration) -> Bool
    }

    private static let functions: [Function] = [
        Function(unslidAddress: 0x32D9_08AC, signature: [
            0xF0, 0xB5, 0x03, 0xAF, 0x2D, 0xE9, 0x00, 0x0D, 0x89, 0xB0, 0x0E, 0x46, 0x00, 0x2E, 0x00, 0xF0,
            0x9F, 0x80, 0x04, 0x68, 0x45, 0x6A, 0x03, 0x6A, 0x05, 0x95, 0x85, 0x6A, 0xA3, 0xF5, 0x00, 0x4E,
        ], body: { $0.bilinearSpan() }),
        Function(unslidAddress: 0x32D9_4DC4, signature: [
            0xF0, 0xB5, 0x03, 0xAF, 0x2D, 0xE9, 0x00, 0x0D, 0x01, 0x2B, 0x30, 0xD9, 0x4F, 0xF4, 0x80, 0x79,
            0xD2, 0xE9, 0x00, 0x45, 0x02, 0x3B, 0x91, 0xE8, 0x00, 0x09, 0xA9, 0xEB, 0x15, 0x6E, 0x08, 0x31,
        ], body: { $0.sourceOverSpan() }),
        Function(unslidAddress: 0x32D9_0F84, signature: [
            0xF0, 0xB5, 0x03, 0xAF, 0x2D, 0xE9, 0x00, 0x05, 0x61, 0xB3, 0xD0, 0xF8, 0x00, 0xE0, 0x06, 0x6A,
            0xD0, 0xF8, 0x24, 0x90, 0x83, 0x6A, 0xD0, 0xF8, 0x2C, 0xC0, 0xDE, 0xE9, 0x00, 0x45, 0xDE, 0xF8,
        ], body: { $0.nearestSpan(opaque: true) }),
        Function(unslidAddress: 0x32D9_0714, signature: [
            0xF0, 0xB5, 0x03, 0xAF, 0x2D, 0xE9, 0x00, 0x05, 0x51, 0xB3, 0xD0, 0xF8, 0x00, 0xE0, 0x06, 0x6A,
            0xD0, 0xF8, 0x24, 0x90, 0x83, 0x6A, 0xD0, 0xF8, 0x2C, 0xC0, 0xDE, 0xE9, 0x00, 0x45, 0xDE, 0xF8,
        ], body: { $0.nearestSpan(opaque: false) }),
    ]

    /// Replaces the functions in every process, once the shared cache's
    /// slide for this boot is known.
    static func install(on cpu: ARMv7CPU, sharedCacheSlide slide: UInt32) {
        let accelerator = QuartzCoreAcceleration(cpu: cpu)
        for function in functions {
            let address = function.unslidAddress &+ slide
            var verified = false
            cpu.nativeFunctions[address] = { cpu in
                // Thumb functions, entered in Thumb state.
                guard cpu.cpsr.thumbState else { return false }
                if !verified {
                    guard let code = accelerator.memory.bytes(address, count: function.signature.count, access: .execute) else { return false }
                    guard code == function.signature else {
                        cpu.nativeFunctions[address] = nil
                        return false
                    }
                    verified = true
                }
                accelerator.memory.begin()
                return function.body(accelerator)
            }
        }
    }

    // MARK: Pixel arithmetic, as the ARM instructions do it

    @inline(__always) private static func uxtb16(_ x: UInt32) -> UInt32 { x & 0x00FF_00FF }
    /// `uxtb16 rd, rm, ror #8`.
    @inline(__always) private static func uxtb16ror8(_ x: UInt32) -> UInt32 { (x >> 8 | x << 24) & 0x00FF_00FF }

    /// 0 if `x <= 0`, `maximum` if at least that (signed), else `x`.
    @inline(__always) private static func clamp(_ x: UInt32, _ maximum: UInt32) -> UInt32 {
        let low = Int32(bitPattern: x) <= 0 ? 0 : x
        return Int32(bitPattern: low) >= Int32(bitPattern: maximum) ? maximum : low
    }

    @inline(__always) private static func integer(_ fixed: UInt32) -> UInt32 { UInt32(bitPattern: Int32(bitPattern: fixed) >> 16) }

    /// The span sampler's state (r0): the image (`+0`), then 16.16 fixed
    /// point x (`+0x20`) and its step (`+0x24`), y (`+0x28`) and its step
    /// (`+0x2c`). The image: pixels (`+0`), bytes per row (`+4`), and the
    /// largest x and y a sample may take (`+0x10`, `+0x14`, 16.16).
    private struct Sampler {
        var x, dx, y, dy: UInt32
        let pixels, rowBytes, maxX, maxY: UInt32
    }

    private func sampler() -> Sampler? {
        let state = cpu.registers[0]
        guard let image = memory.read32(state), let x = memory.read32(state &+ 0x20), let dx = memory.read32(state &+ 0x24),
              let y = memory.read32(state &+ 0x28), let dy = memory.read32(state &+ 0x2C),
              let pixels = memory.read32(image), let rowBytes = memory.read32(image &+ 4),
              let maxX = memory.read32(image &+ 0x10), let maxY = memory.read32(image &+ 0x14) else { return nil }
        return Sampler(x: x, dx: dx, y: y, dy: dy, pixels: pixels, rowBytes: rowBytes, maxX: maxX, maxY: maxY)
    }

    // MARK: The functions

    /// `(sampler, count, destination)`: `count` bilinearly filtered
    /// premultiplied pixels along the sampler's line.
    private func bilinearSpan() -> Bool {
        var count = cpu.registers[1]
        var destination = cpu.registers[2]
        guard count != 0 else { return true }
        guard let s = sampler() else { return false }
        var x = s.x &- 0x8000, y = s.y &- 0x8000
        while count != 0 {
            let y0 = Self.clamp(y, s.maxY), y1 = Self.clamp(y &+ 0x10000, s.maxY)
            let x0 = Self.clamp(x, s.maxX), x1 = Self.clamp(x &+ 0x10000, s.maxX)
            let row0 = Self.integer(y0) &* s.rowBytes, row1 = Self.integer(y1) &* s.rowBytes
            let column0 = Self.integer(x0) << 2, column1 = Self.integer(x1) << 2
            guard let p00 = memory.read32(s.pixels &+ row0 &+ column0), let p01 = memory.read32(s.pixels &+ row1 &+ column0),
                  let p11 = memory.read32(s.pixels &+ row1 &+ column1), let p10 = memory.read32(s.pixels &+ row0 &+ column1) else { return false }
            let wy = (y0 >> 8) & 0xFF, wx = (x0 >> 8) & 0xFF

            let aLow = Self.uxtb16(Self.uxtb16(p00) &+ (((Self.uxtb16(p01) &- Self.uxtb16(p00)) &* wy) >> 8))
            let bLow = Self.uxtb16(Self.uxtb16(p10) &+ (((Self.uxtb16(p11) &- Self.uxtb16(p10)) &* wy) >> 8))
            let aHigh = Self.uxtb16(Self.uxtb16ror8(p00) &+ (((Self.uxtb16ror8(p01) &- Self.uxtb16ror8(p00)) &* wy) >> 8))
            let bHigh = Self.uxtb16(Self.uxtb16ror8(p10) &+ (((Self.uxtb16ror8(p11) &- Self.uxtb16ror8(p10)) &* wy) >> 8))
            let low = Self.uxtb16(aLow &+ (((bLow &- aLow) &* wx) >> 8))
            let high = ((bHigh &- aHigh) &* wx &+ (aHigh << 8)) & ~0x00FF_00FF
            guard memory.write32(low | high, at: destination) else { return false }

            destination &+= 4
            x &+= s.dx
            y &+= s.dy
            count &-= 1
        }
        return true
    }

    /// `(sampler, count, destination)`: `count` nearest-neighbour pixels
    /// along the sampler's line; with `opaque`, alpha forced to 255.
    private func nearestSpan(opaque: Bool) -> Bool {
        var count = cpu.registers[1]
        var destination = cpu.registers[2]
        guard count != 0 else { return true }
        guard var s = sampler() else { return false }
        let alpha: UInt32 = opaque ? 0xFF00_0000 : 0

        // Most spans are a row of the image at its own size: a copy.
        let lastX = Int64(Int32(bitPattern: s.x)) + Int64(count - 1) * 0x10000
        if s.dy == 0, s.dx == 0x10000, Int32(bitPattern: s.x) >= 0, lastX < Int64(Int32(bitPattern: s.maxX)) {
            let source = s.pixels &+ Self.integer(Self.clamp(s.y, s.maxY)) &* s.rowBytes &+ (Self.integer(s.x) << 2)
            if (source | destination) & 3 == 0 {
                return runs(count: Int(count), destination: destination, sources: source, nil) { d, a, _, n in
                    for i in 0..<n {
                        d.storeBytes(of: a.load(fromByteOffset: i * 4, as: UInt32.self) | alpha, toByteOffset: i * 4, as: UInt32.self)
                    }
                }
            }
        }

        while count != 0 {
            let row = Self.integer(Self.clamp(s.y, s.maxY)) &* s.rowBytes
            let column = Self.integer(Self.clamp(s.x, s.maxX)) << 2
            guard let pixel = memory.read32(s.pixels &+ row &+ column), memory.write32(pixel | alpha, at: destination) else { return false }
            destination &+= 4
            s.x &+= s.dx
            s.y &+= s.dy
            count &-= 1
        }
        return true
    }

    /// `(destination, below, above, count)`: premultiplied `above` over
    /// `below`, pixel by pixel: `above + below * (256 - above's alpha) / 256`.
    private func sourceOverSpan() -> Bool {
        let destination = cpu.registers[0], below = cpu.registers[1], above = cpu.registers[2]
        let count = Int(cpu.registers[3])
        guard (destination | below | above) & 3 == 0 else { return false }
        return runs(count: count, destination: destination, sources: below, above) { d, b, a, n in
            for i in 0..<n {
                let top = a!.load(fromByteOffset: i * 4, as: UInt32.self)
                let bottom = b.load(fromByteOffset: i * 4, as: UInt32.self)
                let weight = 256 &- (top >> 24)
                let low = (Self.uxtb16(bottom) &* weight) >> 8 & 0x00FF_00FF
                let high = (Self.uxtb16ror8(bottom) &* weight) & ~0x00FF_00FF
                d.storeBytes(of: top &+ (low | high), toByteOffset: i * 4, as: UInt32.self)
            }
        }
    }

    /// `count` words at `destination` and at one or two sources, in runs
    /// that stay on one page for all of them: `body(destination, first,
    /// second, words)` for each. Every page is checked before the first
    /// run — a call handed back to the guest is redone from the start, so
    /// it mustn't have written anything (a blend's destination is often
    /// one of its sources).
    private func runs(count: Int, destination: UInt32, sources first: UInt32, _ second: UInt32?,
                      _ body: (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer?, Int) -> Void) -> Bool {
        for writing in [false, true] {
            var d = destination, a = first, b = second ?? 0, left = count
            while left > 0 {
                var n = min(left, GuestPageCache.wordsLeftOnPage(d), GuestPageCache.wordsLeftOnPage(a))
                if second != nil { n = min(n, GuestPageCache.wordsLeftOnPage(b)) }
                guard let dp = memory.span(d, count: n * 4, access: .write), let ap = memory.span(a, count: n * 4, access: .read) else { return false }
                var bp: UnsafeMutableRawPointer?
                if second != nil {
                    guard let host = memory.span(b, count: n * 4, access: .read) else { return false }
                    bp = host
                }
                if writing { body(dp, ap, bp, n) }
                d &+= UInt32(n * 4)
                a &+= UInt32(n * 4)
                b &+= UInt32(n * 4)
                left -= n
            }
        }
        return true
    }
}
