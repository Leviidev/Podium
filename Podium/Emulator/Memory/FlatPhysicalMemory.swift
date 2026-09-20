import Foundation

/// A contiguous, bounds-checked block of guest physical memory.
///
/// This is real, working memory — not a stub — but it is not yet wired to
/// anything: no CPU exists to read/write through it, and it does not yet
/// model the iPod touch 4's actual 256 MB physical map (RAM base address,
/// reserved regions, memory-mapped device windows). Those are Milestone 3
/// work. This class is the foundation that work builds on.
final class FlatPhysicalMemory: MemoryBus {
    let baseAddress: UInt32
    private var storage: [UInt8]

    init(length: Int, baseAddress: UInt32 = 0) {
        precondition(length > 0, "Memory region must have a nonzero length")
        self.baseAddress = baseAddress
        self.storage = [UInt8](repeating: 0, count: length)
    }

    var length: Int { storage.count }

    func readByte(at address: UInt32) throws -> UInt8 {
        let index = try offset(for: address, width: 1)
        return storage[index]
    }

    func readWord16(at address: UInt32) throws -> UInt16 {
        let index = try offset(for: address, width: 2)
        return UInt16(storage[index]) | (UInt16(storage[index + 1]) << 8)
    }

    func readWord32(at address: UInt32) throws -> UInt32 {
        let index = try offset(for: address, width: 4)
        return UInt32(storage[index])
            | (UInt32(storage[index + 1]) << 8)
            | (UInt32(storage[index + 2]) << 16)
            | (UInt32(storage[index + 3]) << 24)
    }

    func writeByte(_ value: UInt8, at address: UInt32) throws {
        let index = try offset(for: address, width: 1)
        storage[index] = value
    }

    func writeWord16(_ value: UInt16, at address: UInt32) throws {
        let index = try offset(for: address, width: 2)
        storage[index] = UInt8(value & 0xFF)
        storage[index + 1] = UInt8((value >> 8) & 0xFF)
    }

    func writeWord32(_ value: UInt32, at address: UInt32) throws {
        let index = try offset(for: address, width: 4)
        storage[index] = UInt8(value & 0xFF)
        storage[index + 1] = UInt8((value >> 8) & 0xFF)
        storage[index + 2] = UInt8((value >> 16) & 0xFF)
        storage[index + 3] = UInt8((value >> 24) & 0xFF)
    }

    func writeBytes(_ bytes: Data, at address: UInt32) throws {
        guard !bytes.isEmpty else { return }
        let index = try offset(for: address, width: bytes.count)
        storage.withUnsafeMutableBufferPointer { buffer in
            _ = bytes.copyBytes(to: UnsafeMutableBufferPointer(rebasing: buffer[index..<(index + bytes.count)]))
        }
    }

    /// Translates a guest address to a storage index, or throws. Uses
    /// 64-bit arithmetic throughout so an address/width near `UInt32.max`
    /// can't wrap around and defeat the bounds check.
    private func offset(for address: UInt32, width: Int) throws -> Int {
        guard address >= baseAddress else {
            throw MemoryAccessError.unmappedAddress(address)
        }
        let relative = UInt64(address - baseAddress)
        guard relative < UInt64(storage.count) else {
            throw MemoryAccessError.unmappedAddress(address)
        }
        guard relative + UInt64(width) <= UInt64(storage.count) else {
            throw MemoryAccessError.outOfBounds(address: address, length: width)
        }
        return Int(relative)
    }
}
