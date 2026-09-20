import SwiftUI

/// A plain-language error presentation with technical detail tucked
/// behind a "Details" disclosure, per the project's error-handling
/// philosophy: the main experience stays friendly, detail is available
/// but never forced on the reader.
struct FriendlyErrorView: View {
    let userMessage: String
    let developerDetail: String
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)

                Text(userMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PodiumMetrics.screenPadding)

                if !developerDetail.isEmpty {
                    DisclosureGroup("Details") {
                        Text(developerDetail)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, PodiumMetrics.screenPadding)
                }

                Spacer()
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
