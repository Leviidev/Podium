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

    private func addressSpace(childCount: Int, children: Data) -> Data {
        node(
            propertiesData: [
                property("#address-cells", value: words([1])),
                property("#size-cells", value: words([1])),
            ],
            childCount: childCount, children: children
        )
    }

    private func words(_ values: [UInt32]) -> Data {
        var data = Data(count: values.count * 4)
        for (index, value) in values.enumerated() { data.writeUInt32LE(value, at: index * 4) }
        return data
    }

    func testInventoryRetainsNodePathAndDeviceTreeProperties() {
        let wifi = node(
            propertiesData: [
                property("name", value: Data("wifi".utf8) + Data([0])),
                property("compatible", value: Data("brcm,bcm4329\0apple,bcm4329\0".utf8)),
                property("reg", value: regValue([(0x3f410000, 0x1000)])),
                property("interrupts", value: regValue([(0x2a, 1)])),
            ],
            childCount: 0, children: Data()
        )
        let armIO = node(
            propertiesData: [property("name", value: Data("arm-io".utf8) + Data([0]))],
            childCount: 1, children: wifi
        )
        let tree = node(propertiesData: [], childCount: 1, children: armIO)

        let nodes = DeviceTreeMemoryMap.nodes(in: tree)
        let wifiNode = nodes.first { $0.path == "/arm-io/wifi" }

        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(wifiNode?.compatibleIdentifiers, ["brcm,bcm4329", "apple,bcm4329"])
        XCTAssertEqual(wifiNode?.regions, [DeviceTreeMemoryMap.Region(address: 0x3f410000, size: 0x1000)])
        XCTAssertEqual(wifiNode?.interruptCells, [0x2a, 1])
    }

    func testTruncatedTreeDoesNotReturnPartialInventory() {
        var tree = Data(count: 8)
        tree.writeUInt32LE(1, at: 0) // one property with no property bytes

        XCTAssertTrue(DeviceTreeMemoryMap.nodes(in: tree).isEmpty)
    }

    func testReferenceFirmwareWiFiDiscoveryArtifacts() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ipswURL = projectRoot.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")
        guard FileManager.default.fileExists(atPath: ipswURL.path) else {
            throw XCTSkip("Local reference IPSW is not available; this inventory check is opt-in.")
        }

        let parsed = try IPSWParser.parse(fileURL: ipswURL)
        let firmware = ImportedFirmware(
            id: UUID(), metadata: parsed.metadata, compatibility: parsed.compatibility,
            importedAt: Date(), storedFileName: ipswURL.lastPathComponent, isActive: true
        )
        let deviceTree = try DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: ipswURL)
        let nodes = DeviceTreeMemoryMap.nodes(in: deviceTree)
        XCTAssertFalse(nodes.isEmpty, "The reference device tree must parse before peripheral discovery.")

        let sdioNodes = nodes.filter { $0.path == "/arm-io/sdio" || $0.path.hasPrefix("/arm-io/sdio/") }
        let sdioController = try XCTUnwrap(sdioNodes.first { $0.path == "/arm-io/sdio" }, "Reference device tree must declare its A4 SDIO controller.")
        XCTAssertTrue(sdioController.compatibleIdentifiers.contains("sdio,s5l8930x"))
        XCTAssertEqual(sdioController.interruptCells.first, 38, "The SDIO host interrupt line is declared by the reference firmware.")
        for required in ["reg", "interrupt-parent", "dma-parent", "dma-channels", "vendor-id", "function-device_reset", "clock-gates", "clock-ids", "local-mac-address"] {
            XCTAssertNotNil(sdioController.properties[required], "Reference SDIO configuration must provide \(required).")
        }
        XCTAssertEqual(sdioController.regions.first?.address, 0, "SDIO register address is child-relative; its parent's ranges map it into physical space.")
        XCTAssertEqual(sdioController.regions.first?.size, 0x1000)
        XCTAssertEqual(DeviceTreeMemoryMap.physicalRegions(for: sdioController, in: nodes).first?.address, 0x8000_0000)
        XCTAssertEqual(DeviceTreeMemoryMap.physicalRegions(for: sdioController, in: nodes).first?.size, 0x1000)
        let interruptController = try XCTUnwrap(sdioController.interruptParent.flatMap { DeviceTreeMemoryMap.node(referencedBy: $0, in: nodes) })
        let dmaController = try XCTUnwrap(sdioController.dmaParent.flatMap { DeviceTreeMemoryMap.node(referencedBy: $0, in: nodes) })
        XCTAssertEqual(interruptController.path, "/arm-io/vic")
        XCTAssertTrue(interruptController.compatibleIdentifiers.contains("vic,pl192"))
        XCTAssertEqual(dmaController.path, "/arm-io/cdma")
        XCTAssertEqual(sdioController.dmaChannels, [3, 0x8000_0020, 0x0008_0004, 0])
        let kernel = try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: ipswURL)
        let kernelMarkers = [
            "AppleBCMWLANCore", "AppleBCMWLANBusInterface", "IO80211Controller",
            "sdiodrv_sendCommand", "sdiodrv_performDMA", "wifi-fw-path", "wifi-nvram-path",
        ]
        for marker in kernelMarkers {
            XCTAssertNotNil(kernel.range(of: Data(marker.utf8)), "Reference kernel lacks expected SDIO/WLAN driver marker: \(marker)")
        }

        let rootFSURL = ipswURL.deletingLastPathComponent().appendingPathComponent("iPod4,1_6.1.6_10B500_Restore.rootfs.hfs")
        guard FileManager.default.fileExists(atPath: rootFSURL.path) else {
            throw XCTSkip("Extracted reference root filesystem is unavailable; SDIO/kernel checks passed.")
        }
        let volume = try HFSPlusVolume(source: FileVolumeSource(url: rootFSURL))
        let rootFS = try RootFilesystemBuilder(volume: volume)
        let firmwarePath = "/usr/share/firmware/wifi/4329b1/loco.bin"
        let firmwareImage = try rootFS.contents(of: firmwarePath)
        XCTAssertFalse(firmwareImage.isEmpty, "Reference BCM4329 firmware must be stored in the extracted iOS root filesystem.")
    }

    func testCollectsRegPropertiesAndTheirAliasedAddress() {
        let child = node(
            propertiesData: [
                property("name", value: Data("wdt".utf8) + Data([0])),
                property("reg", value: regValue([(0x3f102020, 0x10)])),
            ],
            childCount: 0, children: Data()
        )
        let tree = addressSpace(childCount: 1, children: child)

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
        let tree = addressSpace(childCount: 1, children: child)

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
                property("reg", value: regValue([(0x4000_1000, 4)])),
            ],
            childCount: 0, children: Data()
        )
        var children = Data()
        children.append(placeholder)
        children.append(inRam)
        let tree = addressSpace(childCount: 2, children: children)

        let regions = DeviceTreeMemoryMap.peripheralRegions(in: tree, excluding: 0x4000_0000..<0x8000_0000)

        XCTAssertTrue(regions.isEmpty)
    }

    func testTranslatesArmIOBusRangesAndAvoidsLowSRAMAlias() {
        let sdio = node(
            propertiesData: [
                property("name", value: Data("sdio".utf8) + Data([0])),
                property("reg", value: regValue([(0, 0x1000)])),
                property("interrupt-parent", value: words([0x1234])),
                property("dma-parent", value: words([0x5678])),
            ],
            childCount: 0, children: Data()
        )
        let vic = node(
            propertiesData: [
                property("name", value: Data("vic".utf8) + Data([0])),
                property("compatible", value: Data("vic,pl192\0".utf8)),
                property("AAPL,phandle", value: words([0x1234])),
            ],
            childCount: 0, children: Data()
        )
        let cdma = node(
            propertiesData: [
                property("name", value: Data("cdma".utf8) + Data([0])),
                property("AAPL,phandle", value: words([0x5678])),
            ],
            childCount: 0, children: Data()
        )
        var armIOChildren = Data()
        armIOChildren.append(sdio)
        armIOChildren.append(vic)
        armIOChildren.append(cdma)
        let armIO = node(
            propertiesData: [
                property("name", value: Data("arm-io".utf8) + Data([0])),
                property("#address-cells", value: words([1])),
                property("#size-cells", value: words([1])),
                property("ranges", value: words([0, 0x8000_0000, 0x4000_0000])),
            ],
            childCount: 3, children: armIOChildren
        )
        let tree = node(
            propertiesData: [
                property("#address-cells", value: words([1])),
                property("#size-cells", value: words([1])),
            ],
            childCount: 1, children: armIO
        )
        let inventory = DeviceTreeMemoryMap.nodes(in: tree)
        guard let controller = inventory.first(where: { $0.path == "/arm-io/sdio" }) else {
            XCTFail("Expected the SDIO controller node")
            return
        }

        XCTAssertEqual(DeviceTreeMemoryMap.physicalRegions(for: controller, in: inventory), [
            DeviceTreeMemoryMap.Region(address: 0x8000_0000, size: 0x1000),
        ])
        XCTAssertEqual(controller.interruptParent.flatMap { DeviceTreeMemoryMap.node(referencedBy: $0, in: inventory) }?.path, "/arm-io/vic")
        XCTAssertEqual(controller.dmaParent.flatMap { DeviceTreeMemoryMap.node(referencedBy: $0, in: inventory) }?.path, "/arm-io/cdma")
        XCTAssertEqual(DeviceTreeMemoryMap.peripheralRegions(
            in: tree,
            excluding: 0x4000_0000..<0x8000_0000,
            alsoExcluding: [0..<0x0010_0000]
        ), [DeviceTreeMemoryMap.Region(address: 0x8000_0000, size: 0x1000)])
    }
}
