import Foundation

/// A contiguous, bounds-checked block of guest physical memory.
///
/// Backed by one anonymous `mmap` reservation rather than a Swift array:
/// pages the guest never touches cost the host nothing, the base pointer
/// is stable for the object's lifetime (the JIT's fast path holds it), and
/// `mapFile(_:at:shared:)` can map file-backed pages into guest DRAM without
/// reading the whole file into host memory up front.
final class FlatPhysicalMemory: MemoryBus {
    var window: (first: UInt32, count: UInt64)? { (baseAddress, UInt64(length)) }
    let baseAddress: UInt32
    let length: Int
    private let pointer: UnsafeMutableRawPointer
    private struct SharedFileMapping {
        let url: URL
        let descriptor: Int32
        let offset: Int
        let length: Int
    }
    private let mappingsLock = NSLock()
    private var sharedFileMappings: [SharedFileMapping] = []

    init(length: Int, baseAddress: UInt32 = 0) {
        precondition(length > 0, "Memory region must have a nonzero length")
        self.baseAddress = baseAddress
        self.length = length
        guard let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), mapped != MAP_FAILED else {
            preconditionFailure("couldn't reserve \(length) bytes of guest memory")
        }
        self.pointer = mapped
    }

    deinit {
        munmap(pointer, length)
        for mapping in sharedFileMappings { close(mapping.descriptor) }
    }

    enum MapFileError: Error {
        case misaligned(address: UInt32)
        case outOfRange(address: UInt32, length: Int)
        case cannotOpen(path: String, errno: Int32)
        case mapFailed(errno: Int32)
        case flushFailed(path: String, errno: Int32)
    }

    /// Maps `url` over guest memory at `address`, private by default.
    /// Private mappings keep guest writes in memory; shared mappings write
    /// them to the backing file so they can survive process exit. `address`
    /// must sit on a host page boundary within this region. Returns the
    /// number of bytes mapped (the file's size).
    @discardableResult
    func mapFile(_ url: URL, at address: UInt32, shared: Bool = false) throws -> Int {
        let pageSize = Int(getpagesize())
        guard address >= baseAddress, Int(address - baseAddress) % pageSize == 0 else {
            throw MapFileError.misaligned(address: address)
        }
        let fd = open(url.path, shared ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw MapFileError.cannotOpen(path: url.path, errno: errno) }
        var retainDescriptor = false
        defer { if !retainDescriptor { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw MapFileError.cannotOpen(path: url.path, errno: errno) }
        let size = Int(info.st_size)
        let offset = Int(address - baseAddress)
        guard size > 0, offset + size <= length else { throw MapFileError.outOfRange(address: address, length: size) }
        let target = pointer + offset
        guard let mapped = mmap(target, size, PROT_READ | PROT_WRITE, (shared ? MAP_SHARED : MAP_PRIVATE) | MAP_FIXED, fd, 0), mapped == target else {
            throw MapFileError.mapFailed(errno: errno)
        }
        if shared {
            mappingsLock.lock()
            sharedFileMappings.append(SharedFileMapping(url: url, descriptor: fd, offset: offset, length: size))
            retainDescriptor = true
            mappingsLock.unlock()
        }
        return size
    }

    /// Synchronously commits guest writes in every shared file mapping to
    /// its backing file. Call after the emulation thread has stopped so a
    /// normal power-off cannot leave dirty guest-disk pages pending in the
    /// host's page cache.
    func flushSharedFileMappings() throws {
        mappingsLock.lock()
        let mappings = sharedFileMappings
        mappingsLock.unlock()

        for mapping in mappings {
            let address = pointer + mapping.offset
            guard msync(address, mapping.length, MS_SYNC) == 0 else {
                let flushError = errno
                throw MapFileError.flushFailed(path: mapping.url.path, errno: flushError)
            }
            let result = fsync(mapping.descriptor)
            let syncError = errno
            guard result == 0 else {
                throw MapFileError.flushFailed(path: mapping.url.path, errno: syncError)
            }
        }
    }

    func fastPathRegion(for address: UInt32) -> (pointer: UnsafeMutableRawPointer, regionBaseAddress: UInt32, regionLength: Int)? {
        guard address >= baseAddress, UInt64(address - baseAddress) < UInt64(length) else {
            return nil
        }
        return (pointer, baseAddress, length)
    }

    func readByte(at address: UInt32) throws -> UInt8 {
        pointer.load(fromByteOffset: try offset(for: address, width: 1), as: UInt8.self)
    }

    func readWord16(at address: UInt32) throws -> UInt16 {
        UInt16(littleEndian: pointer.loadUnaligned(fromByteOffset: try offset(for: address, width: 2), as: UInt16.self))
    }

    func readWord32(at address: UInt32) throws -> UInt32 {
        UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: try offset(for: address, width: 4), as: UInt32.self))
    }

    func writeByte(_ value: UInt8, at address: UInt32) throws {
        pointer.storeBytes(of: value, toByteOffset: try offset(for: address, width: 1), as: UInt8.self)
    }

    func writeWord16(_ value: UInt16, at address: UInt32) throws {
        pointer.storeBytes(of: value.littleEndian, toByteOffset: try offset(for: address, width: 2), as: UInt16.self)
    }

    func writeWord32(_ value: UInt32, at address: UInt32) throws {
        pointer.storeBytes(of: value.littleEndian, toByteOffset: try offset(for: address, width: 4), as: UInt32.self)
    }

    func writeBytes(_ bytes: Data, at address: UInt32) throws {
        guard !bytes.isEmpty else { return }
        let index = try offset(for: address, width: bytes.count)
        bytes.withUnsafeBytes { source in
            (pointer + index).copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }

    func readBytes(_ count: Int, at address: UInt32) throws -> Data {
        guard count > 0 else { return Data() }
        let index = try offset(for: address, width: count)
        return Data(bytes: pointer + index, count: count)
    }

    /// Translates a guest address to a byte offset, or throws. Uses
    /// 64-bit arithmetic throughout so an address/width near `UInt32.max`
    /// can't wrap around and defeat the bounds check.
    private func offset(for address: UInt32, width: Int) throws -> Int {
        guard address >= baseAddress else {
            throw MemoryAccessError.unmappedAddress(address)
        }
        let relative = UInt64(address - baseAddress)
        guard relative < UInt64(length) else {
            throw MemoryAccessError.unmappedAddress(address)
        }
        guard relative + UInt64(width) <= UInt64(length) else {
            throw MemoryAccessError.outOfBounds(address: address, length: width)
        }
        return Int(relative)
    }
}
