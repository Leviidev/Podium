import Foundation
import Observation

/// Fetches Podium's one reference firmware from Apple's CDN (via ipsw.me's
/// index) straight into the firmware library, so a first-time user doesn't
/// have to go find an IPSW themselves.
///
/// This never touches a user-provided file — it downloads its own copy to
/// a temp location, verifies it against ipsw.me's published SHA-256, and
/// only then hands it to `FirmwareLibrary` through the exact same import
/// path a manually-picked file goes through.
@MainActor
@Observable
final class ReferenceFirmwareDownloader {
    private(set) var phase: FirmwareDownloadPhase = .idle
    /// The validated firmware the current (or next) download will fetch.
    /// The automatic launch-time download targets the iOS 7.1.2 (iPhone 4)
    /// reference build; the firmware screen also lists the older iPod
    /// touch 4 build as an explicit choice.
    var downloadingFirmware: ReferenceFirmware = .iPhone4712

    private let apiClient: IPSWMeAPIClient
    private var activeDownloadTask: FirmwareDownloadTask?

    init(apiClient: IPSWMeAPIClient = IPSWMeAPIClient()) {
        self.apiClient = apiClient
    }

    /// Starts a download only if nothing compatible is already imported.
    /// Safe to call every time the main screen appears.
    func downloadIfNeeded(into library: FirmwareLibrary) async {
        guard !phase.isActive else { return }
        guard !library.firmwares.contains(where: { $0.compatibility.isCompatible }) else { return }
        await run(into: library)
    }

    func retry(into library: FirmwareLibrary) async {
        guard !phase.isActive else { return }
        await run(into: library)
    }

    func cancel() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        phase = .idle
    }

    private func run(into library: FirmwareLibrary) async {
        phase = .checkingAvailability
        do {
            let info = try await apiClient.fetchReferenceFirmwareInfo(downloadingFirmware)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("podium-download-\(UUID().uuidString).ipsw")

            let downloadTask = FirmwareDownloadTask(destinationURL: tempURL) { [weak self] written, total in
                Task { @MainActor in
                    self?.phase = .downloading(bytesWritten: written, totalBytes: total)
                }
            }
            activeDownloadTask = downloadTask
            phase = .downloading(bytesWritten: 0, totalBytes: info.filesize)
            try await downloadTask.download(from: info.url)
            activeDownloadTask = nil

            phase = .verifying
            let actualChecksum = try await Task.detached(priority: .utility) {
                try FileHasher.sha256(of: tempURL)
            }.value
            guard actualChecksum.caseInsensitiveCompare(info.sha256sum) == .orderedSame else {
                try? FileManager.default.removeItem(at: tempURL)
                phase = .failed(FirmwareDownloadError.checksumMismatch.userMessage)
                return
            }

            phase = .importing
            let imported = try await library.importFirmware(from: tempURL)
            library.setActive(imported)
            try? FileManager.default.removeItem(at: tempURL)

            phase = .completed
        } catch is CancellationError {
            phase = .idle
        } catch let error as FriendlyError {
            phase = .failed(error.userMessage)
        } catch let urlError as URLError where urlError.code == .cancelled {
            phase = .idle
        } catch {
            phase = .failed("Podium couldn't download the firmware. Check your connection and try again.")
        }
    }
}
