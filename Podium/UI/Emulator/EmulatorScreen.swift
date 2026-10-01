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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                GeometryReader { displayProxy in
                    let displayHeight = min(displayProxy.size.height, displayProxy.size.width * 1.5)
                    let displayWidth = displayHeight / 1.5

                    screen
                        .frame(width: displayWidth, height: displayHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                        .gesture(touchGesture(in: CGSize(width: displayWidth, height: displayHeight)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: min(geometry.size.height * 0.68, 610))

                deviceDescription
                    .padding(.top, 18)

                Spacer(minLength: 20)

                EmulatorControlBar { event in
                    if case .powerButton(pressed: true) = event, !emulatorCore.isPoweredOn, emulatorCore.bootStage == nil, let firmware {
                        powerOn(firmware)
                    } else {
                        emulatorCore.sendInput(event)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
                .padding(.bottom, max(geometry.safeAreaInsets.bottom == 0 ? 18 : 8, 8))
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .ignoresSafeArea(edges: .bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
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

    @ViewBuilder
    private var deviceDescription: some View {
        VStack(spacing: 7) {
            Text(firmware.map { "\($0.displayName) · iOS \($0.metadata.productVersion)" } ?? "No firmware selected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if case .error(let message) = emulatorCore.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if !emulatorCore.isPoweredOn, emulatorCore.bootStage == nil,
               !emulatorCore.isBusy, let firmware, firmware.compatibility.isCompatible {
                Button {
                    powerOn(firmware)
                } label: {
                    Label("Power On", systemImage: "power")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
            if emulatorCore.hasStorageFlushFailure {
                Button("Retry Storage Flush", systemImage: "arrow.clockwise") {
                    emulatorCore.retryStorageFlush()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
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
