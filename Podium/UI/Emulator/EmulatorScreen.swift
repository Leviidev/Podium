import SwiftUI

struct EmulatorScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(EmulatorCore.self) private var emulatorCore
    @State private var touchActive = false

    private var firmware: ImportedFirmware? {
        firmwareLibrary.activeFirmware
    }

    /// The live display once iOS has reached its lock screen; until then
    /// the boot screen, with its progress bar.
    @ViewBuilder
    private var screen: some View {
        if emulatorCore.bootStage == .running, let source = emulatorCore.framebufferSource {
            GuestFramebufferView(source: source)
        } else {
            BootProgressView(stage: emulatorCore.bootStage, instructionsPerSecond: emulatorCore.instructionsPerSecond)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            GeometryReader { proxy in
                screen
                    .contentShape(Rectangle())
                    .gesture(touchGesture(in: proxy.size))
            }
            .aspectRatio(640.0 / 960.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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

            if case .error(let message) = emulatorCore.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if !emulatorCore.isPoweredOn, emulatorCore.bootStage == nil,
               !emulatorCore.isBusy, let firmware, firmware.compatibility.isCompatible {
                Button("Power On") { powerOn(firmware) }
                    .buttonStyle(.podiumPrimary)
                    .padding(.horizontal, 40)
            }
            if emulatorCore.hasStorageFlushFailure {
                Button("Retry Storage Flush", systemImage: "arrow.clockwise") {
                    emulatorCore.retryStorageFlush()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal, 40)
            }

            Spacer()

            EmulatorControlBar { event in
                if case .powerButton(pressed: true) = event, !emulatorCore.isPoweredOn, emulatorCore.bootStage == nil, let firmware {
                    powerOn(firmware)
                } else {
                    emulatorCore.sendInput(event)
                }
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
            if emulatorCore.isPoweredOn || emulatorCore.storageFlushFailure != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        emulatorCore.powerOff()
                    } label: {
                        Label(emulatorCore.isPoweredOn ? "Power Off" : "Retry Power Off", systemImage: "power.circle")
                    }
                }
            }
        }
    }

    private func powerOn(_ firmware: ImportedFirmware) {
        Task {
            await emulatorCore.powerOn(firmware: firmware, storedAt: firmwareLibrary.fileURL(for: firmware))
        }
    }

    /// One finger on the virtual touchscreen: down, moves, up.
    private func touchGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = devicePoint(from: value.location, in: size)
                if touchActive {
                    emulatorCore.sendInput(.touchMoved(point))
                } else {
                    touchActive = true
                    emulatorCore.sendInput(.touchBegan(point))
                }
            }
            .onEnded { value in
                touchActive = false
                emulatorCore.sendInput(.touchEnded(devicePoint(from: value.location, in: size)))
            }
    }

    /// Maps a location in the displayed screen to the device's own
    /// 640×960 pixel coordinates.
    private func devicePoint(from location: CGPoint, in size: CGSize) -> TouchPoint {
        guard size.width > 0, size.height > 0 else {
            return TouchPoint(x: 0, y: 0, touchID: 0)
        }
        let x = min(max(location.x / size.width, 0), 1) * 640
        let y = min(max(location.y / size.height, 0), 1) * 960
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
