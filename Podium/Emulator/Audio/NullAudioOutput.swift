import Foundation

/// An `AudioOutput` that discards everything. Audio is explicitly not a
/// requirement for the first-boot milestone (Section 18 of the project
/// spec); this exists purely so callers elsewhere in the architecture
/// have something conforming to depend on rather than an optional they
/// have to special-case.
final class NullAudioOutput: AudioOutput {
    var volume: Float = 1.0

    func enqueue(samples: [Float]) {}
    func pause() {}
    func resume() {}
}
