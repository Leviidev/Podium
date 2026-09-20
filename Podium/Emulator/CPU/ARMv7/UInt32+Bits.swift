import Foundation

extension UInt32 {
    /// Extracts bits [high:low] (inclusive, high >= low), right-aligned —
    /// e.g. `word.bitField(27, 26)` for a 2-bit field at that position.
    func bitField(_ high: Int, _ low: Int) -> UInt32 {
        let width = high - low + 1
        let mask: UInt32 = width >= 32 ? 0xFFFF_FFFF : ((1 << width) - 1)
        return (self >> low) & mask
    }

    func bit(_ index: Int) -> Bool {
        (self >> index) & 1 != 0
    }
}
