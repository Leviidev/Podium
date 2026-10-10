import Foundation
import Darwin

/// A disk lives in the host filesystem, never in the ARM physical address space.
/// All offsets stay 64-bit, including I/O beyond 4 GiB. Only requested blocks
/// enter guest RAM. The guest execution thread owns this descriptor.
final class FileBackedStorage: VirtualStorageDevice {
    static let capacity: UInt64 = 8 * 1024 * 1024 * 1024
    let blockSize = 512
    let blockCount: Int
    let byteCount: UInt64
    private let descriptor: Int32
    private let temporaryURL: URL?

    struct IOError: Error { let code: Int32 }

    init(url: URL, persistent: Bool) throws {
        var activeURL = url
        var scratchURL: URL?
        if !persistent {
            activeURL = FileManager.default.temporaryDirectory.appendingPathComponent("Podium-disk-\(UUID().uuidString).hfs")
            try Self.sparseCopy(from: url, to: activeURL)
            scratchURL = activeURL
        }
        let fd = open(activeURL.path, O_RDWR)
        guard fd >= 0 else {
            if let scratchURL { try? FileManager.default.removeItem(at: scratchURL) }
            throw IOError(code: errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size % 512 == 0 else {
            close(fd)
            if let scratchURL { try? FileManager.default.removeItem(at: scratchURL) }
            throw IOError(code: EINVAL)
        }
        descriptor = fd
        temporaryURL = scratchURL
        byteCount = UInt64(info.st_size)
        blockCount = Int(info.st_size / 512)
    }

    deinit {
        close(descriptor)
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    func readBlocks(at index: Int, count: Int) throws -> Data {
        guard index >= 0, count >= 0, index <= blockCount, count <= blockCount - index else {
            throw VirtualStorageError.outOfRange(index: index, count: count)
        }
        return try read(at: UInt64(index) * 512, count: count * 512)
    }

    func writeBlocks(_ data: Data, at index: Int) throws {
        guard data.count % 512 == 0 else { throw VirtualStorageError.sizeMismatch }
        guard index >= 0, index <= blockCount, data.count / 512 <= blockCount - index else {
            throw VirtualStorageError.outOfRange(index: index, count: data.count / 512)
        }
        try write(data, at: UInt64(index) * 512)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= byteCount, UInt64(count) <= byteCount - offset else { throw IOError(code: EINVAL) }
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var done = 0
            while done < count {
                let n = pread(descriptor, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset + UInt64(done)))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw IOError(code: n == 0 ? EIO : errno) }
                done += n
            }
        }
        return bytes
    }

    func write(_ bytes: Data, at offset: UInt64) throws {
        guard offset <= byteCount, UInt64(bytes.count) <= byteCount - offset else { throw IOError(code: EINVAL) }
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var done = 0
            while done < bytes.count {
                let n = pwrite(descriptor, buffer.baseAddress!.advanced(by: done), bytes.count - done, off_t(offset + UInt64(done)))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw IOError(code: n == 0 ? EIO : errno) }
                done += n
            }
        }
    }

    func synchronize() throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw IOError(code: errno)
        }
    }

    /// APFS clone preserves holes and is cheap. The fallback skips zero chunks
    /// instead of expanding all eight GiB into allocated host blocks.
    static func sparseCopy(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! NSNumber).uint64Value
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw IOError(code: EIO) }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.truncate(atOffset: size)
            var offset: UInt64 = 0
            while offset < size {
                guard let chunk = try input.read(upToCount: Int(min(1 << 20, size - offset))), !chunk.isEmpty else { throw IOError(code: EIO) }
                if chunk.contains(where: { $0 != 0 }) {
                    try output.seek(toOffset: offset)
                    try output.write(contentsOf: chunk)
                }
                offset += UInt64(chunk.count)
            }
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
