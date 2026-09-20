import Foundation

/// Routes hardware interrupt lines to the CPU, modeling the A4's
/// interrupt controller.
///
/// No implementation exists yet — raising/masking/servicing interrupts
/// only means something once a CPU exists to receive them.
protocol InterruptController: AnyObject {
    func raise(line: Int)
    func clear(line: Int)
    func setMasked(_ masked: Bool, line: Int)
}
