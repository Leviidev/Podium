import Foundation

/// What the A4's display pipe is actually showing: the layers the kernel's
/// AppleCLCD/AppleDisplayPipe programmed, read through the display DART
/// the way the hardware fetches them, composited into one BGRA8 frame.
///
/// Until a layer is enabled this falls back to `bootFramebuffer`, the
/// static framebuffer `boot_args.Video` points at; until the kernel sets
/// up the DART, layer addresses (iBoot's boot logo layer) are physical.
///
/// Layer registers, from openiBoot's A4 `clcd.c` (which programs the same
/// pipe) and the kernel's own writes: layer `n` at pipe `+0x4040 + n *
/// 0x1000` — control `+0x0` (bit 0 enable, bits 11:8 format: 0 32-bit
/// BGRA, 4 RGB565), buffer device address `+0x4`, stride `+0x8` (bytes,
/// low bits flags), size `+0x20` (`width << 16 | height`).
final class DisplayScanout: FramebufferSource {
    static let pipeBase: UInt32 = 0x8900_0000
    static let layerOffsets: [UInt32] = [0x4040, 0x5040]
    /// `mapper-clcd` is DART stream 0.
    static let clcdStream = 0

    struct Layer: Equatable {
        let control: UInt32
        let address: UInt32
        let stride: Int
        let width: Int
        let height: Int
        var enabled: Bool { control & 1 != 0 && address != 0 && width > 0 && height > 0 }
        var bytesPerPixel: Int { (control >> 8) & 0xF == 4 ? 2 : 4 }
    }

    private let memory: MemoryBus
    private let dart: S5L8930XDART
    private let bootFramebuffer: FramebufferSource
    let pixelWidth: Int
    let pixelHeight: Int

    init(memory: MemoryBus, dart: S5L8930XDART, bootFramebuffer: FramebufferSource) {
        self.memory = memory
        self.dart = dart
        self.bootFramebuffer = bootFramebuffer
        pixelWidth = bootFramebuffer.pixelWidth
        pixelHeight = bootFramebuffer.pixelHeight
    }

    func layer(_ index: Int) -> Layer {
        let base = Self.pipeBase + Self.layerOffsets[index]
        let word = { (offset: UInt32) in (try? self.memory.readWord32(at: base + offset)) ?? 0 }
        let size = word(0x20)
        return Layer(control: word(0), address: word(4), stride: Int(word(8) & ~0x3F), width: Int(size >> 16), height: Int(size & 0xFFFF))
    }

    var activeLayers: [Layer] { Self.layerOffsets.indices.map(layer).filter(\.enabled) }

    func copyCurrentFrame(into buffer: UnsafeMutableRawBufferPointer) {
        let layers = activeLayers
        guard !layers.isEmpty else { return bootFramebuffer.copyCurrentFrame(into: buffer) }
        let byteCount = pixelWidth * pixelHeight * 4
        guard buffer.count >= byteCount else { return }
        let output = buffer.bindMemory(to: UInt32.self)
        for index in 0..<(pixelWidth * pixelHeight) { output[index] = 0xFF00_0000 }
        for (index, layer) in layers.enumerated() {
            draw(layer, into: output, blend: index > 0)
        }
    }

    /// Fetches one layer row by row through the DART. Rows can straddle
    /// device pages that map to scattered physical pages, so each page's
    /// run is translated on its own.
    private func draw(_ layer: Layer, into output: UnsafeMutableBufferPointer<UInt32>, blend: Bool) {
        let width = min(layer.width, pixelWidth)
        let height = min(layer.height, pixelHeight)
        let stride = layer.stride > 0 ? layer.stride : layer.width * layer.bytesPerPixel
        let rowBytes = width * layer.bytesPerPixel
        let translated = dart.hasSegments(stream: Self.clcdStream)
        var row = Data(count: rowBytes)
        for y in 0..<height {
            let rowAddress = layer.address &+ UInt32(y * stride)
            var filled = 0
            while filled < rowBytes {
                let deviceAddress = rowAddress &+ UInt32(filled)
                let run = min(rowBytes - filled, 0x1000 - Int(deviceAddress & 0xFFF))
                if let physical = translated ? dart.translate(deviceAddress, stream: Self.clcdStream, memory: memory) : deviceAddress,
                   let bytes = try? memory.readBytes(run, at: physical) {
                    row.replaceSubrange(filled..<(filled + run), with: bytes)
                } else {
                    row.resetBytes(in: filled..<(filled + run))
                }
                filled += run
            }
            row.withUnsafeBytes { raw in
                let base = y * pixelWidth
                if layer.bytesPerPixel == 2 {
                    let pixels = raw.bindMemory(to: UInt16.self)
                    for x in 0..<width { output[base + x] = Self.bgra(fromRGB565: pixels[x]) }
                } else {
                    let pixels = raw.bindMemory(to: UInt32.self)
                    for x in 0..<width {
                        output[base + x] = blend ? Self.over(pixels[x], output[base + x]) : pixels[x] | 0xFF00_0000
                    }
                }
            }
        }
    }

    private static func bgra(fromRGB565 pixel: UInt16) -> UInt32 {
        let r = UInt32(pixel >> 11) * 255 / 31
        let g = UInt32((pixel >> 5) & 0x3F) * 255 / 63
        let b = UInt32(pixel & 0x1F) * 255 / 31
        return 0xFF00_0000 | r << 16 | g << 8 | b
    }

    /// Premultiplied source-over.
    private static func over(_ source: UInt32, _ destination: UInt32) -> UInt32 {
        let alpha = source >> 24
        guard alpha != 0xFF else { return source }
        guard alpha != 0 else { return destination }
        var result: UInt32 = 0xFF00_0000
        for shift: UInt32 in [0, 8, 16] {
            let s = (source >> shift) & 0xFF
            let d = (destination >> shift) & 0xFF
            result |= min(255, s + d * (255 - alpha) / 255) << shift
        }
        return result
    }
}
