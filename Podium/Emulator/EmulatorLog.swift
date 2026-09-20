import Foundation

/// One line of the emulator's activity log, shown in Developer Settings.
/// This is a real (if currently sparse) log, not sample/placeholder text —
/// every entry corresponds to something that actually happened.
struct EmulatorLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let message: String

    var formattedTime: String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
