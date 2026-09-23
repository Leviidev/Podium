import XCTest
@testable import Podium

final class DeviceTreePatcherTests: XCTestCase {
    /// Builds a minimal synthetic Apple DeviceTree binary matching the
    /// real reference tree's shape closely enough to exercise the
    /// patcher: root -> cpus -> cpu0, with cpu0 holding a `name`
    /// property plus the six frequency properties as 4-byte zeros.
    private func makeSyntheticDeviceTree() -> Data {
        func property(_ name: String, value: Data) -> Data {
            var data = Data(count: 32)
            data.replaceSubrange(0..<name.utf8.count, with: Array(name.utf8))
            var lengthBytes = Data(count: 4)
            lengthBytes.writeUInt32LE(UInt32(value.count), at: 0)
            data.append(lengthBytes)
            data.append(value)
            let padding = (4 - (value.count % 4)) % 4
            data.append(Data(repeating: 0, count: padding))
            return data
        }
        func node(propertiesData: [Data], childCount: Int, children: Data) -> Data {
            var header = Data(count: 8)
            header.writeUInt32LE(UInt32(propertiesData.count), at: 0)
            header.writeUInt32LE(UInt32(childCount), at: 4)
            for p in propertiesData { header.append(p) }
            header.append(children)
            return header
        }

        let zero4 = Data(repeating: 0, count: 4)
        let cpu0Properties = [
            property("name", value: Data("cpu0".utf8) + Data([0])),
            property("bus-frequency", value: zero4),
            property("peripheral-frequency", value: zero4),
            property("memory-frequency", value: zero4),
            property("timebase-frequency", value: zero4),
            property("clock-frequency", value: zero4),
            property("fixed-frequency", value: zero4),
            property("unrelated-4byte-prop", value: zero4),
        ]
        let cpu0 = node(propertiesData: cpu0Properties, childCount: 0, children: Data())

        let cpusProperties = [property("name", value: Data("cpus".utf8) + Data([0]))]
        let cpus = node(propertiesData: cpusProperties, childCount: 1, children: cpu0)

        let root = node(propertiesData: [], childCount: 1, children: cpus)
        return root
    }

    /// Finds a property's value offset by searching for its 32-byte
    /// name field directly in the raw bytes — independent of
    /// `DeviceTreePatcher`'s own traversal, so this test can't just be
    /// checking the patcher's math against itself.
    private func valueOffset(of propertyName: String, in tree: Data) -> Int? {
        var nameField = Data(count: 32)
        nameField.replaceSubrange(0..<propertyName.utf8.count, with: Array(propertyName.utf8))
        guard let range = tree.range(of: nameField) else { return nil }
        return range.lowerBound - tree.startIndex + 32 + 4
    }

    func testExpandsTheSixNamedFrequencyPropertiesUnderCpusCpu0To8Bytes() {
        var tree = makeSyntheticDeviceTree()
        DeviceTreePatcher.patchClockPlaceholders(&tree)

        let expected: [String: UInt64] = [
            "bus-frequency": 200_000_000,
            "peripheral-frequency": 100_000_000,
            "memory-frequency": 200_000_000,
            "timebase-frequency": 24_000_000,
            "clock-frequency": 800_000_000,
            "fixed-frequency": 24_000_000,
        ]
        for (name, expectedValue) in expected {
            guard let offset = valueOffset(of: name, in: tree) else {
                return XCTFail("Could not locate \(name) in the patched tree")
            }
            XCTAssertEqual(tree.readUInt32LE(at: offset - 4), 8, "\(name)'s length field should now be 8")
            let low = UInt64(tree.readUInt32LE(at: offset))
            let high = UInt64(tree.readUInt32LE(at: offset + 4))
            XCTAssertEqual(low | (high << 32), expectedValue, "\(name) should hold its real/zero-extended 64-bit value")
        }

        // The unrelated property (not in the patch list) must be untouched.
        guard let unrelatedOffset = valueOffset(of: "unrelated-4byte-prop", in: tree) else {
            return XCTFail("Could not locate unrelated-4byte-prop in the patched tree")
        }
        XCTAssertEqual(tree.readUInt32LE(at: unrelatedOffset - 4), 4, "unrelated-4byte-prop's length must stay 4")
        XCTAssertEqual(tree.readUInt32LE(at: unrelatedOffset), 0, "unrelated-4byte-prop's value must stay untouched")
    }

    func testGrowsTreeByExactlyFourBytesPerExpandedProperty() {
        var tree = makeSyntheticDeviceTree()
        let originalSize = tree.count
        DeviceTreePatcher.patchClockPlaceholders(&tree)
        // Six properties, each growing from a 4-byte value to an
        // 8-byte one: +4 bytes apiece, nothing else changes size.
        XCTAssertEqual(tree.count, originalSize + 6 * 4)
    }

    func testIsIdempotent() {
        var tree = makeSyntheticDeviceTree()
        DeviceTreePatcher.patchClockPlaceholders(&tree)
        let onceSize = tree.count
        // A second pass must not find any more 4-byte placeholders to
        // expand (they're all 8 bytes now), so nothing should change.
        DeviceTreePatcher.patchClockPlaceholders(&tree)
        XCTAssertEqual(tree.count, onceSize)
    }

    /// Builds a minimal synthetic tree with a top-level `pram` node
    /// holding an 8-byte, zeroed `reg` property — matching the real
    /// reference tree's shipped-as-placeholder shape.
    private func makeSyntheticDeviceTreeWithPram() -> Data {
        func property(_ name: String, value: Data) -> Data {
            var data = Data(count: 32)
            data.replaceSubrange(0..<name.utf8.count, with: Array(name.utf8))
            var lengthBytes = Data(count: 4)
            lengthBytes.writeUInt32LE(UInt32(value.count), at: 0)
            data.append(lengthBytes)
            data.append(value)
            let padding = (4 - (value.count % 4)) % 4
            data.append(Data(repeating: 0, count: padding))
            return data
        }
        func node(propertiesData: [Data], childCount: Int, children: Data) -> Data {
            var header = Data(count: 8)
            header.writeUInt32LE(UInt32(propertiesData.count), at: 0)
            header.writeUInt32LE(UInt32(childCount), at: 4)
            for p in propertiesData { header.append(p) }
            header.append(children)
            return header
        }

        let pramProperties = [
            property("name", value: Data("pram".utf8) + Data([0])),
            property("reg", value: Data(count: 8)),
        ]
        let pram = node(propertiesData: pramProperties, childCount: 0, children: Data())
        return node(propertiesData: [], childCount: 1, children: pram)
    }

    func testPatchPramRegionOverwritesRegValueInPlace() {
        var tree = makeSyntheticDeviceTreeWithPram()
        let originalSize = tree.count
        DeviceTreePatcher.patchPramRegion(&tree, physicalAddress: 0x8100_0000, size: 0x1000)

        // In-place overwrite: no length/offset change at all.
        XCTAssertEqual(tree.count, originalSize)

        var nameField = Data(count: 32)
        nameField.replaceSubrange(0..<"reg".utf8.count, with: Array("reg".utf8))
        guard let range = tree.range(of: nameField) else {
            return XCTFail("Could not locate reg property in the patched tree")
        }
        let valueOffset = range.lowerBound - tree.startIndex + 32 + 4
        XCTAssertEqual(tree.readUInt32LE(at: valueOffset), 0x8100_0000)
        XCTAssertEqual(tree.readUInt32LE(at: valueOffset + 4), 0x1000)
    }

    /// Walks the generated image the way the kernel's
    /// `IODTNVRAM::initNVRAMImage` does (advance by each header's length,
    /// in 16-byte units) — it must terminate, find `common` first and the
    /// free partition after it, with valid header checksums. An all-zero
    /// image (the shipped template) never advances.
    func testNVRAMImageParsesLikeIODTNVRAM() {
        let size = 0x2000
        let image = DeviceTreePatcher.nvramImage(size: size, variables: [("auto-boot", "true"), ("boot-args", "debug=0x8")])
        var offset = 0
        var names: [String] = []
        var steps = 0
        while offset < size {
            steps += 1
            XCTAssertLessThan(steps, 16, "partition walk must terminate")
            if steps >= 16 { break }
            let units = Int(image[offset + 2]) | Int(image[offset + 3]) << 8
            XCTAssertGreaterThan(units, 0)
            var header = image[offset..<offset + 16]
            let storedChecksum = header[header.startIndex + 1]
            header[header.startIndex + 1] = 0
            XCTAssertEqual(DeviceTreePatcher.partitionChecksum(header), storedChecksum)
            names.append(String(decoding: image[offset + 4..<offset + 16].prefix(while: { $0 != 0 }), as: UTF8.self))
            offset += units * 16
        }
        XCTAssertEqual(offset, size)
        XCTAssertEqual(names, ["common", "wwwwwwwwwwww"])
        let common = String(decoding: image[16..<64], as: UTF8.self)
        XCTAssertTrue(common.hasPrefix("auto-boot=true\0boot-args=debug=0x8\0"))
    }

    /// `addProperty` appends to the right node, after its existing
    /// properties and before its children, and bumps the node's count.
    func testAddRAMDiskAppendsToMemoryMap() {
        func property(_ name: String, value: Data) -> Data {
            var data = Data(count: 32)
            data.replaceSubrange(0..<name.utf8.count, with: Array(name.utf8))
            var length = Data(count: 4)
            length.writeUInt32LE(UInt32(value.count), at: 0)
            return data + length + value + Data(count: (4 - value.count % 4) % 4)
        }
        func node(_ properties: [Data], children: [Data]) -> Data {
            var header = Data(count: 8)
            header.writeUInt32LE(UInt32(properties.count), at: 0)
            header.writeUInt32LE(UInt32(children.count), at: 4)
            return header + properties.reduce(Data(), +) + children.reduce(Data(), +)
        }
        let memoryMap = node([property("name", value: Data("memory-map\u{0}".utf8))], children: [])
        let chosen = node([property("name", value: Data("chosen\u{0}".utf8))], children: [memoryMap])
        let after = node([property("name", value: Data("after\u{0}".utf8))], children: [])
        var tree = node([], children: [chosen, after])
        let originalCount = tree.count

        DeviceTreePatcher.addRAMDisk(&tree, physicalAddress: 0x4100_0000, size: 0x2000_0000)

        XCTAssertEqual(tree.count, originalCount + 32 + 4 + 8)
        guard let offset = valueOffset(of: "RAMDisk", in: tree) else { return XCTFail("no RAMDisk property") }
        XCTAssertEqual(tree.readUInt32LE(at: offset), 0x4100_0000)
        XCTAssertEqual(tree.readUInt32LE(at: offset + 4), 0x2000_0000)
        XCTAssertEqual(tree.readUInt32LE(at: offset - 4), 8, "length field")
        // memory-map's header: now two properties.
        let memoryMapOffset = tree.range(of: Data("memory-map".utf8))!.lowerBound - tree.startIndex - 36 - 8
        XCTAssertEqual(tree.readUInt32LE(at: memoryMapOffset), 2)
        XCTAssertNotNil(tree.range(of: Data("after".utf8)), "the node after is intact")
        XCTAssertGreaterThan(tree.range(of: Data("after".utf8))!.lowerBound, tree.startIndex + offset)
    }
}
