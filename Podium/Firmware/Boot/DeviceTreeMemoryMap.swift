import Foundation

/// Reads every peripheral's real physical `reg` address/size straight
/// out of a specific firmware's own device tree, so `EmulatorCore` can
/// back each one with real, zero-initialized memory instead of the CPU
/// hard-faulting the first time real kernel code touches SoC hardware
/// outside DRAM.
///
/// This intentionally makes no attempt to model any peripheral's real
/// register *behavior* (status bits, side effects, interrupts) — see
/// `SegmentedMemoryBus`'s doc comment for why that's a deliberate,
/// narrow claim rather than a shortcut. It only discovers where real
/// hardware genuinely exists, from data the real IPSW already
/// contains, the same honesty standard `DeviceTreePatcher` holds to.
enum DeviceTreeMemoryMap {
    private static let nodeHeaderSize = 8
    private static let propertyNameSize = 32
    private static let propertyHeaderSize = propertyNameSize + 4

    /// One translated physical region a peripheral's `reg` property declares.
    struct Region: Equatable {
        let address: UInt32
        let size: UInt32
    }

    /// A node from Apple's binary device tree, retaining its raw properties
    /// so hardware discovery can inspect the real compatible, bus, and IRQ
    /// declarations instead of guessing from MMIO ranges alone.
    struct Node: Equatable {
        let name: String
        let path: String
        let parentPath: String?
        let properties: [String: Data]

        var phandle: UInt32? {
            guard let value = properties["AAPL,phandle"] ?? properties["phandle"], value.count >= 4 else { return nil }
            return value.readUInt32LE(at: 0)
        }

        var interruptParent: UInt32? {
            guard let value = properties["interrupt-parent"], value.count >= 4 else { return nil }
            return value.readUInt32LE(at: 0)
        }

        var dmaParent: UInt32? {
            guard let value = properties["dma-parent"], value.count >= 4 else { return nil }
            return value.readUInt32LE(at: 0)
        }

        var dmaChannels: [UInt32] {
            guard let value = properties["dma-channels"] else { return [] }
            return stride(from: 0, to: value.count - value.count % 4, by: 4).map { value.readUInt32LE(at: $0) }
        }

        var compatibleIdentifiers: [String] {
            guard let compatible = properties["compatible"] else { return [] }
            return compatible.split(separator: 0, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
        }

        /// Raw one-cell `{address, size}` tuples for diagnostics on this
        /// 32-bit firmware. Use `physicalRegions(for:in:)` to map them.
        var regions: [Region] {
            guard let reg = properties["reg"] else { return [] }
            var result: [Region] = []
            var offset = 0
            while offset + 8 <= reg.count {
                result.append(Region(address: reg.readUInt32LE(at: offset), size: reg.readUInt32LE(at: offset + 4)))
                offset += 8
            }
            return result
        }

        /// Raw interrupt cells as little-endian words. Their interpretation
        /// depends on the interrupt controller named by the node's tree path.
        var interruptCells: [UInt32] {
            guard let interrupts = properties["interrupts"] else { return [] }
            return stride(from: 0, to: interrupts.count - interrupts.count % 4, by: 4)
                .map { interrupts.readUInt32LE(at: $0) }
        }
    }

    /// Walks the binary tree into named nodes with the properties the
    /// firmware actually declares. A malformed/truncated tree yields no
    /// inventory rather than a partial list that could mislead hardware setup.
    static func nodes(in deviceTree: Data) -> [Node] {
        var result: [Node] = []
        guard collectNodes(deviceTree, offset: 0, parentPath: nil, into: &result) != nil else { return [] }
        return result
    }

    /// Looks up an Apple or standard device-tree phandle in the parsed tree.
    static func node(referencedBy phandle: UInt32, in nodes: [Node]) -> Node? {
        nodes.first { $0.phandle == phandle }
    }

    /// Resolves a node's `reg` tuples from its parent bus address space
    /// through each ancestor's `ranges` into the root physical address
    /// space. A missing `ranges` on a non-root bus is not translatable;
    /// an empty `ranges` property is an identity map.
    static func physicalRegions(for node: Node, in nodes: [Node]) -> [Region] {
        guard let parentPath = node.parentPath,
              let parent = nodes.first(where: { $0.path == parentPath }),
              let reg = node.properties["reg"] else { return [] }
        let addressCells = cellCount("#address-cells", on: parent, default: 2)
        let sizeCells = cellCount("#size-cells", on: parent, default: 1)
        guard let addressCells, let sizeCells, addressCells > 0, sizeCells > 0 else { return [] }
        let tupleBytes = (addressCells + sizeCells) * 4
        guard tupleBytes > 0, reg.count % tupleBytes == 0 else { return [] }

        var result: [Region] = []
        var offset = 0
        while offset < reg.count {
            guard let rawAddress = cellValue(reg, offset: offset, count: addressCells),
                  let rawSize = cellValue(reg, offset: offset + addressCells * 4, count: sizeCells),
                  rawSize > 0,
                  let address = translate(rawAddress, size: rawSize, through: parent, nodes: nodes),
                  address <= UInt64(UInt32.max), rawSize <= UInt64(UInt32.max) else {
                offset += tupleBytes
                continue
            }
            let (end, overflow) = address.addingReportingOverflow(rawSize)
            guard !overflow, end <= UInt64(UInt32.max) + 1 else {
                offset += tupleBytes
                continue
            }
            result.append(Region(address: UInt32(address), size: UInt32(rawSize)))
            offset += tupleBytes
        }
        return result
    }

    /// Every `reg` region translated through each bus's `ranges`, plus
    /// the legacy alias with bit 31 toggled. Apple's Samsung-derived
    /// SoCs expose both aliases; a kernel trace confirmed a real access
    /// to the aliased PMGR range. Zero-size regions and ranges overlapping
    /// guest RAM or reserved on-chip SRAM are not backed a second time.
    static func peripheralRegions(
        in deviceTree: Data,
        excluding ramRange: Range<UInt32>,
        alsoExcluding otherRanges: [Range<UInt32>] = []
    ) -> [Region] {
        let inventory = nodes(in: deviceTree)
        let regions = inventory.flatMap { physicalRegions(for: $0, in: inventory) }
        let excludedRanges = [ramRange] + otherRanges

        func overlapsExcluded(_ region: Region) -> Bool {
            let start = UInt64(region.address)
            let end = start + UInt64(region.size)
            return excludedRanges.contains { range in
                start < UInt64(range.upperBound) && UInt64(range.lowerBound) < end
            }
        }

        var seen = Set<UInt32>()
        var result: [Region] = []
        for region in regions {
            // A region already mapped as guest RAM or reserved SRAM is not
            // an MMIO declaration; do not create a second alias for it.
            guard !overlapsExcluded(region) else { continue }
            for address in [region.address, region.address ^ 0x8000_0000] {
                let candidate = Region(address: address, size: region.size)
                guard !overlapsExcluded(candidate), !seen.contains(address) else { continue }
                seen.insert(address)
                result.append(candidate)
            }
        }
        return result
    }

    private static func cellCount(_ property: String, on node: Node, default defaultValue: Int) -> Int? {
        guard let value = node.properties[property] else { return defaultValue }
        guard value.count >= 4 else { return nil }
        let count = Int(value.readUInt32LE(at: 0))
        return (1...2).contains(count) ? count : nil
    }

    /// Reads one- or two-cell little-endian property values into UInt64.
    /// Apple firmware stores each 32-bit cell little-endian; multi-cell
    /// values follow the device-tree high-cell-first convention.
    private static func cellValue(_ data: Data, offset: Int, count: Int) -> UInt64? {
        guard (1...2).contains(count), offset >= 0, offset + count * 4 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<count {
            value = (value << 32) | UInt64(data.readUInt32LE(at: offset + index * 4))
        }
        return value
    }

    private static func translate(_ address: UInt64, size: UInt64, through initialBus: Node, nodes: [Node]) -> UInt64? {
        var address = address
        var bus = initialBus
        while bus.path != "/" {
            guard let parentPath = bus.parentPath,
                  let parent = nodes.first(where: { $0.path == parentPath }),
                  let ranges = bus.properties["ranges"] else { return nil }
            if !ranges.isEmpty {
                guard let childAddressCells = cellCount("#address-cells", on: bus, default: 2),
                      let parentAddressCells = cellCount("#address-cells", on: parent, default: 1),
                      let sizeCells = cellCount("#size-cells", on: bus, default: 1) else { return nil }
                let tupleBytes = (childAddressCells + parentAddressCells + sizeCells) * 4
                guard tupleBytes > 0, ranges.count % tupleBytes == 0 else { return nil }
                var mappedAddress: UInt64?
                var offset = 0
                while offset < ranges.count {
                    guard let childBase = cellValue(ranges, offset: offset, count: childAddressCells),
                          let parentBase = cellValue(ranges, offset: offset + childAddressCells * 4, count: parentAddressCells),
                          let rangeSize = cellValue(ranges, offset: offset + (childAddressCells + parentAddressCells) * 4, count: sizeCells),
                          rangeSize > 0,
                          address >= childBase,
                          address - childBase <= rangeSize,
                          size <= rangeSize - (address - childBase) else {
                        offset += tupleBytes
                        continue
                    }
                    let (translated, overflow) = parentBase.addingReportingOverflow(address - childBase)
                    guard !overflow else { return nil }
                    mappedAddress = translated
                    break
                }
                guard let mappedAddress else { return nil }
                address = mappedAddress
            }
            bus = parent
        }
        return address
    }

    @discardableResult
    private static func collectNodes(_ data: Data, offset: Int, parentPath: String?, into nodes: inout [Node]) -> Int? {
        guard offset >= 0, offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        let nChildren = Int(data.readUInt32LE(at: offset + 4))
        var cursor = offset + nodeHeaderSize
        var properties: [String: Data] = [:]

        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let rawLength = data.readUInt32LE(at: cursor + propertyNameSize)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            let valueOffset = cursor + propertyHeaderSize
            let paddedLength = (realLength + 3) & ~3
            guard realLength <= data.count - valueOffset, paddedLength <= data.count - valueOffset else { return nil }
            properties[name] = data.subdata(in: valueOffset..<(valueOffset + realLength))
            cursor = valueOffset + paddedLength
        }

        let name = properties["name"].map { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } ?? ""
        let path: String
        if let parentPath {
            path = parentPath == "/" ? "/" + name : parentPath + "/" + name
        } else {
            path = "/"
        }
        nodes.append(Node(name: name, path: path, parentPath: parentPath, properties: properties))

        for _ in 0..<nChildren {
            guard let end = collectNodes(data, offset: cursor, parentPath: path, into: &nodes) else { return nil }
            cursor = end
        }
        return cursor
    }
}
