import SwiftUI

/// What the virtual screen shows while the iPod is off or starting up:
/// black, like the real panel, with a progress bar and an estimate of how
/// long is left.
struct BootProgressView: View {
    let stage: EmulatorCore.BootStage?
    let instructionsPerSecond: Double

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(stage == nil ? 0.25 : 0.9))
                if let stage {
                    VStack(spacing: 10) {
                        ProgressView(value: fraction(of: stage))
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(maxWidth: 180)
                        Text(title(of: stage))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                        if let detail = detail(of: stage) {
                            Text(detail)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .multilineTextAlignment(.center)
                } else {
                    Text("Powered off")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(24)
        }
    }

    private func fraction(of stage: EmulatorCore.BootStage) -> Double {
        switch stage {
        case .preparingFilesystem(let phase, let fraction):
            // Extraction is the quicker half of the work.
            return phase == .extracting ? fraction * 0.4 : 0.4 + fraction * 0.6
        case .loadingKernel: return 0
        case .booting(let fraction, _): return fraction
        case .running: return 1
        }
    }

    private func title(of stage: EmulatorCore.BootStage) -> String {
        switch stage {
        case .preparingFilesystem: return "Preparing iOS for first launch…"
        case .loadingKernel: return "Loading the kernel…"
        case .booting(_, let remaining):
            guard let remaining else { return "Starting iOS…" }
            return "Starting iOS — \(Self.format(remaining)) left"
        case .running: return "Ready"
        }
    }

    private func detail(of stage: EmulatorCore.BootStage) -> String? {
        switch stage {
        case .preparingFilesystem(let phase, let fraction):
            let step = phase == .extracting ? "Extracting the root filesystem" : "Building the 8 GiB disk"
            return "\(step) · \(Int(fraction * 100))%"
        case .booting:
            guard instructionsPerSecond > 0 else { return nil }
            return String(format: "%.0f M instructions/s", instructionsPerSecond / 1_000_000)
        default:
            return nil
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 10 { return "a few seconds" }
        if total < 60 { return "about \(total) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "about \(minutes) min" : "about \(minutes) min \(rest) s"
    }
}
