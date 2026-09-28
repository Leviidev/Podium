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
    private var regions: [MemoryBus] {
        didSet { rebuildSegments() }
    }

    /// Every address range some region declares, flattened into
    /// non-overlapping segments each owned by the highest-priority
    /// (earliest added) region covering it, sorted for binary search.
    private var segmentStarts: [UInt64] = []
    private var segmentEnds: [UInt64] = []
    private var segmentRegions: [Int] = []
    private var hasUndeclaredRegions = false

    private func rebuildSegments() {
        hasUndeclaredRegions = regions.contains { $0.window == nil }
        var boundaries = Set<UInt64>()
        for region in regions {
            guard let window = region.window else { continue }
            boundaries.insert(UInt64(window.first))
            boundaries.insert(UInt64(window.first) + window.count)
        }
        let sorted = boundaries.sorted()
        var starts: [UInt64] = [], ends: [UInt64] = [], owners: [Int] = []
        for (low, high) in zip(sorted, sorted.dropFirst()) {
            guard let owner = regions.firstIndex(where: { region in
                guard let window = region.window else { return false }
                return UInt64(window.first) <= low && high <= UInt64(window.first) + window.count
            }) else { continue }
            if let last = owners.last, last == owner, ends.last == low {
                ends[ends.count - 1] = high
            } else {
                starts.append(low); ends.append(high); owners.append(owner)
            }
        }
        segmentStarts = starts
        segmentEnds = ends
        segmentRegions = owners
    }

    /// Stateless on purpose: the display is read from the UI thread while
    /// the CPU runs, and a shared "last segment used" shortcut raced —
    /// one thread could swap it between another's bounds check and its
    /// use, handing a CPU access to the wrong device.
    @inline(__always)
    private func region(containing address: UInt32) -> MemoryBus? {
        let a = UInt64(address)
        var low = 0, high = segmentStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if a < segmentStarts[mid] { high = mid - 1 }
            else if a >= segmentEnds[mid] { low = mid + 1 }
            else { return regions[segmentRegions[mid]] }
        }
        return nil
    }

    init(regions: [MemoryBus]) {
        precondition(!regions.isEmpty, "SegmentedMemoryBus needs at least one region")
        self.regions = regions
        rebuildSegments()
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

    func readBytes(_ count: Int, at address: UInt32) throws -> Data {
        try dispatch(address) { try $0.readBytes(count, at: address) }
    }

    func fastPathRegion(for address: UInt32) -> (pointer: UnsafeMutableRawPointer, regionBaseAddress: UInt32, regionLength: Int)? {
        for region in regions {
            if let found = region.fastPathRegion(for: address) {
                return found
            }
        }
        return nil
    }

    /// Hands the access to the region that owns the address (see
    /// `rebuildSegments` — the order regions were added is the priority,
    /// so a device modeled on top of generic peripheral backing wins).
    /// Regions that don't declare a window are asked in turn after that
    /// and may refuse with `unmappedAddress`.
    private func dispatch<T>(_ address: UInt32, _ operation: (MemoryBus) throws -> T) throws -> T {
        if let region = region(containing: address) {
            return try operation(region)
        }
        guard hasUndeclaredRegions else { throw MemoryAccessError.unmappedAddress(address) }
        var lastError: Error?
        for region in regions where region.window == nil {
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
