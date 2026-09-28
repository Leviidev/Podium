import Foundation

/// The Advanced SIMD (NEON) / VFPv3 extension register file: 32 64-bit
/// `D` registers (`D0`–`D31`), each pair also addressable as one 128-bit
/// `Q` register (`Q0`=`D0`:`D1`, ..., `Q15`=`D30`:`D31`) — not modeled yet
/// since nothing decoded so far needs a `Q`-width operation. Entirely
/// separate from the 16 general-purpose `Registers`: real hardware keeps
/// this as its own register bank with its own encoding space, and reset
/// state is architecturally unpredictable (real hardware doesn't
/// guarantee zero either), so this starting at zero is Podium's own
/// choice, not a traced fact.
struct NEONRegisters {
    /// Inline rather than an `Array`, for the same reason as `Registers`:
    /// no uniqueness check on every write.
    private var storage: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    subscript(index: Int) -> UInt64 {
        get {
            precondition((0..<32).contains(index), "D register index out of range: \(index)")
            return withUnsafeBytes(of: storage) { $0.load(fromByteOffset: index &* 8, as: UInt64.self) }
        }
        set {
            precondition((0..<32).contains(index), "D register index out of range: \(index)")
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: newValue, toByteOffset: index &* 8, as: UInt64.self) }
        }
    }

    /// Single-precision `S` registers alias the low 16 `D` registers:
    /// `S(2n)` is the low half of `D(n)`, `S(2n+1)` the high half.
    func single(_ index: Int) -> UInt32 {
        precondition((0..<32).contains(index), "S register index out of range: \(index)")
        return UInt32(truncatingIfNeeded: self[index / 2] >> (index % 2 == 0 ? 0 : 32))
    }

    mutating func setSingle(_ index: Int, _ value: UInt32) {
        precondition((0..<32).contains(index), "S register index out of range: \(index)")
        let shift: UInt64 = index % 2 == 0 ? 0 : 32
        self[index / 2] = (self[index / 2] & ~(0xFFFF_FFFF << shift)) | (UInt64(value) << shift)
    }
}
