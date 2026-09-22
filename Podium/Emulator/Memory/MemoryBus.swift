import Foundation

/// Byte-addressable memory access, the shape both physical RAM and
/// memory-mapped devices present to the CPU/MMU.
///
/// Reads and writes are explicitly little-endian at this layer (ARMv7 on
/// Apple A4 runs little-endian), so callers never need to reason about
/// byte order themselves.
protocol MemoryBus: AnyObject {
    /// Total addressable length in bytes.
    var length: Int { get }

    func readByte(at address: UInt32) throws -> UInt8
    func readWord16(at address: UInt32) throws -> UInt16
    func readWord32(at address: UInt32) throws -> UInt32

    func writeByte(_ value: UInt8, at address: UInt32) throws
    func writeWord16(_ value: UInt16, at address: UInt32) throws
    func writeWord32(_ value: UInt32, at address: UInt32) throws

    /// Writes a contiguous run of bytes starting at `address`. Conformers
    /// may override this for a bulk copy; the default just calls
    /// `writeByte` in a loop, correct but not what you want for
    /// megabyte-sized transfers like loading a kernel image.
    func writeBytes(_ bytes: Data, at address: UInt32) throws

    /// Reads a contiguous run of `count` bytes starting at `address`.
    /// Conformers may override this for a bulk copy; the default just
    /// calls `readByte` in a loop, correct but not what you want for a
    /// framebuffer-sized read every frame.
    func readBytes(_ count: Int, at address: UInt32) throws -> Data

    /// A raw, stable host pointer to the backing storage of whichever
    /// region actually covers `address`, for a JIT fast path — see
    /// `ThumbJITTranslator`'s load/store support. Most conformers can't
    /// offer this (this codebase only has one that meaningfully can,
    /// `FlatPhysicalMemory`, whose backing array is fixed-size for its
    /// whole lifetime once constructed); the default implementation
    /// returns `nil`, and JIT-compiled loads/stores fall back to the
    /// interpreter whenever it does. Returns `nil` when `address` isn't
    /// covered by this bus at all, so a caller doesn't need a separate
    /// bounds check before asking.
    func fastPathRegion(for address: UInt32) -> (pointer: UnsafeMutableRawPointer, regionBaseAddress: UInt32, regionLength: Int)?
}

extension MemoryBus {
    func writeBytes(_ bytes: Data, at address: UInt32) throws {
        for (offset, byte) in bytes.enumerated() {
            try writeByte(byte, at: address &+ UInt32(offset))
        }
    }

    func readBytes(_ count: Int, at address: UInt32) throws -> Data {
        var bytes = Data(capacity: count)
        for offset in 0..<count {
            bytes.append(try readByte(at: address &+ UInt32(offset)))
        }
        return bytes
    }

    func fastPathRegion(for address: UInt32) -> (pointer: UnsafeMutableRawPointer, regionBaseAddress: UInt32, regionLength: Int)? {
        nil
    }
}
