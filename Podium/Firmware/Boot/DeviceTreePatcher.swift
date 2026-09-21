import Foundation

/// Patches specific zero-valued clock properties in the device tree
/// template this app ships (extracted as-is from the IPSW, never
/// touched by a real iBoot) so the real kernel's early platform-expert
/// code doesn't crash on them.
///
/// **What this is, and isn't:** the shipped `DeviceTree.n81ap.img3` is
/// the *unpopulated* build artifact — on real hardware, iBoot patches
/// in device-specific data (serial numbers, ECIDs, and several clock
/// properties) before ever handing control to the kernel. Podium has
/// no real device to read most of those values from, so this patcher
/// does not invent them. It exists only because the real kernel's own
/// compiled code has a genuine quirk for this small set of clock
/// properties: when a property's value isn't exactly 8 bytes, the code
/// reads it once as a 32-bit value and, separately, inside an `IT`
/// block, only reads a *second* word if the property "is" 8 bytes —
/// except that check is corrupted by an unrelated side effect: Thumb's
/// narrow, always-flag-setting `MOV` (there's no non-flag-setting
/// narrow encoding at all) executing *inside* that same `IT` block
/// clobbers the flag the block's own remaining predicate depends on,
/// so the "is-8-bytes" branch fires regardless of the property's real
/// length — confirmed by tracing real ITSTATE/CPSR values through this
/// exact sequence against the actual kernel. With these properties
/// left at their shipped 4-byte `0`, that redundant read dereferences
/// NULL (or a tiny offset from it). A genuinely 8-byte-encoded
/// property — which is exactly what a real, iBoot-populated device
/// tree uses for these same properties on modern Apple Silicon Macs,
/// confirmed via public `ioreg -l` dumps — never takes that corrupted
/// branch at all, since the length check is satisfied honestly before
/// the flag-clobbering `MOV` ever executes.
///
/// So this patcher *expands* each of these properties from a 4-byte
/// value to an 8-byte one (growing the tree and shifting everything
/// after it, exactly like a real property of that size always did) —
/// not overwriting bytes in place. `timebase-frequency` is set to a
/// real, independently-verifiable value (24 MHz — confirmed via public
/// `ioreg -l` dumps showing this exact property/value on multiple
/// generations of real Apple ARM hardware, including modern Apple
/// Silicon Macs, all the way back through this SoC generation's
/// contemporaries). The remaining properties (bus/peripheral/memory/
/// clock/fixed-frequency) don't have a verified public value for this
/// exact SoC, so they're zero-extended rather than guessed at — this
/// keeps the redundant read from crashing without dressing up an
/// invented number as real hardware data.
enum DeviceTreePatcher {
    private static let nodeHeaderSize = 8
    private static let propertyNameSize = 32
    private static let propertyHeaderSize = propertyNameSize + 4 // name + length

    private struct PropertyLocation {
        let name: String
        let lengthFieldOffset: Int
        let valueOffset: Int
        let currentLength: Int
    }

    /// `(nodePath, propertyName -> replacement 8-byte value)` —
    /// `nodePath` is the sequence of `"name"` property values to
    /// descend through from the root. Verified against the real
    /// reference device tree: `/cpus/cpu0` has exactly these six
    /// frequency properties, all shipped as 4-byte zero placeholders.
    private static let realTimebaseFrequencyHz: UInt64 = 24_000_000

    private static let targets: [(path: [String], properties: [String: UInt64])] = [
        (["cpus", "cpu0"], [
            "bus-frequency": 0,
            "peripheral-frequency": 0,
            "memory-frequency": 0,
            "timebase-frequency": realTimebaseFrequencyHz,
            "clock-frequency": 0,
            "fixed-frequency": 0,
        ]),
    ]

    /// Patches `deviceTree` in place. Growing 4-byte properties to
    /// 8 bytes changes the tree's total size, so callers must read
    /// `deviceTree.count` (and anything derived from it, like
    /// `boot_args.deviceTreeLength` or `topOfKernelData`) *after*
    /// calling this, not before.
    static func patchClockPlaceholders(_ deviceTree: inout Data) {
        for target in targets {
            let locations = findProperties(in: deviceTree, path: target.path, propertyNames: Set(target.properties.keys))
            // Apply from the highest offset down: growing a property's
            // value shifts everything after it, but never anything
            // before it (including its own name/length header, both
            // at lower offsets than its value), so already-found
            // offsets for not-yet-processed properties stay valid.
            for location in locations.sorted(by: { $0.valueOffset > $1.valueOffset }) {
                guard location.currentLength == 4, let value = target.properties[location.name] else { continue }
                var replacement = Data(count: 8)
                replacement.writeUInt32LE(UInt32(truncatingIfNeeded: value), at: 0)
                replacement.writeUInt32LE(UInt32(truncatingIfNeeded: value >> 32), at: 4)
                deviceTree.replaceSubrange(
                    deviceTree.startIndex + location.valueOffset..<deviceTree.startIndex + location.valueOffset + 4,
                    with: replacement
                )
                deviceTree.writeUInt32LE(8, at: location.lengthFieldOffset)
            }
        }
    }

    /// Points the `pram` node's `reg` property (shipped as `{0, 0}` in
    /// the unpopulated IPSW template — the same placeholder pattern as
    /// the clock properties above, just for a RAM-backed scratch
    /// region rather than a clock value) at a real, backed physical
    /// range within Podium's own guest RAM, so the real kernel's
    /// `check_for_panic_log()` (confirmed against the actual XNU
    /// source, `pexpert/arm/pe_init.c`) can successfully `ml_io_map`
    /// it instead of hitting an unbacked page. Real hardware has iBoot
    /// reserve and populate this region for a persistent panic-log
    /// ring buffer; Podium has no iBoot, so this plays that same,
    /// narrowly-scoped role — reserving real memory, not fabricating
    /// its contents. The kernel's own code tolerates any content: it
    /// checks the region's first word against two known magic values
    /// (`'BTRC'`/`'SHMC'`) and, if neither matches, just logs a
    /// message and `bzero`s the region before continuing — so this
    /// deliberately writes nothing beyond the property patch itself;
    /// Podium's already-zero-initialized RAM is exactly the "no
    /// previous panic" case the real kernel already handles. `reg` is
    /// already exactly 8 bytes in the shipped tree (an `{address,
    /// size}` pair), so this is a plain in-place overwrite — no
    /// length/offset shifting like the 4-to-8-byte clock expansion
    /// needs.
    static func patchPramRegion(_ deviceTree: inout Data, physicalAddress: UInt32, size: UInt32) {
        let locations = findProperties(in: deviceTree, path: ["pram"], propertyNames: ["reg"])
        guard let location = locations.first, location.currentLength == 8 else { return }
        deviceTree.writeUInt32LE(physicalAddress, at: location.valueOffset)
        deviceTree.writeUInt32LE(size, at: location.valueOffset + 4)
    }

    /// Read-only walk collecting every requested property's location
    /// within the target node — nothing here mutates `data`, so the
    /// offsets it returns are all still valid relative to each other
    /// (mutation happens afterward, highest offset first).
    private static func findProperties(in data: Data, path: [String], propertyNames: Set<String>) -> [PropertyLocation] {
        var results: [PropertyLocation] = []
        _ = walk(data, offset: 0, remainingPath: path, propertyNames: propertyNames, results: &results)
        return results
    }

    @discardableResult
    private static func walk(
        _ data: Data, offset: Int, remainingPath: [String], propertyNames: Set<String>, results: inout [PropertyLocation]
    ) -> Int? {
        guard offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        let nChildren = Int(data.readUInt32LE(at: offset + 4))
        var cursor = offset + nodeHeaderSize

        var nodeName: String?
        var localMatches: [PropertyLocation] = []
        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let lengthFieldOffset = cursor + propertyNameSize
            let rawLength = data.readUInt32LE(at: lengthFieldOffset)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            let valueOffset = cursor + propertyHeaderSize

            if name == "name", nodeName == nil {
                let valueBytes = data[data.startIndex + valueOffset..<data.startIndex + valueOffset + realLength]
                nodeName = String(decoding: valueBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if remainingPath.isEmpty, propertyNames.contains(name) {
                localMatches.append(PropertyLocation(name: name, lengthFieldOffset: lengthFieldOffset, valueOffset: valueOffset, currentLength: realLength))
            }
            cursor = valueOffset + ((realLength + 3) & ~3)
        }

        if remainingPath.isEmpty {
            results.append(contentsOf: localMatches)
            return cursor
        }

        guard let firstSegment = remainingPath.first else { return cursor }
        for _ in 0..<nChildren {
            let childOffset = cursor
            guard cursor + nodeHeaderSize <= data.count else { return nil }
            let childName = peekName(data, offset: childOffset)
            if childName == firstSegment {
                guard let end = walk(data, offset: childOffset, remainingPath: Array(remainingPath.dropFirst()), propertyNames: propertyNames, results: &results) else { return nil }
                cursor = end
            } else {
                guard let end = skipNode(data, offset: childOffset) else { return nil }
                cursor = end
            }
        }
        return cursor
    }

    private static func peekName(_ data: Data, offset: Int) -> String? {
        guard offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        var cursor = offset + nodeHeaderSize
        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let rawLength = data.readUInt32LE(at: cursor + propertyNameSize)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            let valueOffset = cursor + propertyHeaderSize
            if name == "name" {
                let valueBytes = data[data.startIndex + valueOffset..<data.startIndex + valueOffset + realLength]
                return String(decoding: valueBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            cursor = valueOffset + ((realLength + 3) & ~3)
        }
        return nil
    }

    private static func skipNode(_ data: Data, offset: Int) -> Int? {
        guard offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        let nChildren = Int(data.readUInt32LE(at: offset + 4))
        var cursor = offset + nodeHeaderSize
        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let rawLength = data.readUInt32LE(at: cursor + propertyNameSize)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            cursor = cursor + propertyHeaderSize + ((realLength + 3) & ~3)
        }
        for _ in 0..<nChildren {
            guard let end = skipNode(data, offset: cursor) else { return nil }
            cursor = end
        }
        return cursor
    }
}
