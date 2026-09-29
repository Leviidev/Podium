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

    /// For the differential tester: one not installed anywhere.
    static func forTesting(on cpu: ARMv7CPU) -> QuartzCoreAcceleration { QuartzCoreAcceleration(cpu: cpu) }

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
        Function(unslidAddress: 0x32D9_1124, signature: [
            0xF0, 0xB5, 0x03, 0xAF, 0x2D, 0xE9, 0x00, 0x0D, 0x8A, 0xB0, 0x0C, 0x46, 0x00, 0x2C, 0x00, 0xF0,
            0xAF, 0x80, 0x46, 0x6A, 0x05, 0x68, 0x03, 0x6A, 0x05, 0x96, 0x86, 0x6A, 0xA3, 0xF5, 0x00, 0x4C,
        ], body: { $0.bilinearOpaqueSpan() }),
    ]

    /// Loops of the scanline rasterizer (`0x32D8E5F8`) that translated
    /// code runs natively in place (see `DBTEngine.registerSnippet`): per
    /// scanline, they step each of a polygon's interpolated attributes —
    /// an array of floats, selected by a bit mask — and they were most of
    /// the guest instructions a frame took. `code` is the loop from its
    /// head to the instruction after its closing branch.
    private struct Loop {
        let unslidAddress: UInt32
        let code: [UInt8]
        let body: (ARMv7CPU, GuestPageCache) -> Bool
    }

    private static let loops: [Loop] = [
        Loop(unslidAddress: 0x32D8_E74A, code: [
            0x14, 0xF0, 0x01, 0x0F, 0x13, 0xD0, 0x93, 0xED, 0x00, 0x1A, 0x92, 0xED, 0x00, 0x2A, 0x62, 0xEF, 0x01, 0x1D, 0x01, 0xFF,
            0x90, 0x1D, 0x8E, 0xED, 0x00, 0x1A, 0x41, 0xFF, 0x30, 0x1D, 0x93, 0xED, 0x00, 0x1A, 0x01, 0xEF, 0x21, 0x1D, 0x80, 0xED,
            0x00, 0x1A, 0x20, 0xEF, 0x10, 0x01, 0x4F, 0xEA, 0x54, 0x09, 0x00, 0x25, 0xB5, 0xEB, 0x54, 0x0F, 0x0E, 0xF1, 0x04, 0x0E,
            0x00, 0xF1, 0x04, 0x00, 0x02, 0xF1, 0x04, 0x02, 0x03, 0xF1, 0x04, 0x03, 0x4C, 0x46, 0xD9, 0xD1,
        ], body: { interpolateAttributes($0, $1) }),
        Loop(unslidAddress: 0x32D8_E804, code: [
            0x14, 0xF0, 0x01, 0x0F, 0x4F, 0xEA, 0x54, 0x0E, 0x20, 0xEF, 0x10, 0x01, 0x1F, 0xBF, 0x93, 0xED, 0x00, 0x0A, 0x92, 0xED,
            0x00, 0x1A, 0x01, 0xEF, 0x00, 0x0D, 0x82, 0xED, 0x00, 0x0A, 0x00, 0x25, 0xB5, 0xEB, 0x54, 0x0F, 0x03, 0xF1, 0x04, 0x03,
            0x02, 0xF1, 0x04, 0x02, 0x6C, 0xA8, 0x94, 0xA9, 0x74, 0x46, 0xE5, 0xD1,
        ], body: { stepAttributes($0, $1, stepAtR2) }),
        Loop(unslidAddress: 0x32D8_E83C, code: [
            0x12, 0xF0, 0x01, 0x0F, 0x4F, 0xEA, 0x52, 0x03, 0x20, 0xEF, 0x10, 0x01, 0x1F, 0xBF, 0x90, 0xED, 0x00, 0x0A, 0x91, 0xED,
            0x00, 0x1A, 0x01, 0xEF, 0x00, 0x0D, 0x81, 0xED, 0x00, 0x0A, 0x00, 0x24, 0xB4, 0xEB, 0x52, 0x0F, 0x00, 0xF1, 0x04, 0x00,
            0x01, 0xF1, 0x04, 0x01, 0x1A, 0x46, 0xE7, 0xD1,
        ], body: { stepAttributes($0, $1, stepAtR1) }),
        // The same two, for the scanlines a clipped polygon skips.
        Loop(unslidAddress: 0x32D8_EB4E, code: [
            0x10, 0xF0, 0x01, 0x0F, 0x4F, 0xEA, 0x50, 0x05, 0x20, 0xEF, 0x10, 0x01, 0x1F, 0xBF, 0x94, 0xED, 0x00, 0x0A, 0x93, 0xED,
            0x00, 0x1A, 0x01, 0xEF, 0x00, 0x0D, 0x83, 0xED, 0x00, 0x0A, 0x4F, 0xF0, 0x00, 0x0C, 0xBC, 0xEB, 0x50, 0x0F, 0x04, 0xF1,
            0x04, 0x04, 0x03, 0xF1, 0x04, 0x03, 0x6C, 0xA9, 0x94, 0xAA, 0x28, 0x46, 0xE4, 0xD1,
        ], body: { stepAttributes($0, $1, stepSkippedAtR3) }),
        Loop(unslidAddress: 0x32D8_EB88, code: [
            0x10, 0xF0, 0x01, 0x0F, 0x4F, 0xEA, 0x50, 0x03, 0x20, 0xEF, 0x10, 0x01, 0x1F, 0xBF, 0x91, 0xED, 0x00, 0x0A, 0x92, 0xED,
            0x00, 0x1A, 0x01, 0xEF, 0x00, 0x0D, 0x82, 0xED, 0x00, 0x0A, 0x00, 0x24, 0xB4, 0xEB, 0x50, 0x0F, 0x01, 0xF1, 0x04, 0x01,
            0x02, 0xF1, 0x04, 0x02, 0x18, 0x46, 0xE7, 0xD1,
        ], body: { stepAttributes($0, $1, stepSkippedAtR2) }),
    ] + [0x32D8_DCD6, 0x32D8_DD18].map { address in
        // The span setup (`0x32D8D978`) has the same loop twice.
        Loop(unslidAddress: address, code: [
            0x16, 0xF0, 0x01, 0x0F, 0x0B, 0xD0, 0x92, 0xED, 0x00, 0x1A, 0x41, 0xFF, 0x30, 0x1D, 0x93, 0xED, 0x00, 0x0A, 0x00, 0xEF,
            0x21, 0x0D, 0x83, 0xED, 0x00, 0x0A, 0x20, 0xEF, 0x10, 0x01, 0x75, 0x08, 0xB1, 0xEB, 0x56, 0x0F, 0x02, 0xF1, 0x04, 0x02,
            0x03, 0xF1, 0x04, 0x03, 0x2E, 0x46, 0xE7, 0xD1,
        ], body: { accumulateScaledAttributes($0, $1) })
    }

    /// Replaces the functions in every process, once the shared cache's
    /// slide for this boot is known.
    static func install(on cpu: ARMv7CPU, sharedCacheSlide slide: UInt32) {
        let accelerator = QuartzCoreAcceleration(cpu: cpu)
        for loop in loops {
            let address = loop.unslidAddress &+ slide
            let code = loop.code, body = loop.body, memory = accelerator.memory
            var verified: Bool?
            cpu.dbt?.registerSnippet(at: address, thumb: true, exit: address &+ UInt32(code.count)) { cpu in
                if verified == nil {
                    guard let found = memory.bytes(address, count: code.count, access: .execute) else { return false }
                    verified = found == code
                }
                guard verified == true else { return false }
                memory.begin()
                return body(cpu, memory)
            }
        }
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

    /// Runs native function `index` of `functions` on the CPU's state, for
    /// the differential tester.
    func runForTesting(_ index: Int) -> Bool {
        memory.begin()
        return Self.functions[index].body(self)
    }

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

    /// `(sampler, count, destination)`: the bilinear sampler for opaque
    /// images (`0x32D91124`) — what scrolling a list mostly draws. The
    /// same filter as `bilinearSpan`, with the alpha lane of each source
    /// pixel taken as 255, and the samples read in its own order.
    private func bilinearOpaqueSpan() -> Bool {
        var count = cpu.registers[1]
        var destination = cpu.registers[2]
        guard count != 0 else { return true }
        guard let s = sampler() else { return false }
        /// A pixel's green and alpha lanes, alpha 255: `lsr #8`, then `bfi` of 0xFF00 over bits 8 up.
        @inline(__always) func high(_ p: UInt32) -> UInt32 { (p >> 8) & 0xFF | 0x00FF_0000 }
        var x = s.x &- 0x8000, y = s.y &- 0x8000
        while count != 0 {
            let y0 = Self.clamp(y, s.maxY), x1 = Self.clamp(x &+ 0x10000, s.maxX)
            let y1 = Self.clamp(y &+ 0x10000, s.maxY), x0 = Self.clamp(x, s.maxX)
            let row0 = Self.integer(y0) &* s.rowBytes, row1 = Self.integer(y1) &* s.rowBytes
            let column0 = Self.integer(x0) << 2, column1 = Self.integer(x1) << 2
            guard let p01 = memory.read32(s.pixels &+ row0 &+ column1), let p11 = memory.read32(s.pixels &+ row1 &+ column1),
                  let p10 = memory.read32(s.pixels &+ row1 &+ column0), let p00 = memory.read32(s.pixels &+ row0 &+ column0) else { return false }
            let wy = (y0 >> 8) & 0xFF, wx = (x0 >> 8) & 0xFF

            let lowRight = Self.uxtb16(Self.uxtb16(p01) &+ (((Self.uxtb16(p11) &- Self.uxtb16(p01)) &* wy) >> 8))
            let lowLeft = Self.uxtb16(Self.uxtb16(p00) &+ (((Self.uxtb16(p10) &- Self.uxtb16(p00)) &* wy) >> 8))
            let highLeft = Self.uxtb16(high(p00) &+ (((high(p10) &- high(p00)) &* wy) >> 8))
            let highRight = Self.uxtb16(high(p01) &+ (((high(p11) &- high(p01)) &* wy) >> 8))
            let low = Self.uxtb16(lowLeft &+ (((lowRight &- lowLeft) &* wx) >> 8))
            let highLanes = ((highRight &- highLeft) &* wx &+ (highLeft << 8)) & ~0x00FF_00FF
            guard memory.write32(low | highLanes, at: destination) else { return false }

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

    // MARK: The rasterizer's loops

    /// Advanced SIMD floating point with the standard FPSCR — what the
    /// interpreter does for these instructions (`ARMv7CPU+NEON.swift`).
    @inline(__always) private static func neonFloat(_ bits: UInt32) -> Float {
        let value = Float(bitPattern: bits)
        return value.isSubnormal ? (value.sign == .minus ? -0.0 : 0.0) : value
    }

    @inline(__always) private static func neonBits(_ value: Float) -> UInt32 {
        if value.isNaN { return 0x7FC0_0000 }
        if value.isSubnormal { return value.sign == .minus ? 0x8000_0000 : 0 }
        return value.bitPattern
    }

    /// `vadd`/`vsub`/`vmul.f32` of two D registers' lanes.
    @inline(__always) private static func lanes(_ a: UInt64, _ b: UInt64, _ operation: (Float, Float) -> Float) -> UInt64 {
        let low = neonBits(operation(neonFloat(UInt32(truncatingIfNeeded: a)), neonFloat(UInt32(truncatingIfNeeded: b))))
        let high = neonBits(operation(neonFloat(UInt32(truncatingIfNeeded: a >> 32)), neonFloat(UInt32(truncatingIfNeeded: b >> 32))))
        return UInt64(low) | UInt64(high) << 32
    }

    @inline(__always) private static func setLow(_ d: UInt64, _ value: UInt32) -> UInt64 { d & 0xFFFF_FFFF_0000_0000 | UInt64(value) }

    /// Iterations of a mask loop (`while (mask >>= 1) != 0`, at least one).
    @inline(__always) private static func iterations(_ mask: UInt32) -> Int { max(1, 32 - mask.leadingZeroBitCount) }

    /// Where `count` words from `address` are in host memory, if the guest
    /// could access them all. Callers check every array before writing
    /// anything.
    @inline(__always) private static func words(_ address: UInt32, _ count: Int, _ access: ARMv7MMU.Access, _ memory: GuestPageCache)
        -> UnsafeMutableRawPointer? {
        address & 3 == 0 ? memory.span(address, count: count * 4, access: access) : nil
    }

    /// Needs the unit enabled and the standard modes, like any translated
    /// vector code; otherwise the guest's own code runs (and traps).
    private static func vectorUnitReady(_ cpu: ARMv7CPU) -> Bool {
        cpu.fpexc & ARMv7CPU.fpexcEnableBit != 0 && cpu.fpscr & 0x03C0_0000 == 0x0300_0000
    }

    /// The loop's final compare (0 against 0) leaves NZCV 0110.
    private static func setLoopFlags(_ cpu: ARMv7CPU) {
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & 0x0FFF_FFFF) | 0x6000_0000
    }

    /// `0x32D8E74A`: for each set bit of r4, from arrays at r3 and r2 into
    /// arrays at lr and r0 — `lr[i] = (r2[i] - r3[i]) * s0`, then
    /// `r0[i] = r3[i] + lr[i] * d16`, both lanes of each operation as the
    /// D-register code computes them.
    static func interpolateAttributes(_ cpu: ARMv7CPU, _ memory: GuestPageCache) -> Bool {
        let r = cpu.registers
        let count = iterations(r[4])
        guard vectorUnitReady(cpu), let from3 = words(r[3], count, .read, memory), let from2 = words(r[2], count, .read, memory),
              let into14 = words(r[14], count, .write, memory), let into0 = words(r[0], count, .write, memory) else { return false }
        let neon = cpu.neon
        let d0 = neon[0], d16 = neon[16]
        var d1 = neon[1], d2 = neon[2], d17 = neon[17]
        var mask = r[4]
        for i in 0..<count {
            if mask & 1 != 0 {
                d1 = setLow(d1, from3.load(fromByteOffset: i * 4, as: UInt32.self))
                d2 = setLow(d2, from2.load(fromByteOffset: i * 4, as: UInt32.self))
                d17 = lanes(d2, d1, -)
                d1 = lanes(d17, d0, *)
                into14.storeBytes(of: UInt32(truncatingIfNeeded: d1), toByteOffset: i * 4, as: UInt32.self)
                d17 = lanes(d1, d16, *)
                d1 = setLow(d1, from3.load(fromByteOffset: i * 4, as: UInt32.self))
                d1 = lanes(d1, d17, +)
                into0.storeBytes(of: UInt32(truncatingIfNeeded: d1), toByteOffset: i * 4, as: UInt32.self)
            }
            mask >>= 1
        }
        neon[1] = d1
        neon[2] = d2
        neon[17] = d17
        let advance = UInt32(count * 4)
        r[0] &+= advance
        r[2] &+= advance
        r[3] &+= advance
        r[14] &+= advance
        r[4] = 0
        r[5] = 0
        r[9] = 0
        setLoopFlags(cpu)
        return true
    }

    /// `0x32D8DCD6` and `0x32D8DD18`: for each set bit of r6,
    /// `r3[i] += r2[i] * d16`. The loop ends when r6 shifted down equals
    /// r1, which is always 0 there; any other r1 is left to the guest.
    static func accumulateScaledAttributes(_ cpu: ARMv7CPU, _ memory: GuestPageCache) -> Bool {
        let r = cpu.registers
        let count = iterations(r[6])
        guard r[1] == 0, vectorUnitReady(cpu), let deltas = words(r[2], count, .read, memory),
              let values = words(r[3], count, .write, memory) else { return false }
        let neon = cpu.neon
        let d16 = neon[16]
        var d0 = neon[0], d1 = neon[1], d17 = neon[17]
        var mask = r[6]
        for i in 0..<count {
            if mask & 1 != 0 {
                d1 = setLow(d1, deltas.load(fromByteOffset: i * 4, as: UInt32.self))
                d17 = lanes(d1, d16, *)
                d0 = setLow(d0, values.load(fromByteOffset: i * 4, as: UInt32.self))
                d0 = lanes(d0, d17, +)
                values.storeBytes(of: UInt32(truncatingIfNeeded: d0), toByteOffset: i * 4, as: UInt32.self)
            }
            mask >>= 1
        }
        neon[0] = d0
        neon[1] = d1
        neon[17] = d17
        let advance = UInt32(count * 4)
        r[2] &+= advance
        r[3] &+= advance
        r[5] = 0
        r[6] = 0
        setLoopFlags(cpu)
        return true
    }

    /// Where a step loop keeps things: the mask and the arrays, the
    /// registers it leaves 0 (the mask, its shifted copy, the one it
    /// compares against), and ones it sets to sp plus an offset.
    struct StepRegisters {
        let mask, source, destination: Int
        let zeroed: [Int]
        let stackAddresses: [(register: Int, offset: UInt32)]
    }

    /// `0x32D8E804`, `0x32D8E83C`, `0x32D8EB4E` and `0x32D8EB88` — one
    /// loop compiled four times with different registers: for each set
    /// bit of the mask, `destination[i] += source[i]` (the add done on
    /// both lanes of d0 and d1).
    static func stepAttributes(_ cpu: ARMv7CPU, _ memory: GuestPageCache, _ at: StepRegisters) -> Bool {
        let r = cpu.registers
        let count = iterations(r[at.mask])
        guard vectorUnitReady(cpu), let deltas = words(r[at.source], count, .read, memory),
              let values = words(r[at.destination], count, .write, memory) else { return false }
        let neon = cpu.neon
        var d0 = neon[0], d1 = neon[1]
        var mask = r[at.mask]
        for i in 0..<count {
            if mask & 1 != 0 {
                d0 = setLow(d0, deltas.load(fromByteOffset: i * 4, as: UInt32.self))
                d1 = setLow(d1, values.load(fromByteOffset: i * 4, as: UInt32.self))
                d0 = lanes(d1, d0, +)
                values.storeBytes(of: UInt32(truncatingIfNeeded: d0), toByteOffset: i * 4, as: UInt32.self)
            }
            mask >>= 1
        }
        neon[0] = d0
        neon[1] = d1
        let advance = UInt32(count * 4)
        r[at.source] &+= advance
        r[at.destination] &+= advance
        for register in at.zeroed { r[register] = 0 }
        for (register, offset) in at.stackAddresses { r[register] = r[13] &+ offset }
        setLoopFlags(cpu)
        return true
    }

    static let stepAtR2 = StepRegisters(mask: 4, source: 3, destination: 2, zeroed: [4, 5, 14], stackAddresses: [(0, 0x1B0), (1, 0x250)])
    static let stepAtR1 = StepRegisters(mask: 2, source: 0, destination: 1, zeroed: [2, 3, 4], stackAddresses: [])
    static let stepSkippedAtR3 = StepRegisters(mask: 0, source: 4, destination: 3, zeroed: [0, 5, 12], stackAddresses: [(1, 0x1B0), (2, 0x250)])
    static let stepSkippedAtR2 = StepRegisters(mask: 0, source: 1, destination: 2, zeroed: [0, 3, 4], stackAddresses: [])
}
