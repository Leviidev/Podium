import Foundation

/// The Advanced SIMD (NEON) / VFPv3 extension register file: 32 64-bit
/// `D` registers (`D0`–`D31`), each pair also addressable as one 128-bit
/// `Q` register (`Q0`=`D0`:`D1`, ..., `Q15`=`D30`:`D31`). Architecturally
/// its own bank, separate from the 16 general-purpose `Registers`, though
/// stored beside them. Reset state is unpredictable on real hardware
/// (which doesn't guarantee zero either), so starting at zero is Podium's
/// own choice, not a traced fact.
struct NEONRegisters {
    /// In the block `Registers` allocates (see `Registers.extensionOffset`),
    /// where translated code reads and writes them directly. A copy of
    /// `NEONRegisters` refers to the same registers.
    let storage: UnsafeMutablePointer<UInt64>

    subscript(index: Int) -> UInt64 {
        get {
            precondition((0..<32).contains(index), "D register index out of range: \(index)")
            return storage[index]
        }
        nonmutating set {
            precondition((0..<32).contains(index), "D register index out of range: \(index)")
            storage[index] = newValue
        }
    }

    /// Single-precision `S` registers alias the low 16 `D` registers:
    /// `S(2n)` is the low half of `D(n)`, `S(2n+1)` the high half.
    func single(_ index: Int) -> UInt32 {
        precondition((0..<32).contains(index), "S register index out of range: \(index)")
        return UnsafeMutableRawPointer(storage).load(fromByteOffset: index &* 4, as: UInt32.self)
    }

    func setSingle(_ index: Int, _ value: UInt32) {
        precondition((0..<32).contains(index), "S register index out of range: \(index)")
        UnsafeMutableRawPointer(storage).storeBytes(of: value, toByteOffset: index &* 4, as: UInt32.self)
    }
}
