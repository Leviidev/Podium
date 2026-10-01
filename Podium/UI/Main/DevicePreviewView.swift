import SwiftUI

/// A clean, off-state iPod touch silhouette for the Home dashboard. The
/// screen remains black so the preview is never mistaken for the live guest.
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
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )

                VStack(spacing: 0) {
                    Circle()
                        .fill(Color(.systemGray2))
                        .frame(width: cameraDiameter, height: cameraDiameter)
                        .padding(.top, bezel * 1.4)

                    RoundedRectangle(cornerRadius: cornerRadius * 0.35, style: .continuous)
                        .fill(Color.black)
                        .padding(.top, bezel)
                        .padding(.horizontal, bezel)
                        .frame(maxHeight: .infinity)

                    Circle()
                        .fill(Color.black)
                        .frame(width: homeButtonDiameter, height: homeButtonDiameter)
                        .background(Color.white.opacity(0.04), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.72), lineWidth: 1.1)
                                .frame(width: homeButtonDiameter * 0.34, height: homeButtonDiameter * 0.34)
                        }
                        .padding(.top, bezel * 0.6)
                        .padding(.bottom, bezel * 1.2)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .aspectRatio(0.55, contentMode: .fit)
        .accessibilityLabel("iPod touch preview")
    }
}

#Preview {
    DevicePreviewView()
        .frame(width: 220)
        .padding()
}
