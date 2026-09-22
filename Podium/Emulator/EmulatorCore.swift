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

    /// The iPod touch 4's actual panel resolution (Section 9 of the
    /// project spec) and the framebuffer's assumed pixel format — 32
    /// bits/pixel, no rotation (`BootVideoInfo.depth`'s low byte).
    /// Nothing confirms this is the exact byte order the real kernel
    /// draws in; `GuestFramebuffer` copies whatever bytes are actually
    /// there rather than assuming this guess is correct.
    static let framebufferWidth = 960
    static let framebufferHeight = 640
    private static let framebufferBytesPerPixel = 4
    private static let framebufferRowBytes = UInt32(framebufferWidth * framebufferBytesPerPixel)
    private static let framebufferSize = framebufferRowBytes * UInt32(framebufferHeight)
    /// Reserved at the very top of the 256 MB RAM window, well above
    /// where the kernel image/device tree/`pram` region load from the
    /// bottom (see `attemptBoot`) — disjoint from that bottom-up layout
    /// by construction, not by coincidence.
    static let framebufferPhysicalAddress: UInt32 = physicalMemoryBaseAddress &+ UInt32(physicalMemorySize) &- framebufferSize

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
        guard let armCPU = cpu as? ARMv7CPU, let memory else { return }

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

            // Real SoC peripheral registers this specific firmware's
            // device tree declares (see `DeviceTreeMemoryMap`'s doc
            // comment) — backed now, once actually known, rather than
            // guessed at when the bus was first stood up.
            let ramRange = Self.physicalMemoryBaseAddress..<(Self.physicalMemoryBaseAddress &+ UInt32(Self.physicalMemorySize))
            for region in DeviceTreeMemoryMap.peripheralRegions(in: deviceTree!, excluding: ramRange) {
                segmentedBus?.addRegion(FlatPhysicalMemory(length: Int(region.size), baseAddress: region.address))
            }
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
        // v_display: iBoot's convention on real hardware is 1 for the
        // main LCD — unconfirmed against this specific kernel's own
        // code (unlike every other field here), so this is a real
        // physical framebuffer either way; only this one field's exact
        // value is a reasonable default rather than a traced fact.
        let video = BootVideoInfo(
            baseAddress: Self.framebufferPhysicalAddress,
            display: 1,
            rowBytes: Self.framebufferRowBytes,
            width: UInt32(Self.framebufferWidth),
            height: UInt32(Self.framebufferHeight),
            depth: 32
        )
        let bootArgs = BootArgsBuilder.build(
            virtBase: Self.physicalMemoryBaseAddress,
            physBase: Self.physicalMemoryBaseAddress,
            memSize: UInt32(Self.physicalMemorySize),
            topOfKernelData: topOfKernelData,
            deviceTreeP: deviceTree != nil ? deviceTreeAddress : 0,
            deviceTreeLength: deviceTreeLength,
            video: video
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

        // Run in chunks rather than one big `run(maxUnits:)` so this loop
        // can watch for the CPU actually reaching the real kernel's
        // `_panic` entry point (0x80017c10, confirmed via `nm` on the
        // decrypted kernelcache) mid-execution. Real device runs so far
        // reach a kernel panic well before any unsupported/undefined
        // instruction or memory fault trips `armCPU.lastError`, so without
        // this, Podium reports a misleadingly generic "still running"
        // status instead of the actual panic.
        let panicEntryAddress: UInt32 = 0x8001_7c10
        let chunkSize = 200_000
        let stepBudget = Self.maxBootUnits
        // With `maxBootUnits` raised into the billions, a single boot
        // attempt can run for a long time with nothing to show for it in
        // the log until it finally halts — this periodic line lets
        // progress be checked (e.g. by pulling the persisted log file off
        // the device mid-run) without waiting for that.
        let progressLogInterval = 50_000_000
        var unitsSinceProgressLog = 0
        var unitsRun = 0
        var hitPanic = false
        while unitsRun < stepBudget {
            let ran = await Task.detached(priority: .userInitiated) {
                armCPU.run(maxUnits: min(chunkSize, stepBudget - unitsRun))
            }.value
            unitsRun += ran
            unitsSinceProgressLog += ran
            if unitsSinceProgressLog >= progressLogInterval {
                unitsSinceProgressLog = 0
                appendLog("Still running: \(unitsRun) instruction groups so far, PC now 0x\(armCPU.registers.pc.hexString8).")
            }
            if armCPU.registers.pc == panicEntryAddress {
                hitPanic = true
                break
            }
            if ran == 0 || armCPU.lastError != nil {
                break
            }
        }

        if hitPanic {
            let message = Self.readCString(from: memory, at: armCPU.registers[0], maxLength: 512)
            status = .error("Kernel panic after \(unitsRun) instruction group\(unitsRun == 1 ? "" : "s"): \(message)")
            appendLog("Kernel reached _panic (0x\(panicEntryAddress.hexString8)). Format string at 0x\(armCPU.registers[0].hexString8): \(message)")
        } else if let error = armCPU.lastError {
            status = .error("Halted after \(unitsRun) instruction group\(unitsRun == 1 ? "" : "s"): \(Self.describe(error)).")
            appendLog("Execution halted: \(error)")
        } else {
            status = .running
            appendLog("Ran \(unitsRun) instruction groups without hitting an unimplemented instruction (step budget reached). PC now 0x\(armCPU.registers.pc.hexString8).")
        }

        // The `pram` region (see the comment above `pramAddress`) is where
        // the real kernel's panic path writes its fully-rendered log —
        // varargs substituted, unlike the raw format string at r0 above —
        // so a real device run's crash log survives even if panic
        // detection above ever misses the exact entry address.
        if let pramText = Self.readPrintableText(from: memory, at: pramAddress, length: Int(pramSize)), !pramText.isEmpty {
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
