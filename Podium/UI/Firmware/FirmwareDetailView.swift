import SwiftUI

struct FirmwareDetailView: View {
    let firmwareID: UUID

    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.confirmBeforeDeletingFirmware) private var confirmBeforeDeleting = true

    @State private var isVerifying = false
    @State private var verifyResult: Bool?
    @State private var isPresentingRemoveConfirmation = false

    private var firmware: ImportedFirmware? {
        firmwareLibrary.firmwares.first { $0.id == firmwareID }
    }

    var body: some View {
        if let firmware {
            List {
                Section {
                    VStack(spacing: 6) {
                        Text("iOS \(firmware.metadata.productVersion)")
                            .font(.title2.weight(.semibold))
                        Text("Build \(firmware.metadata.buildVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        compatibilityBadge(for: firmware)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section("Firmware Details") {
                    LabeledContent("Device", value: firmware.displayName)
                    LabeledContent("iOS Version", value: firmware.metadata.productVersion)
                    LabeledContent("Build", value: firmware.metadata.buildVersion)
                    LabeledContent("Size", value: firmware.metadata.fileSizeBytes.formattedByteCount)
                    LabeledContent("Imported", value: firmware.importedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Original File", value: firmware.metadata.originalFileName)
                }

                Section {
                    Button {
                        firmwareLibrary.setActive(firmware)
                    } label: {
                        Label(
                            firmware.isActive ? "Active Firmware" : "Set as Active",
                            systemImage: firmware.isActive ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .disabled(firmware.isActive)

                    Button {
                        verify(firmware)
                    } label: {
                        HStack {
                            Label("Verify", systemImage: "checkmark.shield")
                            Spacer()
                            if isVerifying {
                                ProgressView()
                            } else if let verifyResult {
                                Image(systemName: verifyResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(verifyResult ? Color.green : Color.red)
                            }
                        }
                    }
                    .disabled(isVerifying)
                }

                Section {
                    Button(role: .destructive) {
                        requestRemoval(of: firmware)
                    } label: {
                        Label("Remove Firmware", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(firmware.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Remove this firmware?",
                isPresented: $isPresentingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    performRemoval(of: firmware)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The imported copy will be deleted from Podium. Your original IPSW file is never touched.")
            }
        } else {
            ContentUnavailableView("Firmware Removed", systemImage: "questionmark.folder")
        }
    }

    private func compatibilityBadge(for firmware: ImportedFirmware) -> some View {
        StatusBadge(
            text: firmware.compatibility.isCompatible ? "Compatible" : firmware.compatibility.summary,
            systemImage: firmware.compatibility.isCompatible ? "checkmark" : "exclamationmark.triangle",
            tone: firmware.compatibility.isCompatible ? .positive : .negative
        )
    }

    private func verify(_ firmware: ImportedFirmware) {
        isVerifying = true
        verifyResult = nil
        Task {
            let result = await firmwareLibrary.verify(firmware)
            isVerifying = false
            verifyResult = result
        }
    }

    private func requestRemoval(of firmware: ImportedFirmware) {
        if confirmBeforeDeleting {
            isPresentingRemoveConfirmation = true
        } else {
            performRemoval(of: firmware)
        }
    }

    private func performRemoval(of firmware: ImportedFirmware) {
        try? firmwareLibrary.remove(firmware)
        dismiss()
    }
}
