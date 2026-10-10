import Foundation

/// Looks up a validated reference firmware (e.g. iPod4,1 / iOS 6.1.6 /
/// 10B500) via the public ipsw.me API — the same source named in Podium's
/// own project brief.
struct IPSWMeAPIClient {
    func endpoint(for firmware: ReferenceFirmware) -> URL {
        URL(string: "https://api.ipsw.me/v4/ipsw/\(firmware.downloadIdentifier)")!
    }

    func fetchReferenceFirmwareInfo(_ firmware: ReferenceFirmware) async throws -> IPSWMeFirmwareInfo {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: endpoint(for: firmware))
        } catch {
            throw FirmwareDownloadError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FirmwareDownloadError.notFound
        }

        do {
            return try JSONDecoder().decode(IPSWMeFirmwareInfo.self, from: data)
        } catch {
            throw FirmwareDownloadError.decodingFailed(underlying: error)
        }
    }
}
