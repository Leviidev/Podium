import Foundation

/// Guest-visible hardware timers (the A4's timer peripherals the kernel
/// depends on for scheduling and timekeeping).
///
/// No implementation exists yet.
protocol TimerController: AnyObject {
    /// Advances timer state by `cycles` CPU cycles, firing any interrupts
    /// whose deadlines have passed.
    func tick(cycles: UInt64)
    func reset()
}
