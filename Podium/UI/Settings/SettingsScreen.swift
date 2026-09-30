import SwiftUI

struct SettingsScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(EmulatorCore.self) private var emulatorCore

    @State private var guestStorage: PersistentGuestStorage.Snapshot?
    @State private var storageError: String?
    @State private var showingEraseConfirmation = false
    @State private var isErasingGuest = false
    @State private var isImportingGuestFiles = false
    @State private var guestFileError: String?
    @State private var guestFileStatus: String?

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

    private func addGuestFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let accessStates = urls.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (url, accessed) in zip(urls, accessStates) where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try firmwareLibrary.persistentGuestStorage.addFiles(urls, emulatorIsBusy: emulatorCore.isBusy)
            let noun = urls.count == 1 ? "file" : "files"
            guestFileStatus = urls.isEmpty ? nil : "Added \(urls.count) \(noun) to Media/Podium."
            refreshGuestStorage()
        } catch {
            guestFileError = error.localizedDescription
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
                Button("Add Files to Virtual iPod…", systemImage: "doc.badge.plus") {
                    isImportingGuestFiles = true
                }
                .disabled(emulatorCore.isBusy || isErasingGuest || guestStorage == nil)
                if let guestFileStatus {
                    Text(guestFileStatus).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Erase Virtual iPod…", role: .destructive) {
                    showingEraseConfirmation = true
                }
                .disabled(emulatorCore.isBusy || isErasingGuest || firmwareLibrary.activeFirmware?.compatibility.isCompatible != true)
            } header: {
                Text("Virtual iPod Storage")
            } footer: {
                Text("Apps, tweaks, settings, and their data are kept in a private disk image. Add Files copies host files into /private/var/mobile/Media/Podium on the guest.")
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
        .fileImporter(isPresented: $isImportingGuestFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addGuestFiles(result)
        }
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
        .alert("Couldn't Add Files", isPresented: Binding(get: { guestFileError != nil }, set: { if !$0 { guestFileError = nil } })) {
            Button("OK", role: .cancel) { guestFileError = nil }
        } message: {
            Text(guestFileError ?? "")
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
