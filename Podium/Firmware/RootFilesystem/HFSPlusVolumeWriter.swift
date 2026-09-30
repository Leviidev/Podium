import Foundation

/// Builds an HFS+ B-tree file bottom-up from records already in key
/// order: leaf nodes packed full in order, then index levels over them
/// until one node remains as the root. Node 0 is the header node, whose
/// map record marks every built node used and the rest free.
enum BTreeBuilder {
    static let variableIndexKeysAttribute: UInt32 = 1 << 2
    private static let descriptorSize = 14

    /// Nodes the records need (header node included).
    static func nodesNeeded(for records: [BTreeRecord], nodeSize: Int) -> Int {
        var levelSizes = packedSizes(records.map { $0.key.count + $0.data.count }, nodeSize: nodeSize)
        var total = 1 + levelSizes.count
        var firstKeys = packFirstKeys(records.map(\.key), sizes: levelSizes)
        while levelSizes.count > 1 {
            levelSizes = packedSizes(firstKeys.map { $0.count + 4 }, nodeSize: nodeSize)
            firstKeys = packFirstKeys(firstKeys, sizes: levelSizes)
            total += levelSizes.count
        }
        return total
    }

    /// The largest node count a header node's map record can describe.
    static func mapCapacity(nodeSize: Int) -> Int { (nodeSize - 256) * 8 }

    /// The tree's bytes, `totalNodes * nodeSize` long.
    static func build(records: [BTreeRecord], header template: BTreeHeader, totalNodes: Int) throws -> [UInt8] {
        let nodeSize = Int(template.nodeSize)
        guard totalNodes <= mapCapacity(nodeSize: nodeSize) else {
            throw HFSPlusError.unsupported("B-tree of \(totalNodes) nodes needs map nodes")
        }
        var nodes: [[UInt8]] = [[]] // node 0 filled last
        var header = template
        var levelKeys: [[UInt8]] = []
        var levelNodes: [Int] = []

        // Leaves.
        let leafGroups = group(records.map { ($0.key, $0.key + $0.data) }, nodeSize: nodeSize)
        for (index, group) in leafGroups.enumerated() {
            let number = nodes.count
            nodes.append(node(kind: -1, height: 1, records: group.map(\.1), nodeSize: nodeSize,
                              previous: index > 0 ? number - 1 : 0, next: index < leafGroups.count - 1 ? number + 1 : 0))
            levelKeys.append(group[0].0)
            levelNodes.append(number)
        }
        header.leafRecords = UInt32(records.count)
        header.firstLeafNode = UInt32(levelNodes.first ?? 0)
        header.lastLeafNode = UInt32(levelNodes.last ?? 0)
        var height: UInt8 = 1

        // Index levels.
        if levelNodes.count > 1, template.attributes & variableIndexKeysAttribute == 0 {
            throw HFSPlusError.unsupported("index nodes with fixed-size keys")
        }
        while levelNodes.count > 1 {
            height += 1
            let entries = zip(levelKeys, levelNodes).map { key, child -> ([UInt8], [UInt8]) in
                var record = key
                record.appendBE32(UInt32(child))
                return (key, record)
            }
            let groups = group(entries, nodeSize: nodeSize)
            levelKeys = []
            levelNodes = []
            for (index, group) in groups.enumerated() {
                let number = nodes.count
                nodes.append(node(kind: 0, height: height, records: group.map(\.1), nodeSize: nodeSize,
                                  previous: index > 0 ? number - 1 : 0, next: index < groups.count - 1 ? number + 1 : 0))
                levelKeys.append(group[0].0)
                levelNodes.append(number)
            }
        }
        header.treeDepth = records.isEmpty ? 0 : UInt16(height)
        header.rootNode = UInt32(levelNodes.first ?? 0)
        guard nodes.count <= totalNodes else { throw HFSPlusError.corrupt("B-tree needs \(nodes.count) nodes, given \(totalNodes)") }
        header.totalNodes = UInt32(totalNodes)
        header.freeNodes = UInt32(totalNodes - nodes.count)
        nodes[0] = headerNode(header, usedNodes: nodes.count, nodeSize: nodeSize)

        var bytes = [UInt8](repeating: 0, count: totalNodes * nodeSize)
        for (number, node) in nodes.enumerated() {
            bytes.replaceSubrange(number * nodeSize..<(number + 1) * nodeSize, with: node)
        }
        return bytes
    }

    private static func packedSizes(_ recordSizes: [Int], nodeSize: Int) -> [Int] {
        var groups: [Int] = []
        var used = descriptorSize + 2
        var count = 0
        for size in recordSizes {
            if count > 0, used + size + 2 > nodeSize {
                groups.append(count)
                used = descriptorSize + 2
                count = 0
            }
            used += size + 2
            count += 1
        }
        if count > 0 { groups.append(count) }
        return groups
    }

    private static func packFirstKeys(_ keys: [[UInt8]], sizes: [Int]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var index = 0
        for size in sizes {
            result.append(keys[index])
            index += size
        }
        return result
    }

    private static func group(_ items: [([UInt8], [UInt8])], nodeSize: Int) -> [[([UInt8], [UInt8])]] {
        let sizes = packedSizes(items.map { $0.1.count }, nodeSize: nodeSize)
        var groups: [[([UInt8], [UInt8])]] = []
        var index = 0
        for size in sizes {
            groups.append(Array(items[index..<index + size]))
            index += size
        }
        return groups
    }

    private static func node(kind: Int8, height: UInt8, records: [[UInt8]], nodeSize: Int, previous: Int, next: Int) -> [UInt8] {
        var node = [UInt8](repeating: 0, count: nodeSize)
        node.putBE32(UInt32(next), at: 0)
        node.putBE32(UInt32(previous), at: 4)
        node[8] = UInt8(bitPattern: kind)
        node[9] = height
        node.putBE16(UInt16(records.count), at: 10)
        var offset = descriptorSize
        for (index, record) in records.enumerated() {
            node.replaceSubrange(offset..<offset + record.count, with: record)
            node.putBE16(UInt16(offset), at: nodeSize - 2 * (index + 1))
            offset += record.count
        }
        node.putBE16(UInt16(offset), at: nodeSize - 2 * (records.count + 1))
        return node
    }

    private static func headerNode(_ header: BTreeHeader, usedNodes: Int, nodeSize: Int) -> [UInt8] {
        var node = [UInt8](repeating: 0, count: nodeSize)
        node[8] = 1 // kBTHeaderNode
        node.putBE16(3, at: 10)
        node.putBE16(header.treeDepth, at: 14)
        node.putBE32(header.rootNode, at: 16)
        node.putBE32(header.leafRecords, at: 20)
        node.putBE32(header.firstLeafNode, at: 24)
        node.putBE32(header.lastLeafNode, at: 28)
        node.putBE16(header.nodeSize, at: 32)
        node.putBE16(header.maxKeyLength, at: 34)
        node.putBE32(header.totalNodes, at: 36)
        node.putBE32(header.freeNodes, at: 40)
        node.putBE32(header.clumpSize, at: 46)
        node[50] = header.btreeType
        node[51] = header.keyCompareType
        node.putBE32(header.attributes, at: 52)
        for used in 0..<usedNodes { node[248 + used / 8] |= 0x80 >> UInt8(used % 8) }
        node.putBE16(14, at: nodeSize - 2)
        node.putBE16(120, at: nodeSize - 4)
        node.putBE16(248, at: nodeSize - 6)
        node.putBE16(UInt16(nodeSize - 8), at: nodeSize - 8)
        return node
    }
}

/// Where a fork's new contents come from.
enum HFSPlusForkContent {
    /// A fork of the source volume, copied as is.
    case sourceFork(HFSPlusForkData, fileID: UInt32, forkType: UInt8)
    case bytes([UInt8])
    /// A host file streamed into the rebuilt volume without loading it all into memory.
    case file(URL, length: UInt64)

    var length: UInt64 {
        switch self {
        case .sourceFork(let fork, _, _): return fork.logicalSize
        case .bytes(let bytes): return UInt64(bytes.count)
        case .file(_, let length): return length
        }
    }
}

/// Writes a new HFSX volume: catalog and attributes rebuilt from the given
/// records, every fork packed contiguously, and `freeSpace` bytes left free
/// for the guest to write into. Journaled if given the journal's files.
///
/// Layout: the volume header in block 0; the allocation bitmap, extents
/// overflow, catalog and attributes files; then each file's data and
/// resource forks in catalog order; then free space; and the alternate
/// volume header in the last block.
final class HFSPlusVolumeWriter {
    struct Progress {
        let bytesWritten: UInt64
        let totalBytes: UInt64
    }

    private let sourceVolume: HFSPlusVolume
    private let blockSize: Int

    /// JournalInfoBlock flags: the journal lives in this file system, and
    /// hasn't been set up yet.
    private static let journalInFileSystem: UInt32 = 1 << 0
    private static let journalNeedsInitializing: UInt32 = 1 << 2

    init(copyingParametersOf sourceVolume: HFSPlusVolume) {
        self.sourceVolume = sourceVolume
        blockSize = sourceVolume.blockSize
    }

    /// - Parameter catalog: every catalog record the new volume holds
    ///   (threads included), in key order. File records' fork data is
    ///   replaced with the new layout.
    /// - Parameter content: each file's forks by CNID; files missing here
    ///   get empty forks.
    func write(
        catalog inputCatalog: [HFSPlusCatalogRecord],
        attributes: [HFSPlusAttributeRecord],
        content: [UInt32: (data: HFSPlusForkContent?, resource: HFSPlusForkContent?)],
        nextCatalogID: UInt32,
        freeSpace: UInt64,
        maximumVolumeBytes: UInt64? = nil,
        journalFiles: (infoBlock: UInt32, journal: UInt32)? = nil,
        to url: URL,
        progress: (Progress) -> Void = { _ in }
    ) throws {
        let source = sourceVolume.header
        guard let catalogTemplate = try sourceVolume.btreeHeader(of: source.catalogFile, fileID: 4),
              let extentsTemplate = try sourceVolume.btreeHeader(of: source.extentsFile, fileID: 3) else {
            throw HFSPlusError.corrupt("missing catalog or extents B-tree")
        }
        let attributesTemplate = try sourceVolume.btreeHeader(of: source.attributesFile, fileID: 8)
            ?? BTreeHeader(nodeSize: 8192, maxKeyLength: 266, clumpSize: UInt32(blockSize) * 256, btreeType: 0, keyCompareType: 0,
                           attributes: 0x6) // big keys, variable index keys
        var catalog = inputCatalog
        let bs = UInt64(blockSize)
        func blocks(_ bytes: UInt64) -> UInt64 { (bytes + bs - 1) / bs }

        // B-tree sizes: what the records need, plus room for the guest to
        // grow them (it creates files and attributes from the first boot).
        let catalogNodeSize = Int(catalogTemplate.nodeSize)
        let catalogUsed = BTreeBuilder.nodesNeeded(for: catalog.map { BTreeRecord(key: $0.key, data: $0.data) }, nodeSize: catalogNodeSize)
        let catalogNodes = min(catalogUsed + max(catalogUsed / 4, 1024), BTreeBuilder.mapCapacity(nodeSize: catalogNodeSize))
        let attributeRecords = attributes.map { BTreeRecord(key: $0.key, data: $0.data) }
        let attributesNodeSize = Int(attributesTemplate.nodeSize)
        let attributesUsed = BTreeBuilder.nodesNeeded(for: attributeRecords, nodeSize: attributesNodeSize)
        let attributesNodes = min(attributesUsed + max(attributesUsed / 4, 256), BTreeBuilder.mapCapacity(nodeSize: attributesNodeSize))
        let extentsNodeSize = Int(extentsTemplate.nodeSize)
        let extentsNodes = 128

        let extentsBlocks = blocks(UInt64(extentsNodes * extentsNodeSize))
        let catalogBlocks = blocks(UInt64(catalogNodes * catalogNodeSize))
        let attributesBlocks = blocks(UInt64(attributesNodes * attributesNodeSize))
        var forkBlocks: UInt64 = 0
        for record in catalog where record.isFile {
            let forks = content[record.catalogNodeID]
            forkBlocks += blocks(forks?.data?.length ?? 0) + blocks(forks?.resource?.length ?? 0)
        }
        // The primary volume header starts at byte 1024, so reserve every
        // allocation block that contains it before placing the allocation
        // bitmap or other forks. With 512-byte blocks that is blocks 0...2;
        // otherwise the bitmap can overwrite the header during the write.
        let primaryHeaderBlocks = blocks(HFSPlusVolumeHeader.offset + UInt64(HFSPlusVolumeHeader.byteCount))
        let alternateHeaderBlocks = blocks(1024)
        let occupiedBlocks = primaryHeaderBlocks + extentsBlocks + catalogBlocks + attributesBlocks + forkBlocks + alternateHeaderBlocks
        let minimumFixedBlocks = occupiedBlocks + blocks(freeSpace)
        var minimumAllocationBlocks: UInt64 = 1
        while blocks((minimumFixedBlocks + minimumAllocationBlocks + 7) / 8) > minimumAllocationBlocks {
            minimumAllocationBlocks += 1
        }
        let minimumTotalBlocks = minimumFixedBlocks + minimumAllocationBlocks
        let totalBlocks: UInt64
        let allocationBlocks: UInt64
        if let maximumVolumeBytes {
            let capacityBlocks = maximumVolumeBytes / bs
            guard capacityBlocks >= minimumTotalBlocks else {
                throw HFSPlusError.unsupported("the rebuilt volume exceeds its maximum capacity")
            }
            totalBlocks = capacityBlocks
            let bitmapBytes = (capacityBlocks + 7) / 8
            allocationBlocks = (bitmapBytes + bs - 1) / bs
            let actualFreeBlocks = capacityBlocks - occupiedBlocks - allocationBlocks
            guard actualFreeBlocks >= blocks(freeSpace) else {
                throw HFSPlusError.unsupported("the rebuilt volume cannot retain the requested free space")
            }
        } else {
            totalBlocks = minimumTotalBlocks
            allocationBlocks = minimumAllocationBlocks
        }
        guard totalBlocks <= UInt64(UInt32.max), allocationBlocks <= UInt64(UInt32.max) else {
            throw HFSPlusError.unsupported("volume too large")
        }

        // Assign blocks.
        var bitmap = [UInt8](repeating: 0, count: Int(allocationBlocks * bs))
        func markUsed(_ start: UInt64, _ count: UInt64) {
            for block in start..<start + count { bitmap[Int(block / 8)] |= 0x80 >> UInt8(block % 8) }
        }
        for block in 0..<primaryHeaderBlocks { markUsed(block, 1) }
        var next = primaryHeaderBlocks
        func allocate(_ count: UInt64) -> UInt64 {
            let start = next
            markUsed(start, count)
            next += count
            return start
        }
        let allocationStart = allocate(allocationBlocks)
        let extentsStart = allocate(extentsBlocks)
        let catalogStart = allocate(catalogBlocks)
        let attributesStart = allocate(attributesBlocks)
        var placements: [(start: UInt64, content: HFSPlusForkContent)] = []
        var dataStarts: [UInt32: (start: UInt64, length: UInt64)] = [:]
        var fileCount: UInt32 = 0
        var folderCount: UInt32 = 0
        for index in catalog.indices {
            if catalog[index].isFolder, catalog[index].catalogNodeID != HFSPlusVolume.rootFolderID { folderCount += 1 }
            guard catalog[index].isFile else { continue }
            fileCount += 1
            let forks = content[catalog[index].catalogNodeID]
            for forkType in [UInt8(0), 0xFF] {
                let forkContent = forkType == 0 ? forks?.data : forks?.resource
                let length = forkContent?.length ?? 0
                let count = blocks(length)
                let start = count > 0 ? allocate(count) : 0
                let fork = HFSPlusForkData.contiguous(logicalSize: length, startBlock: UInt32(start), blockCount: UInt32(count))
                if forkType == 0 {
                    catalog[index].dataFork = fork
                    dataStarts[catalog[index].catalogNodeID] = (start, length)
                } else {
                    catalog[index].resourceFork = fork
                }
                if let forkContent, count > 0 { placements.append((start, forkContent)) }
            }
        }
        let nextAllocation = next
        for block in (totalBlocks - alternateHeaderBlocks)..<totalBlocks { markUsed(block, 1) }

        // Metadata.
        let catalogBytes = try BTreeBuilder.build(records: catalog.map { BTreeRecord(key: $0.key, data: $0.data) },
                                                  header: catalogTemplate, totalNodes: catalogNodes)
        let attributesBytes = try BTreeBuilder.build(records: attributeRecords, header: attributesTemplate, totalNodes: attributesNodes)
        let extentsBytes = try BTreeBuilder.build(records: [], header: extentsTemplate, totalNodes: extentsNodes)

        var header = source.bytes
        header.putBE32((source.attributes & ~(HFSPlusVolumeHeader.journaledAttribute | HFSPlusVolumeHeader.inconsistentAttribute))
                       | HFSPlusVolumeHeader.unmountedAttribute, at: 4)
        header.putBE32(0x3130_2E30, at: 8) // lastMountedVersion "10.0"
        header.putBE32(0, at: 12) // journalInfoBlock

        // The journal: its info block says where it is, and that it needs
        // initializing — the kernel makes a fresh, empty journal there when
        // it first mounts the volume, as for a disk just given one.
        if let journalFiles, let info = dataStarts[journalFiles.infoBlock], let journal = dataStarts[journalFiles.journal],
           info.length >= bs, journal.length > 0 {
            var infoBlock = [UInt8](repeating: 0, count: Int(info.length))
            infoBlock.putBE32(Self.journalInFileSystem | Self.journalNeedsInitializing, at: 0)
            infoBlock.putBE64(journal.start * bs, at: 36)
            infoBlock.putBE64(journal.length, at: 44)
            if let placement = placements.firstIndex(where: { $0.start == info.start }) { placements[placement].content = .bytes(infoBlock) }
            header.putBE32(header.be32(4) | HFSPlusVolumeHeader.journaledAttribute, at: 4)
            header.putBE32(0x4846_534A, at: 8) // lastMountedVersion "HFSJ": a journaled volume
            header.putBE32(UInt32(info.start), at: 12)
        }
        header.putBE32(fileCount, at: 32)
        header.putBE32(folderCount, at: 36)
        header.putBE32(UInt32(totalBlocks), at: 44)
        header.putBE32(UInt32(totalBlocks - UInt64(bitmap.popCount(bits: Int(totalBlocks)))), at: 48)
        header.putBE32(UInt32(nextAllocation), at: 52)
        header.putBE32(nextCatalogID, at: 64)
        header.putBE32(source.bytes.be32(68) &+ 1, at: 68) // writeCount
        let clump = UInt32(blockSize)
        HFSPlusForkData.contiguous(logicalSize: allocationBlocks * bs, startBlock: UInt32(allocationStart), blockCount: UInt32(allocationBlocks), clumpSize: clump)
            .write(into: &header, at: 112)
        HFSPlusForkData.contiguous(logicalSize: UInt64(extentsBytes.count), startBlock: UInt32(extentsStart), blockCount: UInt32(extentsBlocks), clumpSize: extentsTemplate.clumpSize)
            .write(into: &header, at: 192)
        HFSPlusForkData.contiguous(logicalSize: UInt64(catalogBytes.count), startBlock: UInt32(catalogStart), blockCount: UInt32(catalogBlocks), clumpSize: catalogTemplate.clumpSize)
            .write(into: &header, at: 272)
        HFSPlusForkData.contiguous(logicalSize: UInt64(attributesBytes.count), startBlock: UInt32(attributesStart), blockCount: UInt32(attributesBlocks), clumpSize: attributesTemplate.clumpSize)
            .write(into: &header, at: 352)
        HFSPlusForkData().write(into: &header, at: 432) // no startup file

        // Write it all out.
        let volumeSize = totalBlocks * bs
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: volumeSize)
        func put(_ bytes: [UInt8], at offset: UInt64) throws {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(bytes))
        }
        try put(header, at: HFSPlusVolumeHeader.offset)
        try put(header, at: volumeSize - 1024)
        try put(bitmap, at: allocationStart * bs)
        try put(extentsBytes, at: extentsStart * bs)
        try put(catalogBytes, at: catalogStart * bs)
        try put(attributesBytes, at: attributesStart * bs)
        let totalForkBytes = placements.reduce(UInt64(0)) { $0 + $1.content.length }
        var written: UInt64 = 0
        var lastReported: UInt64 = 0
        for placement in placements {
            try handle.seek(toOffset: placement.start * bs)
            switch placement.content {
            case .bytes(let bytes):
                try handle.write(contentsOf: Data(bytes))
                written += UInt64(bytes.count)
            case .sourceFork(let fork, let fileID, let forkType):
                try sourceVolume.readFork(fork, fileID: fileID, forkType: forkType) { chunk in
                    try handle.write(contentsOf: Data(chunk))
                    written += UInt64(chunk.count)
                    if written - lastReported >= 8 << 20 {
                        lastReported = written
                        progress(Progress(bytesWritten: written, totalBytes: totalForkBytes))
                    }
                }
            case .file(let sourceURL, let length):
                let source = try FileHandle(forReadingFrom: sourceURL)
                defer { try? source.close() }
                var remaining = length
                while remaining > 0 {
                    let requested = Int(min(remaining, 1 << 20))
                    guard let chunk = try source.read(upToCount: requested), !chunk.isEmpty else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
                    }
                    try handle.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                    written += UInt64(chunk.count)
                    if written - lastReported >= 8 << 20 {
                        lastReported = written
                        progress(Progress(bytesWritten: written, totalBytes: totalForkBytes))
                    }
                }
            }
        }
        progress(Progress(bytesWritten: written, totalBytes: totalForkBytes))
        try handle.synchronize()
    }
}

private extension Array where Element == UInt8 {
    /// Set bits among the first `bits` (MSB-first) bits.
    func popCount(bits: Int) -> Int {
        var count = 0
        for index in 0..<(bits / 8) { count += self[index].nonzeroBitCount }
        for bit in 0..<(bits % 8) where self[bits / 8] & (0x80 >> UInt8(bit)) != 0 { count += 1 }
        return count
    }
}
