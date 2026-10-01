import Compression
import Foundation

/// Installs supported Debian package payloads into the guest HFS+ root.
/// This is not dpkg: maintainer scripts and unsupported control features are rejected.
enum DebianPackageInstaller {
    struct InstalledPackage {
        let name: String
        let version: String
        let files: [String]
        let payloadBytes: UInt64
    }

    enum PackageError: LocalizedError, CustomStringConvertible {
        case invalidArchive(String)
        case unsupported(String)
        case unsafePath(String)
        case duplicatePackage(String)
        case missingDependency(package: String, dependency: String)
        case insufficientPayloadSpace

        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .invalidArchive(let detail): return "Invalid Debian package: \(detail)"
            case .unsupported(let detail): return "This Debian package can't be installed offline: \(detail)"
            case .unsafePath(let path): return "The Debian package contains an unsafe path: \(path)"
            case .duplicatePackage(let name): return "Package \(name) is already installed. Remove it before installing another copy."
            case .missingDependency(let package, let dependency): return "Package \(package) requires \(dependency), which isn't installed or included in this batch."
            case .insufficientPayloadSpace: return "The package payloads don't fit while keeping required free space in the guest volume."
            }
        }}


    private struct Item {
        enum Kind {
            case directory
            case file(URL, UInt64)
            case symlink(String)
        }
        let path: String
        let mode: UInt16
        let owner: UInt32
        let group: UInt32
        let kind: Kind}


    private struct Dependency {
        let name: String
        let relation: String?
        let version: String?}


    private struct Package {
        let name: String
        let version: String
        let architecture: String
        let description: String?
        let dependencies: [[Dependency]]
        let items: [Item]
        let expandedArchiveBytes: Int
        let archiveEntryCount: Int}


    private static func deletingLastPathComponentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "/" }
        return separator == path.startIndex ? "/" : String(path[..<separator])}


    private struct TarResult {
        var files: [String: Data] = [:]
        var items: [Item] = []
        var entryCount = 0}


    private enum ArchiveFormat {
        case tar
        case gzipTar}


    private static let maximumArchiveSize = 256 << 20
    private static let maximumControlSize = 32 << 20
    private static let maximumPayloadSize = 512 << 20
    private static let maximumEntries = 50_000
    private static let maximumPathLength = 1_024
    private static let minimumFreeReserve: UInt64 = 8 << 20

    /// Parses and validates every package before mutating the in-memory volume.
    static func install(_ urls: [URL], into builder: RootFilesystemBuilder, stagingDirectory: URL) throws -> [InstalledPackage] {
        guard !urls.isEmpty else { return [] }
        guard urls.count <= 100 else { throw PackageError.unsupported("install at most 100 packages at once") }
        // iOS commonly exposes /var as a symlink to /private/var. Resolve
        // that expected alias, but never follow a link at the dpkg database
        // itself (or its info/status entries) while creating bookkeeping.
        let dpkg = try builder.resolvedPath("/var/lib/dpkg", resolvingFinalComponent: false)
        let dpkgInfo = dpkg + "/info"
        let statusPath = dpkg + "/status"
        guard ![dpkg, dpkgInfo, statusPath].contains(where: builder.isSymbolicLink(at:)) else {
            throw PackageError.unsupported("the existing dpkg database contains symbolic links")
        }

        var selectedBytes: UInt64 = 0
        for url in urls {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.uint64Value <= UInt64(maximumArchiveSize) else {
                throw PackageError.unsupported("each package must be a regular file no larger than 256 MiB")
            }
            let (next, overflow) = selectedBytes.addingReportingOverflow(size.uint64Value)
            guard !overflow, next <= UInt64(maximumArchiveSize) else {
                throw PackageError.unsupported("selected packages exceed the 256 MiB batch limit")
            }
            selectedBytes = next
        }

        try? FileManager.default.removeItem(at: stagingDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var packages: [Package] = []
        var expandedBytes = 0
        var entryCount = 0
        for (index, url) in urls.enumerated() {
            let stage = stagingDirectory.appendingPathComponent("package-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumArchiveSize else {
                throw PackageError.unsupported("a selected package grew beyond the 256 MiB archive limit")
            }
            let package = try parse(data, staging: stage,
                                   maximumExpandedBytes: maximumPayloadSize - expandedBytes,
                                   maximumEntries: maximumEntries - entryCount)
            let (nextBytes, bytesOverflow) = expandedBytes.addingReportingOverflow(package.expandedArchiveBytes)
            let (nextCount, countOverflow) = entryCount.addingReportingOverflow(package.archiveEntryCount)
            guard !bytesOverflow, nextBytes <= maximumPayloadSize, !countOverflow, nextCount <= maximumEntries else {
                throw PackageError.unsupported("selected packages exceed archive limits")
            }
            expandedBytes = nextBytes
            entryCount = nextCount
            packages.append(package)
        }

        let oldStatus = builder.contains(statusPath) ? String(decoding: try builder.contents(of: statusPath), as: UTF8.self) : ""
        let installed = installedPackages(in: oldStatus)
        var names = Set<String>()
        for package in packages {
            guard names.insert(package.name).inserted else { throw PackageError.duplicatePackage(package.name) }
            guard installed[package.name] == nil else { throw PackageError.duplicatePackage(package.name) }
            for group in package.dependencies where !group.contains(where: { satisfied($0, installed: installed, batch: packages) }) {
                throw PackageError.missingDependency(package: package.name, dependency: group.map(\.name).joined(separator: " | "))
            }
        }

        var planned: [String: Item.Kind] = [:]
        var canonicalPaths: [String: String] = [:]
        var totalPayload: UInt64 = 0
        var metadataBytes: UInt64 = 1 << 20
        for item in packages.flatMap(\.items) {
            let path = try canonicalPayloadPath(item.path, in: builder)
            canonicalPaths[item.path] = path
            guard path != dpkg, !path.hasPrefix(dpkg + "/") else {
                throw PackageError.unsupported("packages may not modify dpkg bookkeeping")
            }
            for component in RootFilesystemBuilder.components(path) {
                let name = String(decoding: component, as: UTF16.self)
                guard !name.hasPrefix("."), !name.hasSuffix("."), !name.hasSuffix(" ") else {
                    throw PackageError.unsafePath(path)
                }
            }
            if let prior = planned[path], !compatible(prior, item.kind) {
                throw PackageError.unsupported("multiple package entries conflict at \(path)")
            }
            planned[path] = item.kind
            if builder.contains(path) {
                if isDirectory(item.kind) != builder.isFolder(at: path) {
                    throw PackageError.unsupported("payload entry conflicts with existing item: \(path)")
                }
            }
            let (nextMetadata, metadataOverflow) = metadataBytes.addingReportingOverflow(UInt64(path.utf8.count + 1))
            guard !metadataOverflow else { throw PackageError.insufficientPayloadSpace }
            metadataBytes = nextMetadata
            if case .file(_, let length) = item.kind {
                let (nextPayload, payloadOverflow) = totalPayload.addingReportingOverflow(length)
                guard !payloadOverflow, nextPayload <= UInt64(maximumPayloadSize) else { throw PackageError.insufficientPayloadSpace }
                totalPayload = nextPayload
            }
        }

        for path in planned.keys {
            var parent = deletingLastPathComponentPath(path)
            while parent != "/" {
                if let parentItem = planned[parent], !isDirectory(parentItem) {
                    throw PackageError.unsupported("non-directory payload entry is a parent: \(parent)")
                }
                if builder.contains(parent), !builder.isFolder(at: parent),
                   !(planned[parent].map(isDirectory) ?? false) {
                    throw PackageError.unsupported("payload parent isn't a directory: \(parent)")
                }
                parent = deletingLastPathComponentPath(parent)
            }
        }
        let required = totalPayload.addingReportingOverflow(metadataBytes)
        guard !required.overflow, required.partialValue <= builder.volumeFreeBytes,
              builder.volumeFreeBytes - required.partialValue >= minimumFreeReserve else {
            throw PackageError.insufficientPayloadSpace
        }

        // Make all directory parents first. Regular files are written before
        // links so package-created links cannot redirect other package writes.
        for path in planned.keys.sorted(by: { pathDepth($0) < pathDepth($1) }) {
            guard let kind = planned[path], isDirectory(kind) else { continue }
            try ensureDirectories(through: path, in: builder)
            let source = packages.flatMap(\.items).first { canonicalPaths[$0.path] == path && isDirectory($0.kind) }!
            try builder.addFolder(path, owner: source.owner, group: source.group, mode: source.mode)
        }
        var fileLists = Array(repeating: [String](), count: packages.count)
        for (packageIndex, package) in packages.enumerated() {
            for item in package.items {
                guard let path = canonicalPaths[item.path] else { throw PackageError.unsafePath(item.path) }
                if case .symlink = item.kind { continue }
                fileLists[packageIndex].append(item.path)
                guard case .file(let source, let length) = item.kind else { continue }
                try ensureParentDirectories(for: path, in: builder)
                try builder.installFile(path, from: source, length: length, owner: item.owner, group: item.group, mode: item.mode)
            }
        }

        try ensureDirectories(through: dpkg, in: builder)
        try builder.addFolder(dpkg, owner: 0, group: 0, mode: 0o755)
        try ensureDirectories(through: dpkgInfo, in: builder)
        try builder.addFolder(dpkgInfo, owner: 0, group: 0, mode: 0o755)
        var status = oldStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        for package in packages {
            var paragraph = "Package: \(package.name)\nStatus: install ok installed\nPriority: optional\nSection: packages\nVersion: \(package.version)\nArchitecture: \(package.architecture)\n"
            if let description = package.description {
                paragraph += "Description: \(description.replacingOccurrences(of: "\n", with: "\n "))\n"
            }
            if !status.isEmpty { status += "\n\n" }
            status += paragraph.trimmingCharacters(in: .newlines)
        }
        for (index, package) in packages.enumerated() {
            for item in package.items {
                guard case .symlink(let target) = item.kind else { continue }
                guard let path = canonicalPaths[item.path], safeSymbolicLinkTarget(target, linkPath: item.path) else {
                    throw PackageError.unsafePath(item.path)
                }
                try ensureParentDirectories(for: path, in: builder)
                try builder.installSymbolicLink(path, target: target, owner: item.owner, group: item.group)
                fileLists[index].append(item.path)
            }
        }
        for (index, package) in packages.enumerated() {
            let contents = Array((fileLists[index].sorted().joined(separator: "\n") + "\n").utf8)
            try builder.installFile(dpkgInfo + "/" + package.name + ".list", contents: contents,
                                    owner: 0, group: 0, mode: 0o644)
        }
        try builder.installFile(statusPath, contents: Array((status + "\n").utf8), owner: 0, group: 0, mode: 0o644)

        return packages.enumerated().map { index, package in
            let bytes = package.items.reduce(UInt64(0)) { sum, item in
                guard case .file(_, let length) = item.kind else { return sum }
                let (next, overflow) = sum.addingReportingOverflow(length)
                return overflow ? .max : next
            }
            return InstalledPackage(name: package.name, version: package.version, files: fileLists[index], payloadBytes: bytes)
        }}


    private static func parse(_ data: Data, staging: URL, maximumExpandedBytes: Int,
                              maximumEntries: Int) throws -> Package {
        let members = try parseAr(data)
        guard let binary = members["debian-binary"],
              String(decoding: binary, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "2.0" else {
            throw PackageError.invalidArchive("missing or unsupported debian-binary version")
        }
        let controlArchive: Data
        let controlFormat: ArchiveFormat
        if let gzip = members["control.tar.gz"] { controlArchive = gzip; controlFormat = .gzipTar }
        else if let tar = members["control.tar"] { controlArchive = tar; controlFormat = .tar }
        else { throw PackageError.unsupported("control.tar.gz or control.tar is required") }
        let dataArchive: Data
        let dataFormat: ArchiveFormat
        if let gzip = members["data.tar.gz"] { dataArchive = gzip; dataFormat = .gzipTar }
        else if let tar = members["data.tar"] { dataArchive = tar; dataFormat = .tar }
        else { throw PackageError.unsupported("data.tar.gz or data.tar is required; xz/lzma payloads aren't supported") }
        let controlTar = try unpack(controlArchive, format: controlFormat, maximum: min(maximumControlSize, maximumExpandedBytes))
        guard controlTar.count <= maximumControlSize else { throw PackageError.unsupported("control archive exceeds its size limit") }
        let control = try parseTar(controlTar, staging: staging, controlMode: true,
                                   maximumEntries: maximumEntries, maximumFileBytes: maximumControlSize)
        guard let controlData = control.files["/control"], let text = String(data: controlData, encoding: .utf8) else {
            throw PackageError.invalidArchive("control archive has no valid UTF-8 control file")
        }
        let fields = try parseFields(text)
        guard let name = fields["Package"], validPackageName(name),
              let version = fields["Version"], validVersion(version),
              let architecture = fields["Architecture"], ["iphoneos-arm", "darwin-arm", "all"].contains(architecture) else {
            throw PackageError.unsupported("control file needs valid Package, Version, and iOS ARM Architecture fields")
        }
        let scripts = ["/preinst", "/postinst", "/prerm", "/postrm", "/config"]
        if let script = scripts.first(where: { control.files[$0] != nil }) {
            throw PackageError.unsupported("maintainer script \(script) is present; scripts are never skipped")
        }
        if control.files["/conffiles"] != nil || control.files["/triggers"] != nil {
            throw PackageError.unsupported("conffiles and dpkg triggers aren't supported")
        }
        let supportedFields: Set<String> = ["Package", "Version", "Architecture", "Description", "Depends", "Maintainer", "Priority", "Section", "Essential", "Homepage", "Installed-Size", "Source", "Multi-Arch", "Tag", "Built-Using", "Static-Built-Using", "Original-Maintainer"]
        if let field = fields.keys.first(where: { !supportedFields.contains($0) }) {
            throw PackageError.unsupported("control field \(field) isn't supported")
        }
        for field in ["Pre-Depends", "Conflicts", "Breaks", "Replaces", "Provides"] where fields[field] != nil {
            throw PackageError.unsupported("control field \(field) isn't supported")
        }

        let remaining = maximumExpandedBytes - controlTar.count
        let payload = try unpack(dataArchive, format: dataFormat, maximum: min(maximumPayloadSize, remaining))
        let parsed = try parseTar(payload, staging: staging, controlMode: false,
                                  maximumEntries: maximumEntries, maximumFileBytes: maximumPayloadSize)
        guard !parsed.items.isEmpty else { throw PackageError.invalidArchive("data archive is empty") }
        let (expanded, expandedOverflow) = controlTar.count.addingReportingOverflow(payload.count)
        let (entries, entriesOverflow) = control.entryCount.addingReportingOverflow(parsed.entryCount)
        guard !expandedOverflow, !entriesOverflow, expanded <= maximumExpandedBytes, entries <= maximumEntries else {
            throw PackageError.unsupported("package exceeds expanded archive limits")
        }
        let dependencies = try parseDependencies(fields["Depends"] ?? "")
        guard dependencies.reduce(0, { $0 + $1.count }) <= maximumEntries else {
            throw PackageError.unsupported("too many package dependencies")
        }
        return Package(name: name, version: version, architecture: architecture, description: fields["Description"],
                       dependencies: dependencies, items: parsed.items, expandedArchiveBytes: expanded,
                       archiveEntryCount: entries)}


    private static func unpack(_ data: Data, format: ArchiveFormat, maximum: Int) throws -> Data {
        switch format {
        case .tar:
            guard data.count <= maximum else { throw PackageError.unsupported("expanded archive exceeds size limit") }
            return data
        case .gzipTar:
            return try gunzip(data, maximumOutput: maximum)
        }}


    private static func parseAr(_ data: Data) throws -> [String: Data] {
        guard data.count >= 8, data.prefix(8) == Data("!<arch>\n".utf8) else {
            throw PackageError.invalidArchive("missing ar archive signature")
        }
        var members: [String: Data] = [:]
        var offset = 8
        while offset < data.count {
            guard offset + 60 <= data.count, data[offset + 58] == 0x60, data[offset + 59] == 0x0A else {
                throw PackageError.invalidArchive("truncated or malformed ar member header")
            }
            let rawName = String(decoding: data[offset..<offset + 16], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard rawName.utf8.count <= 16, rawName.allSatisfy({ $0.isASCII }), !rawName.hasPrefix("#1/") else {
                throw PackageError.unsupported("non-portable ar member names aren't supported")
            }
            guard let size = UInt64(String(decoding: data[offset + 48..<offset + 58], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
                  size <= UInt64(Int.max) else { throw PackageError.invalidArchive("invalid ar member size") }
            let name = rawName.hasSuffix("/") ? String(rawName.dropLast()) : rawName
            let start = offset + 60
            guard size <= UInt64(data.count - start) else { throw PackageError.invalidArchive("ar member exceeds archive bounds") }
            let end = start + Int(size)
            if name != "/", name != "//" {
                guard members[name] == nil else { throw PackageError.invalidArchive("duplicate ar member \(name)") }
                members[name] = data.subdata(in: start..<end)
            }
            offset = end + (Int(size) & 1)
        }
        guard offset == data.count else { throw PackageError.invalidArchive("invalid ar padding") }
        return members}


    private static func gunzip(_ data: Data, maximumOutput: Int) throws -> Data {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else {
            throw PackageError.invalidArchive("invalid gzip header")
        }
        let flags = data[3]
        guard flags & 0xE0 == 0 else { throw PackageError.invalidArchive("reserved gzip flags are set") }
        var cursor = 10
        if flags & 4 != 0 {
            guard cursor + 2 <= data.count else { throw PackageError.invalidArchive("truncated gzip extra field") }
            let extraLength = Int(data.readUInt16LE(at: cursor))
            cursor += 2
            guard extraLength <= data.count - cursor else { throw PackageError.invalidArchive("truncated gzip extra field") }
            cursor += extraLength
        }
        for flag in [UInt8(8), 16] where flags & flag != 0 {
            while cursor < data.count && data[cursor] != 0 { cursor += 1 }
            guard cursor < data.count else { throw PackageError.invalidArchive("unterminated gzip field") }
            cursor += 1
        }
        if flags & 2 != 0 {
            guard cursor + 2 <= data.count else { throw PackageError.invalidArchive("truncated gzip header checksum") }
            cursor += 2
        }
        let compressedEnd = data.count - 8
        guard cursor < compressedEnd, maximumOutput >= 0 else { throw PackageError.invalidArchive("truncated gzip stream") }
        var output = Data()
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PackageError.unsupported("couldn't initialize gzip decompression")
        }
        defer { compression_stream_destroy(stream) }
        let chunkSize = 1 << 20
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw PackageError.invalidArchive("empty gzip stream") }
            stream.pointee.src_ptr = base.advanced(by: cursor)
            stream.pointee.src_size = compressedEnd - cursor
            var finished = false
            while !finished {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let state = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard state != COMPRESSION_STATUS_ERROR else { throw PackageError.invalidArchive("corrupt deflate stream") }
                let count = chunkSize - stream.pointee.dst_size
                guard count <= maximumOutput, output.count <= maximumOutput - count else {
                    throw PackageError.unsupported("expanded archive exceeds size limit")
                }
                if count > 0 { output.append(chunk, count: count) }
                if state == COMPRESSION_STATUS_END { finished = true }
                else if count == 0 && stream.pointee.src_size == 0 { throw PackageError.invalidArchive("incomplete deflate stream") }
            }
            guard stream.pointee.src_size == 0 else { throw PackageError.invalidArchive("trailing deflate data") }
        }
        guard crc32(output) == data.readUInt32LE(at: compressedEnd),
              UInt32(truncatingIfNeeded: output.count) == data.readUInt32LE(at: compressedEnd + 4) else {
            throw PackageError.invalidArchive("gzip checksum mismatch")
        }
        return output}


    private static func parseTar(_ data: Data, staging: URL, controlMode: Bool,
                                 maximumEntries: Int, maximumFileBytes: Int) throws -> TarResult {
        guard data.count % 512 == 0 else { throw PackageError.invalidArchive("tar length isn't block-aligned") }
        var result = TarResult()
        var offset = 0
        var longName: String?
        var seen = Set<String>()
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<offset + 512)
            if header.allSatisfy({ $0 == 0 }) {
                guard data[offset...].allSatisfy({ $0 == 0 }) else { throw PackageError.invalidArchive("nonzero bytes after tar end marker") }
                break
            }
            result.entryCount += 1
            guard result.entryCount <= maximumEntries else { throw PackageError.unsupported("too many tar entries") }
            try checkTarChecksum(header)
            let length = try octal(header, at: 124, count: 12)
            guard length <= UInt64(maximumFileBytes) else { throw PackageError.unsupported("tar entry exceeds size limit") }
            let start = offset + 512
            guard length <= UInt64(data.count - start) else { throw PackageError.invalidArchive("truncated tar entry") }
            let end = start + Int(length)
            let rawType = header[156]
            if controlMode && rawType == 0x4C {
                throw PackageError.unsupported("GNU long-name control entries aren't supported")
            }
            if rawType == 0x4C {
                guard length > 0, length <= UInt64(maximumPathLength) else { throw PackageError.unsafePath("GNU long pathname") }
                longName = String(decoding: data[start..<end].prefix { $0 != 0 }, as: UTF8.self)
            } else {
                let name = try normalizePath(longName ?? tarPath(header))
                longName = nil
                let type = rawType == 0 ? 0x30 : rawType
                if controlMode {
                    guard name.split(separator: "/").count <= 1,
                          type == 0x30 || type == 0x35 else {
                        throw PackageError.unsupported("unsupported control archive entry")
                    }
                    guard seen.insert(name).inserted else { throw PackageError.invalidArchive("duplicate control path") }
                    if type == 0x30 { result.files[name] = data.subdata(in: start..<end) }
                } else if name != "/" {
                    guard seen.insert(name).inserted else { throw PackageError.invalidArchive("duplicate payload path \(name)") }
                    let mode = UInt16(try octal(header, at: 100, count: 8) & 0x0FFF)
                    let owner = try uint32(header, at: 108, count: 8)
                    let group = try uint32(header, at: 116, count: 8)
                    switch type {
                    case 0x30:
                        let fileURL = staging.appendingPathComponent("payload-\(result.items.count)")
                        try data.subdata(in: start..<end).write(to: fileURL, options: .atomic)
                        result.items.append(Item(path: name, mode: mode, owner: owner, group: group, kind: .file(fileURL, length)))
                    case 0x35:
                        result.items.append(Item(path: name, mode: mode, owner: owner, group: group, kind: .directory))
                    case 0x32:
                        let target = try tarString(header, at: 157, count: 100)
                        guard !target.isEmpty else { throw PackageError.unsafePath(name) }
                        result.items.append(Item(path: name, mode: mode, owner: owner, group: group, kind: .symlink(target)))
                    case 0x31: throw PackageError.unsupported("hard links aren't supported: \(name)")
                    default: throw PackageError.unsupported("special tar entry isn't supported: \(name)")
                    }
                }
            }
            let (rounded, overflow) = length.addingReportingOverflow(511)
            guard !overflow else { throw PackageError.invalidArchive("tar size overflow") }
            let (padded, paddedOverflow) = (rounded / 512).multipliedReportingOverflow(by: 512)
            guard !paddedOverflow, padded <= UInt64(data.count - start) else { throw PackageError.invalidArchive("invalid tar padding") }
            offset = start + Int(padded)
        }
        guard offset <= data.count, data[offset...].allSatisfy({ $0 == 0 }), longName == nil else {
            throw PackageError.invalidArchive("invalid trailing tar data")
        }
        return result}


    private static func parseFields(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            if line.first == " " || line.first == "\t" {
                guard let current else { throw PackageError.invalidArchive("orphan control continuation") }
                result[current, default: ""] += "\n" + String(line.dropFirst())
            } else {
                guard let colon = line.firstIndex(of: ":") else { throw PackageError.invalidArchive("malformed control field") }
                let key = String(line[..<colon])
                guard !key.isEmpty, result[key] == nil else { throw PackageError.invalidArchive("duplicate control field") }
                result[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                current = key
            }
        }
        return result}


    private static func parseDependencies(_ value: String) throws -> [[Dependency]] {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try split(value, separator: ",").map { group in
            try split(group, separator: "|").map { alternative in
                let text = alternative.trimmingCharacters(in: .whitespaces)
                let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let raw = parts.first, !text.contains("[") && !text.contains("]"), !raw.contains(":"), validPackageName(raw) else {
                    throw PackageError.unsupported("unsupported dependency syntax: \(text)")
                }
                guard parts.count == 1 || parts.count == 3 else { throw PackageError.unsupported("dependency expression: \(text)") }
                guard parts.count == 3 else { return Dependency(name: raw, relation: nil, version: nil) }
                let op = String(parts[1].dropFirst())
                let version = String(parts[2].dropLast())
                guard parts[1].hasPrefix("("), parts[2].hasSuffix(")"),
                      ["<<", "<=", "=", ">=", ">>"].contains(op), validVersion(version) else {
                    throw PackageError.unsupported("dependency constraint: \(text)")
                }
                return Dependency(name: raw, relation: op, version: version)
            }
        }}


    private static func satisfied(_ dependency: Dependency, installed: [String: String], batch: [Package]) -> Bool {
        let version = installed[dependency.name] ?? batch.first(where: { $0.name == dependency.name })?.version
            ?? (["firmware", "iphoneos-arm"].contains(dependency.name) ? "6.1.6" : nil)
        guard let version else { return false }
        guard let relation = dependency.relation, let required = dependency.version else { return true }
        let compare = compareVersion(version, required)
        switch relation {
        case "<<": return compare < 0
        case "<=": return compare <= 0
        case "=": return compare == 0
        case ">=": return compare >= 0
        case ">>": return compare > 0
        default: return false
        }}


    private static func installedPackages(in status: String) -> [String: String] {
        var installed: [String: String] = [:]
        for paragraph in status.components(separatedBy: "\n\n") {
            guard let fields = try? parseFields(paragraph), fields["Status"] == "install ok installed",
                  let name = fields["Package"], let version = fields["Version"] else { continue }
            installed[name] = version
        }
        return installed}


    private static func ensureDirectories(through path: String, in builder: RootFilesystemBuilder) throws {
        var current: [String] = []
        for component in RootFilesystemBuilder.components(path) {
            current.append(String(decoding: component, as: UTF16.self))
            let candidate = "/" + current.joined(separator: "/")
            let resolved = try builder.resolvedPath(candidate)
            if builder.contains(resolved) {
                guard builder.isFolder(at: resolved) else { throw PackageError.unsupported("directory conflicts at \(resolved)") }
            } else {
                try builder.addFolder(resolved, owner: 0, group: 0, mode: 0o755)
            }
        }}


    private static func ensureParentDirectories(for path: String, in builder: RootFilesystemBuilder) throws {
        let parent = deletingLastPathComponentPath(path)
        try ensureDirectories(through: parent, in: builder)}


    private static func canonicalPayloadPath(_ path: String, in builder: RootFilesystemBuilder) throws -> String {
        let components = RootFilesystemBuilder.components(path)
        guard components.count <= 255, let last = components.last else { throw PackageError.unsafePath(path) }
        let name = String(decoding: last, as: UTF16.self)
        let parent = components.dropLast().map { String(decoding: $0, as: UTF16.self) }
        let parentPath = parent.isEmpty ? "/" : "/" + parent.joined(separator: "/")
        guard parent.count <= 255 else { throw PackageError.unsafePath(path) }
        let resolvedParent = try builder.resolvedPath(parentPath)
        guard resolvedParent.utf8.count + name.utf8.count + 1 <= maximumPathLength else { throw PackageError.unsafePath(path) }
        if builder.contains(resolvedParent), !builder.isFolder(at: resolvedParent) {
            throw PackageError.unsupported("payload parent isn't a directory: \(resolvedParent)")
        }
        return resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name}


    private static func safeSymbolicLinkTarget(_ target: String, linkPath: String) -> Bool {
        guard target.utf8.count <= maximumPathLength,
              !target.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        var depth = target.hasPrefix("/") ? 0 : max(0, linkPath.split(separator: "/").count - 1)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard depth > 0 else { return false }
                depth -= 1
            } else {
                depth += 1
            }
        }
        return true}


    private static func pathDepth(_ path: String) -> Int { path.split(separator: "/").count }

    private static func compatible(_ lhs: Item.Kind, _ rhs: Item.Kind) -> Bool {
        if case .directory = lhs, case .directory = rhs { return true }
        return false}


    private static func isDirectory(_ item: Item) -> Bool {
        if case .directory = item.kind { return true }
        return false}


    private static func isDirectory(_ kind: Item.Kind) -> Bool {
        if case .directory = kind { return true }
        return false}


    private static func normalizePath(_ input: String) throws -> String {
        guard input.utf8.count <= maximumPathLength,
              !input.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F }) else {
            throw PackageError.unsafePath(input)
        }
        var value = input
        while value.hasPrefix("./") { value.removeFirst(2) }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }), components.allSatisfy({ $0.utf16.count <= 255 }) else {
            throw PackageError.unsafePath(input)
        }
        let path = components.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
        guard path.utf8.count <= maximumPathLength else { throw PackageError.unsafePath(input) }
        return path.isEmpty ? "/" : "/" + path}


    private static func tarPath(_ header: Data) throws -> String {
        let name = try tarString(header, at: 0, count: 100)
        let prefix = try tarString(header, at: 345, count: 155)
        return prefix.isEmpty ? name : prefix + "/" + name}


    private static func tarString(_ data: Data, at offset: Int, count: Int) throws -> String {
        guard offset >= 0, offset + count <= data.count,
              let value = String(data: data[offset..<offset + count].prefix { $0 != 0 }, encoding: .utf8) else {
            throw PackageError.invalidArchive("invalid tar string")
        }
        return value}


    private static func octal(_ data: Data, at offset: Int, count: Int) throws -> UInt64 {
        guard offset >= 0, offset + count <= data.count else { throw PackageError.invalidArchive("truncated tar numeric field") }
        let text = String(decoding: data[offset..<offset + count].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || text.allSatisfy({ $0 >= "0" && $0 <= "7" }),
              let value = text.isEmpty ? 0 : UInt64(text, radix: 8) else { throw PackageError.invalidArchive("invalid tar octal field") }
        return value}


    private static func uint32(_ data: Data, at offset: Int, count: Int) throws -> UInt32 {
        let value = try octal(data, at: offset, count: count)
        guard value <= UInt64(UInt32.max) else { throw PackageError.invalidArchive("tar uid/gid overflow") }
        return UInt32(value)}


    private static func checkTarChecksum(_ header: Data) throws {
        let expected = try octal(header, at: 148, count: 8)
        var sum: UInt64 = 0
        for index in header.indices { sum += (148..<156).contains(index) ? 32 : UInt64(header[index]) }
        guard sum == expected else { throw PackageError.invalidArchive("tar header checksum mismatch") }}


    private static func split(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var depth = 0
        var start = text.startIndex
        for index in text.indices {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" { depth = max(0, depth - 1) }
            if text[index] == separator && depth == 0 {
                result.append(String(text[start..<index]))
                start = text.index(after: index)
            }
        }
        result.append(String(text[start...]))
        return result}


    private static func validPackageName(_ name: String) -> Bool {
        guard let first = name.utf8.first, (97...122).contains(first) || (48...57).contains(first),
              name.utf8.count <= 128 else { return false }
        return name.utf8.dropFirst().allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46].contains($0)
        }}


    private static func validVersion(_ version: String) -> Bool {
        !version.isEmpty && version.utf8.count <= 256 && version.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 58, 126].contains($0)
        }}


    private static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        func fields(_ value: String) -> (UInt64, String, String) {
            let epochParts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let epoch = epochParts.count == 2 ? UInt64(epochParts[0]) ?? 0 : 0
            let rest = epochParts.count == 2 ? String(epochParts[1]) : value
            let revisionParts = rest.split(separator: "-", omittingEmptySubsequences: false)
            return (epoch, String(revisionParts.first ?? ""), revisionParts.count > 1 ? revisionParts.dropFirst().joined(separator: "-") : "0")
        }
        let a = fields(lhs), b = fields(rhs)
        if a.0 != b.0 { return a.0 < b.0 ? -1 : 1 }
        for (left, right) in [(a.1, b.1), (a.2, b.2)] {
            let result = compareVersionPart(left, right)
            if result != 0 { return result }
        }
        return 0}


    private static func compareVersionPart(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var i = 0
        var j = 0
        func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        func order(_ byte: UInt8?) -> Int {
            guard let byte else { return 0 }
            if byte == 0x7E { return -1 }
            if (65...90).contains(byte) || (97...122).contains(byte) { return Int(byte) }
            return Int(byte) + 256
        }
        while i < left.count || j < right.count {
            while (i < left.count && !digit(left[i])) || (j < right.count && !digit(right[j])) {
                let a = i < left.count && !digit(left[i]) ? order(left[i]) : order(nil)
                let b = j < right.count && !digit(right[j]) ? order(right[j]) : order(nil)
                if a != b { return a < b ? -1 : 1 }
                if i < left.count && !digit(left[i]) { i += 1 }
                if j < right.count && !digit(right[j]) { j += 1 }
            }
            while i < left.count && left[i] == 48 { i += 1 }
            while j < right.count && right[j] == 48 { j += 1 }
            var iEnd = i
            var jEnd = j
            while iEnd < left.count && digit(left[iEnd]) { iEnd += 1 }
            while jEnd < right.count && digit(right[jEnd]) { jEnd += 1 }
            if iEnd - i != jEnd - j { return iEnd - i < jEnd - j ? -1 : 1 }
            if iEnd > i {
                for offset in 0..<(iEnd - i) where left[i + offset] != right[j + offset] {
                    return left[i + offset] < right[j + offset] ? -1 : 1
                }
            }
            i = iEnd
            j = jEnd
        }
        return 0}


    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
