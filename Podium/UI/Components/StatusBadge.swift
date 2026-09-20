import SwiftUI

/// A short, plain status indicator — icon plus text, colored, no pill or
/// card background. Used for firmware compatibility and emulator status.
struct StatusBadge: View {
    enum Tone {
        case positive
        case neutral
        case negative

        var color: Color {
            switch self {
            case .positive: return .green
            case .neutral: return .secondary
            case .negative: return .red
            }
        }
    }

    let text: String
    var systemImage: String? = nil
    let tone: Tone

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tone.color)
    }
}
