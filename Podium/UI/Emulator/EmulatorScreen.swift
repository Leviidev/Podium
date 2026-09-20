import SwiftUI

struct EmulatorScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(EmulatorCore.self) private var emulatorCore

    private var firmware: ImportedFirmware? {
        firmwareLibrary.activeFirmware
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            GeometryReader { proxy in
                PlaceholderFramebufferView(statusLabel: emulatorCore.status.label)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let point = devicePoint(from: value.location, in: proxy.size)
                                emulatorCore.sendInput(.touchBegan(point))
                                emulatorCore.sendInput(.touchEnded(point))
                            }
                    )
            }
            .aspectRatio(640.0 / 960.0, contentMode: .fit)
            .padding(.horizontal, 40)

            if let firmware {
                Text("\(firmware.displayName) · iOS \(firmware.metadata.productVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("No firmware selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            EmulatorControlBar { event in
                emulatorCore.sendInput(event)
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Podium").font(.headline)
                    Text(emulatorCore.status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Maps a tap location within the displayed framebuffer view to the
    /// virtual device's own 960×640 point coordinate space.
    private func devicePoint(from location: CGPoint, in size: CGSize) -> TouchPoint {
        guard size.width > 0, size.height > 0 else {
            return TouchPoint(x: 0, y: 0, touchID: 0)
        }
        let x = (location.x / size.width) * 640
        let y = (location.y / size.height) * 960
        return TouchPoint(x: x, y: y, touchID: 0)
    }
}

#Preview {
    NavigationStack {
        EmulatorScreen()
    }
    .environment(FirmwareLibrary())
    .environment(EmulatorCore())
}
