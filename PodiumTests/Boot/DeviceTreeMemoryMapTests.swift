import XCTest
@testable import Podium

final class DeviceTreeMemoryMapTests: XCTestCase {
    private func property(_ name: String, value: Data) -> Data {
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

    private func node(propertiesData: [Data], childCount: Int, children: Data) -> Data {
        var header = Data(count: 8)
        header.writeUInt32LE(UInt32(propertiesData.count), at: 0)
        header.writeUInt32LE(UInt32(childCount), at: 4)
        for p in propertiesData { header.append(p) }
        header.append(children)
        return header
    }

    private func regValue(_ pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (address, size) in pairs {
            var chunk = Data(count: 8)
            chunk.writeUInt32LE(address, at: 0)
            chunk.writeUInt32LE(size, at: 4)
            data.append(chunk)
        }
        return data
    }

    func testCollectsRegPropertiesAndTheirAliasedAddress() {
        let child = node(
            propertiesData: [
                property("name", value: Data("wdt".utf8) + Data([0])),
                property("reg", value: regValue([(0x3f102020, 0x10)])),
            ],
            childCount: 0, children: Data()
        )
        let tree = node(propertiesData: [], childCount: 1, children: child)

        let regions = DeviceTreeMemoryMap.peripheralRegions(in: tree, excluding: 0x8000_0000..<0x9000_0000)

        XCTAssertTrue(regions.contains(DeviceTreeMemoryMap.Region(address: 0x3f102020, size: 0x10)))
        XCTAssertTrue(regions.contains(DeviceTreeMemoryMap.Region(address: 0xbf102020, size: 0x10)))
        XCTAssertEqual(regions.count, 2)
    }

    func testCollectsMultipleRegPairsFromOneProperty() {
        let child = node(
            propertiesData: [
                property("name", value: Data("pmgr".utf8) + Data([0])),
                property("reg", value: regValue([(0x3f100000, 0x6000), (0x5e00000, 0x1000)])),
            ],
            childCount: 0, children: Data()
        )
        let tree = node(propertiesData: [], childCount: 1, children: child)

        let regions = DeviceTreeMemoryMap.peripheralRegions(in: tree, excluding: 0x8000_0000..<0x9000_0000)

        XCTAssertTrue(regions.contains(DeviceTreeMemoryMap.Region(address: 0x3f100000, size: 0x6000)))
        XCTAssertTrue(regions.contains(DeviceTreeMemoryMap.Region(address: 0x5e00000, size: 0x1000)))
    }

    func testSkipsZeroSizePlaceholdersAndRamRangeAddresses() {
        let placeholder = node(
            propertiesData: [
                property("name", value: Data("pram".utf8) + Data([0])),
                property("reg", value: regValue([(0, 0)])),
            ],
            childCount: 0, children: Data()
        )
        let inRam = node(
            propertiesData: [
                property("name", value: Data("cpu0".utf8) + Data([0])),
                property("reg", value: regValue([(0x8000_1000, 4)])),
            ],
            childCount: 0, children: Data()
        )
        var children = Data()
        children.append(placeholder)
        children.append(inRam)
        let tree = node(propertiesData: [], childCount: 2, children: children)

        let regions = DeviceTreeMemoryMap.peripheralRegions(in: tree, excluding: 0x8000_0000..<0x9000_0000)

        XCTAssertTrue(regions.isEmpty)
    }
}
