import SwiftUI

struct FirmwareRow: View {
    let firmware: ImportedFirmware

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("iOS \(firmware.metadata.productVersion)")
                    .font(.body.weight(.medium))
                Text("\(firmware.displayName) · Build \(firmware.metadata.buildVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(
                    text: firmware.compatibility.isCompatible ? "Compatible" : firmware.compatibility.summary,
                    systemImage: firmware.compatibility.isCompatible ? "checkmark" : nil,
                    tone: firmware.compatibility.isCompatible ? .positive : .neutral
                )
                .font(.caption)

                if firmware.isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
