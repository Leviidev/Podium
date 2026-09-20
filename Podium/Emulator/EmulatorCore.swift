import Foundation
import Observation

/// Coordinates the emulator subsystems for the UI layer.
///
/// `EmulatorCore` depends on every subsystem through a protocol (`CPU?`,
/// `MemoryBus?`, `AudioOutput`, `NetworkInterface`), never a concrete
/// type, so the frontend is never coupled to a specific implementation —
/// today's `nil` CPU and stub audio/network can be swapped for real
/// implementations as they're built without touching UI code.
///
/// Right now there is no CPU and no memory-mapped hardware, so `status`
/// stays `.notImplemented`. It does not advance to `.booting` just
/// because a firmware was selected — that would misrepresent what's
/// actually happening.
@MainActor
@Observable
final class EmulatorCore {
    private(set) var status: EmulatorStatus = .notImplemented
    private(set) var log: [EmulatorLogEntry] = []

    let cpu: CPU?
    let memory: MemoryBus?
    let audioOutput: AudioOutput
    let networkInterface: NetworkInterface
    let inputController: InputController

    private static let logCapacity = 200

    init(
        cpu: CPU? = nil,
        memory: MemoryBus? = nil,
        audioOutput: AudioOutput = NullAudioOutput(),
        networkInterface: NetworkInterface = NullNetworkInterface(),
        inputController: InputController = PassthroughInputController()
    ) {
        self.cpu = cpu
        self.memory = memory
        self.audioOutput = audioOutput
        self.networkInterface = networkInterface
        self.inputController = inputController
        appendLog("Emulator core not implemented. Firmware parsing and the module architecture are in place; CPU and hardware emulation haven't started yet.")
    }

    func sendInput(_ event: InputEvent) {
        inputController.send(event)
        appendLog("Input: \(describe(event))")
    }

    private func describe(_ event: InputEvent) -> String {
        switch event {
        case .touchBegan(let point): return "touch began at (\(Int(point.x)), \(Int(point.y)))"
        case .touchMoved(let point): return "touch moved to (\(Int(point.x)), \(Int(point.y)))"
        case .touchEnded: return "touch ended"
        case .homeButton(let pressed): return "Home button \(pressed ? "pressed" : "released")"
        case .powerButton(let pressed): return "Power button \(pressed ? "pressed" : "released")"
        case .volumeUp(let pressed): return "Volume up \(pressed ? "pressed" : "released")"
        case .volumeDown(let pressed): return "Volume down \(pressed ? "pressed" : "released")"
        }
    }

    private func appendLog(_ message: String) {
        log.append(EmulatorLogEntry(date: Date(), message: message))
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
    }
}
