import Foundation

enum FirmwareDownloadPhase: Equatable {
    case idle
    case checkingAvailability
    case downloading(bytesWritten: Int64, totalBytes: Int64)
    case verifying
    case importing
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed: return false
        case .checkingAvailability, .downloading, .verifying, .importing: return true
        }
    }
}
