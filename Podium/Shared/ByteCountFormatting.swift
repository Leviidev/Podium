import Foundation

extension Int64 {
    /// Human-readable file size, e.g. "742 MB".
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
