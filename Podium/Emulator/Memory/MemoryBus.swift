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
}

extension MemoryBus {
    func writeBytes(_ bytes: Data, at address: UInt32) throws {
        for (offset, byte) in bytes.enumerated() {
            try writeByte(byte, at: address &+ UInt32(offset))
        }
    }
}
