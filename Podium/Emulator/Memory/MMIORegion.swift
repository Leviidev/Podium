import Foundation

/// A memory-mapped hardware device: a window of 32-bit registers whose
/// reads and writes have real side effects, unlike the plain storage
/// `FlatPhysicalMemory` gives a peripheral nobody has modeled yet.
protocol MMIODevice: AnyObject {
    /// `offset` is relative to the device's window and 4-byte aligned.
    func readRegister(at offset: UInt32) -> UInt32
    func writeRegister(_ value: UInt32, at offset: UInt32)
}

/// Places an `MMIODevice` at one physical address window on a
/// `SegmentedMemoryBus`. Must be added to the bus *ahead of* any generic
/// peripheral backing covering the same addresses, since the bus hands an
/// access to the first region that accepts it.
///
/// Byte and halfword accesses are narrowed from / merged into the
/// containing 32-bit register (a read-modify-write for stores) — real
/// kernel code accesses these registers as whole words, so this only
/// needs to be correct, not side-effect-exact, for narrower access.
final class MMIORegion: MemoryBus {
    let baseAddress: UInt32
    let length: Int
    private let device: MMIODevice

    init(device: MMIODevice, baseAddress: UInt32, length: UInt32) {
        self.device = device
        self.baseAddress = baseAddress
        self.length = Int(length)
    }

    private func offset(of address: UInt32) throws -> UInt32 {
        guard address >= baseAddress, UInt64(address - baseAddress) < UInt64(length) else {
            throw MemoryAccessError.unmappedAddress(address)
        }
        return address - baseAddress
    }

    func readWord32(at address: UInt32) throws -> UInt32 {
        let offset = try offset(of: address)
        let aligned = device.readRegister(at: offset & ~3)
        return offset & 3 == 0 ? aligned : aligned >> ((offset & 3) * 8)
    }

    func readWord16(at address: UInt32) throws -> UInt16 {
        let offset = try offset(of: address)
        return UInt16(truncatingIfNeeded: device.readRegister(at: offset & ~3) >> ((offset & 3) * 8))
    }

    func readByte(at address: UInt32) throws -> UInt8 {
        let offset = try offset(of: address)
        return UInt8(truncatingIfNeeded: device.readRegister(at: offset & ~3) >> ((offset & 3) * 8))
    }

    func writeWord32(_ value: UInt32, at address: UInt32) throws {
        let offset = try offset(of: address)
        guard offset & 3 == 0 else { return try merge(value, width: 32, at: offset) }
        device.writeRegister(value, at: offset)
    }

    func writeWord16(_ value: UInt16, at address: UInt32) throws {
        try merge(UInt32(value), width: 16, at: try offset(of: address))
    }

    func writeByte(_ value: UInt8, at address: UInt32) throws {
        try merge(UInt32(value), width: 8, at: try offset(of: address))
    }

    private func merge(_ value: UInt32, width: UInt32, at offset: UInt32) throws {
        let shift = (offset & 3) * 8
        let mask: UInt32 = (width == 32 ? 0xFFFF_FFFF : (1 << width) - 1) << shift
        let current = device.readRegister(at: offset & ~3)
        device.writeRegister((current & ~mask) | ((value << shift) & mask), at: offset & ~3)
    }
}
