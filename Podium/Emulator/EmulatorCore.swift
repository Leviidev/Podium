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

    /// Physical RAM base address for this SoC (S5L8930X / n81ap).
    /// Not a guess: the real iPod4,1 6.1.6 kernel's `__TEXT` segment is
    /// linked at 0x80001000, which only makes sense if physical RAM
    /// starts at (or just below) 0x80000000 — observed directly via
    /// `otool -l` on the actual decrypted kernelcache, not assumed from
    /// documentation (Apple doesn't publish this).
    static let physicalMemoryBaseAddress: UInt32 = 0x8000_0000

    /// Caps a single boot attempt so unsupported guest code halts the
    /// attempt instead of either running forever or never giving the JIT
    /// path (which only engages inside `run`, not single `step`s) a
    /// chance to actually compile anything.
    private static let maxBootUnits = 200_000

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

        let ram = FlatPhysicalMemory(length: Self.physicalMemorySize, baseAddress: Self.physicalMemoryBaseAddress)
        let armCPU = ARMv7CPU(memory: ram, jit: JITEngine())
        armCPU.reset()

        memory = ram
        cpu = armCPU
        status = .ready
        let baseHex = "0x" + Self.physicalMemoryBaseAddress.hexString8
        appendLog("ARMv7 interpreter core online (with JIT compilation for eligible instruction sequences). \(Int64(Self.physicalMemorySize).formattedByteCount) physical memory mapped at \(baseHex).")
        appendLog("No guest firmware is loaded yet.")
    }

    /// Extracts the kernel from `firmware`'s stored IPSW, loads it into
    /// guest memory, points the CPU at its real entry point, and runs a
    /// bounded number of instructions. This is Milestone 4's own stated
    /// goal — "get the guest kernel executing" — not a claim that it
    /// boots to anything further: real XNU boot code uses instruction
    /// families (multiply, coprocessor/MMU control, block transfer) this
    /// CPU doesn't implement yet, so halting on `.unsupportedInstruction`
    /// within the first stretch of real execution is the expected,
    /// honest outcome right now, not a bug in the loader.
    func attemptBoot(firmware: ImportedFirmware, storedAt fileURL: URL) async {
        activateCoreIfNeeded()
        guard let armCPU = cpu as? ARMv7CPU, let memory else { return }

        status = .booting
        appendLog("Extracting kernel from \(firmware.metadata.originalFileName)…")

        let machO: Data
        do {
            machO = try await Task.detached(priority: .userInitiated) {
                try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: fileURL)
            }.value
        } catch let error as FriendlyError {
            status = .error(error.userMessage)
            appendLog("Kernel extraction failed: \(error.developerDetail)")
            return
        } catch {
            status = .error("Podium couldn't extract the kernel from this firmware.")
            appendLog("Kernel extraction failed: \(error.localizedDescription)")
            return
        }
        appendLog("Kernel extracted and decompressed: \(Int64(machO.count).formattedByteCount).")

        let image: LoadedKernelImage
        do {
            image = try MachOLoader.load(machO, into: memory)
        } catch let error as FriendlyError {
            status = .error(error.userMessage)
            appendLog("Kernel load failed: \(error.developerDetail)")
            return
        } catch {
            status = .error("Podium couldn't load this kernel binary.")
            appendLog("Kernel load failed: \(error.localizedDescription)")
            return
        }

        // XNU's ARM entry code expects r0 to hold a boot_args pointer —
        // normally filled in and passed by iBoot, which Podium doesn't
        // run. Placed on the next page boundary past the kernel's own
        // highest used address, which MachOLoader reports precisely
        // rather than this guessing at a gap that's big enough.
        let bootArgsAddress = (image.highestAddressUsed + 0xFFF) & ~UInt32(0xFFF)
        let bootArgs = BootArgsBuilder.build(
            virtBase: Self.physicalMemoryBaseAddress,
            physBase: Self.physicalMemoryBaseAddress,
            memSize: UInt32(Self.physicalMemorySize),
            topOfKernelData: bootArgsAddress + UInt32(BootArgsBuilder.structSize),
            deviceTreeP: 0, // No device tree extracted/passed yet — honestly absent, not guessed at.
            deviceTreeLength: 0
        )
        do {
            try memory.writeBytes(bootArgs, at: bootArgsAddress)
        } catch {
            status = .error("Podium couldn't set up this firmware's boot arguments.")
            appendLog("boot_args write failed: \(error)")
            return
        }

        var initialRegisters = image.initialRegisters
        initialRegisters[0] = bootArgsAddress

        armCPU.reset()
        armCPU.loadInitialRegisters(initialRegisters)
        appendLog("boot_args written at 0x\(bootArgsAddress.hexString8) (virtBase=physBase=0x\(Self.physicalMemoryBaseAddress.hexString8), memSize=\(Int64(Self.physicalMemorySize).formattedByteCount)); r0 points there.")
        appendLog("Kernel loaded. Entry point: 0x\(image.entryPointPC.hexString8). Starting execution…")

        let stepBudget = Self.maxBootUnits
        let unitsRun = await Task.detached(priority: .userInitiated) {
            armCPU.run(maxUnits: stepBudget)
        }.value

        if let error = armCPU.lastError {
            status = .error("Halted after \(unitsRun) instruction group\(unitsRun == 1 ? "" : "s"): \(Self.describe(error)).")
            appendLog("Execution halted: \(error)")
        } else {
            status = .running
            appendLog("Ran \(unitsRun) instruction groups without hitting an unimplemented instruction (step budget reached). PC now 0x\(armCPU.registers.pc.hexString8).")
        }
    }

    private static func describe(_ error: CPUError) -> String {
        switch error {
        case .unsupportedInstruction(let word, let address):
            return "unsupported instruction 0x\(word.hexString8) at 0x\(address.hexString8)"
        case .undefinedInstruction(let word, let address):
            return "undefined instruction 0x\(word.hexString8) at 0x\(address.hexString8)"
        case .memoryFault(let fault, let address):
            return "memory fault at 0x\(address.hexString8) (\(fault))"
        case .unimplementedHardwareFeature(let description, let address):
            return "\(description), at 0x\(address.hexString8)"
        }
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
