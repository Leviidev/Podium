import Foundation

/// Extracts ordinary single-app IPA archives into /Applications on the guest volume.
/// This only copies app bundles; it does not run Apple's installer or register, sign, or launch apps.
enum IPAInstaller {
    struct InstalledApp {
        let name: String
        let bundleIdentifier: String
        let payloadBytes: UInt64
    }

    enum InstallError: LocalizedError, CustomStringConvertible {
        case unsupported(String)
        case invalidArchive(String)
        case unsafePath(String)
        case alreadyInstalled(String)
        case insufficientSpace

        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .unsupported(let detail): return "This IPA can't be installed: \(detail)"
            case .invalidArchive(let detail): return "Invalid IPA archive: \(detail)"
            case .unsafePath(let path): return "The IPA contains an unsafe path: \(path)"
            case .alreadyInstalled(let app): return "An app named or identified as \(app) is already present in /Applications."
            case .insufficientSpace: return "The app bundle doesn't fit while keeping required free space in the guest volume."
            }
        }
    }

    private enum EntryKind: Equatable {
        case directory
        case file
        case symbolicLink
    }

    private struct ArchiveItem {
        let entry: ZipEntry
        let archivePath: String
        let bundleRelativePath: String
        let kind: EntryKind
    }

    private struct ExtractedItem {
        let relativePath: String
        let kind: EntryKind
        let sourceURL: URL?
        let length: UInt64
        let linkTarget: String?
        let mode: UInt16
    }

    private struct AppArchive {
        let appName: String
        let bundleIdentifier: String
        let executable: String
        let items: [ExtractedItem]
        let payloadBytes: UInt64
    }

    private static let maximumIPABytes: UInt64 = 512 << 20
    private static let maximumExpandedBytes: UInt64 = 2 << 30
    private static let maximumEntries = 50_000
    private static let maximumEntryBytes: UInt64 = 512 << 20
    private static let maximumInfoPlistBytes: UInt64 = 4 << 20
    private static let maximumLinkBytes: UInt64 = 1 << 10
    private static let maximumPathBytes = 1_024
    private static let minimumFreeReserve: UInt64 = 8 << 20
    private static let crc32Table: [UInt32] = (0...255).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    /// Validate the whole batch before mutating the builder, then add directories,
    /// regular files, and finally safe in-bundle relative symlinks.
    static func install(_ urls: [URL], into builder: RootFilesystemBuilder, stagingDirectory: URL) throws -> [InstalledApp] {
        guard !urls.isEmpty else { return [] }
        guard urls.count <= 10 else { throw InstallError.unsupported("install at most 10 apps at once") }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: stagingDirectory)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var archives: [AppArchive] = []
        var totalExpanded: UInt64 = 0
        var totalEntries = 0
        var identifiers = Set<String>()
        var names = Set<String>()
        for (index, url) in urls.enumerated() {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.uint64Value > 0, size.uint64Value <= maximumIPABytes else {
                throw InstallError.unsupported("each IPA must be a regular file no larger than 512 MiB")
            }
            let reader = try ZipArchiveReader(fileURL: url)
            guard reader.entries.count <= maximumEntries - totalEntries else {
                throw InstallError.unsupported("selected IPAs contain too many archive entries")
            }
            let stage = stagingDirectory.appendingPathComponent("app-\(index)", isDirectory: true)
            let parsed = try extractAndValidate(reader, staging: stage, expandedLimit: maximumExpandedBytes - totalExpanded)
            let (nextExpanded, expandedOverflow) = totalExpanded.addingReportingOverflow(parsed.payloadBytes)
            guard !expandedOverflow, nextExpanded <= maximumExpandedBytes else { throw InstallError.unsupported("expanded app bundles exceed 2 GiB") }
            totalExpanded = nextExpanded
            totalEntries += reader.entries.count
            let identifierKey = Self.collisionKey(parsed.bundleIdentifier)
            let nameKey = Self.collisionKey(parsed.appName)
            guard identifiers.insert(identifierKey).inserted, names.insert(nameKey).inserted else {
                throw InstallError.alreadyInstalled(parsed.bundleIdentifier)
            }
            archives.append(parsed)
        }

        let applications = try builder.resolvedPath("/Applications")
        guard !builder.isSymbolicLink(at: applications) else {
            throw InstallError.unsupported("/Applications is a symbolic link")
        }
        try ensureDirectory(applications, in: builder)
        let existingNames = Set(try builder.children(of: applications).map { Self.collisionKey($0.name) })
        for archive in archives where existingNames.contains(Self.collisionKey(archive.appName)) {
            throw InstallError.alreadyInstalled(archive.appName)
        }
        for child in try builder.children(of: applications) where builder.isFolder(at: applications + "/" + child.name) {
            let existingPath = applications + "/" + child.name + "/Info.plist"
            guard builder.contains(existingPath), let data = try? Data(builder.contents(of: existingPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String else { continue }
            if identifiers.contains(Self.collisionKey(identifier)) || archives.contains(where: { Self.collisionKey($0.bundleIdentifier) == Self.collisionKey(identifier) }) {
                throw InstallError.alreadyInstalled(identifier)
            }
        }

        var destinations: [String: AppArchive] = [:]
        var totalPayload: UInt64 = 0
        var metadataReserve: UInt64 = 1 << 20
        for archive in archives {
            let bundlePath = applications + "/" + archive.appName
            guard !builder.contains(bundlePath), destinations[Self.collisionKey(bundlePath)] == nil else {
                throw InstallError.alreadyInstalled(archive.appName)
            }
            destinations[Self.collisionKey(bundlePath)] = archive
            for item in archive.items {
                let destination = bundlePath + (item.relativePath.isEmpty ? "" : "/" + item.relativePath)
                guard destination.utf8.count <= maximumPathBytes else { throw InstallError.unsafePath(destination) }
                let (nextMetadata, metadataOverflow) = metadataReserve.addingReportingOverflow(UInt64(destination.utf8.count + 1))
                guard !metadataOverflow else { throw InstallError.insufficientSpace }
                metadataReserve = nextMetadata
                if case .file = item.kind {
                    let (nextPayload, payloadOverflow) = totalPayload.addingReportingOverflow(item.length)
                    guard !payloadOverflow else { throw InstallError.insufficientSpace }
                    totalPayload = nextPayload
                }
            }
        }
        let required = totalPayload.addingReportingOverflow(metadataReserve)
        guard !required.overflow, required.partialValue <= builder.volumeFreeBytes,
              builder.volumeFreeBytes - required.partialValue >= minimumFreeReserve else { throw InstallError.insufficientSpace }

        for archive in archives {
            let bundlePath = applications + "/" + archive.appName
            try ensureDirectory(bundlePath, in: builder)
            for item in archive.items where item.kind == .directory {
                try ensureDirectory(bundlePath + "/" + item.relativePath, in: builder)
            }
        }
        for archive in archives {
            let bundlePath = applications + "/" + archive.appName
            for item in archive.items where item.kind == .file {
                guard let sourceURL = item.sourceURL else { throw InstallError.invalidArchive("an extracted file is missing") }
                let path = bundlePath + "/" + item.relativePath
                try ensureBundleParents(for: item.relativePath, bundlePath: bundlePath, in: builder)
                let mode = item.relativePath == archive.executable ? 0o755 : (item.mode == 0 ? 0o644 : item.mode & 0o777)
                try builder.addFile(path, from: sourceURL, length: item.length, owner: 0, group: 0, mode: mode)
            }
        }
        for archive in archives {
            let bundlePath = applications + "/" + archive.appName
            for item in archive.items where item.kind == .symbolicLink {
                guard let target = item.linkTarget else { throw InstallError.invalidArchive("a symbolic link has no target") }
                let path = bundlePath + "/" + item.relativePath
                try ensureBundleParents(for: item.relativePath, bundlePath: bundlePath, in: builder)
                try builder.addSymbolicLink(path, target: target,
                                            owner: 0, group: 0, template: "/private/etc/fstab")
            }
        }
        return archives.map { InstalledApp(name: $0.appName, bundleIdentifier: $0.bundleIdentifier, payloadBytes: $0.payloadBytes) }
    }

    private static func extractAndValidate(_ reader: ZipArchiveReader, staging: URL, expandedLimit: UInt64) throws -> AppArchive {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        guard !reader.entries.isEmpty else { throw InstallError.invalidArchive("the archive is empty") }
        var appRoots = Set<String>()
        var items: [ArchiveItem] = []
        var seenPaths = Set<String>()
        var kindsByPath: [String: EntryKind] = [:]
        var declaredExpanded: UInt64 = 0

        for entry in reader.entries {
            guard entry.name.utf8.count <= maximumPathBytes,
                  !entry.name.contains("\\"), !entry.name.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F }) else {
                throw InstallError.unsafePath(entry.name)
            }
            let isDir = entry.isDirectory
            let path = isDir && entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf16.count <= 255 }) else {
                throw InstallError.unsafePath(entry.name)
            }
            let appType = entry.unixMode & 0o170000
            let kind: EntryKind
            if appType == 0o120000 {
                kind = .symbolicLink
            } else if appType == 0o100000 {
                guard !entry.name.hasSuffix("/") else { throw InstallError.invalidArchive("a regular file path ends with a slash") }
                kind = .file
            } else if appType == 0 {
                kind = isDir ? .directory : .file
            } else if appType == 0o040000 {
                guard isDir else { throw InstallError.invalidArchive("a directory entry lacks a trailing slash") }
                kind = .directory
            } else {
                throw InstallError.unsupported("special files and unsupported Unix file types aren't allowed")
            }
            if case .symbolicLink = kind, isDir { throw InstallError.invalidArchive("a symbolic link is marked as a directory") }
            if case .directory = kind, entry.uncompressedSize != 0 { throw InstallError.invalidArchive("directory entries must be empty") }
            if case .symbolicLink = kind, entry.uncompressedSize > maximumLinkBytes { throw InstallError.unsupported("symbolic link targets exceed 1 KiB") }
            if case .file = kind, entry.uncompressedSize > maximumEntryBytes { throw InstallError.unsupported("an app file exceeds 512 MiB") }
            let (nextSize, sizeOverflow) = declaredExpanded.addingReportingOverflow(entry.uncompressedSize)
            guard !sizeOverflow, nextSize <= expandedLimit else { throw InstallError.unsupported("expanded app bundles exceed the size limit") }
            declaredExpanded = nextSize

            let key = Self.collisionKey(path)
            guard seenPaths.insert(key).inserted else { throw InstallError.invalidArchive("duplicate archive path \(path)") }
            for count in 1..<parts.count {
                let parent = parts.prefix(count).joined(separator: "/")
                if let parentKind = kindsByPath[Self.collisionKey(parent)], parentKind != .directory {
                    throw InstallError.unsafePath(path)
                }
            }
            kindsByPath[key] = kind

            guard parts[0] == "Payload" else {
                // Exported IPAs can contain installer metadata, symbol maps, or
                // SwiftSupport alongside Payload. They are not guest app files.
                continue
            }
            if parts.count == 1 {
                guard case .directory = kind else { throw InstallError.invalidArchive("Payload must be a directory") }
                continue
            }
            let appRoot = parts[1]
            guard appRoot.hasSuffix(".app"), appRoot.count > 4,
                  Self.isSafeAppName(String(appRoot.dropLast(4))) else {
                throw InstallError.invalidArchive("Payload must contain one top-level .app bundle")
            }
            appRoots.insert(appRoot)
            let relative = parts.dropFirst(2).joined(separator: "/")
            if parts.count == 2 {
                guard case .directory = kind else { throw InstallError.invalidArchive("the .app bundle root must be a directory") }
                continue
            }
            items.append(ArchiveItem(entry: entry, archivePath: path, bundleRelativePath: relative, kind: kind))
        }
        guard appRoots.count == 1, let appName = appRoots.first else {
            throw InstallError.invalidArchive("the IPA must contain exactly one app bundle")
        }
        for item in items {
            if item.bundleRelativePath == "Info.plist" {
                guard case .file = item.kind else { throw InstallError.invalidArchive("Info.plist must be a regular file") }
            }
            let ancestors = item.bundleRelativePath.split(separator: "/").dropLast().map(String.init)
            var parent = ""
            for component in ancestors {
                parent = parent.isEmpty ? component : parent + "/" + component
                if let parentKind = kindsByPath[Self.collisionKey("Payload/" + appName + "/" + parent)], parentKind != .directory {
                    throw InstallError.unsafePath(item.archivePath)
                }
            }
        }

        let appStage = staging.appendingPathComponent("Payload", isDirectory: true).appendingPathComponent(appName, isDirectory: true)
        try fileManager.createDirectory(at: appStage, withIntermediateDirectories: true)
        var extracted: [ExtractedItem] = []
        var infoURL: URL?
        var infoKind: EntryKind?
        var payloadBytes: UInt64 = 0
        for item in items {
            let output = item.bundleRelativePath.isEmpty ? appStage : item.bundleRelativePath.split(separator: "/").reduce(appStage) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
            switch item.kind {
            case .directory:
                try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
                extracted.append(ExtractedItem(relativePath: item.bundleRelativePath, kind: .directory, sourceURL: nil,
                                               length: 0, linkTarget: nil, mode: item.entry.unixMode & 0o777))
            case .file:
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fileManager.createFile(atPath: output.path, contents: nil) else { throw InstallError.invalidArchive("couldn't create staged file \(item.archivePath)") }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                try streamAndValidate(item.entry, from: reader) { data in
                    try handle.write(contentsOf: data)
                }
                try handle.synchronize()
                if item.bundleRelativePath == "Info.plist" {
                    guard item.entry.uncompressedSize <= maximumInfoPlistBytes else { throw InstallError.unsupported("Info.plist exceeds 4 MiB") }
                    infoURL = output
                    infoKind = .file
                }
                if item.bundleRelativePath == "" { throw InstallError.invalidArchive("an app bundle contains a file without a name") }
                let (nextPayload, payloadOverflow) = payloadBytes.addingReportingOverflow(item.entry.uncompressedSize)
                guard !payloadOverflow else { throw InstallError.unsupported("app payload size overflows") }
                payloadBytes = nextPayload
                extracted.append(ExtractedItem(relativePath: item.bundleRelativePath, kind: .file, sourceURL: output,
                                               length: item.entry.uncompressedSize, linkTarget: nil,
                                               mode: item.entry.unixMode & 0o777))
            case .symbolicLink:
                var targetData = Data()
                try streamAndValidate(item.entry, from: reader) { data in
                    guard targetData.count <= Int(maximumLinkBytes) - data.count else { throw InstallError.unsupported("symbolic link target exceeds 1 KiB") }
                    targetData.append(data)
                }
                guard let target = String(data: targetData, encoding: .utf8), Self.isSafeLinkTarget(target, linkPath: item.bundleRelativePath) else {
                    throw InstallError.unsafePath(item.archivePath)
                }
                extracted.append(ExtractedItem(relativePath: item.bundleRelativePath, kind: .symbolicLink, sourceURL: nil,
                                               length: item.entry.uncompressedSize, linkTarget: target, mode: item.entry.unixMode & 0o777))
            }
        }
        guard let infoURL, infoKind == .file,
              let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, Self.isValidBundleIdentifier(identifier),
              let executable = info["CFBundleExecutable"] as? String, Self.isSafeFilenameComponent(executable),
              let executableItem = extracted.first(where: { $0.relativePath == executable && $0.kind == .file }) else {
            throw InstallError.invalidArchive("Info.plist must declare a valid bundle identifier and a regular CFBundleExecutable")
        }
        guard executableItem.length > 0 else { throw InstallError.invalidArchive("the declared app executable is empty") }
        return AppArchive(appName: appName, bundleIdentifier: identifier, executable: executable,
                          items: extracted, payloadBytes: payloadBytes)
    }

    private static func streamAndValidate(_ entry: ZipEntry, from reader: ZipArchiveReader,
                                          consume: (Data) throws -> Void) throws {
        var written: UInt64 = 0
        var crc: UInt32 = 0xFFFF_FFFF
        try reader.stream(entry) { buffer in
            let (next, overflow) = written.addingReportingOverflow(UInt64(buffer.count))
            guard !overflow, next <= entry.uncompressedSize else {
                throw InstallError.invalidArchive("\(entry.name) expands beyond its declared size")
            }
            written = next
            if let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                for index in 0..<buffer.count {
                    let tableIndex = Int((crc ^ UInt32(bytes[index])) & 0xFF)
                    crc = (crc >> 8) ^ crc32Table[tableIndex]
                }
                try consume(Data(bytes: bytes, count: buffer.count))
            }
        }
        guard written == entry.uncompressedSize, ~crc == entry.crc32 else {
            throw InstallError.invalidArchive("\(entry.name) has an invalid size or CRC checksum")
        }
    }

    private static func ensureBundleParents(for relativePath: String, bundlePath: String, in builder: RootFilesystemBuilder) throws {
        let components = relativePath.split(separator: "/").dropLast().map(String.init)
        var path = bundlePath
        for component in components {
            path += "/" + component
            try ensureDirectory(path, in: builder)
        }
    }

    private static func ensureDirectory(_ path: String, in builder: RootFilesystemBuilder) throws {
        let resolved = try builder.resolvedPath(path)
        if builder.contains(resolved) {
            guard builder.isFolder(at: resolved) else { throw InstallError.unsupported("app directory conflicts with an existing file: \(resolved)") }
        } else {
            let parent = resolved.split(separator: "/").dropLast().joined(separator: "/")
            if !parent.isEmpty { try ensureDirectory("/" + parent, in: builder) }
            try builder.addFolder(resolved, owner: 0, group: 0, mode: 0o755)
        }
    }

    private static func isSafeLinkTarget(_ target: String, linkPath: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), target.utf8.count <= Int(maximumLinkBytes),
              !target.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        var depth = max(0, linkPath.split(separator: "/").count - 1)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard depth > 0 else { return false }
                depth -= 1
            } else {
                depth += 1
            }
        }
        return true
    }

    private static func isSafeFilenameComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf16.count <= 255 &&
        !value.hasSuffix(".") && !value.hasSuffix(" ") &&
        !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F || $0 == "/" || $0 == "\\" })
    }

    private static func isSafeAppName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf16.count <= 251 &&
        !value.hasSuffix(".") && !value.hasSuffix(" ") &&
        !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F || $0 == "/" || $0 == "\\" })
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 255 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { isSafeBundleIdentifierComponent(String($0)) }
    }

    private static func isSafeBundleIdentifierComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_"
        }
    }

    private static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}
