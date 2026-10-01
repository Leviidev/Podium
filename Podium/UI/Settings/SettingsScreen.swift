import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(EmulatorCore.self) private var emulatorCore

    @State private var guestStorage: PersistentGuestStorage.Snapshot?
    @State private var storageError: String?
    @State private var showingEraseConfirmation = false
    @State private var isErasingGuest = false
    @State private var isImportingGuestFiles = false
    @State private var isImportingPackages = false
    @State private var isImportingIPAs = false
    @State private var isInstallingPackages = false
    @State private var isInstallingIPAs = false
    @State private var guestFileError: String?
    @State private var guestFileStatus: String?

    @AppStorage(AppStorageKeys.appearance) private var appearanceRawValue = AppearanceOption.dark.rawValue
    @AppStorage(AppStorageKeys.confirmBeforeDeletingFirmware) private var confirmBeforeDeleting = true
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

    private func installPackages(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isInstallingPackages = true
            defer { isInstallingPackages = false }
            let accessStates = urls.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (url, accessed) in zip(urls, accessStates) where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let packages = try firmwareLibrary.persistentGuestStorage.installDebianPackages(
                urls,
                forFirmwareAt: firmwareLibrary.activeFirmware.map { firmwareLibrary.fileURL(for: $0) },
                emulatorIsBusy: emulatorCore.isBusy
            )
            guestFileStatus = "Installed \(packages.count) offline Debian package\(packages.count == 1 ? "" : "s"). Restart iOS to load any installed system components."
            refreshGuestStorage()
        } catch {
            guestFileError = error.localizedDescription
        }
    }

    private func installIPAs(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isInstallingIPAs = true
            defer { isInstallingIPAs = false }
            let accessStates = urls.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (url, accessed) in zip(urls, accessStates) where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let apps = try firmwareLibrary.persistentGuestStorage.installIPAs(
                urls,
                forFirmwareAt: firmwareLibrary.activeFirmware.map { firmwareLibrary.fileURL(for: $0) },
                emulatorIsBusy: emulatorCore.isBusy
            )
            guestFileStatus = "Copied \(apps.count) app bundle\(apps.count == 1 ? "" : "s") into /Applications. Apps aren't signed, registered, or launched by this basic installer."
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
            get: { AppearanceOption(rawValue: appearanceRawValue) ?? .dark },
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsCard("General", systemImage: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Appearance")
                                .font(.subheadline.weight(.medium))
                            Picker("Appearance", selection: appearance) {
                                ForEach(AppearanceOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        cardDivider

                        if firmwareLibrary.firmwares.isEmpty {
                            NavigationLink {
                                FirmwareScreen()
                            } label: {
                                settingsLinkRow("Firmware", detail: "Import a compatible iOS image", systemImage: "shippingbox")
                            }
                            .buttonStyle(.plain)
                        } else {
                            Picker(selection: defaultFirmwareSelection) {
                                ForEach(firmwareLibrary.firmwares) { firmware in
                                    Text("iOS \(firmware.metadata.productVersion) — \(firmware.displayName)")
                                        .tag(firmware.id as UUID?)
                                }
                            } label: {
                                settingsLinkRow("Active Firmware", detail: firmwareLibrary.activeFirmware.map { "iOS \($0.metadata.productVersion) · \($0.displayName)" } ?? "Select firmware", systemImage: "shippingbox")
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                        }

                        cardDivider

                        Toggle(isOn: $confirmBeforeDeleting) {
                            Label("Confirm Before Deleting", systemImage: "trash")
                                .font(.subheadline)
                        }
                        .tint(.blue)
                    }
                }

                settingsCard("Virtual iPod", systemImage: "ipod") {
                    VStack(alignment: .leading, spacing: 15) {
                        if let guestStorage {
                            HStack(alignment: .top, spacing: 0) {
                                storageMetric("\(Int64(clamping: guestStorage.usedBytes).formattedByteCount)", label: "USED")
                                storageMetric("\(Int64(clamping: guestStorage.freeBytes).formattedByteCount)", label: "FREE")
                                storageMetric("\(Int64(clamping: guestStorage.totalBytes).formattedByteCount)", label: "TOTAL")
                            }
                            .padding(.vertical, 3)
                        } else {
                            Label("Storage is prepared the first time you launch the virtual iPod.", systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        cardDivider

                        actionRow("Install IPA Apps", detail: "Add .ipa apps to /Applications", systemImage: "app.badge.plus",
                                  isDisabled: !canModifyGuestStorage || isInstallingIPAs) {
                            isImportingIPAs = true
                        }
                        cardDivider
                        actionRow("Add Files", detail: "Copy files into the guest media folder", systemImage: "folder.badge.plus",
                                  isDisabled: !canModifyGuestStorage || isInstallingPackages) {
                            isImportingGuestFiles = true
                        }
                        cardDivider
                        actionRow("Offline Packages", detail: "Install supported Debian .deb files", systemImage: "shippingbox",
                                  isDisabled: !canModifyGuestStorage || isInstallingPackages || isInstallingIPAs) {
                            isImportingPackages = true
                        }

                        if isInstallingIPAs || isInstallingPackages {
                            cardDivider
                            HStack(spacing: 9) {
                                ProgressView()
                                Text(isInstallingIPAs ? "Installing apps…" : "Installing packages…")
                                    .font(.footnote.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        if let guestFileStatus {
                            Text(guestFileStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if emulatorCore.isBusy {
                            Text("Power off the virtual iPod before changing guest storage.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        cardDivider
                        Button(role: .destructive) {
                            showingEraseConfirmation = true
                        } label: {
                            Label("Erase Virtual iPod Data", systemImage: "trash")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .disabled(emulatorCore.isBusy || isErasingGuest || firmwareLibrary.activeFirmware?.compatibility.isCompatible != true)
                    }
                }

                settingsCard("Emulator", systemImage: "gamecontroller") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Touchscreen, Home, volume, and power controls are available when the iPod is open.", systemImage: "hand.tap")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let firmware = firmwareLibrary.activeFirmware {
                            cardDivider
                            HStack {
                                Text("Device")
                                Spacer()
                                Text("\(firmware.displayName) · iOS \(firmware.metadata.productVersion)")
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.caption)
                        }
                    }
                }

                settingsCard("Advanced", systemImage: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 13) {
                        Toggle(isOn: $showDeveloperSettings) {
                            Label("Show Developer Settings", systemImage: "ladybug")
                                .font(.subheadline)
                        }
                        .tint(.blue)
                        if showDeveloperSettings {
                            cardDivider
                            NavigationLink {
                                DeveloperSettingsScreen()
                            } label: {
                                settingsLinkRow("Developer Console", detail: "CPU state and emulator logs", systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshGuestStorage() }
        .onChange(of: firmwareLibrary.activeFirmware?.id) { refreshGuestStorage() }
        .fileImporter(isPresented: $isImportingGuestFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addGuestFiles(result)
        }
        .fileImporter(isPresented: $isImportingPackages, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            installPackages(result)
        }
        .fileImporter(isPresented: $isImportingIPAs, allowedContentTypes: [.ipa], allowsMultipleSelection: true) { result in
            installIPAs(result)
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

    private var canModifyGuestStorage: Bool {
        !emulatorCore.isBusy && !isErasingGuest && !isInstallingPackages && !isInstallingIPAs
            && guestStorage != nil && firmwareLibrary.activeFirmware?.compatibility.isCompatible == true
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private func settingsCard<Content: View>(_ title: String, systemImage: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func storageMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsLinkRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func actionRow(_ title: String, detail: String, systemImage: String, isDisabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsLinkRow(title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
    .environment(FirmwareLibrary())
    .environment(EmulatorCore())
}
