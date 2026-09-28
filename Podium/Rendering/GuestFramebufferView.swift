import Metal
import QuartzCore
import SwiftUI
import UIKit

/// Shows what a `FramebufferSource` holds, redrawn with Metal on every
/// display refresh (up to 60 times a second).
///
/// Each frame is copied straight from guest memory into one of three
/// shared-storage Metal buffers — each the backing store of a texture —
/// and drawn as a full-screen triangle, so the only CPU work per frame is
/// that one copy. Touches pass through to the SwiftUI gesture around it.
struct GuestFramebufferView: UIViewRepresentable {
    let source: FramebufferSource

    func makeUIView(context: Context) -> FramebufferMetalView {
        FramebufferMetalView(source: source)
    }

    func updateUIView(_ view: FramebufferMetalView, context: Context) {
        view.source = source
    }

    static func dismantleUIView(_ view: FramebufferMetalView, coordinator: ()) {
        view.stop()
    }
}

final class FramebufferMetalView: UIView {
    var source: FramebufferSource

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private static let framesInFlight = 3
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    private var frames: [(buffer: MTLBuffer, texture: MTLTexture)] = []
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: framesInFlight)
    private var displayLink: CADisplayLink?

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    // One triangle covering the view: (0,0), (2,0), (0,2) in uv space.
    vertex Varyings frameVertex(uint id [[vertex_id]]) {
        float2 corner = float2((id << 1) & 2, id & 2);
        Varyings out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 frameFragment(Varyings in [[stage_in]], texture2d<float> frame [[texture(0)]], sampler linear [[sampler(0)]]) {
        return float4(frame.sample(linear, in.uv).rgb, 1.0);
    }
    """

    init(source: FramebufferSource) {
        self.source = source
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap(Self.makePipeline)
        sampler = device.flatMap { device in
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            return device.makeSamplerState(descriptor: descriptor)
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .black
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frameVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frameFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// The frame buffers, (re)made for the source's size.
    private func frameStorage() -> (buffer: MTLBuffer, texture: MTLTexture)? {
        guard let device else { return nil }
        let width = source.pixelWidth, height = source.pixelHeight
        guard width > 0, height > 0 else { return nil }
        if frames.first.map({ $0.texture.width != width || $0.texture.height != height }) ?? true {
            frames = (0..<Self.framesInFlight).compactMap { _ in
                let bytesPerRow = width * 4
                guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else { return nil }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow) else { return nil }
                return (buffer, texture)
            }
        }
        guard frames.count == Self.framesInFlight else { return nil }
        frameIndex = (frameIndex + 1) % Self.framesInFlight
        return frames[frameIndex]
    }

    fileprivate func drawFrame() {
        guard let queue, let pipeline, let sampler, metalLayer.drawableSize.width > 0 else { return }
        // Skip a refresh rather than wait if the GPU is still behind.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let frame = frameStorage(), let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        source.copyCurrentFrame(into: UnsafeMutableRawBufferPointer(start: frame.buffer.contents(), count: frame.buffer.length))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        let inFlight = inFlight
        commandBuffer.addCompletedHandler { _ in inFlight.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// The display link's target, holding the view weakly: a display link
/// retains its target, and would otherwise keep the view alive.
private final class DisplayLinkTarget: NSObject {
    weak var view: FramebufferMetalView?

    init(_ view: FramebufferMetalView) {
        self.view = view
    }

    @objc func tick() {
        view?.drawFrame()
    }
}
