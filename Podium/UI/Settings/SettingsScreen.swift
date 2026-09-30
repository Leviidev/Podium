import SwiftUI

struct SettingsScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(EmulatorCore.self) private var emulatorCore

    @State private var guestStorage: PersistentGuestStorage.Snapshot?
    @State private var storageError: String?
    @State private var showingEraseConfirmation = false
    @State private var isErasingGuest = false

    @AppStorage(AppStorageKeys.appearance) private var appearanceRawValue = AppearanceOption.system.rawValue
    @AppStorage(AppStorageKeys.confirmBeforeDeletingFirmware) private var confirmBeforeDeleting = true
    @AppStorage(AppStorageKeys.showFrameRate) private var showFrameRate = false
    @AppStorage(AppStorageKeys.showDeveloperSettings) private var showDeveloperSettings = false

    private func refreshGuestStorage() {
        do {
            guestStorage = try firmwareLibrary.persistentGuestStorage.snapshot()
            storageError = nil
        } catch {
            guestStorage = nil
            storageError = error.localizedDescription
        }
    }

    private func eraseGuestStorage() {
        guard let firmware = firmwareLibrary.activeFirmware else { return }
        isErasingGuest = true
        defer { isErasingGuest = false }
        do {
            _ = try firmwareLibrary.persistentGuestStorage.eraseActiveVolume(
                for: firmwareLibrary.fileURL(for: firmware),
                emulatorIsBusy: emulatorCore.isBusy
            )
            refreshGuestStorage()
        } catch {
            storageError = error.localizedDescription
        }
    }

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
                if let guestStorage {
                    LabeledContent("Used", value: Int64(clamping: guestStorage.usedBytes).formattedByteCount)
                    LabeledContent("Available", value: Int64(clamping: guestStorage.freeBytes).formattedByteCount)
                    LabeledContent("Total", value: Int64(clamping: guestStorage.totalBytes).formattedByteCount)
                } else {
                    LabeledContent("Status") {
                        Text("Not prepared yet").foregroundStyle(.secondary)
                    }
                }
                Button("Erase Virtual iPod…", role: .destructive) {
                    showingEraseConfirmation = true
                }
                .disabled(emulatorCore.isBusy || isErasingGuest || firmwareLibrary.activeFirmware?.compatibility.isCompatible != true)
            } header: {
                Text("Virtual iPod Storage")
            } footer: {
                Text("Apps, tweaks, settings, and their data are kept in a private disk image on this device, not in the imported firmware file.")
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
        .task { refreshGuestStorage() }
        .confirmationDialog("Erase all virtual iPod data?", isPresented: $showingEraseConfirmation, titleVisibility: .visible) {
            Button("Erase Virtual iPod", role: .destructive) { eraseGuestStorage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes installed apps, tweaks, preferences, and guest files. The firmware image remains installed.")
        }
        .alert("Virtual iPod Storage", isPresented: Binding(get: { storageError != nil }, set: { if !$0 { storageError = nil } })) {
            Button("OK", role: .cancel) { storageError = nil }
        } message: {
            Text(storageError ?? "")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
    .environment(FirmwareLibrary())
    .environment(EmulatorCore())
}
