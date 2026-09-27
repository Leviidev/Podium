import Foundation

/// Edits an HFS+ volume's catalog in memory — removing items, replacing
/// file contents, adding files — then writes the result as a new, packed
/// volume with `HFSPlusVolumeWriter`.
///
/// Records are kept byte for byte (ownership, modes, dates, hard-link
/// chains, flags), so everything not edited comes through unchanged; only
/// where each fork lives is new.
final class RootFilesystemBuilder {
    private let volume: HFSPlusVolume
    private var records: [HFSPlusCatalogRecord]
    private var removed = Set<Int>()
    private var indexByID: [UInt32: Int] = [:]
    private var childrenByParent: [UInt32: [Int]] = [:]
    private var attributes: [HFSPlusAttributeRecord]
    private var replacedContent: [UInt32: [UInt8]] = [:]
    /// Compressed files whose contents were replaced: their decmpfs
    /// attribute and resource fork are dropped.
    private var decompressed = Set<UInt32>()
    private var nextCatalogID: UInt32

    init(volume: HFSPlusVolume) throws {
        self.volume = volume
        records = try volume.catalogRecords()
        attributes = try volume.attributeRecords()
        nextCatalogID = volume.header.nextCatalogID
        for (index, record) in records.enumerated() where record.isFolder || record.isFile {
            indexByID[record.catalogNodeID] = index
            childrenByParent[record.parentID, default: []].append(index)
        }
        guard indexByID[HFSPlusVolume.rootFolderID] != nil else { throw HFSPlusError.corrupt("no root folder") }
    }

    var fileCount: Int { records.indices.filter { !removed.contains($0) && records[$0].isFile }.count }

    // MARK: Lookup

    static func components(_ path: String) -> [[UInt16]] {
        path.split(separator: "/").map { Array(String($0).utf16) }
    }

    func index(of path: String) -> Int? {
        var current = HFSPlusVolume.rootFolderID
        var found: Int? = indexByID[current]
        for component in Self.components(path) {
            guard let match = (childrenByParent[current] ?? []).first(where: { !removed.contains($0) && records[$0].name == component }) else { return nil }
            found = match
            current = records[match].catalogNodeID
        }
        return found
    }

    func children(of path: String) throws -> [(name: String, index: Int)] {
        guard let folder = index(of: path), records[folder].isFolder else { throw HFSPlusError.missingPath(path) }
        return (childrenByParent[records[folder].catalogNodeID] ?? []).filter { !removed.contains($0) }
            .map { (String(decoding: records[$0].name, as: UTF16.self), $0) }
    }

    func contents(of path: String) throws -> [UInt8] {
        guard let index = index(of: path), records[index].isFile else { throw HFSPlusError.missingPath(path) }
        let record = records[index]
        let id = record.catalogNodeID
        if let replaced = replacedContent[id] { return replaced }
        if record.isCompressed, let header = decmpfsAttribute(of: id) {
            return try Decmpfs.decompress(attribute: header) {
                try volume.readWholeFork(record.resourceFork, fileID: id, forkType: 0xFF)
            }
        }
        return try volume.readWholeFork(record.dataFork, fileID: id, forkType: 0)
    }

    private func decmpfsAttribute(of fileID: UInt32) -> [UInt8]? {
        let name = Array(Decmpfs.attributeName.utf16)
        return attributes.first { $0.fileID == fileID && $0.name == name }?.inlineData
    }

    // MARK: Edits

    /// Removes an item (a folder with everything in it). Missing paths
    /// are ignored, as `rm -rf` would.
    func remove(_ path: String) throws {
        guard let index = index(of: path) else { return }
        try remove(index: index)
    }

    /// Removes the children of a folder whose names match `pattern` (an
    /// `fnmatch` glob), except those in `keeping`.
    func removeChildren(of path: String, matching pattern: String = "*", keeping: Set<String> = []) throws {
        for child in try children(of: path) where !keeping.contains(child.name) && fnmatch(pattern, child.name, 0) == 0 {
            try remove(index: child.index)
        }
    }

    /// Replaces a file's contents, stored uncompressed.
    func replaceContents(of path: String, with bytes: [UInt8]) throws {
        guard let index = index(of: path), records[index].isFile, !records[index].isHardLink else { throw HFSPlusError.missingPath(path) }
        let id = records[index].catalogNodeID
        if records[index].isCompressed {
            records[index].isCompressed = false
            decompressed.insert(id)
            let decmpfsName = Array(Decmpfs.attributeName.utf16)
            if !attributes.contains(where: { $0.fileID == id && $0.name != decmpfsName }) {
                records[index].flags &= ~HFSPlusCatalogRecord.hasAttributesFlag
            }
        }
        replacedContent[id] = bytes
    }

    /// Rewrites a property list file, keeping its format (binary or XML).
    func editPropertyList(_ path: String, _ edit: (NSMutableDictionary) -> Void) throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let original = try contents(of: path)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(original), options: .mutableContainersAndLeaves, format: &format) as? NSMutableDictionary else {
            throw HFSPlusError.corrupt("\(path) isn't a dictionary property list")
        }
        edit(plist)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try replaceContents(of: path, with: [UInt8](data))
    }

    /// Adds (or replaces) a file, copying ownership, mode and dates from
    /// `template` — an existing file — unless `mode` overrides the
    /// permission bits.
    func addFile(_ path: String, contents: [UInt8], template templatePath: String, mode: UInt16? = nil) throws {
        if index(of: path) != nil {
            try replaceContents(of: path, with: contents)
            return
        }
        var parts = Self.components(path)
        let name = parts.removeLast()
        let parentPath = "/" + parts.map { String(decoding: $0, as: UTF16.self) }.joined(separator: "/")
        guard let parent = index(of: parentPath), records[parent].isFolder else { throw HFSPlusError.missingPath(parentPath) }
        guard let templateIndex = index(of: templatePath), records[templateIndex].isFile, !records[templateIndex].isHardLink else {
            throw HFSPlusError.missingPath(templatePath)
        }
        let id = nextCatalogID
        nextCatalogID += 1
        var data = records[templateIndex].data
        data.putBE16(0x0002, at: 2) // thread record exists; no attributes, no link chain
        data.putBE32(id, at: 8)
        data[40] = 0 // adminFlags
        data[41] = 0 // ownerFlags: not compressed
        if let mode { data.putBE16((data.be16(42) & 0xF000) | (mode & 0x0FFF), at: 42) }
        data.putBE32(0, at: 44) // bsdInfo.special
        for offset in 48..<80 { data[offset] = 0 } // Finder info
        let record = HFSPlusCatalogRecord(parentID: records[parent].catalogNodeID, name: name, data: data)
        records.append(record)
        let newIndex = records.count - 1
        indexByID[id] = newIndex
        childrenByParent[record.parentID, default: []].append(newIndex)
        records[parent].valence += 1
        replacedContent[id] = contents
    }

    private func remove(index: Int) throws {
        let record = records[index]
        guard record.catalogNodeID != HFSPlusVolume.rootFolderID else { throw HFSPlusError.unsupported("removing the root folder") }
        guard !record.isHardLink else { throw HFSPlusError.unsupported("removing hard link \(String(decoding: record.name, as: UTF16.self))") }
        removeSubtree(index)
        if let parent = indexByID[record.parentID] {
            records[parent].valence -= 1
            if record.isFolder, records[parent].flags & HFSPlusCatalogRecord.hasFolderCountFlag != 0 {
                records[parent].folderCount -= 1
            }
        }
    }

    private func removeSubtree(_ index: Int) {
        removed.insert(index)
        let id = records[index].catalogNodeID
        if records[index].isFolder {
            for child in childrenByParent[id] ?? [] where !removed.contains(child) { removeSubtree(child) }
        }
    }

    // MARK: Output

    /// Writes the edited volume, unjournaled, with `freeSpace` bytes free.
    func write(to url: URL, freeSpace: UInt64, progress: (HFSPlusVolumeWriter.Progress) -> Void = { _ in }) throws {
        var removedIDs = Set<UInt32>()
        var catalog: [HFSPlusCatalogRecord] = []
        var content: [UInt32: (data: HFSPlusForkContent?, resource: HFSPlusForkContent?)] = [:]
        for index in records.indices where !records[index].isThread {
            if removed.contains(index) { removedIDs.insert(records[index].catalogNodeID); continue }
            let record = records[index]
            catalog.append(record)
            catalog.append(HFSPlusCatalogRecord.thread(for: record))
            guard record.isFile else { continue }
            let id = record.catalogNodeID
            let data: HFSPlusForkContent? = replacedContent[id].map { .bytes($0) }
                ?? (record.dataFork.logicalSize > 0 ? .sourceFork(record.dataFork, fileID: id, forkType: 0) : nil)
            let resource: HFSPlusForkContent? = record.resourceFork.logicalSize > 0 && !decompressed.contains(id)
                ? .sourceFork(record.resourceFork, fileID: id, forkType: 0xFF) : nil
            content[id] = (data, resource)
        }
        catalog.sort(by: HFSPlusCatalogRecord.areInIncreasingOrder)
        let decmpfsName = Array(Decmpfs.attributeName.utf16)
        let keptAttributes = attributes.filter {
            !removedIDs.contains($0.fileID) && !(decompressed.contains($0.fileID) && $0.name == decmpfsName)
        }
        if let external = keptAttributes.first(where: { $0.recordType != HFSPlusAttributeRecord.inlineDataType }) {
            throw HFSPlusError.unsupported(String(format: "extended attribute stored out of line (type 0x%x) on file %u", external.recordType, external.fileID))
        }
        try HFSPlusVolumeWriter(copyingParametersOf: volume).write(
            catalog: catalog,
            attributes: keptAttributes.sorted(by: HFSPlusAttributeRecord.areInIncreasingOrder),
            content: content,
            nextCatalogID: nextCatalogID,
            freeSpace: freeSpace,
            to: url,
            progress: progress
        )
    }
}

/// The changes Podium makes to iOS 6.1.6's root filesystem so it can boot
/// from a RAM disk in the emulator — the same set `prepare_rootfs.sh`
/// applies on a Mac.
enum RootFilesystemRecipe {
    /// Bumped whenever the edits change, so prepared images are rebuilt.
    static let version = 1
    /// Room left for the guest to write into (logs, caches, preferences).
    static let freeSpace: UInt64 = 64 << 20

    static func apply(to builder: RootFilesystemBuilder, keybagBootstrap: [UInt8]) throws {
        // The volume is rebuilt unjournaled; its old journal is just space.
        try builder.remove("/.journal")
        try builder.remove("/.journal_info_block")

        // Trim assets the lock screen never touches, so the image leaves
        // room in the guest's 1 GB of RAM.
        try builder.removeChildren(of: "/private/var/mobile/Library/PreinstalledAssets")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/VoiceServices.framework/TTSResources")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/VoiceServices.framework/RecognitionResources")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/SportsWorkout.framework/voices")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/CoreHandwriting.framework/CDModel-bin")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/FaceCoreLight.framework", matching: "*.dat")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/GeoServices.framework", matching: "*.shieldpack")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/GeoServices.framework", matching: "*.shieldindex")
        for font in ["HiraginoKakuGothicProNW3.otf", "HiraginoKakuGothicProNW6.otf", "HiraginoMinchoProNW3.otf", "HiraginoMinchoProNW6.otf",
                     "STHeiti-Light.ttc", "STHeiti-Medium.ttc", "AppleSDGothicNeoBold.otf", "AppleSDGothicNeoMedium.otf", "AppleGothic.otf"] {
            try builder.remove("/System/Library/Fonts/Cache/" + font)
        }
        try builder.removeChildren(of: "/System/Library/TextInput", keeping: ["TextInput_en.bundle", "TextInput_emoji.bundle"])
        try builder.removeChildren(of: "/System/Library/LinguisticData", keeping: ["en", "Latn"])
        try builder.remove("/usr/standalone/update/ramdisk/H3SURamDisk.dmg")
        for path in ["/usr/share/mecabra/zh", "/usr/share/mecabra/ja", "/usr/share/tokenizer/ja", "/usr/share/tokenizer/zh"] {
            try builder.remove(path)
        }
        try builder.remove("/System/Library/Frameworks/GameKit.framework/GameKit@2x.artwork")
        try builder.remove("/System/Library/Frameworks/GameKit.framework/GameKit@2x~iphone.artwork")
        try builder.removeChildren(of: "/System/Library/PrivateFrameworks/DataDetectorsCore.framework", matching: "*asia*")

        // Root on the RAM disk, read-write.
        try builder.replaceContents(of: "/private/etc/fstab", with: Array("/dev/md0 / hfs rw 0 1\n".utf8))

        // There's no SGX GPU: CoreAnimation's window server only tries an
        // OpenGL ES context while CA_ENABLE_OGL isn't 0, and retries on
        // every frame when that fails — each try a long SGX driver
        // timeout in the kernel — before drawing in software.
        // CA_NO_ACCEL keeps CoreGraphics off the IOSurface accelerator.
        try builder.editPropertyList("/System/Library/LaunchDaemons/com.apple.backboardd.plist") { plist in
            let environment = (plist["EnvironmentVariables"] as? NSMutableDictionary) ?? NSMutableDictionary()
            environment["CA_NO_ACCEL"] = "1"
            environment["CA_ENABLE_OGL"] = "0"
            plist["EnvironmentVariables"] = environment
        }

        // keybagd reboots into recovery without a system keybag, which only
        // a restore creates; keybag_bootstrap creates it the way a restore
        // does, then execs keybagd.
        try builder.addFile("/usr/libexec/keybag_bootstrap", contents: keybagBootstrap, template: "/usr/libexec/keybagd", mode: 0o755)
        try builder.editPropertyList("/System/Library/LaunchDaemons/com.apple.mobile.keybagd.plist") { plist in
            plist["ProgramArguments"] = ["/usr/libexec/keybag_bootstrap", "/usr/libexec/keybagd", "-t", "15"]
        }

        // First-boot state a restored device already has: data migration
        // done for this build, and Setup Assistant's own markers.
        let preferences = "/private/var/mobile/Library/Preferences/"
        let template = preferences + ".GlobalPreferences.plist"
        try builder.addFile(preferences + "com.apple.backboardd.plist",
                            contents: try binaryPlist(["BKDataMigratorLastSystemVersion": "10B500"]), template: template)
        try builder.addFile(preferences + "com.apple.purplebuddy.plist",
                            contents: try binaryPlist(["SetupDone": true, "SetupFinishedAllSteps": true, "SetupVersion": 6]), template: template)
        try builder.addFile(preferences + "com.apple.keyboard.plist",
                            contents: try binaryPlist(["BuddySetupDone": true]), template: template)
    }

    private static func binaryPlist(_ dictionary: [String: Any]) throws -> [UInt8] {
        [UInt8](try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0))
    }
}
