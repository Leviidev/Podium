import Foundation

/// Produces the guest's display contents for the renderer to draw.
///
/// No implementation exists yet — there is no guest writing pixels
/// anywhere. `Rendering/PlaceholderFramebufferView` draws an honest
/// placeholder instead of calling this. Once a real display controller
/// exists, it will publish frames sized to the iPod touch 4's native
/// 960×640 panel.
protocol FramebufferSource: AnyObject {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }

    /// Copies the current frame as tightly-packed BGRA8 into `buffer`,
    /// which must be at least `pixelWidth * pixelHeight * 4` bytes.
    func copyCurrentFrame(into buffer: UnsafeMutableRawBufferPointer)
}
