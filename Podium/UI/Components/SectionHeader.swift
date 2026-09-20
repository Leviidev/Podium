import SwiftUI

/// A small caps section label for custom (non-`List`) layouts, matching
/// the style system `Section` headers already use in lists/forms.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}
