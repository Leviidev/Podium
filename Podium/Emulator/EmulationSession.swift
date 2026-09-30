import Foundation

/// One powered-on run of the emulated iPod touch: its own RAM, CPU and
/// A4 hardware, set up the way iBoot leaves them, with the kernel loaded
/// and the root filesystem mapped in as a RAM disk — then run on a
/// dedicated thread until it's powered off, panics, or halts.
///
/// Everything guest-facing happens on that thread. Other threads only
/// queue input (`send`) and read `snapshot()`; the display is read from
/// guest memory as the hardware would scan it out, which tolerates
/// racing the CPU's writes.
final class EmulationSession {
    enum State: Equatable {
        case running
        case stopped
        /// iOS shut itself down.
        case shutDown
        /// iOS asked to restart.
        case restarting
        case panicked(String)
        case halted(String)
    }

    struct Snapshot {
        let state: State
        let retiredInstructions: UInt64
        let virtualTime: UInt64
        let jitAvailable: Bool
    }

    struct StopResult {
        let state: State
        /// False means the mapped guest disk could not be durably committed;
        /// keep the session alive so the caller can retry instead of unmapping it.
        let storageFlushed: Bool
    }

    /// `_panic` and the unexported `panic_context` (reached from exception
    /// handlers, jumping into `_panic`'s tail) in the 10B500 kernelcache,
    /// with the register holding each one's format string.
    private static let panicEntries: [UInt32: Int] = [0x8001_7C10: 0, 0x8001_7F28: 2]
    /// `boot(paniced, howto, command)` in the same kernelcache, where every
    /// shutdown and restart begins once launchd asks for one; `howto` bit 3
    /// (`RB_HALT`) tells a shutdown from a restart. The run ends there:
    /// everything the kernel does after it — syncing and unmounting a root
    /// filesystem whose changes are discarded at power-off anyway, telling
    /// every driver — only takes time. A lot of it: by then the root
    /// filesystem's cached pages are going, and a launchd thread that
    /// wakes up faults on its own code, takes the signal, faults again in
    /// the handler, and crowds out the halt for a minute or more.
    private static let shutdownEntry: UInt32 = 0x801D_F6E8
    /// `shared_region_map_and_slide_np` (syscall 438, from `sysent`), which
    /// launchd's dyld calls once, early, to map the dyld shared cache: the
    /// slide it picked is the fourth word of the arguments (`r1 + 0xc`),
    /// and QuartzCoreAcceleration needs it.
    private static let sharedRegionEntry: UInt32 = 0x8021_DC94
    private static let haltFlag: UInt32 = 1 << 3

    let cpu: ARMv7CPU
    let platform: S5L8930XPlatform
    let display: DisplayScanout
    private let bus: SegmentedMemoryBus
    /// The physical address space, for diagnostics.
    var memoryBus: MemoryBus { bus }
    private let ram: FlatPhysicalMemory
    /// The persistent user volume, if this run shares it with the host file.
    private let persistentRootFilesystem: Bool
    /// Where the RAM disk sits in guest RAM (offsets from its base).
    private var ramDiskRange: Range<Int> = 0..<0
    private var messageBufferOffset: Int?
    private var messagesRead = 0

    private let lock = NSLock()
    private var pendingInput: [(event: InputEvent, sent: Date)] = []
    /// Buttons down: when the press was sent, and the guest time it
    /// landed at (emulation thread only).
    private var buttonsDown: [Button: (sent: Date, landed: UInt64)] = [:]
    /// Buttons released on the host whose release the guest hasn't seen
    /// yet, and the guest time it lands at (emulation thread only).
    private var releasesDue: [Button: UInt64] = [:]
    private var stopRequested = false
    private var state: State = .running
    private var runLoopHasStarted = false
    private var runLoopHasFinished = false
    private var stateBeforeStorageFlushFailure: State?
    private var storageFlushError: String?
    private let runLoopFinished = DispatchGroup()
    private var retired: UInt64 = 0
    private var virtualTime: UInt64 = 0
    private var thread: Thread?
    private var guestReset = false
    /// Called on the emulation thread once the run ends, for any reason.
    var onFinish: ((State) -> Void)?

    /// `persistent`: the guest's writes to its root filesystem go to the
    /// image file, and last; otherwise every boot starts from the image.
    init(kernel: Data, deviceTree: Data, rootFilesystem: URL, persistent: Bool = false) throws {
        ram = FlatPhysicalMemory(length: GuestMemoryLayout.ramSize, baseAddress: GuestMemoryLayout.ramPhysicalBase)
        persistentRootFilesystem = persistent
        // A small on-chip SRAM at low physical addresses, separate from
        // DRAM: the kernel's pmap has put early page tables there.
        let lowSRAM = FlatPhysicalMemory(length: 0x0010_0000, baseAddress: 0)
        bus = SegmentedMemoryBus(regions: [ram, lowSRAM])
        // Not the old block JIT (its short kernel-only blocks cost more to
        // look up than they saved); DBTEngine, attached below, is what
        // translates guest code now.
        cpu = ARMv7CPU(memory: bus, jit: nil)
        cpu.linearMap = (GuestMemoryLayout.kernelVirtualBase, GuestMemoryLayout.ramPhysicalBase, UInt32(GuestMemoryLayout.ramSize))
        GuestAccommodations.install(on: cpu)
        // Devices with real behavior go on the bus before the plain
        // storage KernelBootstrap adds for the other peripheral windows.
        platform = S5L8930XPlatform(cpu: cpu)
        for region in platform.regions { bus.addRegion(region) }
        display = DisplayScanout(memory: bus, dart: platform.dart2, bootFramebuffer: GuestFramebuffer(
            memory: ram,
            baseAddress: GuestMemoryLayout.framebufferPhysicalAddress,
            pixelWidth: GuestMemoryLayout.framebufferWidth,
            pixelHeight: GuestMemoryLayout.framebufferHeight
        ))

        let size = try FileManager.default.attributesOfItem(atPath: rootFilesystem.path)[.size] as? Int ?? 0
        let prepared = try KernelBootstrap.prepare(kernel: kernel, deviceTree: deviceTree, on: bus, ramDiskSize: size)
        if let address = prepared.ramDiskAddress {
            _ = try ram.mapFile(rootFilesystem, at: address, shared: persistent)
            let start = Int(address - GuestMemoryLayout.ramPhysicalBase)
            ramDiskRange = start..<start + size
        }
        cpu.reset()
        cpu.loadInitialRegisters(prepared.initialRegisters)
        cpu.breakpoints = Set(Self.panicEntries.keys).union([Self.shutdownEntry, Self.sharedRegionEntry])
        // Translated code wherever this process may run generated code (on
        // iOS, once a debugger such as StikDebug has prepared memory for
        // it); the interpreter otherwise.
        cpu.dbt = DBTEngine(cpu: cpu)
        KernelAcceleration.install(on: cpu)
        // A reset by any other route (the kernel ends a halt with the
        // watchdog, and spins until it lands) ends the run too; the run
        // loop sees it at the end of the chunk.
        platform.watchdog.onReset = { [unowned self] in guestReset = true }
    }

    func start() {
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "Podium emulation"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        lock.lock()
        guard !runLoopHasStarted, !runLoopHasFinished else { lock.unlock(); return }
        self.thread = thread
        runLoopHasStarted = true
        runLoopFinished.enter()
        lock.unlock()
        thread.start()
    }

    /// Stops at the next CPU chunk boundary. Persistent storage is flushed
    /// by the run loop before this returns. If the flush fails, the session
    /// remains available so the caller can retry before unmapping the disk.
    @discardableResult
    func stop() -> StopResult {
        lock.lock()
        if runLoopHasFinished {
            if let previousState = stateBeforeStorageFlushFailure {
                do {
                    try ram.flushSharedFileMappings()
                    storageFlushError = nil
                    stateBeforeStorageFlushFailure = nil
                    state = previousState
                } catch {
                    storageFlushError = "\(error)"
                    state = .halted("couldn't flush persistent guest storage: \(error)")
                }
            }
            let result = StopResult(state: state, storageFlushed: storageFlushError == nil)
            lock.unlock()
            return result
        }
        if runLoopHasStarted, thread == nil {
            // Another stop is performing the pre-start flush.
            lock.unlock()
            runLoopFinished.wait()
            lock.lock()
            let result = StopResult(state: state, storageFlushed: storageFlushError == nil)
            lock.unlock()
            return result
        }
        guard runLoopHasStarted else {
            // Seal the session against a concurrent start, and let any other
            // stop caller wait until this synchronous flush is complete.
            runLoopHasStarted = true
            runLoopFinished.enter()
            lock.unlock()
            var finalState = State.stopped
            if persistentRootFilesystem {
                do {
                    try ram.flushSharedFileMappings()
                } catch {
                    finalState = .halted("couldn't flush persistent guest storage: \(error)")
                }
            }
            lock.lock()
            if case .halted(let message) = finalState, message.hasPrefix("couldn't flush persistent guest storage:") {
                stateBeforeStorageFlushFailure = .stopped
                storageFlushError = message
            }
            state = finalState
            runLoopHasFinished = true
            let result = StopResult(state: finalState, storageFlushed: storageFlushError == nil)
            lock.unlock()
            runLoopFinished.leave()
            return result
        }
        stopRequested = true
        lock.unlock()
        inputArrived.signal()
        runLoopFinished.wait()
        lock.lock()
        let result = StopResult(state: state, storageFlushed: storageFlushError == nil)
        lock.unlock()
        return result
    }

    /// A natural guest shutdown with a failed final sync stays recoverable
    /// until Power Off retries the commit.
    var hasStorageFlushFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storageFlushError != nil
    }

    var storageFlushFailureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return storageFlushError
    }

    func send(_ event: InputEvent) {
        lock.lock()
        pendingInput.append((event, Date()))
        lock.unlock()
        inputArrived.signal()
    }

    // MARK: Pacing

    /// Wakes the emulation thread from an idle wait.
    private let inputArrived = DispatchSemaphore(value: 0)
    /// The host moment guest time was last pinned to, and that time.
    private var paceAnchor: (host: UInt64, virtual: UInt64)?

    /// The guest's clock, in `virtualTime` units per host second.
    private static let virtualTimePerHostSecond = 24_000_000 * Double(S5L8930XPlatform.instructionsPerTimebaseTick)
    /// Lag behind real time forgiven rather than caught up.
    private static let forgivenLag = 0.25

    /// How far virtual time may run: no faster than real time, so an idle
    /// guest's clock — its timeouts, auto-lock, animations — keeps real
    /// time instead of racing ahead as WFI skips. A busy guest runs
    /// behind real time; that lag is forgiven rather than caught up in a
    /// burst.
    private func paceLimit() -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let virtual = cpu.virtualTime
        guard let anchor = paceAnchor else {
            paceAnchor = (now, virtual)
            return virtual
        }
        let allowed = anchor.virtual &+ UInt64(Double(now &- anchor.host) / 1e9 * Self.virtualTimePerHostSecond)
        if allowed > virtual, Double(allowed &- virtual) / Self.virtualTimePerHostSecond > Self.forgivenLag {
            paceAnchor = (now, virtual)
            return virtual &+ UInt64(Self.forgivenLag * Self.virtualTimePerHostSecond)
        }
        return allowed
    }

    /// Sleeps until guest time may reach the next device event (or a bit,
    /// if there's none), or input arrives.
    private func waitWhileIdle(limit: UInt64) {
        let next = cpu.nextDeviceEventAt
        let seconds = next == .max ? 0.05 : min(Double(next &- min(next, limit)) / Self.virtualTimePerHostSecond, 0.05)
        let started = DispatchTime.now().uptimeNanoseconds
        _ = inputArrived.wait(timeout: .now() + max(seconds, 0.001))
        idleNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- started
    }

    /// Host time the emulation thread has spent waiting for guest time to
    /// catch up (the guest idle), for measuring how busy it is.
    private(set) var idleNanoseconds: UInt64 = 0

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(state: state, retiredInstructions: retired, virtualTime: virtualTime, jitAvailable: cpu.dbt != nil)
    }

    // MARK: Buttons

    enum Button { case home, power, volumeUp, volumeDown }

    private static func button(_ event: InputEvent) -> (button: Button, pressed: Bool)? {
        switch event {
        case .homeButton(let pressed): (.home, pressed)
        case .powerButton(let pressed): (.power, pressed)
        case .volumeUp(let pressed): (.volumeUp, pressed)
        case .volumeDown(let pressed): (.volumeDown, pressed)
        case .touchBegan, .touchMoved, .touchEnded: nil
        }
    }

    private static func release(_ button: Button) -> InputEvent {
        switch button {
        case .home: .homeButton(pressed: false)
        case .power: .powerButton(pressed: false)
        case .volumeUp: .volumeUp(pressed: false)
        case .volumeDown: .volumeDown(pressed: false)
        }
    }

    /// Guest time, in `virtualTime` units, per second: the 24 MHz timebase.
    private static let virtualTimePerSecond = 24_000_000 * Double(S5L8930XPlatform.instructionsPerTimebaseTick)
    /// The longest hold a release waits for: a little over the two
    /// seconds iOS takes for "slide to power off". Not much more — while
    /// the guest is busy its clock runs behind real time, so a longer wait
    /// keeps iOS thinking the button is down (and ignoring the slider)
    /// for real seconds after it was let go.
    private static let longestHold: TimeInterval = 3

    /// Applies input, all at once except button releases. The guest's
    /// clock runs several times slower than the host's while it's busy,
    /// and iOS tells a press from a hold by how long it lasts in its own
    /// time — so a button is released only once the guest has seen it
    /// held as long as it really was (up to `longestHold`). Otherwise a
    /// hold long enough to bring up "slide to power off" could land as a
    /// tap, which sleeps the device. Touches never wait.
    private func apply(_ input: [(event: InputEvent, sent: Date)]) {
        for (event, sent) in input {
            guard let (button, pressed) = Self.button(event) else {
                platform.handle(event)
                continue
            }
            if pressed {
                if releasesDue.removeValue(forKey: button) != nil { platform.handle(Self.release(button)) }
                platform.handle(event)
                buttonsDown[button] = (sent, cpu.virtualTime)
            } else if let down = buttonsDown.removeValue(forKey: button) {
                let held = min(max(sent.timeIntervalSince(down.sent), 0), Self.longestHold)
                releasesDue[button] = down.landed &+ UInt64(held * Self.virtualTimePerSecond)
            } else {
                platform.handle(event)
            }
        }
        for (button, due) in releasesDue where cpu.virtualTime >= due {
            releasesDue[button] = nil
            platform.handle(Self.release(button))
        }
    }

    // MARK: Running

    /// This boot's dyld shared cache slide, once known.
    private(set) var sharedCacheSlide: UInt32?

    private func runLoop() {
        var finalState = State.stopped
        while true {
            lock.lock()
            let stopping = stopRequested
            let input = pendingInput
            pendingInput.removeAll()
            lock.unlock()
            if stopping { break }
            apply(input)

            let limit = paceLimit()
            cpu.idleSkipLimit = limit
            let ran = cpu.run(maxUnits: 1_000_000)
            if guestReset {
                finalState = .shutDown
                break
            }
            if cpu.hitBreakpoint == Self.sharedRegionEntry {
                cpu.breakpoints.remove(Self.sharedRegionEntry)
                if let arguments = cpu.hostAddress(ofVirtual: cpu.registers[1] &+ 0xC, for: .read) {
                    sharedCacheSlide = arguments.load(as: UInt32.self)
                    QuartzCoreAcceleration.install(on: cpu, sharedCacheSlide: arguments.load(as: UInt32.self))
                }
                continue
            }
            if cpu.hitBreakpoint == Self.shutdownEntry {
                finalState = cpu.registers[1] & Self.haltFlag != 0 ? .shutDown : .restarting
                break
            }
            if let hit = cpu.hitBreakpoint, let register = Self.panicEntries[hit] {
                let format = cpu.registers[register]
                finalState = .panicked(readCString(atKernelVirtual: format))
                break
            }
            if let error = cpu.lastError {
                finalState = .halted("\(error)")
                break
            }
            if cpu.idleBlocked {
                waitWhileIdle(limit: limit)
            } else if ran == 0, cpu.hitBreakpoint == nil {
                finalState = .halted("the CPU stopped making progress")
                break
            }
            lock.lock()
            retired = cpu.retiredInstructionCount
            virtualTime = cpu.virtualTime
            lock.unlock()
        }
        let stateBeforeFlush = finalState
        retired = cpu.retiredInstructionCount
        virtualTime = cpu.virtualTime
        if persistentRootFilesystem {
            do {
                try ram.flushSharedFileMappings()
            } catch {
                finalState = .halted("couldn't flush persistent guest storage: \(error)")
                lock.lock()
                stateBeforeStorageFlushFailure = stateBeforeFlush
                storageFlushError = "\(error)"
                lock.unlock()
            }
        }
        lock.lock()
        state = finalState
        runLoopHasFinished = true
        lock.unlock()
        runLoopFinished.leave()
        onFinish?(finalState)
    }

    /// Kernel messages logged since the last call, read straight from the
    /// kernel's message buffer (`msgbuf`, found by its magic) in guest RAM.
    /// Safe from any thread; call from one at a time.
    func newKernelMessages() -> String {
        guard let region = ram.fastPathRegion(for: GuestMemoryLayout.ramPhysicalBase) else { return "" }
        let raw = UnsafeRawBufferPointer(start: region.pointer, count: region.regionLength)
        func word(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        func ring(at offset: Int) -> (start: Int, size: Int, next: Int)? {
            guard offset + 20 <= raw.count, word(offset) == 0x63061 else { return nil }
            let size = Int(word(offset + 4)), next = Int(word(offset + 8)), buffer = word(offset + 16)
            guard size >= 0x1000, size <= 0x10_0000, next < size, buffer >= GuestMemoryLayout.kernelVirtualBase else { return nil }
            let start = Int(GuestMemoryLayout.physical(fromKernelVirtual: buffer) &- GuestMemoryLayout.ramPhysicalBase)
            guard start >= 0, start + size <= raw.count else { return nil }
            return (start, size, next)
        }
        if messageBufferOffset == nil {
            var offset = 0
            while offset + 20 <= raw.count {
                if ramDiskRange.contains(offset) { offset = ramDiskRange.upperBound; continue }
                if word(offset) == 0x63061, ring(at: offset) != nil { messageBufferOffset = offset; break }
                offset += 4
            }
        }
        guard let offset = messageBufferOffset, let buffer = ring(at: offset) else { return "" }
        let last = messagesRead
        messagesRead = buffer.next
        guard buffer.next != last else { return "" }
        let bytes = buffer.next > last
            ? Array(raw[buffer.start + last..<buffer.start + buffer.next])
            : Array(raw[buffer.start + last..<buffer.start + buffer.size]) + Array(raw[buffer.start..<buffer.start + buffer.next])
        return String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
    }

    private func readCString(atKernelVirtual address: UInt32) -> String {
        var bytes: [UInt8] = []
        var cursor = GuestMemoryLayout.physical(fromKernelVirtual: address)
        while bytes.count < 512, let byte = try? bus.readByte(at: cursor), byte != 0 {
            bytes.append(byte)
            cursor &+= 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
