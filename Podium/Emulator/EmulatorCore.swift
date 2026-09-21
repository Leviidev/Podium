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

    /// Extracts the kernel (and, best-effort, the device tree) from
    /// `firmware`'s stored IPSW, loads them into guest memory, points
    /// the CPU at its real entry point, and runs a bounded number of
    /// instructions. This is Milestone 4's own stated goal — "get the
    /// guest kernel executing" — not a claim that it boots to
    /// anything further: real XNU boot code still exercises
    /// instruction families and kernel subsystems this emulator
    /// doesn't fully model yet, so halting on `.unsupportedInstruction`
    /// or a memory fault partway through real execution remains the
    /// expected, honest outcome, not a bug in the loader.
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

        var deviceTree: Data?
        do {
            let extracted = try await Task.detached(priority: .userInitiated) {
                try DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: fileURL)
            }.value
            deviceTree = extracted
            appendLog("Device tree extracted: \(Int64(extracted.count).formattedByteCount).")
        } catch let error as FriendlyError {
            // Not fatal — some firmware may not declare/have a usable
            // device tree, and XNU's very early entry code doesn't
            // touch it. boot_args.deviceTreeP is left honestly zero
            // rather than this failure blocking the boot attempt.
            appendLog("Device tree extraction skipped: \(error.developerDetail)")
        } catch {
            appendLog("Device tree extraction skipped: \(error.localizedDescription)")
        }

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
        // The real kernel's own boot code reads topOfKernelData straight
        // into TTBR0 (confirmed via llvm-objdump: `ldr r4, [r0, #0x10]`
        // then `mcr p15, #0, r5, c2, c0, #0` with r5 built from r4) —
        // and TTBR0's low 14 bits are architecturally reserved/ignored
        // (ARM DDI 0406C B4.1.154), so a real MMU walk always masks them
        // off. A topOfKernelData that isn't itself 16KB-aligned would
        // silently have its own first-level table address rounded down
        // to some earlier, unrelated 16KB boundary — on real hardware
        // this can't happen because iBoot always hands the kernel an
        // aligned value, so this rounds up the same way rather than
        // reproducing an address a real bootloader would never produce.
        // The device tree, if extracted, is placed on its own page right
        // after boot_args — real iBoot page-aligns each component it
        // hands the kernel, and `topOfKernelData` below is computed to
        // cover it, so there's no risk of the kernel's own early
        // allocator reusing this range.
        // The shipped device tree is the unpopulated IPSW template —
        // iBoot never ran to patch in real clock/serial data. A
        // handful of clock properties, left at their shipped 4-byte
        // `0`, make the real kernel dereference `0` as a pointer (a
        // genuine quirk of how a Thumb IT block's flags interact here
        // — see DeviceTreePatcher's doc comment). Patching happens
        // before any size-dependent layout below, since expanding
        // those properties to their real 8-byte encoding changes the
        // tree's total length.
        if deviceTree != nil {
            DeviceTreePatcher.patchClockPlaceholders(&deviceTree!)
        }

        let deviceTreeAddress = (bootArgsAddress + UInt32(BootArgsBuilder.structSize) + 0xFFF) & ~UInt32(0xFFF)
        let deviceTreeLength = UInt32(deviceTree?.count ?? 0)

        // The `pram` node's `reg` property (see `DeviceTreePatcher
        // .patchPramRegion`'s doc comment) needs to point at real,
        // backed physical memory for the real kernel's panic-log
        // mapping to succeed — reserved on its own page right after
        // the device tree, same as every other component here.
        let pramAddress = (deviceTreeAddress + deviceTreeLength + 0xFFF) & ~UInt32(0xFFF)
        let pramSize: UInt32 = 0x1000
        if deviceTree != nil {
            DeviceTreePatcher.patchPramRegion(&deviceTree!, physicalAddress: pramAddress, size: pramSize)
        }

        let topOfKernelData = (pramAddress + pramSize + 0x3FFF) & ~UInt32(0x3FFF)
        let bootArgs = BootArgsBuilder.build(
            virtBase: Self.physicalMemoryBaseAddress,
            physBase: Self.physicalMemoryBaseAddress,
            memSize: UInt32(Self.physicalMemorySize),
            topOfKernelData: topOfKernelData,
            deviceTreeP: deviceTree != nil ? deviceTreeAddress : 0,
            deviceTreeLength: deviceTreeLength
        )
        do {
            try memory.writeBytes(bootArgs, at: bootArgsAddress)
            if let deviceTree {
                try memory.writeBytes(deviceTree, at: deviceTreeAddress)
                appendLog("Device tree written at 0x\(deviceTreeAddress.hexString8) (\(Int64(deviceTree.count).formattedByteCount)).")
            }
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
