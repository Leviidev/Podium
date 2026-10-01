import SwiftUI

/// The virtual device's physical controls. Taps and holds are reported as
/// separate press/release events so the guest sees the real button state.
struct EmulatorControlBar: View {
    let onEvent: (InputEvent) -> Void

    var body: some View {
        HStack(spacing: 0) {
            HoldableButton(systemImage: "power", accessibilityLabel: "Sleep/Wake") { onEvent(.powerButton(pressed: $0)) }
            HoldableButton(systemImage: "speaker.minus", accessibilityLabel: "Volume Down") { onEvent(.volumeDown(pressed: $0)) }
            HoldableButton(systemImage: "house.fill", accessibilityLabel: "Home") { onEvent(.homeButton(pressed: $0)) }
            HoldableButton(systemImage: "speaker.plus", accessibilityLabel: "Volume Up") { onEvent(.volumeUp(pressed: $0)) }
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.primary)
        .frame(maxWidth: 360)
    }
}

/// A native button whose entire equal-width cell is tappable.
private struct HoldableButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let onChange: (Bool) -> Void

    var body: some View {
        Button(action: {}) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoldableButtonStyle(onChange: onChange))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction {
            onChange(true)
            onChange(false)
        }
    }
}

/// ButtonStyle exposes the platform's own down/up/cancel tracking, avoiding
/// the narrow, independently-recognized drag gestures used by the old bar.
private struct HoldableButtonStyle: ButtonStyle {
    let onChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .background {
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06))
                    .frame(width: 48, height: 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: configuration.isPressed) { _, isPressed in
                onChange(isPressed)
            }
    }
}
