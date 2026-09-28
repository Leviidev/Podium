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
        /// iOS shut itself down (or restarted): the watchdog reset it.
        case shutDown
        case panicked(String)
        case halted(String)
    }

    struct Snapshot {
        let state: State
        let retiredInstructions: UInt64
        let virtualTime: UInt64
        let jitAvailable: Bool
    }

    /// `_panic` and the unexported `panic_context` (reached from exception
    /// handlers, jumping into `_panic`'s tail) in the 10B500 kernelcache,
    /// with the register holding each one's format string.
    private static let panicEntries: [UInt32: Int] = [0x8001_7C10: 0, 0x8001_7F28: 2]

    let cpu: ARMv7CPU
    let platform: S5L8930XPlatform
    let display: DisplayScanout
    private let bus: SegmentedMemoryBus
    /// The physical address space, for diagnostics.
    var memoryBus: MemoryBus { bus }
    private let ram: FlatPhysicalMemory
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
    private var retired: UInt64 = 0
    private var virtualTime: UInt64 = 0
    private var thread: Thread?
    private var guestReset = false
    /// Called on the emulation thread once the run ends, for any reason.
    var onFinish: ((State) -> Void)?

    init(kernel: Data, deviceTree: Data, rootFilesystem: URL) throws {
        ram = FlatPhysicalMemory(length: GuestMemoryLayout.ramSize, baseAddress: GuestMemoryLayout.ramPhysicalBase)
        // A small on-chip SRAM at low physical addresses, separate from
        // DRAM: the kernel's pmap has put early page tables there.
        let lowSRAM = FlatPhysicalMemory(length: 0x0010_0000, baseAddress: 0)
        bus = SegmentedMemoryBus(regions: [ram, lowSRAM])
        // No JIT: now that the interpreter keeps decoded instructions, its
        // short kernel-only blocks cost more to look up than they save
        // (measured 48M instructions/s with it, 51M without), and on a
        // device it needs a debugger attached to run at all.
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
            _ = try ram.mapFile(rootFilesystem, at: address)
            let start = Int(address - GuestMemoryLayout.ramPhysicalBase)
            ramDiskRange = start..<start + size
        }
        cpu.reset()
        cpu.loadInitialRegisters(prepared.initialRegisters)
        cpu.breakpoints = Set(Self.panicEntries.keys)
        // The CPU spins until the reset lands; the run loop sees it at the
        // end of the chunk.
        platform.watchdog.onReset = { [unowned self] in guestReset = true }
    }

    func start() {
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "Podium emulation"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        self.thread = thread
        thread.start()
    }

    /// Stops the CPU at the next chunk boundary.
    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    func send(_ event: InputEvent) {
        lock.lock()
        pendingInput.append((event, Date()))
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(state: state, retiredInstructions: retired, virtualTime: virtualTime, jitAvailable: cpu.jit?.isAvailable ?? false)
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
    /// The longest hold a release waits for: longer than any press iOS
    /// tells from a hold (about two seconds, for "slide to power off").
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

            let ran = cpu.run(maxUnits: 1_000_000)
            if guestReset {
                finalState = .shutDown
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
            if ran == 0, cpu.hitBreakpoint == nil {
                finalState = .halted("the CPU stopped making progress")
                break
            }
            lock.lock()
            retired = cpu.retiredInstructionCount
            virtualTime = cpu.virtualTime
            lock.unlock()
        }
        lock.lock()
        state = finalState
        retired = cpu.retiredInstructionCount
        virtualTime = cpu.virtualTime
        lock.unlock()
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
