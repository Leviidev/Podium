import Foundation

/// Draws a `FramebufferSource`'s frames.
///
/// No implementation exists yet, and deliberately so: building a Metal
/// pipeline now would mean a renderer with nothing real to render, since
/// no `FramebufferSource` produces frames yet (Milestone 3). The eventual
/// implementation uploads each frame into a Metal texture and composites
/// it into the SwiftUI emulator view via `MTKView`/`CAMetalLayer`, per
/// the pipeline in Section 10 of the project spec. Until then,
/// `PlaceholderFramebufferView` is what `EmulatorScreen` actually shows.
protocol DisplayRenderer: AnyObject {
    func render(_ source: FramebufferSource)
}
