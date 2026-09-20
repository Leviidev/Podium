import os

/// Central place to obtain subsystem loggers so log categories stay
/// consistent across modules instead of ad-hoc string literals.
enum PodiumLog {
    private static let subsystem = "com.leviidev.podium"

    static let firmware = Logger(subsystem: subsystem, category: "firmware")
    static let emulator = Logger(subsystem: subsystem, category: "emulator")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
