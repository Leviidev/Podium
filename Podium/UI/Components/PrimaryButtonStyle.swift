import SwiftUI

/// The app's one prominent call-to-action style (e.g. "Launch"): flat
/// accent fill, no gradient, no shadow.
struct PodiumPrimaryButtonStyle: ButtonStyle {
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isDisabled ? Color.secondary.opacity(0.35) : Color.accentColor,
                in: RoundedRectangle(cornerRadius: PodiumMetrics.controlCornerRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == PodiumPrimaryButtonStyle {
    static var podiumPrimary: PodiumPrimaryButtonStyle { PodiumPrimaryButtonStyle() }
    static func podiumPrimary(isDisabled: Bool) -> PodiumPrimaryButtonStyle {
        PodiumPrimaryButtonStyle(isDisabled: isDisabled)
    }
}
