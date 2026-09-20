import Foundation
#if canImport(Darwin)
import Darwin
import libkern.OSCacheControl
#endif

enum ExecutableMemoryError: Error {
    /// `mmap(MAP_JIT)` itself failed outright.
    case allocationFailed
    /// `mprotect()` refused to make the page writable or executable —
    /// the expected outcome on a plain sideloaded iOS build without a
    /// debugger-granted dynamic-codesigning right. `JITEngine` treats
    /// this as "JIT unavailable" and falls back to interpretation
    /// rather than treating it as fatal.
    case writeProtectionUnavailable
}

/// Allocates RWX memory the W^X-safe way Apple Silicon requires: pages
/// mapped with `MAP_JIT`, toggled between writable and executable around
/// each write rather than ever being both at once.
///
/// Apple's per-thread toggle for this (`pthread_jit_write_protect_np`)
/// is explicitly unavailable on iOS — the SDK marks it
/// `__API_UNAVAILABLE(ios, tvos, watchos, driverkit)` in
/// `<pthread/pthread.h>` — and its would-be iOS-era replacement
/// (`pthread_jit_write_with_callback_np`) is separately marked
/// `__SWIFT_UNAVAILABLE_MSG("This interface cannot be safely used from
/// Swift")` in that same header. Neither is a gap to route around with a
/// private-API lookup; Apple has deliberately withheld direct
/// write-protection control from third-party Swift code on iOS. This
/// uses the ordinary, always-available POSIX `mprotect()` instead — the
/// standard portable mechanism for the same job on any Unix-like system,
/// not an iOS-specific bypass. Whether it actually succeeds in making a
/// newly-written page executable still depends on the process holding
/// the underlying dynamic-codesigning right (an entitlement, or a
/// debugger attached) — see `JITEngine`'s doc comment for what that
/// means in practice for this app.
enum ExecutableMemoryAllocator {
    static func allocate(byteCount: Int) throws -> UnsafeMutableRawPointer {
        let pointer = mmap(
            nil,
            roundedUpToPageSize(byteCount),
            PROT_READ | PROT_WRITE | PROT_EXEC,
            MAP_PRIVATE | MAP_ANON | MAP_JIT,
            -1,
            0
        )
        guard let pointer, pointer != MAP_FAILED else {
            throw ExecutableMemoryError.allocationFailed
        }
        return pointer
    }

    static func deallocate(_ pointer: UnsafeMutableRawPointer, byteCount: Int) {
        munmap(pointer, roundedUpToPageSize(byteCount))
    }

    /// Writes `words` into `pointer` (whose backing allocation must be
    /// at least `words.count * 4` bytes), re-protects the page as
    /// execute-only, and flushes the instruction cache so the CPU can't
    /// observe stale or partially-written code — required on ARM64,
    /// where instruction and data caches aren't coherent with each
    /// other.
    static func write(_ words: [UInt32], to pointer: UnsafeMutableRawPointer) throws {
        let byteCount = words.count * MemoryLayout<UInt32>.size
        let protectedSize = roundedUpToPageSize(byteCount)

        guard mprotect(pointer, protectedSize, PROT_READ | PROT_WRITE) == 0 else {
            throw ExecutableMemoryError.writeProtectionUnavailable
        }

        words.withUnsafeBufferPointer { buffer in
            pointer.copyMemory(from: buffer.baseAddress!, byteCount: byteCount)
        }

        guard mprotect(pointer, protectedSize, PROT_READ | PROT_EXEC) == 0 else {
            throw ExecutableMemoryError.writeProtectionUnavailable
        }

        sys_icache_invalidate(pointer, byteCount)
    }

    private static func roundedUpToPageSize(_ byteCount: Int) -> Int {
        let pageSize = Int(getpagesize())
        return ((byteCount + pageSize - 1) / pageSize) * pageSize
    }
}
