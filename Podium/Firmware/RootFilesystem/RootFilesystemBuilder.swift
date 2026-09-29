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
    /// Stores a compressed file's contents plainly. Hard links and files
    /// that aren't compressed (or aren't there) are left as they are.
    func storeUncompressed(_ path: String) throws {
        guard let index = index(of: path), records[index].isFile, records[index].isCompressed, !records[index].isHardLink else { return }
        try replaceContents(of: path, with: try contents(of: path))
    }

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
        insert(HFSPlusCatalogRecord(parentID: records[parent].catalogNodeID, name: name, data: data), parent: parent)
        replacedContent[id] = contents
    }

    /// Adds a folder (or updates an existing one's ownership and mode),
    /// its record modeled on its parent's.
    func addFolder(_ path: String, owner: UInt32, group: UInt32, mode: UInt16) throws {
        if let existing = index(of: path) {
            guard records[existing].isFolder else { throw HFSPlusError.unsupported("\(path) exists and isn't a folder") }
            setOwnership(existing, owner: owner, group: group, mode: mode)
            return
        }
        let (parent, name) = try parentAndName(of: path)
        let id = nextCatalogID
        nextCatalogID += 1
        var data = records[parent].data
        data.putBE32(0, at: 4) // valence
        data.putBE32(id, at: 8)
        data.putBE32(0, at: 84) // folderCount
        data.putBE16(data.be16(2) & HFSPlusCatalogRecord.hasFolderCountFlag, at: 2)
        for offset in 48..<80 { data[offset] = 0 } // Finder info
        insert(HFSPlusCatalogRecord(parentID: records[parent].catalogNodeID, name: name, data: data), parent: parent)
        setOwnership(records.count - 1, owner: owner, group: group, mode: mode)
    }

    /// Adds (or replaces) a file with explicit ownership and mode.
    func addFile(_ path: String, contents: [UInt8], owner: UInt32, group: UInt32, mode: UInt16, template templatePath: String) throws {
        try addFile(path, contents: contents, template: templatePath)
        guard let index = index(of: path) else { throw HFSPlusError.missingPath(path) }
        setOwnership(index, owner: owner, group: group, mode: mode)
    }

    /// Adds a symbolic link: an HFS+ file of type 'slnk'/'rhap' whose data
    /// fork is the target path.
    func addSymbolicLink(_ path: String, target: String, owner: UInt32, group: UInt32, template templatePath: String) throws {
        try addFile(path, contents: Array(target.utf8), template: templatePath)
        guard let index = index(of: path) else { throw HFSPlusError.missingPath(path) }
        records[index].data.putBE32(0x736C_6E6B, at: 48) // 'slnk'
        records[index].data.putBE32(0x7268_6170, at: 52) // 'rhap'
        setOwnership(index, owner: owner, group: group, mode: 0o120755)
    }

    private func setOwnership(_ index: Int, owner: UInt32, group: UInt32, mode: UInt16) {
        records[index].data.putBE32(owner, at: 32)
        records[index].data.putBE32(group, at: 36)
        let type = records[index].isFolder ? 0o040000 : (mode & 0o170000 != 0 ? mode & 0o170000 : 0o100000)
        records[index].data.putBE16(UInt16(type) | (mode & 0o7777), at: 42)
    }

    private func parentAndName(of path: String) throws -> (parent: Int, name: [UInt16]) {
        var parts = Self.components(path)
        let name = parts.removeLast()
        let parentPath = "/" + parts.map { String(decoding: $0, as: UTF16.self) }.joined(separator: "/")
        guard let parent = index(of: parentPath), records[parent].isFolder else { throw HFSPlusError.missingPath(parentPath) }
        return (parent, name)
    }

    private func insert(_ record: HFSPlusCatalogRecord, parent: Int) {
        records.append(record)
        let newIndex = records.count - 1
        indexByID[record.catalogNodeID] = newIndex
        childrenByParent[record.parentID, default: []].append(newIndex)
        records[parent].valence += 1
        if record.isFolder, records[parent].flags & HFSPlusCatalogRecord.hasFolderCountFlag != 0 {
            records[parent].folderCount += 1
        }
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
    static let version = 11
    /// Room left for the guest to write into (logs, caches, preferences).
    static let freeSpace: UInt64 = 64 << 20

    static func apply(to builder: RootFilesystemBuilder, keybagBootstrap: [UInt8], firstBootState: Data? = nil, bootReadFiles: [String] = []) throws {
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

        // Root on the RAM disk, read-write. (No content protection: see
        // GuestAccommodations.)
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
        // done for this build, and Setup Assistant finished. Setup can't
        // finish here — it activates the device with Apple — so this is
        // what it records when it does: `SetupDone`, and `SetupVersion` 3
        // (Preferences.framework's PSSetupAssistantNeedsToRun runs it
        // again below that). They're read both per host
        // (kCFPreferencesCurrentHost, which CoreFoundation files under
        // ByHost — PSSetupAssistantNeedsToRun) and for any host
        // (CFPreferencesGetAppBooleanValue), so both files are written.
        let preferences = "/private/var/mobile/Library/Preferences/"
        let template = preferences + ".GlobalPreferences.plist"
        try builder.addFile(preferences + "com.apple.backboardd.plist",
                            contents: try binaryPlist(["BKDataMigratorLastSystemVersion": "10B500"]), template: template)
        let setupDone = try binaryPlist(["SetupDone": true, "SetupFinishedAllSteps": true, "SetupVersion": 3])
        try builder.addFile(preferences + "com.apple.purplebuddy.plist", contents: setupDone, template: template)
        try builder.addFolder(preferences + "ByHost", owner: 501, group: 501, mode: 0o755)
        try builder.addFile(preferences + "ByHost/com.apple.purplebuddy.plist", contents: setupDone, template: template)
        try builder.addFile(preferences + "com.apple.keyboard.plist",
                            contents: try binaryPlist(["BuddySetupDone": true]), template: template)

        try applyHactivation(to: builder)

        if let firstBootState { try applyFirstBootState(firstBootState, to: builder) }

        // Grouped table views — Settings and most other lists — fill their
        // background with UITableViewTexture.png, 16 by 2 pixels. With no
        // GPU, CoreAnimation draws a pattern one image-sized tile at a
        // time, each a quad through its whole software renderer: some
        // 17,000 for one screen, nearly all the work of a frame while
        // Settings scrolls. The same stripes tiled out to a screenful look
        // the same (the pattern is drawn pixel for pixel, and a screen is
        // a whole number of periods) and draw as one tile.
        try UIKitArtwork.tile(image: "UITableViewTexture.png", in: "/System/Library/Frameworks/UIKit.framework/Shared@2x.artwork",
                              toWidth: 640, height: 960, builder: builder)

        // The files the guest reads while it boots, stored uncompressed.
        // Nearly every file here is HFS-compressed (decmpfs), and the
        // kernel inflates whatever it reads — every page of the ICU data,
        // every exec of dyld, daemons' binaries, /etc — which was a tenth
        // of all the instructions a boot ran. The list (measured by
        // logging the kernel's decmpfs reads across a boot) costs ~43 MB
        // of the RAM disk and takes away nearly all of that.
        for path in bootReadFiles { try builder.storeUncompressed(path) }
    }

    /// First boot's one-time work, done ahead of time: what a first boot
    /// of this very image leaves in /private/var — the system keybag, the
    /// keychain holding lockdownd's activation identity (a 1024-bit RSA
    /// key pair whose generation was most of a first boot's instructions),
    /// lockdownd's records, and every cache and database first boot builds
    /// (LaunchServices', SpringBoard's rendered images and icons, the
    /// apps' databases). A power-on here starts from the image every time,
    /// so without this every boot would be a first boot. It was captured
    /// by booting in the emulator until well past the lock screen (see
    /// GuestTools/first_boot_capture); the keybag and keychain are sealed
    /// with the emulated A4's stand-in UID key, which is the same on every
    /// run, so they open here too.
    ///
    /// A binary property list: an array of `path`, `kind` (folder, file,
    /// symlink), `mode`, `uid`, `gid`, and `data` or `target`, parents
    /// before children.
    static func applyFirstBootState(_ plist: Data, to builder: RootFilesystemBuilder) throws {
        guard let entries = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [[String: Any]] else {
            throw HFSPlusError.corrupt("first-boot state isn't an array of entries")
        }
        let template = "/private/var/mobile/Library/Preferences/.GlobalPreferences.plist"
        for entry in entries {
            guard let path = entry["path"] as? String, let kind = entry["kind"] as? String,
                  let mode = entry["mode"] as? Int, let uid = entry["uid"] as? Int, let gid = entry["gid"] as? Int else { continue }
            switch kind {
            case "folder":
                try builder.addFolder(path, owner: UInt32(uid), group: UInt32(gid), mode: UInt16(mode))
            case "file":
                try builder.addFile(path, contents: [UInt8](entry["data"] as? Data ?? Data()), owner: UInt32(uid), group: UInt32(gid),
                                    mode: UInt16(mode), template: template)
            case "symlink":
                try builder.addSymbolicLink(path, target: entry["target"] as? String ?? "", owner: UInt32(uid), group: UInt32(gid), template: template)
            default:
                continue
            }
        }
    }

    /// Activation. A restored iOS 6 device is unactivated until Apple's
    /// activation server signs a record for its hardware identity, and
    /// until then lockdownd reports it bricked and SpringBoard runs Setup
    /// to activate it — a virtual iPod has no identity Apple would sign.
    /// lockdownd has its own way past this for devices that shouldn't be
    /// activated ("hactivation"): when MobileGestalt's ShouldHactivate
    /// answer is true it reports the device Activated without a record
    /// (dealwith_activation: "Short circuiting activation state to
    /// Activated."). That answer comes from a per-model table in which
    /// every retail model, the iPod touch 4 included, says no. So this
    /// changes the one instruction in lockdownd's device-type setup that
    /// takes the answer (`mov r2, r0` after MGGetBoolAnswer("ShouldHactivate"),
    /// stored as the flag) to `movs r2, #1`, and recomputes the changed
    /// page's hash in lockdownd's (ad-hoc) signature so the kernel keeps
    /// it valid — lockdownd needs its entitlements for the keychain.
    static let lockdowndShouldHactivate = (offset: 0x1_BD40, original: [0x00, 0xF0, 0xE8, 0xF8, 0x02, 0x46, 0x49, 0xF6] as [UInt8],
                                           patched: [0x00, 0xF0, 0xE8, 0xF8, 0x01, 0x22, 0x49, 0xF6] as [UInt8])

    static func applyHactivation(to builder: RootFilesystemBuilder) throws {
        let path = "/usr/libexec/lockdownd"
        var lockdownd = try builder.contents(of: path)
        let site = lockdowndShouldHactivate
        guard lockdownd.count > site.offset + 8, Array(lockdownd[site.offset..<site.offset + 8]) == site.original else {
            throw HFSPlusError.corrupt("lockdownd isn't the 10B500 build this expects")
        }
        lockdownd.replaceSubrange(site.offset..<site.offset + 8, with: site.patched)
        try CodeDirectory.updatePageHashes(&lockdownd)
        try builder.replaceContents(of: path, with: lockdownd)
    }

    /// A file list resource: one path per line; `#` starts a comment.
    static func fileList(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func binaryPlist(_ dictionary: [String: Any]) throws -> [UInt8] {
        [UInt8](try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0))
    }
}
