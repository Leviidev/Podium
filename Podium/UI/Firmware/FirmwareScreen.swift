import SwiftUI
import UniformTypeIdentifiers

struct FirmwareScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @State private var isPresentingImporter = false
    @State private var importError: ImportErrorPresentation?

    var body: some View {
        List {
            if firmwareLibrary.firmwares.isEmpty {
                emptyState
            } else {
                Section("Imported Firmware") {
                    ForEach(firmwareLibrary.firmwares) { firmware in
                        NavigationLink {
                            FirmwareDetailView(firmwareID: firmware.id)
                        } label: {
                            FirmwareRow(firmware: firmware)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Firmware")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingImporter = true
                } label: {
                    if firmwareLibrary.isImporting {
                        ProgressView()
                    } else {
                        Label("Import IPSW", systemImage: "plus")
                    }
                }
                .disabled(firmwareLibrary.isImporting)
            }
        }
        .fileImporter(isPresented: $isPresentingImporter, allowedContentTypes: [.ipsw]) { result in
            handleImportResult(result)
        }
        .sheet(item: $importError) { presentation in
            FriendlyErrorView(
                userMessage: presentation.userMessage,
                developerDetail: presentation.developerDetail
            ) {
                importError = nil
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Firmware Imported", systemImage: "square.and.arrow.down")
        } description: {
            Text("Import an IPSW to get started. Podium currently supports \(DeviceCatalog.iPodTouch4.marketingName) on iOS \(ReferenceFirmware.productVersion).")
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    try await firmwareLibrary.importFirmware(from: url)
                } catch let error as FriendlyError {
                    importError = ImportErrorPresentation(userMessage: error.userMessage, developerDetail: error.developerDetail)
                } catch {
                    importError = ImportErrorPresentation(userMessage: "Podium couldn't import this file.", developerDetail: error.localizedDescription)
                }
            }
        case .failure(let error):
            importError = ImportErrorPresentation(userMessage: "Podium couldn't access this file.", developerDetail: error.localizedDescription)
        }
    }
}

private struct ImportErrorPresentation: Identifiable {
    let id = UUID()
    let userMessage: String
    let developerDetail: String
}

#Preview {
    NavigationStack {
        FirmwareScreen()
    }
    .environment(FirmwareLibrary())
}
