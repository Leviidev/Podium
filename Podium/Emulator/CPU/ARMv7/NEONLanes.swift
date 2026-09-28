import Foundation

/// A NEON operation's elements, held inline. The executor used to pull
/// them into `[UInt64]` arrays — several heap allocations for every NEON
/// instruction, in code (memcpy, zlib, the software compositor, the
/// kernel's SHA-1) that runs them back to back. 32 lanes covers every
/// operation: two Q registers of bytes, interleaved.
struct NEONLanes: RandomAccessCollection, MutableCollection {
    static let capacity = 32
    private var storage: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private(set) var count: Int

    init(repeating value: UInt64, count: Int) {
        precondition(count <= Self.capacity, "too many NEON lanes: \(count)")
        self.count = count
        if value != 0 { for index in 0..<count { self[index] = value } }
    }

    init() { count = 0 }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(index: Int) -> UInt64 {
        get { withUnsafeBytes(of: storage) { $0.load(fromByteOffset: index &* 8, as: UInt64.self) } }
        set { withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: newValue, toByteOffset: index &* 8, as: UInt64.self) } }
    }

    mutating func append(_ value: UInt64) {
        precondition(count < Self.capacity, "too many NEON lanes")
        count += 1
        self[count - 1] = value
    }
}
