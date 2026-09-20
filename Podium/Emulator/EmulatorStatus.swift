import Foundation

/// The emulator's actual state. Every case here must correspond to
/// something Podium is really doing — there is no "fake progress" case.
enum EmulatorStatus: Equatable {
    /// No CPU core is implemented yet. This is Podium's honest starting
    /// state, and where it stays until Milestone 3/4 land.
    case notImplemented
    case ready
    case booting
    case running
    case paused
    case stopped
    case error(String)

    var label: String {
        switch self {
        case .notImplemented: return "Emulator core not implemented"
        case .ready: return "Ready"
        case .booting: return "Booting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .error(let message): return message
        }
    }

    /// Whether this status reflects real guest execution, as opposed to
    /// an idle/unavailable state. Used to decide whether it's honest to
    /// show a live framebuffer view at all.
    var isActive: Bool {
        switch self {
        case .booting, .running, .paused: return true
        case .notImplemented, .ready, .stopped, .error: return false
        }
    }
}
