import Foundation
#if canImport(Darwin)
import Darwin
import libkern.OSCacheControl
#endif

/// The memory translated code lives in: one region, allocated the first
/// time it's asked for and kept for the life of the process. On iOS it
/// comes from the attached debugger (StikDebug) — each request is a round
/// trip to it, and later ones are unreliable — so there is never a second
/// allocation: when the region fills up, everything in it is discarded
/// and translation starts over in the same memory.
///
/// Code is written at `writable` and runs at `executable`; they're the
/// same memory, at one address or two depending on how it was obtained.
final class JITMemory {
    let executable: UnsafeMutableRawPointer
    let writable: UnsafeMutableRawPointer
    let size: Int
    /// macOS keeps `MAP_JIT` memory either writable or executable, per
    /// thread, switched with `pthread_jit_write_protect_np`.
    private let switchesWriteProtection: Bool

    /// How the region was obtained, for the boot log: an RWX MAP_JIT
    /// mapping, the debugger-prepared dual-mapped pair, or nothing.
    let modeDescription: String

    static let regionSize = 64 << 20

    /// nil when this process can't run generated code (on iOS, when no
    /// debugger has prepared memory for it).
    /// The allocated region, or nil while no mode has succeeded. A nil
    /// result is returned again cheaply until `retryAllocation` is called:
    /// StikDebug can attach to a running process at any time, and the next
    /// power-on should then try again (each attempt is cheap — one refused
    /// mmap and possibly one unserviced breakpoint). After a success, the
    /// region is kept for the life of the process.
    private static var stored: JITMemory?
    private static var allocationFailed = false
    private static let allocationLock = NSLock()

    static var shared: JITMemory? {
        allocationLock.lock()
        defer { allocationLock.unlock() }
        if stored == nil, allocationFailed {
            allocationFailed = false
            stored = allocate()
            if stored == nil { allocationFailed = true }
        }
        return stored
    }

    private init(executable: UnsafeMutableRawPointer, writable: UnsafeMutableRawPointer, size: Int, switchesWriteProtection: Bool, modeDescription: String) {
        self.executable = executable
        self.writable = writable
        self.size = size
        self.switchesWriteProtection = switchesWriteProtection
        self.modeDescription = modeDescription
    }

    private static func allocate() -> JITMemory? {
        #if os(macOS)
        guard let region = mmap(nil, regionSize, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0),
              region != MAP_FAILED else { return nil }
        return JITMemory(executable: region, writable: region, size: regionSize, switchesWriteProtection: true, modeDescription: "RWX MAP_JIT")
        #elseif os(iOS)
        var writable: UnsafeMutableRawPointer?
        var mode = PodiumJITModeNone
        guard let executable = podium_jit_allocate(regionSize, &writable, &mode), let writable else { return nil }
        let description: String
        switch mode {
        case PodiumJITModeRWX: description = "RWX MAP_JIT"
        case PodiumJITModeDualMapped: description = "debugger dual-mapped"
        default: description = "unknown mode"
        }
        return JITMemory(executable: executable, writable: writable, size: regionSize, switchesWriteProtection: false, modeDescription: description)
        #else
        return nil
        #endif
    }

    /// Marks a retryable failure. Called by `shared` when an allocation
    /// attempt comes back nil, so a later call (the next power-on, after
    /// the user attached StikDebug) tries again.

    /// Makes the region writable on this thread, for `body`, then
    /// executable again, with the instruction cache made coherent for the
    /// bytes at `offset..<offset + length`.
    func write(at offset: Int, length: Int, _ body: (UnsafeMutableRawPointer) -> Void) {
        #if os(macOS)
        if switchesWriteProtection { pthread_jit_write_protect_np(0) }
        #endif
        body(writable + offset)
        #if os(macOS)
        if switchesWriteProtection { pthread_jit_write_protect_np(1) }
        #endif
        sys_icache_invalidate(executable + offset, length)
    }
}
