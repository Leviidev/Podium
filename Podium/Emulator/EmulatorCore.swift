import Foundation
import Observation

/// Coordinates the emulator for the UI: powering the virtual iPod on
/// (preparing its root filesystem the first time), tracking boot progress
/// toward the lock screen, forwarding input, and powering it off.
///
/// The machine itself is an `EmulationSession`, created fresh for every
/// power-on and run on its own thread; this class only polls it.
@MainActor
@Observable
final class EmulatorCore {
    /// Where a power-on is up to, for the boot screen.
    enum BootStage: Equatable {
        /// First launch only: building the root filesystem from the IPSW.
        case preparingFilesystem(RootFilesystemPreparer.Phase, fraction: Double)
        case loadingKernel
        /// iOS is starting; `fraction` of the way to the lock screen, and
        /// roughly how long is left at the current speed.
        case booting(fraction: Double, secondsRemaining: Double?)
        /// The lock screen (or anything later) is up.
        case running
    }

    private(set) var status: EmulatorStatus = .stopped
    private(set) var bootStage: BootStage?
    private(set) var log: [EmulatorLogEntry] = []
    private(set) var framebufferSource: FramebufferSource?
    private(set) var session: EmulationSession?
    /// Guest instructions per second over the last few seconds.
    private(set) var instructionsPerSecond: Double = 0
    private(set) var jitAvailable = false

    var cpu: CPU? { session?.cpu }
    var isPoweredOn: Bool { session != nil }

    let audioOutput: AudioOutput
    let networkInterface: NetworkInterface
    let inputController: InputController

    static let physicalMemorySize = GuestMemoryLayout.ramSize
    static let framebufferWidth = GuestMemoryLayout.framebufferWidth
    static let framebufferHeight = GuestMemoryLayout.framebufferHeight

    /// Guest instructions from power-on to the lock screen, measured with
    /// the app's own session code on the Mac; replaced by what this device
    /// actually took once it has booted once, so later estimates match.
    private static let defaultBootInstructions: Double = 5_500_000_000
    /// Per root filesystem recipe: a new recipe can change how much work
    /// boot does.
    private static let measuredBootInstructionsKey = "EmulatorCore.measuredBootInstructions.\(RootFilesystemRecipe.version)"
    private static let logCapacity = 200

    private var pollTask: Task<Void, Never>?
    /// What the running machine was powered on with, so a restart iOS
    /// asks for can power it straight back on.
    private var poweredOnWith: (firmware: ImportedFirmware, fileURL: URL)?
    private var rateSamples: [(time: Date, retired: UInt64)] = []

    init(
        audioOutput: AudioOutput = NullAudioOutput(),
        networkInterface: NetworkInterface = NullNetworkInterface(),
        inputController: InputController = PassthroughInputController()
    ) {
        self.audioOutput = audioOutput
        self.networkInterface = networkInterface
        self.inputController = inputController
    }

    private var expectedBootInstructions: Double {
        let measured = UserDefaults.standard.double(forKey: Self.measuredBootInstructionsKey)
        return measured > 1_000_000_000 ? measured : Self.defaultBootInstructions
    }

    // MARK: Power

    /// Boots `firmware` to its lock screen. Returns once the machine is
    /// running (or failed to start); boot progress continues in
    /// `bootStage`.
    func powerOn(firmware: ImportedFirmware, storedAt fileURL: URL) async {
        guard session == nil, bootStage == nil else { return }
        Self.resetLogFile()
        await boot(firmware: firmware, storedAt: fileURL)
    }

    private func boot(firmware: ImportedFirmware, storedAt fileURL: URL) async {
        guard session == nil, bootStage == nil else { return }
        poweredOnWith = (firmware, fileURL)
        status = .booting
        bootStage = .loadingKernel
        appendLog("Powering on \(firmware.displayName) (iOS \(firmware.metadata.productVersion)).")

        do {
            if !RootFilesystemPreparer.isPrepared(forFirmwareAt: fileURL) {
                appendLog("Preparing the root filesystem from the IPSW (first launch only)…")
                bootStage = .preparingFilesystem(.extracting, fraction: 0)
                let keybagBootstrap = try Self.bundledKeybagBootstrap()
                let firstBootState = Bundle.main.url(forResource: "first_boot_state", withExtension: "plist").flatMap { try? Data(contentsOf: $0) }
                let bootReadFiles = Bundle.main.url(forResource: "boot_read_files", withExtension: "txt")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(RootFilesystemRecipe.fileList) ?? []
                let started = Date()
                try await Task.detached(priority: .userInitiated) {
                    try RootFilesystemPreparer.prepare(firmwareAt: fileURL, keybagBootstrap: keybagBootstrap, firstBootState: firstBootState,
                                                       bootReadFiles: bootReadFiles) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, case .preparingFilesystem = self.bootStage else { return }
                            self.bootStage = .preparingFilesystem(progress.phase, fraction: progress.fraction)
                        }
                    }
                }.value
                appendLog(String(format: "Root filesystem ready in %.1f s.", Date().timeIntervalSince(started)))
            }
            bootStage = .loadingKernel
            let rootFilesystem = RootFilesystemPreparer.imageURL(forFirmwareAt: fileURL)
            let session = try await Task.detached(priority: .userInitiated) {
                let kernel = try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: fileURL)
                let deviceTree = try DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: fileURL)
                return try EmulationSession(kernel: kernel, deviceTree: deviceTree, rootFilesystem: rootFilesystem)
            }.value
            session.onFinish = { [weak self] state in
                Task { @MainActor in self?.sessionFinished(state) }
            }
            self.session = session
            framebufferSource = session.display
            rateSamples = [(Date(), 0)]
            bootStage = .booting(fraction: 0, secondsRemaining: nil)
            session.start()
            appendLog("Kernel loaded; iOS is starting.")
            startPolling()
        } catch let error as FriendlyError {
            fail(error.userMessage, detail: error.developerDetail)
        } catch {
            fail("Podium couldn't start this firmware.", detail: "\(error)")
        }
    }

    /// Cuts the power: the machine stops at once and its memory is freed.
    func powerOff() {
        guard let session else { return }
        session.onFinish = nil
        session.stop()
        pollTask?.cancel()
        pollTask = nil
        self.session = nil
        framebufferSource = nil
        bootStage = nil
        status = .stopped
        appendLog("Powered off.")
    }

    func sendInput(_ event: InputEvent) {
        inputController.send(event)
        session?.send(event)
    }

    // MARK: Progress

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.poll()
            }
        }
    }

    private func poll() {
        guard let session else { return }
        let snapshot = session.snapshot()
        jitAvailable = snapshot.jitAvailable
        let now = Date()
        rateSamples.append((now, snapshot.retiredInstructions))
        rateSamples.removeAll { now.timeIntervalSince($0.time) > 6 }
        if let first = rateSamples.first, let last = rateSamples.last, last.time > first.time {
            instructionsPerSecond = Double(last.retired - first.retired) / last.time.timeIntervalSince(first.time)
        }
        guard case .booting = bootStage else { return }
        if Self.lockScreenIsUp(session.display) {
            bootStage = .running
            status = .running
            UserDefaults.standard.set(Double(snapshot.retiredInstructions), forKey: Self.measuredBootInstructionsKey)
            appendLog("Lock screen up after \(snapshot.retiredInstructions) instructions.")
            return
        }
        let expected = expectedBootInstructions
        let done = Double(snapshot.retiredInstructions)
        let fraction = min(done / expected, 0.99)
        let remaining = instructionsPerSecond > 0 ? max(expected - done, 0) / instructionsPerSecond : nil
        bootStage = .booting(fraction: fraction, secondsRemaining: remaining)
    }

    /// The boot screens (Apple logo, SpringBoard's logo flare) are almost
    /// all black or a dark glow; the lock screen is a bright, full-screen
    /// wallpaper.
    static func lockScreenIsUp(_ display: DisplayScanout) -> Bool {
        guard !display.activeLayers.isEmpty else { return false }
        let width = display.pixelWidth, height = display.pixelHeight
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { display.copyCurrentFrame(into: $0) }
        var bright = 0, sampled = 0
        for index in stride(from: 0, to: pixels.count, by: 37) {
            let pixel = pixels[index]
            let sum = (pixel & 0xFF) + (pixel >> 8 & 0xFF) + (pixel >> 16 & 0xFF)
            sampled += 1
            if sum > 3 * 48 { bright += 1 }
        }
        return Double(bright) / Double(sampled) > 0.4
    }

    private func sessionFinished(_ state: EmulationSession.State) {
        pollTask?.cancel()
        pollTask = nil
        session = nil
        bootStage = nil
        switch state {
        case .panicked(let message):
            status = .error("iOS panicked: \(message)")
            appendLog("Kernel panic: \(message)")
        case .halted(let reason):
            status = .error("Emulation stopped: \(reason)")
            appendLog("Halted: \(reason)")
        case .shutDown:
            status = .stopped
            framebufferSource = nil
            appendLog("iOS shut down.")
        case .restarting:
            status = .stopped
            framebufferSource = nil
            appendLog("iOS is restarting.")
            if let (firmware, fileURL) = poweredOnWith {
                Task { await boot(firmware: firmware, storedAt: fileURL) }
            }
        case .stopped, .running:
            status = .stopped
        }
    }

    private func fail(_ message: String, detail: String) {
        status = .error(message)
        bootStage = nil
        appendLog("Power-on failed: \(detail)")
    }

    private static func bundledKeybagBootstrap() throws -> [UInt8] {
        guard let url = Bundle.main.url(forResource: "keybag_bootstrap", withExtension: "bin") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "keybag_bootstrap.bin is missing from the app bundle"])
        }
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: Log

    private func appendLog(_ message: String) {
        let entry = EmulatorLogEntry(date: Date(), message: message)
        log.append(entry)
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
        Self.persistLogLine("\(entry.formattedTime) \(message)")
    }

    /// Every log entry, additionally mirrored to a file in the app's
    /// Documents directory, so a device run's log survives the app quitting
    /// and can be pulled off the device (`xcrun devicectl device copy
    /// from`) without the UI.
    private static let logFileURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("podium.log")
    }()

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
