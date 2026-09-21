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

    /// One physical region a peripheral's `reg` property declares.
    struct Region: Equatable {
        let address: UInt32
        let size: UInt32
    }

    /// Every `reg`-bearing region in the whole tree, each 8-byte
    /// `{address, size}` pair a property may contain (several nodes —
    /// `pmgr` in particular — list more than one), plus that same
    /// physical address with bit 31 toggled. Apple's older Samsung-
    /// derived SoCs, this one included, expose peripheral registers a
    /// second time at `address | 0x8000_0000` — an uncached/write-
    /// combine alias of the identical hardware — and real kernel code
    /// uses either form interchangeably (confirmed empirically: a real
    /// fault this session landed on `pmgr`'s aliased address, not its
    /// plain one). Zero-size pairs (still-unpopulated placeholders
    /// like `pram`/`memory`/`vram` before their own dedicated patches
    /// run) are skipped, since a zero-length region is meaningless to
    /// back. Regions whose address already falls within `excluding`
    /// (real guest RAM) are also skipped — DRAM is already backed, and
    /// a couple of nodes (`cpu0`, `pram` once patched) legitimately
    /// have RAM-range `reg` values that would otherwise collide.
    static func peripheralRegions(in deviceTree: Data, excluding ramRange: Range<UInt32>) -> [Region] {
        var regions: [Region] = []
        collectRegProperties(deviceTree, offset: 0, into: &regions)

        var seen = Set<UInt32>()
        var result: [Region] = []
        for region in regions {
            // A `reg` value that's already inside guest RAM (e.g.
            // `cpu0`'s, which isn't a peripheral address at all) isn't
            // a real MMIO peripheral, so its bit-31 "alias" wouldn't
            // mean anything either — only alias genuine peripheral
            // addresses.
            guard region.size > 0, !ramRange.contains(region.address) else { continue }
            for address in [region.address, region.address ^ 0x8000_0000] {
                guard !ramRange.contains(address), !seen.contains(address) else { continue }
                seen.insert(address)
                result.append(Region(address: address, size: region.size))
            }
        }
        return result
    }

    @discardableResult
    private static func collectRegProperties(_ data: Data, offset: Int, into regions: inout [Region]) -> Int? {
        guard offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        let nChildren = Int(data.readUInt32LE(at: offset + 4))
        var cursor = offset + nodeHeaderSize

        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let lengthFieldOffset = cursor + propertyNameSize
            let rawLength = data.readUInt32LE(at: lengthFieldOffset)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            let valueOffset = cursor + propertyHeaderSize

            if name == "reg" {
                var pairOffset = valueOffset
                while pairOffset + 8 <= valueOffset + realLength {
                    let address = data.readUInt32LE(at: pairOffset)
                    let size = data.readUInt32LE(at: pairOffset + 4)
                    regions.append(Region(address: address, size: size))
                    pairOffset += 8
                }
            }
            cursor = valueOffset + ((realLength + 3) & ~3)
        }

        for _ in 0..<nChildren {
            guard let end = collectRegProperties(data, offset: cursor, into: &regions) else { return nil }
            cursor = end
        }
        return cursor
    }
}
