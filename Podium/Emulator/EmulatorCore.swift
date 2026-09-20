import Foundation
import Observation

/// Coordinates the emulator subsystems for the UI layer.
///
/// `EmulatorCore` depends on every subsystem through a protocol (`CPU?`,
/// `MemoryBus?`, `AudioOutput`, `NetworkInterface`), never a concrete
/// type, so the frontend is never coupled to a specific implementation.
///
/// `cpu`/`memory` start `nil` and are brought up lazily by
/// `activateCoreIfNeeded()` — there's no reason to hold 256 MB of guest
/// RAM before the user has actually opened the emulator screen. Once
/// activated, `status` becomes `.ready`: a real ARMv7 interpreter exists
/// and is reset and waiting, which is honestly what "ready" means here.
/// It does not advance to `.booting`/`.running` just because a firmware
/// was selected — there is still no kernelcache extraction or boot
/// pipeline to actually load and run guest code, so nothing is executing
/// and status must not claim otherwise.
@MainActor
@Observable
final class EmulatorCore {
    private(set) var status: EmulatorStatus = .notImplemented
    private(set) var log: [EmulatorLogEntry] = []
    private(set) var cpu: CPU?
    private(set) var memory: MemoryBus?

    let audioOutput: AudioOutput
    let networkInterface: NetworkInterface
    let inputController: InputController

    /// The iPod touch 4's actual RAM size (Section 9 of the project spec).
    static let physicalMemorySize = 256 * 1024 * 1024

    private static let logCapacity = 200

    init(
        audioOutput: AudioOutput = NullAudioOutput(),
        networkInterface: NetworkInterface = NullNetworkInterface(),
        inputController: InputController = PassthroughInputController()
    ) {
        self.audioOutput = audioOutput
        self.networkInterface = networkInterface
        self.inputController = inputController
        appendLog("Emulator core not implemented. Firmware parsing and the module architecture are in place; no CPU is active yet.")
    }

    /// Brings up the CPU/memory subsystems if they aren't already. Safe
    /// to call repeatedly (e.g. every time the emulator screen appears).
    func activateCoreIfNeeded() {
        guard cpu == nil else { return }

        let ram = FlatPhysicalMemory(length: Self.physicalMemorySize)
        let armCPU = ARMv7CPU(memory: ram, jit: JITEngine())
        armCPU.reset()

        memory = ram
        cpu = armCPU
        status = .ready
        appendLog("ARMv7 interpreter core online (with JIT compilation for eligible instruction sequences). \(Int64(Self.physicalMemorySize).formattedByteCount) physical memory mapped at 0x00000000.")
        appendLog("No guest firmware is loaded — there is no kernelcache extraction or boot pipeline yet, so the CPU has nothing to execute.")
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
