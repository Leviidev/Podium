import Foundation

/// Reads the guest's actual framebuffer out of physical memory — the same
/// region `EmulatorCore` points `boot_args.Video` at, so whatever the
/// guest kernel draws there (if anything; nothing forces it to) is what
/// this returns. No conversion is applied: bytes are copied out exactly
/// as the guest wrote them, at whatever pixel format that turns out to
/// be — this class doesn't get to assume BGRA8 is correct where reality
/// might disagree.
final class GuestFramebuffer: FramebufferSource {
    private let memory: MemoryBus
    private let baseAddress: UInt32
    let pixelWidth: Int
    let pixelHeight: Int

    init(memory: MemoryBus, baseAddress: UInt32, pixelWidth: Int, pixelHeight: Int) {
        self.memory = memory
        self.baseAddress = baseAddress
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    func copyCurrentFrame(into buffer: UnsafeMutableRawBufferPointer) {
        let byteCount = pixelWidth * pixelHeight * 4
        guard buffer.count >= byteCount else { return }
        // A guest memory fault here (e.g. this physical range somehow
        // isn't backed) leaves `buffer` untouched rather than crashing
        // the renderer — the same "stay honest, don't fake a frame"
        // stance as everywhere else, just expressed as "show nothing new"
        // instead of a status string.
        guard let frame = try? memory.readBytes(byteCount, at: baseAddress) else { return }
        frame.copyBytes(to: buffer)
    }
}
