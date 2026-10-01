import SwiftUI

/// The virtual device's physical controls. Tap sends a complete button
/// press; a press-and-hold emits down/up so guest hold actions still work.
struct EmulatorControlBar: View {
    let onEvent: (InputEvent) -> Void

    var body: some View {
        HStack(spacing: 0) {
            HoldableButton(systemImage: "power", accessibilityLabel: "Sleep/Wake") { onEvent(.powerButton(pressed: $0)) }
            Spacer(minLength: 8)
            HoldableButton(systemImage: "speaker.minus", accessibilityLabel: "Volume Down") { onEvent(.volumeDown(pressed: $0)) }
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                Image(systemName: "circle")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                HoldableButton(systemImage: "circle", accessibilityLabel: "Home") { onEvent(.homeButton(pressed: $0)) }
            }
            Spacer(minLength: 8)
            HoldableButton(systemImage: "speaker.plus", accessibilityLabel: "Volume Up") { onEvent(.volumeUp(pressed: $0)) }
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.primary)
        .frame(maxWidth: 320)
    }
}

/// A button that reports touch-down and touch-up separately.
private struct HoldableButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let onChange: (Bool) -> Void
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .frame(width: 44, height: 44)
            .opacity(isPressed ? 0.4 : 1)
            .background(Color.primary.opacity(isPressed ? 0.14 : 0.06), in: Circle())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onChange(true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onChange(false)
                    }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onChange(true)
                onChange(false)
            }
    }
}
