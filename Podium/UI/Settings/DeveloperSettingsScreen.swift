import SwiftUI

/// Secondary, hidden-by-default screen (Section 13 of the project spec).
/// Everything here is either a real static fact, the CPU's actual live
/// state once activated, or Podium's real activity log — never sample or
/// placeholder data. Downcasting `emulatorCore.cpu` to `ARMv7CPU` is
/// intentional and confined to this one debug-only screen — everywhere
/// else in the app depends only on the `CPU` protocol.
struct DeveloperSettingsScreen: View {
    @Environment(EmulatorCore.self) private var emulatorCore

    private var armCPU: ARMv7CPU? {
        emulatorCore.cpu as? ARMv7CPU
    }

    var body: some View {
        List {
            Section("CPU") {
                LabeledContent("Target Architecture", value: "ARMv7 (Apple A4)")
                if let armCPU {
                    LabeledContent("Status", value: "Interpreter active")
                    LabeledContent("PC", value: hex(armCPU.registers.pc))
                    LabeledContent("CPSR Flags", value: cpsrSummary(armCPU.cpsr))
                    if let error = armCPU.lastError {
                        LabeledContent("Halted", value: describe(error))
                            .foregroundStyle(.red)
                    }
                } else {
                    LabeledContent("Status", value: "Not active")
                }
            }

            if let armCPU {
                Section("Registers") {
                    ForEach(0..<16, id: \.self) { index in
                        LabeledContent(registerName(index), value: hex(armCPU.registers[index]))
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            Section {
                if let jit = armCPU?.jit {
                    LabeledContent("Available", value: jit.isAvailable ? "Yes" : "No — interpreting only")
                    LabeledContent("Compiled Blocks", value: "\(jit.stats.compiledBlockCount)")
                    LabeledContent("Cache Hits", value: "\(jit.stats.cacheHitCount)")
                    LabeledContent("Interpreter Fallbacks", value: "\(jit.stats.interpreterFallbackCount)")
                } else {
                    LabeledContent("Status", value: "Not active")
                }
            } header: {
                Text("JIT")
            } footer: {
                Text("On iOS, native code execution normally requires a debugger-granted right this app doesn't request by default — \"No\" here usually means that, not a bug.")
            }

            Section("Memory") {
                LabeledContent("Target RAM", value: Int64(EmulatorCore.physicalMemorySize).formattedByteCount)
                LabeledContent("Status", value: emulatorCore.memory != nil ? "Mapped at 0x00000000" : "Not active")
            }

            Section("Boot Arguments") {
                Text("Not yet supported.")
                    .foregroundStyle(.secondary)
            }

            Section("Emulator Log") {
                if emulatorCore.log.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(emulatorCore.log.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.formattedTime)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hex(_ value: UInt32) -> String {
        "0x" + value.hexString8
    }

    private func registerName(_ index: Int) -> String {
        switch index {
        case Registers.pcIndex: return "r15 (pc)"
        case Registers.lrIndex: return "r14 (lr)"
        case Registers.spIndex: return "r13 (sp)"
        default: return "r\(index)"
        }
    }

    private func cpsrSummary(_ cpsr: CPSR) -> String {
        (cpsr.negative ? "N" : "-")
            + (cpsr.zero ? "Z" : "-")
            + (cpsr.carry ? "C" : "-")
            + (cpsr.overflow ? "V" : "-")
    }

    private func describe(_ error: CPUError) -> String {
        switch error {
        case .unsupportedInstruction(let word, let address):
            return "Unsupported instruction \(hex(word)) at \(hex(address))"
        case .undefinedInstruction(let word, let address):
            return "Undefined instruction \(hex(word)) at \(hex(address))"
        case .memoryFault(let fault, let address):
            return "Memory fault at \(hex(address)): \(fault)"
        }
    }
}

#Preview {
    NavigationStack {
        DeveloperSettingsScreen()
    }
    .environment(EmulatorCore())
}
