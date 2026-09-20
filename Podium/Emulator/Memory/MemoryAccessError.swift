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
    /// A real MMU translation-table walk (`ARMv7MMU`) rejected this
    /// virtual address — a first/second-level descriptor marked the
    /// region not-present, a DACR domain forbade access, or an AP/XN
    /// check forbade this specific read/write/execute. Modeled generically
    /// rather than split into prefetch-abort/data-abort, since Podium
    /// doesn't implement exception entry for the guest to distinguish them.
    case translationFault(virtualAddress: UInt32, reason: String)
}
