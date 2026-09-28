import SwiftUI

/// The device's physical buttons, laid out as a slim bar rather than
/// permanently overlaid on the display (Section 12 of the project spec).
/// Each button reports its own press and release, so holding one — the
/// sleep/wake button, to reach "slide to power off" — reaches the guest
/// as a real hold.
struct EmulatorControlBar: View {
    let onEvent: (InputEvent) -> Void

    var body: some View {
        HStack(spacing: 40) {
            HoldableButton(systemImage: "power", accessibilityLabel: "Sleep/Wake") { onEvent(.powerButton(pressed: $0)) }
            HoldableButton(systemImage: "speaker.minus", accessibilityLabel: "Volume Down") { onEvent(.volumeDown(pressed: $0)) }
            HoldableButton(systemImage: "circle", accessibilityLabel: "Home") { onEvent(.homeButton(pressed: $0)) }
            HoldableButton(systemImage: "speaker.plus", accessibilityLabel: "Volume Up") { onEvent(.volumeUp(pressed: $0)) }
        }
        .font(.title2)
        .foregroundStyle(.primary)
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
