import Foundation

/// Dispatches every access to whichever of several disjoint `MemoryBus`
/// regions actually contains the address, rather than assuming guest
/// physical memory is one contiguous block.
///
/// Real hardware isn't one flat address space either — DRAM lives at
/// one physical range and memory-mapped peripheral registers live at
/// many small, scattered ones. Podium's own real, extracted device
/// tree confirms this for the reference firmware: `arm-io`'s children
/// (`pmgr`, `wdt`, `gpio`, `vic`, ...) each carry their own real,
/// non-placeholder `reg` physical base/size — see
/// `DeviceTreeMemoryMap.peripheralRegions`, which reads every one of
/// them out of the actual device tree rather than hardcoding guessed
/// addresses. Several of Apple's older Samsung-derived SoCs, this one
/// included, also expose the same physical registers a second time at
/// `address | 0x80000000` (an uncached/write-combine alias); real
/// kernel code freely uses either form (confirmed empirically — a
/// fault this session landed on the aliased address of `pmgr`'s
/// range, not its plain one), so `DeviceTreeMemoryMap` backs both. The
/// real kernel's own boot code maps and writes into these regions
/// during early platform-expert initialization; before this existed,
/// any such access hard-faulted with `.unmappedAddress` since
/// `FlatPhysicalMemory` only ever modeled DRAM.
///
/// This backs the peripheral window with ordinary, zero-initialized
/// storage — reads/writes succeed and round-trip like plain memory —
/// rather than modeling any specific register's real hardware
/// semantics (side effects, status bits, interrupts). That's an
/// intentionally narrow claim: it stops the CPU from hard-faulting on
/// an address the real device genuinely has, without pretending to
/// emulate what's actually attached there.
final class SegmentedMemoryBus: MemoryBus {
    private var regions: [MemoryBus]

    init(regions: [MemoryBus]) {
        precondition(!regions.isEmpty, "SegmentedMemoryBus needs at least one region")
        self.regions = regions
    }

    /// Appends a region discovered after construction — e.g. the real
    /// peripheral map read out of a specific firmware's device tree,
    /// which isn't known yet when the CPU/memory bus is first stood
    /// up (see `EmulatorCore.attemptBoot`).
    func addRegion(_ region: MemoryBus) {
        regions.append(region)
    }

    var length: Int { regions.reduce(0) { $0 + $1.length } }

    func readByte(at address: UInt32) throws -> UInt8 {
        try dispatch(address) { try $0.readByte(at: address) }
    }

    func readWord16(at address: UInt32) throws -> UInt16 {
        try dispatch(address) { try $0.readWord16(at: address) }
    }

    func readWord32(at address: UInt32) throws -> UInt32 {
        try dispatch(address) { try $0.readWord32(at: address) }
    }

    func writeByte(_ value: UInt8, at address: UInt32) throws {
        try dispatch(address) { try $0.writeByte(value, at: address) }
    }

    func writeWord16(_ value: UInt16, at address: UInt32) throws {
        try dispatch(address) { try $0.writeWord16(value, at: address) }
    }

    func writeWord32(_ value: UInt32, at address: UInt32) throws {
        try dispatch(address) { try $0.writeWord32(value, at: address) }
    }

    func writeBytes(_ bytes: Data, at address: UInt32) throws {
        try dispatch(address) { try $0.writeBytes(bytes, at: address) }
    }

    /// Tries each region in order, since a region only knows its own
    /// bounds (there's no separate range table to keep in sync) —
    /// whichever one doesn't throw `unmappedAddress` for this address
    /// handles it. Any other error (out-of-bounds, misaligned) is
    /// real and propagates immediately rather than falling through.
    private func dispatch<T>(_ address: UInt32, _ operation: (MemoryBus) throws -> T) throws -> T {
        var lastError: Error?
        for region in regions {
            do {
                return try operation(region)
            } catch MemoryAccessError.unmappedAddress {
                lastError = MemoryAccessError.unmappedAddress(address)
                continue
            }
        }
        throw lastError ?? MemoryAccessError.unmappedAddress(address)
    }
}
