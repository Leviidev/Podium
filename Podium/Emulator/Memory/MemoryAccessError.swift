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
    /// `ARMv7CPU.raiseDataAbort` maps the `reason` to the real DFSR
    /// encoding the guest's abort handler reads. Raised during a data
    /// access, this dispatches a real ARMv7 Data Abort exception into the
    /// guest's own vector table (`ARMv7CPU.raiseDataAbort`) instead of
    /// halting Podium outright — real hardware would do exactly that, and
    /// the guest's own abort handler is what decides whether it's
    /// recoverable. Raised during an instruction *fetch*, it's still a
    /// plain halt: that would be a Prefetch Abort, a different vector
    /// Podium doesn't dispatch yet.
    /// `isWrite` becomes DFSR's WnR bit: the guest's abort handler uses it
    /// to ask its VM system for write access, so a write fault reported as
    /// a read would be mapped read-only again and fault forever.
    case translationFault(virtualAddress: UInt32, reason: TranslationFaultReason, isWrite: Bool)
}

/// The reason a translation-table walk rejected a virtual address.
/// Encoded as a typed value rather than a free-form string so that
/// `ARMv7CPU.dataFaultStatus` can classify it with a O(1) integer
/// switch instead of Foundation `.contains()` string scans — a
/// meaningful speedup given how frequently the kernel raises page
/// faults during boot (demand-paging, stack guards, etc.).
enum TranslationFaultReason: Equatable {
    /// First-level descriptor is invalid (bits[1:0] == 0b00 or 0b11).
    case sectionTranslation
    /// Second-level descriptor is invalid (bits[1:0] == 0b00).
    case pageTranslation
    /// DACR domain field forbids any access. `isPage` distinguishes a
    /// small/large page mapping from a section — the guest's DFSR encodes
    /// the two differently.
    case domainFault(isPage: Bool)
    /// AP/XN permission check rejected this specific access type.
    case permissionFault(isPage: Bool)
}
