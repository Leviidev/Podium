import SwiftUI

/// Shows the reference firmware's real download progress — never a fake
/// progress bar. Renders nothing while `phase` is `.idle` or `.completed`,
/// so callers can drop this in unconditionally above their normal content.
struct FirmwareDownloadBanner: View {
    let phase: FirmwareDownloadPhase
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch phase {
        case .idle, .completed:
            EmptyView()

        case .checkingAvailability:
            statusCard {
                ProgressView()
                    .controlSize(.small)
                Text("Looking up iOS \(ReferenceFirmware.productVersion)…")
                    .font(.subheadline)
            }

        case .downloading(let written, let total):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Downloading iOS \(ReferenceFirmware.productVersion)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(.caption)
                }
                ProgressView(value: total > 0 ? Double(written) / Double(total) : 0)
                Text(total > 0 ? "\(written.formattedByteCount) of \(total.formattedByteCount)" : written.formattedByteCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(PodiumMetrics.screenPadding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: PodiumMetrics.cardCornerRadius, style: .continuous))

        case .verifying:
            statusCard {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying download…")
                    .font(.subheadline)
            }

        case .importing:
            statusCard {
                ProgressView()
                    .controlSize(.small)
                Text("Importing…")
                    .font(.subheadline)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .font(.subheadline.weight(.medium))
            }
            .padding(PodiumMetrics.screenPadding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: PodiumMetrics.cardCornerRadius, style: .continuous))
        }
    }

    private func statusCard(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(PodiumMetrics.screenPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: PodiumMetrics.cardCornerRadius, style: .continuous))
    }
}
