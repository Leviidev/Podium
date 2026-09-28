import Foundation

/// Told by the CPU when `virtualTime` reaches `nextDeviceEventAt`.
protocol DeviceEventHandler: AnyObject {
    func deviceEventDue(at virtualTime: UInt64)
}

/// The A4 (S5L8930X) SoC hardware that has real behavior, as opposed to
/// the plain storage `DeviceTreeMemoryMap` backs every other peripheral
/// with: the system timer, the power manager, the interrupt controller, and
/// the IOP's and single-wire interface's handshakes, the CDMA engine's
/// memory-to-memory AES, the I²C buses with the PMU on them, the I²S
/// controller's channel status, the display DART's segment table, and the
/// LCD's display pipe and CLCD interrupts at 60 frames a second, wired to
/// the CPU's IRQ/FIQ pins and to its virtual clock.
///
/// Time is virtual: the timebase counter advances one tick per
/// `instructionsPerTimebaseTick` retired instructions (plus whatever WFI
/// skips), never with the host's wall clock. Every run is therefore
/// deterministic — the same instruction always sees the same time, JIT or
/// not — which is what makes JIT-vs-interpreter lockstep checking and
/// reproducible boot traces possible. 16 instructions per 24 MHz tick
/// models a ~384 MIPS CPU, in the range of a real 800 MHz Cortex-A8.
final class S5L8930XPlatform: DeviceEventHandler {
    static let instructionsPerTimebaseTick: UInt64 = 16

    /// Physical base addresses, from the device tree's `arm-io` children.
    /// Both the plain address and its `| 0x80000000` alias are mapped —
    /// see `DeviceTreeMemoryMap` on why these SoCs expose both.
    static let pmgrBase: UInt32 = 0x3F10_0000
    static let vicBase: UInt32 = 0x3F20_0000
    static let iopBase: UInt32 = 0x0630_0000
    static let swiBase: UInt32 = 0x3F60_0000
    static let i2c0Base: UInt32 = 0x0320_0000
    static let i2c2Base: UInt32 = 0x0340_0000
    static let i2c0InterruptLine = 0x13
    static let i2s0Base: UInt32 = 0x0450_0400
    static let dart2Base: UInt32 = 0x09D0_0000
    static let displayPipeBase: UInt32 = 0x0900_0000
    static let clcdBase: UInt32 = 0x0920_0000
    static let dsimBase: UInt32 = 0x0950_0000
    static let gpioBase: UInt32 = 0x3FA0_0000
    static let gpioInterruptLine = 0x74
    static let spi1Base: UInt32 = 0x0210_0000
    static let spi1InterruptLine = 0x1E
    static let displayPipeInterruptLine = 0x2A
    static let clcdInterruptLine = 0x29
    /// Timebase ticks per frame: 24 MHz / 60 Hz.
    static let frameTicks: UInt64 = 400_000
    static let i2c2InterruptLine = 0x15
    private static let aliasBit: UInt32 = 0x8000_0000

    private unowned let cpu: ARMv7CPU
    private(set) var interruptController: PL192InterruptController!
    private(set) var timer: S5L8930XTimer!
    let powerManager = S5L8930XPowerManager()
    /// Fires when iOS shuts down or restarts.
    let watchdog = S5L8930XWatchdog()
    let iop = S5L8930XIOP()
    let swi = S5L8930XSWI()
    private(set) var cdma: S5L8930XCDMA!
    private(set) var i2c0: S5L8930XI2C!
    private(set) var i2c2: S5L8930XI2C!
    let pmu = D1815PMU()
    let audioCodec = CS42L59Codec()
    let i2s0 = S5L8930XI2S()
    /// The display IOMMU (`dart2`), which scanout translates through.
    let dart2 = S5L8930XDART()
    private(set) var displayPipe: S5L8930XDisplayPipe!
    private(set) var clcd: S5L8930XCLCD!
    /// The MIPI DSI link to the panel.
    let dsim = S5L8930XDSIM()
    /// Buttons and the touch controller's interrupt line.
    private(set) var gpio: S5L8930XGPIO!
    /// The bus the touchscreen controller is on.
    private(set) var spi1: S5L8930XSPI!
    let touch = MultitouchN1()
    private var nextFrameTick: UInt64 = frameTicks

    init(cpu: ARMv7CPU) {
        self.cpu = cpu
        interruptController = PL192InterruptController { [unowned cpu] irq, fiq in
            cpu.irqAsserted = irq
            cpu.fiqAsserted = fiq
        }
        timer = S5L8930XTimer(
            currentTick: { [unowned cpu] in cpu.virtualTime / Self.instructionsPerTimebaseTick },
            deadlineChanged: { [unowned self] in self.rescheduleNextEvent() },
            setInterruptLine: { [unowned self] asserted in
                self.interruptController.setLine(S5L8930XTimer.interruptLine, asserted: asserted)
            }
        )
        cdma = S5L8930XCDMA(
            memory: { [unowned cpu] in cpu.memory },
            setInterruptLine: { [unowned self] line, asserted in
                self.interruptController.setLine(line, asserted: asserted)
            }
        )
        i2c0 = S5L8930XI2C { [unowned self] asserted in
            self.interruptController.setLine(Self.i2c0InterruptLine, asserted: asserted)
        }
        i2c2 = S5L8930XI2C { [unowned self] asserted in
            self.interruptController.setLine(Self.i2c2InterruptLine, asserted: asserted)
        }
        i2c0.attach(pmu, at: D1815PMU.address)
        i2c0.attach(audioCodec, at: CS42L59Codec.address)
        displayPipe = S5L8930XDisplayPipe { [unowned self] asserted in
            self.interruptController.setLine(Self.displayPipeInterruptLine, asserted: asserted)
        }
        clcd = S5L8930XCLCD { [unowned self] asserted in
            self.interruptController.setLine(Self.clcdInterruptLine, asserted: asserted)
        }
        gpio = S5L8930XGPIO { [unowned self] asserted in
            self.interruptController.setLine(Self.gpioInterruptLine, asserted: asserted)
        }
        spi1 = S5L8930XSPI { [unowned self] asserted in
            self.interruptController.setLine(Self.spi1InterruptLine, asserted: asserted)
        }
        spi1.slave = touch
        cdma.attach(spi1, dataRegister: Self.spi1Base + S5L8930XSPI.transmitData)
        cdma.attach(spi1, dataRegister: Self.spi1Base + S5L8930XSPI.receiveData)
        spi1.dmaRequest = { [unowned self] in self.cdma.pumpPeripherals() }
        touch.setAttention = { [unowned self] asserted in
            self.gpio.setInputLevel(!asserted, pin: S5L8930XGPIO.Pin.touchInterrupt)
        }
        gpio.onOutputChanged = { [unowned self] pin, level in
            // The touch controller's chip select is active low; its reset
            // line puts it back in its bootloader.
            if pin == MultitouchN1.chipSelectPin { self.touch.chipSelectChanged(!level) }
            if pin == MultitouchN1.resetPin { self.touch.reset() }
        }
        cpu.deviceEventHandler = self
        rescheduleNextEvent()
    }

    /// The MMIO regions to put on the bus — ahead of the generic
    /// peripheral backing for the same addresses (`SegmentedMemoryBus`
    /// hands each access to the first region that accepts it).
    var regions: [MemoryBus] {
        // Order matters: the timer sits inside the PMGR window, so its
        // region must come first to claim its own registers.
        let windows: [(MMIODevice, UInt32, UInt32)] = [
            (timer, Self.pmgrBase + S5L8930XTimer.windowOffsetInPMGR, S5L8930XTimer.windowLength),
            (watchdog, Self.pmgrBase + S5L8930XWatchdog.windowOffsetInPMGR, S5L8930XWatchdog.windowLength),
            (powerManager, Self.pmgrBase, S5L8930XPowerManager.windowLength),
            (interruptController, Self.vicBase, PL192InterruptController.windowLength),
            (iop, Self.iopBase, S5L8930XIOP.windowLength),
            (swi, Self.swiBase, S5L8930XSWI.windowLength),
            (cdma, S5L8930XCDMA.channelsBase, S5L8930XCDMA.channelsLength),
            (cdma.aes, S5L8930XCDMA.aesBase, S5L8930XCDMA.aesLength),
            (i2c0, Self.i2c0Base, S5L8930XI2C.windowLength),
            (i2c2, Self.i2c2Base, S5L8930XI2C.windowLength),
            (i2s0, Self.i2s0Base, S5L8930XI2S.windowLength),
            (dart2, Self.dart2Base, S5L8930XDART.windowLength),
            (displayPipe, Self.displayPipeBase, S5L8930XDisplayPipe.windowLength),
            (clcd, Self.clcdBase, S5L8930XCLCD.windowLength),
            (dsim, Self.dsimBase, S5L8930XDSIM.windowLength),
            (gpio, Self.gpioBase, S5L8930XGPIO.windowLength),
            (spi1, Self.spi1Base, S5L8930XSPI.windowLength),
        ]
        return windows.flatMap { device, base, length in
            [base, base | Self.aliasBit].map { MMIORegion(device: device, baseAddress: $0, length: length) }
        }
    }

    /// Delivers user input to the hardware it belongs to. The buttons are
    /// active low: pressing one pulls its pin to 0.
    func handle(_ event: InputEvent) {
        switch event {
        case .homeButton(let pressed): gpio.setInputLevel(!pressed, pin: S5L8930XGPIO.Pin.menu)
        case .powerButton(let pressed): gpio.setInputLevel(!pressed, pin: S5L8930XGPIO.Pin.hold)
        case .volumeUp(let pressed): gpio.setInputLevel(!pressed, pin: S5L8930XGPIO.Pin.volumeUp)
        case .volumeDown(let pressed): gpio.setInputLevel(!pressed, pin: S5L8930XGPIO.Pin.volumeDown)
        case .touchBegan(let point): touch(.began, point)
        case .touchMoved(let point): touch(.moved, point)
        case .touchEnded(let point): touch(.ended, point)
        }
    }

    /// The guest's clock in milliseconds (the timebase runs at 24 MHz).
    private var milliseconds: UInt32 {
        UInt32(truncatingIfNeeded: cpu.virtualTime / Self.instructionsPerTimebaseTick / 24_000)
    }

    private func touch(_ phase: MultitouchN1.Phase, _ point: TouchPoint) {
        touch.touch(phase, x: point.x / Double(GuestMemoryLayout.framebufferWidth), y: point.y / Double(GuestMemoryLayout.framebufferHeight),
                    time: milliseconds)
    }

    func deviceEventDue(at virtualTime: UInt64) {
        let tick = virtualTime / Self.instructionsPerTimebaseTick
        timer.advance(toTick: tick)
        if tick >= nextFrameTick {
            displayPipe.frameEnded()
            clcd.frameEnded()
            touch.scan(time: milliseconds)
            nextFrameTick = (tick / Self.frameTicks + 1) * Self.frameTicks
        }
        rescheduleNextEvent()
    }

    private func rescheduleNextEvent() {
        cpu.nextDeviceEventAt = min(timer.eventDeadlineTick ?? .max, nextFrameTick) &* Self.instructionsPerTimebaseTick
    }
}
