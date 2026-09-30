import Foundation

/// Random access to the bytes of a volume (a disk image's partition, or
/// a plain file), by byte offset from the volume's start.
protocol VolumeByteSource {
    func readBytes(_ count: Int, at offset: UInt64) throws -> [UInt8]
}

enum HFSPlusError: Error, CustomStringConvertible {
    case notHFSPlus
    case corrupt(String)
    case unsupported(String)
    case missingPath(String)

    var description: String {
        switch self {
        case .notHFSPlus: return "not an HFS+ volume"
        case .corrupt(let what): return "corrupt HFS+ volume: \(what)"
        case .unsupported(let what): return "unsupported HFS+ feature: \(what)"
        case .missingPath(let path): return "no such path in the volume: \(path)"
        }
    }
}

extension Array where Element == UInt8 {
    func be16(_ offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
    func be32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
    func be64(_ offset: Int) -> UInt64 { UInt64(be32(offset)) << 32 | UInt64(be32(offset + 4)) }
    mutating func putBE16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value >> 8); self[offset + 1] = UInt8(value & 0xFF)
    }
    mutating func putBE32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((value >> (24 - 8 * UInt32(i))) & 0xFF) }
    }
    mutating func putBE64(_ value: UInt64, at offset: Int) {
        putBE32(UInt32(value >> 32), at: offset); putBE32(UInt32(value & 0xFFFF_FFFF), at: offset + 4)
    }
    mutating func appendBE16(_ value: UInt16) { append(UInt8(value >> 8)); append(UInt8(value & 0xFF)) }
    mutating func appendBE32(_ value: UInt32) { appendBE16(UInt16(value >> 16)); appendBE16(UInt16(value & 0xFFFF)) }
}

/// An HFS+ extent descriptor: a run of allocation blocks.
struct HFSPlusExtent: Equatable {
    var startBlock: UInt32
    var blockCount: UInt32
}

/// `HFSPlusForkData`: a fork's size and its first eight extents (80 bytes
/// on disk).
struct HFSPlusForkData: Equatable {
    static let byteCount = 80
    var logicalSize: UInt64 = 0
    var clumpSize: UInt32 = 0
    var totalBlocks: UInt32 = 0
    var extents: [HFSPlusExtent] = Array(repeating: HFSPlusExtent(startBlock: 0, blockCount: 0), count: 8)

    init() {}

    init(bytes: [UInt8], at offset: Int) {
        logicalSize = bytes.be64(offset)
        clumpSize = bytes.be32(offset + 8)
        totalBlocks = bytes.be32(offset + 12)
        extents = (0..<8).map { HFSPlusExtent(startBlock: bytes.be32(offset + 16 + $0 * 8), blockCount: bytes.be32(offset + 20 + $0 * 8)) }
    }

    func write(into bytes: inout [UInt8], at offset: Int) {
        bytes.putBE64(logicalSize, at: offset)
        bytes.putBE32(clumpSize, at: offset + 8)
        bytes.putBE32(totalBlocks, at: offset + 12)
        for (index, extent) in extents.enumerated() {
            bytes.putBE32(extent.startBlock, at: offset + 16 + index * 8)
            bytes.putBE32(extent.blockCount, at: offset + 20 + index * 8)
        }
    }

    /// One contiguous run of `blockCount` blocks at `startBlock`.
    static func contiguous(logicalSize: UInt64, startBlock: UInt32, blockCount: UInt32, clumpSize: UInt32 = 0) -> HFSPlusForkData {
        var fork = HFSPlusForkData()
        fork.logicalSize = logicalSize
        fork.clumpSize = clumpSize
        fork.totalBlocks = blockCount
        if blockCount > 0 { fork.extents[0] = HFSPlusExtent(startBlock: startBlock, blockCount: blockCount) }
        return fork
    }
}

/// The volume header at byte 1024 (TN1150), as raw bytes with accessors
/// for the fields Podium reads or rewrites.
struct HFSPlusVolumeHeader {
    static let offset: UInt64 = 1024
    static let byteCount = 512
    static let signatureHFSPlus: UInt16 = 0x482B // "H+"
    static let signatureHFSX: UInt16 = 0x4858 // "HX"
    static let journaledAttribute: UInt32 = 1 << 13
    static let unmountedAttribute: UInt32 = 1 << 8
    static let inconsistentAttribute: UInt32 = 1 << 11

    var bytes: [UInt8]

    var signature: UInt16 { bytes.be16(0) }
    var attributes: UInt32 { get { bytes.be32(4) } set { bytes.putBE32(newValue, at: 4) } }
    var blockSize: UInt32 { bytes.be32(40) }
    var totalBlocks: UInt32 { bytes.be32(44) }
    var freeBlocks: UInt32 { bytes.be32(48) }
    var nextCatalogID: UInt32 { get { bytes.be32(64) } set { bytes.putBE32(newValue, at: 64) } }
    var modifyDate: UInt32 { bytes.be32(16) }
    var allocationFile: HFSPlusForkData { HFSPlusForkData(bytes: bytes, at: 112) }
    var extentsFile: HFSPlusForkData { HFSPlusForkData(bytes: bytes, at: 192) }
    var catalogFile: HFSPlusForkData { HFSPlusForkData(bytes: bytes, at: 272) }
    var attributesFile: HFSPlusForkData { HFSPlusForkData(bytes: bytes, at: 352) }
}

/// Fixed B-tree header record fields (`BTHeaderRec`).
struct BTreeHeader {
    var treeDepth: UInt16
    var rootNode: UInt32
    var leafRecords: UInt32
    var firstLeafNode: UInt32
    var lastLeafNode: UInt32
    var nodeSize: UInt16
    var maxKeyLength: UInt16
    var totalNodes: UInt32
    var freeNodes: UInt32
    var clumpSize: UInt32
    var btreeType: UInt8
    var keyCompareType: UInt8
    var attributes: UInt32

    init(node: [UInt8]) {
        let o = 14
        treeDepth = node.be16(o)
        rootNode = node.be32(o + 2)
        leafRecords = node.be32(o + 6)
        firstLeafNode = node.be32(o + 10)
        lastLeafNode = node.be32(o + 14)
        nodeSize = node.be16(o + 18)
        maxKeyLength = node.be16(o + 20)
        totalNodes = node.be32(o + 22)
        freeNodes = node.be32(o + 26)
        clumpSize = node.be32(o + 32)
        btreeType = node[o + 36]
        keyCompareType = node[o + 37]
        attributes = node.be32(o + 38)
    }

    init(nodeSize: UInt16, maxKeyLength: UInt16, clumpSize: UInt32, btreeType: UInt8, keyCompareType: UInt8, attributes: UInt32) {
        treeDepth = 0; rootNode = 0; leafRecords = 0; firstLeafNode = 0; lastLeafNode = 0
        self.nodeSize = nodeSize; self.maxKeyLength = maxKeyLength
        totalNodes = 0; freeNodes = 0
        self.clumpSize = clumpSize; self.btreeType = btreeType; self.keyCompareType = keyCompareType; self.attributes = attributes
    }
}

/// One leaf record of a B-tree: its key bytes (including the 2-byte key
/// length) and its data bytes.
struct BTreeRecord {
    var key: [UInt8]
    var data: [UInt8]
}

/// A catalog leaf record, decoded just enough to rebuild the volume. The
/// record's own bytes are kept verbatim; only fork data and folder counts
/// are ever rewritten.
struct HFSPlusCatalogRecord {
    static let folderType: UInt16 = 1
    static let fileType: UInt16 = 2
    static let folderThreadType: UInt16 = 3
    static let fileThreadType: UInt16 = 4
    static let hasAttributesFlag: UInt16 = 0x0004
    static let hasFolderCountFlag: UInt16 = 0x0010
    /// `UF_COMPRESSED` in the BSD owner flags: contents are in the
    /// `com.apple.decmpfs` attribute (and resource fork), not the data fork.
    static let compressedOwnerFlag: UInt8 = 0x20

    var parentID: UInt32
    var name: [UInt16]
    var data: [UInt8]

    var recordType: UInt16 { data.be16(0) }
    var isFolder: Bool { recordType == Self.folderType }
    var isFile: Bool { recordType == Self.fileType }
    var isThread: Bool { recordType == Self.folderThreadType || recordType == Self.fileThreadType }
    /// The item's own CNID (folders and files).
    var catalogNodeID: UInt32 { data.be32(8) }
    /// For thread records: the item's parent and name.
    var threadParentID: UInt32 { data.be32(4) }

    var flags: UInt16 { get { data.be16(2) } set { data.putBE16(newValue, at: 2) } }
    var valence: UInt32 { get { data.be32(4) } set { data.putBE32(newValue, at: 4) } }
    var folderCount: UInt32 { get { data.be32(84) } set { data.putBE32(newValue, at: 84) } }
    var fileMode: UInt16 { data.be16(42) }
    var isCompressed: Bool {
        get { isFile && data[41] & Self.compressedOwnerFlag != 0 }
        set { data[41] = newValue ? data[41] | Self.compressedOwnerFlag : data[41] & ~Self.compressedOwnerFlag }
    }
    var fileType: UInt32 { data.be32(48) }
    var fileCreator: UInt32 { data.be32(52) }
    var dataFork: HFSPlusForkData {
        get { HFSPlusForkData(bytes: data, at: 88) }
        set { newValue.write(into: &data, at: 88) }
    }
    var resourceFork: HFSPlusForkData {
        get { HFSPlusForkData(bytes: data, at: 168) }
        set { newValue.write(into: &data, at: 168) }
    }
    /// A file hard link ('hlnk'/'hfs+'), whose content lives in the
    /// private metadata folder's iNode file.
    var isHardLink: Bool { isFile && fileType == 0x686C_6E6B && fileCreator == 0x6866_732B }

    var key: [UInt8] { Self.key(parentID: parentID, name: name) }

    static func key(parentID: UInt32, name: [UInt16]) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(8 + name.count * 2)
        key.appendBE16(UInt16(6 + name.count * 2))
        key.appendBE32(parentID)
        key.appendBE16(UInt16(name.count))
        for unit in name { key.appendBE16(unit) }
        return key
    }

    /// HFSX binary ordering (`kHFSBinaryCompare`): parent ID, then the
    /// name's UTF-16 code units as unsigned integers.
    static func areInIncreasingOrder(_ a: HFSPlusCatalogRecord, _ b: HFSPlusCatalogRecord) -> Bool {
        if a.parentID != b.parentID { return a.parentID < b.parentID }
        return a.name.lexicographicallyPrecedes(b.name)
    }

    static func thread(for item: HFSPlusCatalogRecord) -> HFSPlusCatalogRecord {
        var data: [UInt8] = []
        data.appendBE16(item.isFolder ? folderThreadType : fileThreadType)
        data.appendBE16(0)
        data.appendBE32(item.parentID)
        data.appendBE16(UInt16(item.name.count))
        for unit in item.name { data.appendBE16(unit) }
        return HFSPlusCatalogRecord(parentID: item.catalogNodeID, name: [], data: data)
    }
}

/// An extended attribute record (attributes B-tree leaf).
struct HFSPlusAttributeRecord {
    static let inlineDataType: UInt32 = 0x10
    var fileID: UInt32
    var startBlock: UInt32
    var name: [UInt16]
    var data: [UInt8]

    var recordType: UInt32 { data.be32(0) }
    /// An inline attribute's value.
    var inlineData: [UInt8]? {
        guard recordType == Self.inlineDataType, data.count >= 16 else { return nil }
        let size = Int(data.be32(12))
        return data.count >= 16 + size ? Array(data[16..<16 + size]) : nil
    }

    var key: [UInt8] {
        var key: [UInt8] = []
        key.appendBE16(UInt16(12 + name.count * 2))
        key.appendBE16(0)
        key.appendBE32(fileID)
        key.appendBE32(startBlock)
        key.appendBE16(UInt16(name.count))
        for unit in name { key.appendBE16(unit) }
        return key
    }

    static func areInIncreasingOrder(_ a: HFSPlusAttributeRecord, _ b: HFSPlusAttributeRecord) -> Bool {
        if a.fileID != b.fileID { return a.fileID < b.fileID }
        if a.name != b.name { return a.name.lexicographicallyPrecedes(b.name) }
        return a.startBlock < b.startBlock
    }
}

/// Reads an HFS+/HFSX volume: its header, catalog and attributes, and
/// file contents.
final class HFSPlusVolume {
    static let rootFolderID: UInt32 = 2

    let source: VolumeByteSource
    let header: HFSPlusVolumeHeader
    let blockSize: Int
    private var overflowExtents: [UInt64: [HFSPlusExtent]] = [:] // (fileID << 8 | forkType) -> extents past the first eight

    init(source: VolumeByteSource) throws {
        self.source = source
        header = HFSPlusVolumeHeader(bytes: try source.readBytes(HFSPlusVolumeHeader.byteCount, at: HFSPlusVolumeHeader.offset))
        guard header.signature == HFSPlusVolumeHeader.signatureHFSPlus || header.signature == HFSPlusVolumeHeader.signatureHFSX else {
            throw HFSPlusError.notHFSPlus
        }
        blockSize = Int(header.blockSize)
        guard blockSize >= 512, blockSize & (blockSize - 1) == 0 else { throw HFSPlusError.corrupt("block size \(blockSize)") }
        for record in try leafRecords(ofSpecialFork: header.extentsFile, fileID: 3) {
            // HFSPlusExtentKey: keyLength, forkType, pad, fileID, startBlock.
            let forkType = UInt64(record.key[2])
            let fileID = UInt64(record.key.be32(4))
            let extents = (0..<8).map { HFSPlusExtent(startBlock: record.data.be32($0 * 8), blockCount: record.data.be32($0 * 8 + 4)) }
            overflowExtents[fileID << 8 | forkType, default: []].append(contentsOf: extents.filter { $0.blockCount > 0 })
        }
    }

    // MARK: Forks

    /// Every extent of a fork, in file order, including any recorded in
    /// the extents overflow file.
    func extents(of fork: HFSPlusForkData, fileID: UInt32, forkType: UInt8) -> [HFSPlusExtent] {
        var extents = fork.extents.filter { $0.blockCount > 0 }
        let inline = extents.reduce(UInt32(0)) { $0 + $1.blockCount }
        if inline < fork.totalBlocks {
            extents += overflowExtents[UInt64(fileID) << 8 | UInt64(forkType)] ?? []
        }
        return extents
    }

    /// Streams a fork's contents, `logicalSize` bytes, in pieces of at
    /// most `chunkBlocks` blocks.
    func readFork(_ fork: HFSPlusForkData, fileID: UInt32, forkType: UInt8, chunkBlocks: Int = 256, _ body: ([UInt8]) throws -> Void) throws {
        var remaining = fork.logicalSize
        for extent in extents(of: fork, fileID: fileID, forkType: forkType) {
            var block = UInt64(extent.startBlock)
            var left = UInt64(extent.blockCount)
            while left > 0, remaining > 0 {
                let blocks = min(left, UInt64(chunkBlocks))
                let bytes = min(blocks * UInt64(blockSize), remaining)
                try body(try source.readBytes(Int(bytes), at: block * UInt64(blockSize)))
                remaining -= bytes
                block += blocks
                left -= blocks
            }
        }
        guard remaining == 0 else { throw HFSPlusError.corrupt("fork of file \(fileID) is shorter than its logical size") }
    }

    func readWholeFork(_ fork: HFSPlusForkData, fileID: UInt32, forkType: UInt8) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Int(fork.logicalSize))
        try readFork(fork, fileID: fileID, forkType: forkType) { out += $0 }
        return out
    }

    // MARK: B-trees

    func btreeHeader(of fork: HFSPlusForkData, fileID: UInt32) throws -> BTreeHeader? {
        guard fork.logicalSize > 0 else { return nil }
        let first = try readForkRange(fork, fileID: fileID, offset: 0, count: 512)
        let nodeSize = Int(first.be16(14 + 18))
        return BTreeHeader(node: try readForkRange(fork, fileID: fileID, offset: 0, count: nodeSize))
    }

    /// Every leaf record of a B-tree stored in a special file, in key
    /// order (following the leaf chain from `firstLeafNode`).
    func leafRecords(ofSpecialFork fork: HFSPlusForkData, fileID: UInt32) throws -> [BTreeRecord] {
        guard let header = try btreeHeader(of: fork, fileID: fileID), header.firstLeafNode != 0 else { return [] }
        let nodeSize = Int(header.nodeSize)
        var records: [BTreeRecord] = []
        var nodeNumber = header.firstLeafNode
        var visited = 0
        while nodeNumber != 0 {
            visited += 1
            guard visited <= header.totalNodes else { throw HFSPlusError.corrupt("leaf chain loops") }
            let node = try readForkRange(fork, fileID: fileID, offset: UInt64(nodeNumber) * UInt64(nodeSize), count: nodeSize)
            guard Int8(bitPattern: node[8]) == -1 else { throw HFSPlusError.corrupt("node \(nodeNumber) in the leaf chain isn't a leaf") }
            let count = Int(node.be16(10))
            for index in 0..<count {
                let start = Int(node.be16(nodeSize - 2 * (index + 1)))
                let end = Int(node.be16(nodeSize - 2 * (index + 2)))
                guard start < end, end <= nodeSize - 2 * (count + 1) else { throw HFSPlusError.corrupt("record offsets in node \(nodeNumber)") }
                let keyLength = Int(node.be16(start)) + 2
                let keyEnd = start + keyLength
                guard keyEnd <= end else { throw HFSPlusError.corrupt("key overruns its record in node \(nodeNumber)") }
                records.append(BTreeRecord(key: Array(node[start..<keyEnd]), data: Array(node[keyEnd..<end])))
            }
            nodeNumber = node.be32(0)
        }
        return records
    }

    private func readForkRange(_ fork: HFSPlusForkData, fileID: UInt32, offset: UInt64, count: Int) throws -> [UInt8] {
        // Special files: map the byte range through the fork's extents.
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var logical: UInt64 = 0
        let blockBytes = UInt64(blockSize)
        for extent in extents(of: fork, fileID: fileID, forkType: 0) {
            let length = UInt64(extent.blockCount) * blockBytes
            let wantStart = offset + UInt64(out.count)
            if wantStart < logical + length, out.count < count {
                let within = wantStart - logical
                let take = min(UInt64(count - out.count), length - within)
                out += try source.readBytes(Int(take), at: UInt64(extent.startBlock) * blockBytes + within)
            }
            logical += length
            if out.count == count { break }
        }
        guard out.count == count else { throw HFSPlusError.corrupt("read past the end of special file \(fileID)") }
        return out
    }

    // MARK: Catalog and attributes

    func catalogRecords() throws -> [HFSPlusCatalogRecord] {
        try leafRecords(ofSpecialFork: header.catalogFile, fileID: 4).map { record in
            let nameLength = Int(record.key.be16(6))
            let name = (0..<nameLength).map { record.key.be16(8 + $0 * 2) }
            return HFSPlusCatalogRecord(parentID: record.key.be32(2), name: name, data: record.data)
        }
    }

    func attributeRecords() throws -> [HFSPlusAttributeRecord] {
        try leafRecords(ofSpecialFork: header.attributesFile, fileID: 8).map { record in
            let nameLength = Int(record.key.be16(12))
            let name = (0..<nameLength).map { record.key.be16(14 + $0 * 2) }
            return HFSPlusAttributeRecord(fileID: record.key.be32(4), startBlock: record.key.be32(8), name: name, data: record.data)
        }
    }
}

/// A volume stored as a plain file (a raw HFS+ image).
final class FileVolumeSource: VolumeByteSource {
    private let fileDescriptor: Int32

    init(url: URL) throws {
        fileDescriptor = open(url.path, O_RDONLY)
        guard fileDescriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    deinit { close(fileDescriptor) }

    func readBytes(_ count: Int, at offset: UInt64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = bytes.withUnsafeMutableBytes { pread(fileDescriptor, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            guard n > 0 else { throw HFSPlusError.corrupt("read past the end of the image at \(offset + UInt64(done))") }
            done += n
        }
        return bytes
    }
}
