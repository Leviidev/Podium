import Foundation

/// Told by the CPU when `virtualTime` reaches `nextDeviceEventAt`.
protocol DeviceEventHandler: AnyObject {
    func deviceEventDue(at virtualTime: UInt64)
}

/// The A4 (S5L8930X) SoC hardware that has real behavior, as opposed to
/// the plain storage `DeviceTreeMemoryMap` backs every other peripheral
/// with: the system timer, the power manager and the interrupt
/// controller, wired to the CPU's IRQ/FIQ pins and to its virtual clock.
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
    private static let aliasBit: UInt32 = 0x8000_0000

    private unowned let cpu: ARMv7CPU
    private(set) var interruptController: PL192InterruptController!
    private(set) var timer: S5L8930XTimer!
    let powerManager = S5L8930XPowerManager()

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
        cpu.deviceEventHandler = self
    }

    /// The MMIO regions to put on the bus — ahead of the generic
    /// peripheral backing for the same addresses (`SegmentedMemoryBus`
    /// hands each access to the first region that accepts it).
    var regions: [MemoryBus] {
        // Order matters: the timer sits inside the PMGR window, so its
        // region must come first to claim its own registers.
        let windows: [(MMIODevice, UInt32, UInt32)] = [
            (timer, Self.pmgrBase + S5L8930XTimer.windowOffsetInPMGR, S5L8930XTimer.windowLength),
            (powerManager, Self.pmgrBase, S5L8930XPowerManager.windowLength),
            (interruptController, Self.vicBase, PL192InterruptController.windowLength),
        ]
        return windows.flatMap { device, base, length in
            [base, base | Self.aliasBit].map { MMIORegion(device: device, baseAddress: $0, length: length) }
        }
    }

    func deviceEventDue(at virtualTime: UInt64) {
        timer.advance(toTick: virtualTime / Self.instructionsPerTimebaseTick)
        rescheduleNextEvent()
    }

    private func rescheduleNextEvent() {
        cpu.nextDeviceEventAt = timer.eventDeadlineTick.map { $0 &* Self.instructionsPerTimebaseTick } ?? .max
    }
}
