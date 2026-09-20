import SwiftUI

/// Shared spacing/corner-radius constants so screens don't accumulate
/// inconsistent magic numbers. Colors intentionally lean on system
/// materials/colors (`Color(.systemBackground)`, `.secondary`, the app's
/// `AccentColor` asset) rather than a custom palette, per the project's
/// "Apple-inspired, not Apple-copying" visual identity.
enum PodiumMetrics {
    static let screenPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 12
}
