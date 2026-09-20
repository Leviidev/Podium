import SwiftUI

struct MainScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(ReferenceFirmwareDownloader.self) private var downloader

    private var activeFirmware: ImportedFirmware? {
        firmwareLibrary.activeFirmware
    }

    private var canLaunch: Bool {
        activeFirmware?.compatibility.isCompatible ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PodiumMetrics.sectionSpacing) {
                    header

                    DevicePreviewView()
                        .frame(maxWidth: 260)
                        .padding(.vertical, 4)

                    FirmwareDownloadBanner(
                        phase: downloader.phase,
                        onCancel: { downloader.cancel() },
                        onRetry: { Task { await downloader.retry(into: firmwareLibrary) } }
                    )

                    launchButton

                    firmwareSummaryCard
                }
                .padding(PodiumMetrics.screenPadding)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Podium")
                .font(.largeTitle.weight(.semibold))
            Text(activeFirmware != nil ? "\(DeviceCatalog.iPodTouch4.shortName) · iOS \(activeFirmware!.metadata.productVersion)" : DeviceCatalog.iPodTouch4.shortName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var launchButton: some View {
        VStack(spacing: 8) {
            NavigationLink {
                EmulatorScreen()
            } label: {
                Label("Launch", systemImage: "play.fill")
            }
            .buttonStyle(.podiumPrimary(isDisabled: !canLaunch))
            .disabled(!canLaunch)

            if !canLaunch, !downloader.phase.isActive {
                Text(activeFirmware == nil ? "Import firmware to begin." : "Selected firmware isn't compatible yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var firmwareSummaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Firmware")

            Divider()

            if let firmware = activeFirmware {
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS \(firmware.metadata.productVersion)")
                        .font(.body.weight(.medium))
                    Text(firmware.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No firmware selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                FirmwareScreen()
            } label: {
                Text(activeFirmware == nil ? "Import Firmware" : "Manage Firmware")
                    .font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    MainScreen()
        .environment(FirmwareLibrary())
        .environment(ReferenceFirmwareDownloader())
}
