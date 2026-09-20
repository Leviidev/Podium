import Foundation

/// Failure reading or writing guest memory.
enum MemoryAccessError: Error, Equatable {
    /// The address is outside any mapped region.
    case unmappedAddress(UInt32)
    /// The access would read/write past the end of a mapped region.
    case outOfBounds(address: UInt32, length: Int)
    /// The access width isn't naturally aligned for the requested
    /// address (relevant once MMU/strict-alignment modes are modeled).
    case misaligned(address: UInt32, width: Int)
}
