import Foundation

/// Produces the guest's display contents for the renderer to draw.
///
/// `DisplayScanout` is what the screen shows once the kernel's display
/// driver takes over: the display pipe's layers, fetched through the DART.
/// Before that it falls back to `GuestFramebuffer`, the static boot
/// framebuffer `boot_args.Video` points at. Sized to the iPod touch 4's
/// native 960×640 panel.
protocol FramebufferSource: AnyObject {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }

    /// Copies the current frame as tightly-packed BGRA8 into `buffer`,
    /// which must be at least `pixelWidth * pixelHeight * 4` bytes.
    func copyCurrentFrame(into buffer: UnsafeMutableRawBufferPointer)
}
