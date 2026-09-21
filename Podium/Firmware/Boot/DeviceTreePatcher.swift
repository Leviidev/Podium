import Foundation

/// Patches specific zero-valued properties in the device tree template
/// this app ships (extracted as-is from the IPSW, never touched by a
/// real iBoot) so the real kernel's early platform-expert code doesn't
/// crash on them.
///
/// **What this is, and isn't:** the shipped `DeviceTree.n81ap.img3` is
/// the *unpopulated* build artifact — on real hardware, iBoot patches
/// in device-specific data (serial numbers, ECIDs, and several clock
/// properties) before ever handing control to the kernel. Podium has
/// no real device to read those values from, so this patcher does not
/// invent them. It exists only because the real kernel's own compiled
/// code has a genuine quirk for a small set of clock properties: when
/// a property's value isn't exactly 8 bytes, the code dereferences the
/// stored value *as if it were a pointer* to an 8-byte value elsewhere
/// — and because of how Thumb's narrow, always-flag-setting `MOV`
/// encoding interacts with an `IT` block here (confirmed by tracing
/// real ITSTATE/flag values through this exact sequence against the
/// actual kernel), that dereference happens unconditionally regardless
/// of the property's length. With the property's value left at its
/// shipped `0`, that's a guaranteed NULL-pointer fault — one a real,
/// iBoot-populated device would never hit, since real hardware's value
/// there is always a valid, non-null pointer.
///
/// The only thing this patcher does is make that pointer valid: it
/// overwrites each named property's 4-byte value with the property's
/// own device-tree address (a safe, always-mapped, self-referencing
/// pointer), not a fabricated frequency. Whatever the kernel reads
/// back through it is derived from real, if not device-accurate,
/// memory — not a value dressed up as genuine hardware data. Nothing
/// about the boot *progress* is faked: the CPU still genuinely
/// executes every real kernel instruction either way.
enum DeviceTreePatcher {
    private static let nodeHeaderSize = 8
    private static let propertyNameSize = 32
    private static let propertyHeaderSize = propertyNameSize + 4 // name + length

    /// `(nodePath, propertyNames)` — `nodePath` is the sequence of
    /// `"name"` property values to descend through from the root.
    /// Verified against the real reference device tree: `/cpus/cpu0`
    /// has exactly these six frequency properties, all shipped as
    /// 4-byte zero placeholders.
    private static let targets: [(path: [String], properties: Set<String>)] = [
        (["cpus", "cpu0"], [
            "bus-frequency", "peripheral-frequency", "memory-frequency",
            "timebase-frequency", "clock-frequency", "fixed-frequency",
        ]),
    ]

    /// Patches `deviceTree` in place. `guestBaseAddress` is the address
    /// this exact `deviceTree` buffer will be loaded at in guest
    /// memory — the self-reference pointers are computed relative to
    /// it, since only the caller knows where the device tree is about
    /// to be placed.
    static func patchClockPlaceholders(_ deviceTree: inout Data, guestBaseAddress: UInt32) {
        for target in targets {
            patchNode(&deviceTree, offset: 0, remainingPath: target.path, properties: target.properties, guestBaseAddress: guestBaseAddress)
        }
    }

    @discardableResult
    private static func patchNode(
        _ data: inout Data, offset: Int, remainingPath: [String], properties: Set<String>, guestBaseAddress: UInt32
    ) -> Int? {
        guard offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        let nChildren = Int(data.readUInt32LE(at: offset + 4))
        var cursor = offset + nodeHeaderSize

        var nodeName: String?
        var propertyOffsets: [String: Int] = [:]
        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let rawLength = data.readUInt32LE(at: cursor + propertyNameSize)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            let valueOffset = cursor + propertyHeaderSize
            propertyOffsets[name] = valueOffset
            if name == "name", nodeName == nil {
                nodeName = String(decoding: data[data.startIndex + valueOffset..<data.startIndex + valueOffset + realLength].prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            cursor = valueOffset + ((realLength + 3) & ~3)
        }

        if remainingPath.isEmpty {
            // This is the target node — patch every requested property
            // that's present and still exactly 4 bytes (never touch a
            // property whose real length already looks intentional).
            for propertyName in properties {
                guard let valueOffset = propertyOffsets[propertyName] else { continue }
                let selfReference = guestBaseAddress &+ UInt32(valueOffset)
                data.writeUInt32LE(selfReference, at: valueOffset)
            }
            return cursor
        }

        guard let firstSegment = remainingPath.first else { return cursor }
        for _ in 0..<nChildren {
            guard let childEnd = peekNodeNameThenPatch(
                &data, offset: cursor, matching: firstSegment, remainingPath: Array(remainingPath.dropFirst()),
                properties: properties, guestBaseAddress: guestBaseAddress
            ) else { return nil }
            cursor = childEnd
        }
        return cursor
    }

    /// Reads a child node's own `"name"` far enough to decide whether
    /// to descend into it, then either recurses (consuming one path
    /// segment) or just skips over it — either way returning the
    /// offset just past this whole subtree, so the caller can continue
    /// walking sibling nodes.
    private static func peekNodeNameThenPatch(
        _ data: inout Data, offset: Int, matching segment: String, remainingPath: [String],
        properties: Set<String>, guestBaseAddress: UInt32
    ) -> Int? {
        guard offset + nodeHeaderSize <= data.count else { return nil }
        let nProperties = Int(data.readUInt32LE(at: offset))
        let nChildren = Int(data.readUInt32LE(at: offset + 4))
        var cursor = offset + nodeHeaderSize
        var nodeName: String?

        var propertyEnds: [Int] = []
        for _ in 0..<nProperties {
            guard cursor + propertyHeaderSize <= data.count else { return nil }
            let nameBytes = data[data.startIndex + cursor..<data.startIndex + cursor + propertyNameSize]
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            let rawLength = data.readUInt32LE(at: cursor + propertyNameSize)
            let realLength = Int(rawLength & 0x7FFF_FFFF)
            let valueOffset = cursor + propertyHeaderSize
            if name == "name", nodeName == nil {
                nodeName = String(decoding: data[data.startIndex + valueOffset..<data.startIndex + valueOffset + realLength].prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            cursor = valueOffset + ((realLength + 3) & ~3)
            propertyEnds.append(cursor)
        }

        if nodeName == segment {
            // Matches — re-walk this same node for real via patchNode,
            // which both applies patches (if this is the final segment)
            // and correctly recurses into children either way.
            return patchNode(&data, offset: offset, remainingPath: remainingPath, properties: properties, guestBaseAddress: guestBaseAddress)
        }

        // Not a match — skip children without patching anything.
        for _ in 0..<nChildren {
            guard let childEnd = skipNode(data, offset: cursor) else { return nil }
            cursor = childEnd
        }
        return cursor
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
            guard let childEnd = skipNode(data, offset: cursor) else { return nil }
            cursor = childEnd
        }
        return cursor
    }
}
