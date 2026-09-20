import SwiftUI

/// The device's physical controls, laid out as a slim bar rather than
/// permanently overlaid on the display (Section 12 of the project spec).
struct EmulatorControlBar: View {
    let onEvent: (InputEvent) -> Void

    var body: some View {
        HStack(spacing: 40) {
            iconButton("power", accessibilityLabel: "Power") {
                onEvent(.powerButton(pressed: true))
            }
            iconButton("speaker.minus", accessibilityLabel: "Volume Down") {
                onEvent(.volumeDown(pressed: true))
            }
            iconButton("circle", accessibilityLabel: "Home") {
                onEvent(.homeButton(pressed: true))
            }
            iconButton("speaker.plus", accessibilityLabel: "Volume Up") {
                onEvent(.volumeUp(pressed: true))
            }
        }
        .font(.title2)
        .foregroundStyle(.primary)
    }

    private func iconButton(_ systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
