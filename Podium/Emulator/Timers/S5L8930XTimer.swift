import Foundation

/// The S5L8930X (A4) system timer, which lives inside the `pmgr` block at
/// `pmgr + 0x2000` (the device tree has no node of its own for it; the
/// watchdog right after it, at `+0x2020`, does). Register layout traced
/// from the real kernel rather than assumed:
///
/// - `0x00`/`0x04`: the 64-bit free-running counter, low/high word, at
///   the device tree's 24 MHz `timebase-frequency` — `mach_absolute_time`
///   reads high, low, high (retrying if the high word changed).
/// - `0x08`: a one-shot countdown. Writing N arms an interrupt N ticks
///   from now — the kernel's rtclock writes 240,000 (10 ms) to schedule
///   its next tick, and `0x7FFFFFFF` to push it out of the way. Reads
///   return the ticks remaining (0 once expired).
/// - `0x10`: control. Bit 0 enables the interrupt; bit 1 reads as
///   "expired" and is write-1-to-clear — the kernel's init writes 3 then
///   1 (clear any stale expiry, then enable).
///
/// The interrupt is VIC line 6, which the kernel routes as FIQ.
/// Registers in the window this doesn't model keep plain storage
/// semantics, same as before this device existed.
final class S5L8930XTimer: MMIODevice {
    static let windowOffsetInPMGR: UInt32 = 0x2000
    static let windowLength: UInt32 = 0x20
    static let interruptLine = 6

    private let currentTick: () -> UInt64
    private let deadlineChanged: () -> Void
    private let setInterruptLine: (Bool) -> Void

    private(set) var eventDeadlineTick: UInt64?
    private var interruptEnabled = false
    private var expired = false
    private var unmodeled = [UInt32](repeating: 0, count: Int(windowLength / 4))

    /// - Parameters:
    ///   - currentTick: the timebase counter's value right now.
    ///   - deadlineChanged: called whenever `eventDeadlineTick` changes,
    ///     so the platform can reschedule its next device event.
    ///   - setInterruptLine: drives this timer's interrupt controller input.
    init(currentTick: @escaping () -> UInt64, deadlineChanged: @escaping () -> Void, setInterruptLine: @escaping (Bool) -> Void) {
        self.currentTick = currentTick
        self.deadlineChanged = deadlineChanged
        self.setInterruptLine = setInterruptLine
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        let now = currentTick()
        switch offset {
        case 0x00:
            return UInt32(truncatingIfNeeded: now)
        case 0x04:
            return UInt32(truncatingIfNeeded: now >> 32)
        case 0x08:
            guard let deadline = eventDeadlineTick, deadline > now else { return 0 }
            return UInt32(clamping: deadline - now)
        case 0x10:
            return (interruptEnabled ? 1 : 0) | (expired ? 2 : 0)
        default:
            return unmodeled[Int(offset / 4)]
        }
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        switch offset {
        case 0x00, 0x04:
            break
        case 0x08:
            eventDeadlineTick = currentTick() &+ UInt64(value)
            deadlineChanged()
        case 0x10:
            interruptEnabled = value & 1 != 0
            if value & 2 != 0 { expired = false }
            updateInterruptLine()
        default:
            unmodeled[Int(offset / 4)] = value
        }
    }

    /// Called by the platform once time reaches `eventDeadlineTick`.
    func advance(toTick now: UInt64) {
        guard let deadline = eventDeadlineTick, now >= deadline else { return }
        eventDeadlineTick = nil
        expired = true
        updateInterruptLine()
        deadlineChanged()
    }

    private func updateInterruptLine() {
        setInterruptLine(expired && interruptEnabled)
    }
}
