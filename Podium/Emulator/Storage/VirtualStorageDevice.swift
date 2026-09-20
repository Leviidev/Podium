import Foundation

/// Block-level storage presented to the guest — the virtual NAND that a
/// guest filesystem driver would sit on top of.
///
/// No implementation exists yet. This is deliberately a block device
/// contract, not a host-filesystem passthrough: guest storage must be
/// mediated through this abstraction rather than emulator components
/// touching host files directly (see Section 17 of the project spec).
protocol VirtualStorageDevice: AnyObject {
    var blockSize: Int { get }
    var blockCount: Int { get }

    func readBlocks(at index: Int, count: Int) throws -> Data
    func writeBlocks(_ data: Data, at index: Int) throws
}

enum VirtualStorageError: Error {
    case outOfRange(index: Int, count: Int)
    case sizeMismatch
}
