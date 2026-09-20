import SwiftUI

/// What `EmulatorScreen` shows today: an aspect-correct, honestly empty
/// display area. No frame is faked here — the label always reflects the
/// emulator's real `EmulatorStatus`, never a scripted "Booting…" sequence.
struct PlaceholderFramebufferView: View {
    let statusLabel: String

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.black)
            .aspectRatio(640.0 / 960.0, contentMode: .fit)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("960 × 640")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                    Text(statusLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
    }
}

#Preview {
    PlaceholderFramebufferView(statusLabel: EmulatorStatus.notImplemented.label)
        .padding()
}
