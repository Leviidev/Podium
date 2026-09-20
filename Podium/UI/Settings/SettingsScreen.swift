import SwiftUI

struct SettingsScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary

    @AppStorage(AppStorageKeys.appearance) private var appearanceRawValue = AppearanceOption.system.rawValue
    @AppStorage(AppStorageKeys.confirmBeforeDeletingFirmware) private var confirmBeforeDeleting = true
    @AppStorage(AppStorageKeys.showFrameRate) private var showFrameRate = false
    @AppStorage(AppStorageKeys.showDeveloperSettings) private var showDeveloperSettings = false

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRawValue) ?? .system },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    private var defaultFirmwareSelection: Binding<UUID?> {
        Binding(
            get: { firmwareLibrary.activeFirmware?.id },
            set: { newValue in
                guard let newValue,
                      let firmware = firmwareLibrary.firmwares.first(where: { $0.id == newValue }) else { return }
                firmwareLibrary.setActive(firmware)
            }
        )
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: appearance) {
                    ForEach(AppearanceOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                if firmwareLibrary.firmwares.isEmpty {
                    LabeledContent("Default Firmware") {
                        Text("None Imported").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Default Firmware", selection: defaultFirmwareSelection) {
                        ForEach(firmwareLibrary.firmwares) { firmware in
                            Text("iOS \(firmware.metadata.productVersion) — \(firmware.displayName)")
                                .tag(firmware.id as UUID?)
                        }
                    }
                }

                Toggle("Confirm Before Deleting Firmware", isOn: $confirmBeforeDeleting)
            }

            Section {
                Toggle("Show Frame Rate", isOn: $showFrameRate)
                LabeledContent("Performance") {
                    Text("Not yet configurable").foregroundStyle(.secondary)
                }
                LabeledContent("Audio") {
                    Text("Not yet available").foregroundStyle(.secondary)
                }
                LabeledContent("Input") {
                    Text("Not yet available").foregroundStyle(.secondary)
                }
                LabeledContent("Save-State Location") {
                    Text("Not yet available").foregroundStyle(.secondary)
                }
            } header: {
                Text("Emulator")
            } footer: {
                Text("These become configurable as emulator hardware support is implemented.")
            }

            Section {
                Toggle("Show Developer Settings", isOn: $showDeveloperSettings)
                if showDeveloperSettings {
                    NavigationLink("Developer") {
                        DeveloperSettingsScreen()
                    }
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Hidden by default — intended for debugging Podium itself, not for everyday use.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
    .environment(FirmwareLibrary())
}
