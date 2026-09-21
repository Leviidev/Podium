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

    func testPatchesOnlyTheSixNamedFrequencyPropertiesUnderCpusCpu0() {
        var tree = makeSyntheticDeviceTree()
        let guestBase: UInt32 = 0x8100_0000

        DeviceTreePatcher.patchClockPlaceholders(&tree, guestBaseAddress: guestBase)

        let frequencyNames = ["bus-frequency", "peripheral-frequency", "memory-frequency", "timebase-frequency", "clock-frequency", "fixed-frequency"]
        for name in frequencyNames {
            guard let offset = valueOffset(of: name, in: tree) else {
                return XCTFail("Could not locate \(name) in the patched tree")
            }
            let value = tree.readUInt32LE(at: offset)
            XCTAssertEqual(value, guestBase &+ UInt32(offset), "\(name) should self-reference its own address")
        }

        // The unrelated property (not in the patch list) must be untouched.
        guard let unrelatedOffset = valueOffset(of: "unrelated-4byte-prop", in: tree) else {
            return XCTFail("Could not locate unrelated-4byte-prop in the patched tree")
        }
        XCTAssertEqual(tree.readUInt32LE(at: unrelatedOffset), 0, "unrelated-4byte-prop must be left alone")
    }

    func testLeavesTreeSizeUnchanged() {
        var tree = makeSyntheticDeviceTree()
        let originalSize = tree.count
        DeviceTreePatcher.patchClockPlaceholders(&tree, guestBaseAddress: 0x8100_0000)
        XCTAssertEqual(tree.count, originalSize, "patching values in place must never resize the tree")
    }
}
