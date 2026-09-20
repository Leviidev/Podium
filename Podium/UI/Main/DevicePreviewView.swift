import SwiftUI

/// A simple, recognizable iPod touch 4 silhouette drawn with plain
/// SwiftUI shapes — no image asset, no decorative gradients. The screen
/// is always drawn off/black: this is a device representation, not a
/// live framebuffer, and should never be mistaken for one.
struct DevicePreviewView: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let cornerRadius = width * 0.14
            let bezel = width * 0.045
            let homeButtonDiameter = width * 0.12
            let cameraDiameter = width * 0.018

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color(.systemGray3), lineWidth: 1)
                    )

                VStack(spacing: 0) {
                    Circle()
                        .fill(Color(.systemGray3))
                        .frame(width: cameraDiameter, height: cameraDiameter)
                        .padding(.top, bezel * 1.4)

                    RoundedRectangle(cornerRadius: cornerRadius * 0.35, style: .continuous)
                        .fill(Color.black)
                        .padding(.top, bezel)
                        .padding(.horizontal, bezel)
                        .frame(maxHeight: .infinity)

                    Circle()
                        .strokeBorder(Color(.systemGray3), lineWidth: 1.5)
                        .frame(width: homeButtonDiameter, height: homeButtonDiameter)
                        .padding(.top, bezel * 0.6)
                        .padding(.bottom, bezel * 1.2)
                }
            }
        }
        .aspectRatio(640.0 / 960.0, contentMode: .fit)
        .accessibilityLabel("iPod touch preview")
    }
}

#Preview {
    DevicePreviewView()
        .frame(width: 220)
        .padding()
}
