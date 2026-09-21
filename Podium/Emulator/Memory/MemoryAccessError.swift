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
    /// rather than split into a separate case per real ARM fault kind;
    /// `ARMv7CPU.raiseDataAbort`'s `reason`-string classification (into the
    /// real DFSR encoding) is what actually distinguishes them for the
    /// guest. Raised during a data access, this now dispatches a real
    /// ARMv7 Data Abort exception into the guest's own vector table
    /// (`ARMv7CPU.raiseDataAbort`) instead of halting Podium outright —
    /// real hardware would do exactly that, and the guest's own abort
    /// handler is what decides whether it's recoverable. Raised during an
    /// instruction *fetch*, it's still a plain halt: that would be a
    /// Prefetch Abort, a different vector Podium doesn't dispatch yet.
    case translationFault(virtualAddress: UInt32, reason: String)
}
