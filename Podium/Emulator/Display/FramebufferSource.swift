import Foundation

/// Produces the guest's display contents for the renderer to draw.
///
/// `GuestFramebuffer` is the real implementation: it reads whatever the
/// guest kernel has actually written into the physical memory region
/// `boot_args.Video` points at. There's still no dedicated display
/// *controller* (no LCD peripheral registers, no vsync, no mode-setting)
/// — this only reads pixels the guest's own kernel/console code decided
/// to draw on its own, which may be nothing, garbage, or a real frame
/// depending how far boot actually got. Sized to the iPod touch 4's
/// native 960×640 panel.
protocol FramebufferSource: AnyObject {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }

    /// Copies the current frame as tightly-packed BGRA8 into `buffer`,
    /// which must be at least `pixelWidth * pixelHeight * 4` bytes.
    func copyCurrentFrame(into buffer: UnsafeMutableRawBufferPointer)
}
