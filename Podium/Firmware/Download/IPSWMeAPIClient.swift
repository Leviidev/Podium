import Foundation

/// Looks up Podium's one reference firmware (iPod4,1 / iOS 6.1.6 / 10B500)
/// via the public ipsw.me API. This is the same source named in Podium's
/// own project brief as the reference for this firmware.
struct IPSWMeAPIClient {
    private static let referenceFirmwareEndpoint = URL(string: "https://api.ipsw.me/v4/ipsw/iPod4,1/10B500")!

    func fetchReferenceFirmwareInfo() async throws -> IPSWMeFirmwareInfo {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: Self.referenceFirmwareEndpoint)
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
