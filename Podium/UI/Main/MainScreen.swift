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
        ScrollView {
            VStack(spacing: 22) {
                header

                DevicePreviewView()
                    .frame(width: 150)
                    .padding(.top, 2)

                launchButton

                FirmwareDownloadBanner(
                    phase: downloader.phase,
                    onCancel: { downloader.cancel() },
                    onRetry: { Task { await downloader.retry(into: firmwareLibrary) } }
                )

                firmwareCard
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("PODIUM")
                .font(.caption.weight(.bold))
                .tracking(2.4)
                .foregroundStyle(.blue)
            Text(DeviceCatalog.iPodTouch4.marketingName)
                .font(.title2.weight(.semibold))
            Text(activeFirmware.map { "iOS \($0.metadata.productVersion)" } ?? "Your virtual iPod")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var launchButton: some View {
        VStack(spacing: 9) {
            NavigationLink {
                EmulatorScreen()
            } label: {
                Label("Launch iPod", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.podiumPrimary(isDisabled: !canLaunch))
            .disabled(!canLaunch)

            if !canLaunch, !downloader.phase.isActive {
                Text(activeFirmware == nil ? "Import compatible firmware to begin." : "The selected firmware is not compatible.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 330)
    }

    private var firmwareCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Firmware", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                if let firmware = activeFirmware {
                    StatusBadge(
                        text: firmware.compatibility.isCompatible ? "Ready" : firmware.compatibility.summary,
                        systemImage: firmware.compatibility.isCompatible ? "checkmark.circle.fill" : "exclamationmark.triangle",
                        tone: firmware.compatibility.isCompatible ? .positive : .negative
                    )
                    .font(.caption)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            if let firmware = activeFirmware {
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS \(firmware.metadata.productVersion) · Build \(firmware.metadata.buildVersion)")
                        .font(.subheadline.weight(.medium))
                    Text(firmware.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No firmware imported yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                FirmwareScreen()
            } label: {
                HStack {
                    Text(activeFirmware == nil ? "Import Firmware" : "Manage Firmware")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(17)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack {
        MainScreen()
    }
    .environment(FirmwareLibrary())
    .environment(ReferenceFirmwareDownloader())
}
