import Foundation

/// Guest virtual memory as a native function reads and writes it: each
/// page it touches is translated once (through the CPU's own MMU and TLB,
/// with the current address space and privilege) and then reached
/// directly in host memory.
///
/// Valid for one native call only — the guest can't remap anything while
/// it runs, but may between calls — so `begin()` forgets every page. A
/// page the guest would fault on (unmapped, or mapped without the access
/// asked for, like a copy-on-write page not yet written) comes back nil,
/// and the caller hands the call back to the guest's own code, which takes
/// the fault properly.
final class GuestPageCache {
    private static let entries = 64

    private unowned(unsafe) let cpu: ARMv7CPU
    private let readTags = UnsafeMutablePointer<UInt32>.allocate(capacity: entries)
    private let readHosts = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: entries)
    private let writeTags = UnsafeMutablePointer<UInt32>.allocate(capacity: entries)
    private let writeHosts = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: entries)

    init(cpu: ARMv7CPU) {
        self.cpu = cpu
        readHosts.initialize(repeating: nil, count: Self.entries)
        writeHosts.initialize(repeating: nil, count: Self.entries)
        begin()
    }

    deinit {
        readTags.deallocate()
        readHosts.deallocate()
        writeTags.deallocate()
        writeHosts.deallocate()
    }

    /// Forgets every translation; call at the start of each native call.
    func begin() {
        // Tag 1 is never a page's (pages are 4 KB aligned).
        readTags.initialize(repeating: 1, count: Self.entries)
        writeTags.initialize(repeating: 1, count: Self.entries)
    }

    @inline(__always)
    private func page(_ address: UInt32, tags: UnsafeMutablePointer<UInt32>, hosts: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                      access: ARMv7MMU.Access) -> UnsafeMutableRawPointer? {
        let base = address & 0xFFFF_F000
        let slot = Int((address >> 12) & UInt32(Self.entries - 1))
        if tags[slot] == base { return hosts[slot] }
        guard let host = cpu.hostAddress(ofVirtual: base, for: access) else { return nil }
        tags[slot] = base
        hosts[slot] = host
        return host
    }

    /// The aligned word at `address`, or nil if the guest couldn't read it.
    @inline(__always)
    func read32(_ address: UInt32) -> UInt32? {
        guard address & 3 == 0, let host = page(address, tags: readTags, hosts: readHosts, access: .read) else { return nil }
        return UInt32(littleEndian: host.load(fromByteOffset: Int(address & 0xFFF), as: UInt32.self))
    }

    /// Stores the aligned word at `address`; false if the guest couldn't.
    @inline(__always)
    func write32(_ value: UInt32, at address: UInt32) -> Bool {
        guard address & 3 == 0, let host = page(address, tags: writeTags, hosts: writeHosts, access: .write) else { return false }
        host.storeBytes(of: value.littleEndian, toByteOffset: Int(address & 0xFFF), as: UInt32.self)
        return true
    }

    /// `count` bytes at `address`, if the guest could read them all.
    func bytes(_ address: UInt32, count: Int, access: ARMv7MMU.Access = .read) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var cursor = address
        while result.count < count {
            guard let host = cpu.hostAddress(ofVirtual: cursor & 0xFFFF_F000, for: access) else { return nil }
            let offset = Int(cursor & 0xFFF)
            let run = min(count - result.count, 0x1000 - offset)
            result.append(contentsOf: UnsafeRawBufferPointer(start: host + offset, count: run))
            cursor &+= UInt32(run)
        }
        return result
    }
}
