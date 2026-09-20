import SwiftUI

/// Secondary, hidden-by-default screen (Section 13 of the project spec).
/// Everything here is either a real static fact or Podium's real,
/// currently-sparse activity log — never sample/placeholder data.
struct DeveloperSettingsScreen: View {
    @Environment(EmulatorCore.self) private var emulatorCore

    private static let targetRAMBytes: Int64 = 256 * 1024 * 1024

    var body: some View {
        List {
            Section("CPU") {
                LabeledContent("Target Architecture", value: "ARMv7 (Apple A4)")
                LabeledContent("Status", value: "Not implemented")
            }

            Section("Memory") {
                LabeledContent("Target RAM", value: Self.targetRAMBytes.formattedByteCount)
                LabeledContent("Status", value: "Not implemented")
            }

            Section("Boot Arguments") {
                Text("Not yet supported.")
                    .foregroundStyle(.secondary)
            }

            Section("Emulator Log") {
                if emulatorCore.log.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(emulatorCore.log.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.formattedTime)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DeveloperSettingsScreen()
    }
    .environment(EmulatorCore())
}
