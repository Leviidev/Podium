import Foundation

/// A CPU core Podium can drive.
///
/// No conforming implementation exists yet — this protocol exists so the
/// rest of the architecture (emulator core, UI, dependency injection) can
/// be built and tested against a stable contract before ARMv7 decode/
/// execute logic exists. `EmulatorCore` holds a `CPU?` and is fully
/// prepared to run without one; it just honestly reports that state.
///
/// The eventual ARMv7 implementation targets the Apple A4's ARMv7-A core:
/// ARM and Thumb instruction sets, banked registers, CPSR/SPSR, exception
/// entry/exit, and MMU-mediated memory access. It should be built as an
/// instruction decoder feeding a separate executor (not one large
/// switch-per-opcode class) so a future JIT can replace the interpreter
/// loop without redesigning instruction semantics.
protocol CPU: AnyObject {
    /// Resets architectural state (registers, mode, PC) to power-on
    /// values. Must be safe to call before the first `step()`/`run()`.
    func reset()

    /// Executes exactly one instruction.
    func step()

    /// Runs continuously until `stop()` is called or an unhandled
    /// exception occurs. Implementations must not block the caller's
    /// thread indefinitely without a way to interrupt — callers are
    /// expected to invoke this from a dedicated execution thread/actor,
    /// never from the main actor.
    func run()

    /// Halts a `run()` loop at the next safe instruction boundary.
    func stop()
}
