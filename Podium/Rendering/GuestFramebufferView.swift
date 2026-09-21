import SwiftUI

/// Draws whatever pixels a `FramebufferSource` currently holds, redrawn on
/// a timer while the emulator is active. Not the eventual Metal-based
/// `DisplayRenderer` from the project spec — that pipeline still has
/// nothing calling it — but genuinely real: it draws the guest's own
/// memory contents as they actually are, not a scripted placeholder.
///
/// Interprets the bytes as BGRA8, matching `FramebufferSource`'s declared
/// contract — but nothing has confirmed that's really the byte order the
/// guest kernel draws in. If a real frame ever lands here with swapped
/// channels, that's the fix to make, not a reason to distrust this view.
struct GuestFramebufferView: View {
    let source: FramebufferSource

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { _ in
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image = currentFrameImage() {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .aspectRatio(CGFloat(source.pixelWidth) / CGFloat(source.pixelHeight), contentMode: .fit)
        } else {
            Color.black
                .aspectRatio(CGFloat(source.pixelWidth) / CGFloat(source.pixelHeight), contentMode: .fit)
        }
    }

    private func currentFrameImage() -> CGImage? {
        let byteCount = source.pixelWidth * source.pixelHeight * 4
        guard byteCount > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: byteCount)
        pixels.withUnsafeMutableBytes { source.copyCurrentFrame(into: $0) }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: source.pixelWidth,
            height: source.pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: source.pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
