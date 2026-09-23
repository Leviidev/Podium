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
    private(set) var framebufferSource: FramebufferSource?
    private var segmentedBus: SegmentedMemoryBus?
    /// The A4's modeled hardware (timer, interrupt controller). The CPU
    /// only holds it weakly, so this is what keeps it alive.
    private var platform: S5L8930XPlatform?

    let audioOutput: AudioOutput
    let networkInterface: NetworkInterface
    let inputController: InputController

    /// See `GuestMemoryLayout` for the real S5L8930X address map these
    /// come from.
    static let physicalMemorySize = GuestMemoryLayout.ramSize
    static let physicalMemoryBaseAddress = GuestMemoryLayout.ramPhysicalBase
    static let framebufferWidth = GuestMemoryLayout.framebufferWidth
    static let framebufferHeight = GuestMemoryLayout.framebufferHeight
    static let framebufferPhysicalAddress = GuestMemoryLayout.framebufferPhysicalAddress

    /// Caps a single boot attempt so unsupported guest code halts the
    /// attempt instead of running forever with no way to observe where it
    /// got to. Set far past what's been reached so far — a standalone
    /// macOS trace of this same kernel (see `.standalone_trace/` at the
    /// repo root, not part of the app target) has run clean past 2
    /// billion instructions without hitting an unsupported/undefined
    /// instruction — so a real device (whose JIT-compiled path should run
    /// this meaningfully faster than that trace's interpreter) gets real
    /// room to find out how much further boot actually goes before this
    /// budget, rather than reporting a misleading "step budget reached"
    /// long before the interesting part of boot.
    private static let maxBootUnits = 50_000_000_000

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
        // A small on-chip SRAM at low physical addresses, entirely
        // separate from the external DRAM window at
        // `physicalMemoryBaseAddress` — a standard feature on SoCs of
        // this era (and this one specifically: a real page-table walk
        // this session hit a coarse second-level table the kernel's
        // own pmap had allocated at physical `0x3000`, well below
        // DRAM, while mapping the `arm-io` peripheral bus — real
        // hardware plausibly keeps early/critical page tables in this
        // always-present on-chip SRAM rather than general DRAM). Not
        // firmware-specific like the peripheral map below, so backed
        // unconditionally here rather than waiting on a device tree.
        let lowSRAM = FlatPhysicalMemory(length: 0x0010_0000, baseAddress: 0)
        // Real SoC peripheral registers live at physical addresses
        // nowhere near DRAM — see `SegmentedMemoryBus`'s doc comment.
        // Only RAM/SRAM are known at this point; `attemptBoot` enriches
        // this same bus with the real peripheral map once a specific
        // firmware's device tree has actually been read (see
        // `DeviceTreeMemoryMap`).
        let bus = SegmentedMemoryBus(regions: [ram, lowSRAM])
        let armCPU = ARMv7CPU(memory: bus, jit: JITEngine())
        armCPU.linearMap = (GuestMemoryLayout.kernelVirtualBase, GuestMemoryLayout.ramPhysicalBase, UInt32(GuestMemoryLayout.ramSize))
        armCPU.reset()

        memory = ram
        segmentedBus = bus
        cpu = armCPU
        framebufferSource = GuestFramebuffer(
            memory: ram,
            baseAddress: Self.framebufferPhysicalAddress,
            pixelWidth: Self.framebufferWidth,
            pixelHeight: Self.framebufferHeight
        )
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
        guard let armCPU = cpu as? ARMv7CPU else { return }

        Self.resetLogFile()
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

        // Devices with real behavior go on the bus first, so they take
        // precedence over the plain-storage backing KernelBootstrap adds for
        // the same peripheral windows.
        guard let segmentedBus else { return }
        let platform = S5L8930XPlatform(cpu: armCPU)
        for region in platform.regions {
            segmentedBus.addRegion(region)
        }
        self.platform = platform

        let prepared: KernelBootstrap.Prepared
        do {
            prepared = try KernelBootstrap.prepare(kernel: machO, deviceTree: deviceTree, on: segmentedBus)
        } catch let error as FriendlyError {
            status = .error(error.userMessage)
            appendLog("Kernel load failed: \(error.developerDetail)")
            return
        } catch {
            status = .error("Podium couldn't load this kernel binary.")
            appendLog("Kernel load failed: \(error.localizedDescription)")
            return
        }
        if let deviceTreeAddress = prepared.deviceTreeAddress {
            appendLog("Device tree written at 0x\(deviceTreeAddress.hexString8) (\(Int64(prepared.deviceTreeLength).formattedByteCount)).")
        }

        armCPU.reset()
        armCPU.loadInitialRegisters(prepared.initialRegisters)
        appendLog("boot_args written at 0x\(prepared.bootArgsAddress.hexString8) (physBase=0x\(GuestMemoryLayout.ramPhysicalBase.hexString8), virtBase=0x\(GuestMemoryLayout.kernelVirtualBase.hexString8), memSize=\(Int64(prepared.memorySizeGivenToKernel).formattedByteCount)); r0 points there.")
        appendLog("Kernel loaded. Entry point: 0x\(prepared.entryPoint.hexString8) (physical). Starting execution…")

        // Breakpoints on the kernel's two panic entries (addresses from
        // `nm` on the decrypted kernelcache): `_panic(fmt, ...)` and the
        // unexported `panic_context(reason, ctx, fmt, ...)` exception
        // handlers use, which jumps into `_panic`'s tail and so never
        // passes its entry. Real runs reach a panic long before any
        // unsupported instruction trips `lastError`; without these,
        // Podium would only report a generic "still running".
        let panicEntries: [UInt32: Int] = [0x8001_7c10: 0, 0x8001_7f28: 2] // entry -> register holding the format string
        armCPU.breakpoints = Set(panicEntries.keys)
        let chunkSize = 200_000
        let stepBudget = Self.maxBootUnits
        // With `maxBootUnits` in the billions, a single boot attempt can run
        // a long time; this periodic line lets progress be checked (e.g. by
        // pulling the persisted log file off the device mid-run).
        let progressLogInterval = 50_000_000
        var unitsSinceProgressLog = 0
        var unitsRun = 0
        var panicFormatRegister: Int?
        while unitsRun < stepBudget {
            let ran = await Task.detached(priority: .userInitiated) {
                armCPU.run(maxUnits: min(chunkSize, stepBudget - unitsRun))
            }.value
            unitsRun += ran
            unitsSinceProgressLog += ran
            if unitsSinceProgressLog >= progressLogInterval {
                unitsSinceProgressLog = 0
                appendLog("Still running: \(armCPU.retiredInstructionCount) instructions so far, PC now 0x\(armCPU.registers.pc.hexString8).")
            }
            if let hit = armCPU.hitBreakpoint {
                panicFormatRegister = panicEntries[hit]
                break
            }
            if ran == 0 || armCPU.lastError != nil {
                break
            }
        }

        let instructions = armCPU.retiredInstructionCount
        if let register = panicFormatRegister {
            let format = armCPU.registers[register]
            let message = Self.readCString(from: segmentedBus, at: GuestMemoryLayout.physical(fromKernelVirtual: format), maxLength: 512)
            status = .error("Kernel panic after \(instructions) instructions: \(message)")
            appendLog("Kernel panicked (entry 0x\(armCPU.registers.pc.hexString8)). Format string at 0x\(format.hexString8): \(message)")
        } else if let error = armCPU.lastError {
            status = .error("Halted after \(instructions) instructions: \(Self.describe(error)).")
            appendLog("Execution halted: \(error)")
        } else {
            status = .running
            appendLog("Ran \(instructions) instructions without hitting an unimplemented instruction (step budget reached). PC now 0x\(armCPU.registers.pc.hexString8).")
        }

        // The `pram` region is where the kernel's panic path writes its
        // fully-rendered log (varargs substituted, unlike the raw format
        // string above), so a device run's crash log survives either way.
        if let pramText = Self.readPrintableText(from: segmentedBus, at: prepared.pramAddress, length: Int(prepared.pramSize)), !pramText.isEmpty {
            appendLog("pram (panic log) region contents: \(pramText)")
        }
    }

    /// Reads a NUL-terminated C string starting at `address`, best-effort
    /// (stops early on any read failure rather than throwing, since this
    /// only ever runs after something has already gone wrong).
    private static func readCString(from memory: MemoryBus, at address: UInt32, maxLength: Int) -> String {
        var bytes: [UInt8] = []
        var cursor = address
        for _ in 0..<maxLength {
            guard let byte = try? memory.readByte(at: cursor), byte != 0 else { break }
            bytes.append(byte)
            cursor &+= 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads `length` bytes starting at `address` and returns the
    /// printable-ASCII subset (kernel panic logs are plain text with
    /// occasional NULs/padding, not arbitrary binary), or nil if the
    /// region couldn't be read at all.
    private static func readPrintableText(from memory: MemoryBus, at address: UInt32, length: Int) -> String? {
        guard let data = try? memory.readBytes(length, at: address) else { return nil }
        let printable = data.filter { $0 == 0x0A || (0x20...0x7E).contains($0) }
        return String(decoding: printable, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let entry = EmulatorLogEntry(date: Date(), message: message)
        log.append(entry)
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
        Self.persistLogLine("\(entry.formattedTime) \(message)")
    }

    /// Every log entry, additionally mirrored to a real file in the app's
    /// Documents directory — unlike the in-memory `log` above (capped at
    /// `logCapacity`, lost on relaunch), this survives the app quitting
    /// or crashing and can be pulled straight off the device (e.g. via
    /// `xcrun devicectl device copy from`) without needing the UI at all.
    private static let logFileURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("podium.log")
    }()

    /// Starts a fresh log file for this boot attempt so it isn't a
    /// confusing mix of unrelated runs.
    private static func resetLogFile() {
        guard let url = logFileURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func persistLogLine(_ line: String) {
        guard let url = logFileURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
