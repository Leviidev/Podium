import Foundation

/// Guest audio output.
protocol AudioOutput: AnyObject {
    var volume: Float { get set }
    func enqueue(samples: [Float])
    func pause()
    func resume()
}
