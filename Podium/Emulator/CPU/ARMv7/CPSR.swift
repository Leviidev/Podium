import Foundation

/// The Current Program Status Register: condition flags plus processor
/// mode/state bits, backed by one raw 32-bit value exactly as the real
/// register is laid out.
///
/// SPSR (the banked "saved" CPSR used to restore state on exception
/// return) is not modeled yet — there is no exception entry/exit for it
/// to matter to. The condition flags (N/Z/C/V) are read by every
/// conditional instruction, and `irqDisabled`/`fiqDisabled` are real,
/// `CPS`-settable state — but since this CPU never raises an interrupt,
/// nothing yet reads them back to decide whether one should be taken.
/// The mode bits are stored faithfully but not yet acted on (no mode
/// banking, no Thumb decode).
struct CPSR {
    var rawValue: UInt32

    private static let negativeBit: UInt32 = 1 << 31
    private static let zeroBit: UInt32 = 1 << 30
    private static let carryBit: UInt32 = 1 << 29
    private static let overflowBit: UInt32 = 1 << 28
    private static let irqDisabledBit: UInt32 = 1 << 7
    private static let fiqDisabledBit: UInt32 = 1 << 6
    private static let thumbBit: UInt32 = 1 << 5

    /// System mode (0b11111): all registers unbanked, matching
    /// `Registers`' unbanked model. Chosen over User mode only so
    /// privileged-only encodings this CPU might later decode don't need
    /// a separate "are we privileged" special case yet.
    static let resetValue: UInt32 = 0b1_1111

    init(rawValue: UInt32 = CPSR.resetValue) {
        self.rawValue = rawValue
    }

    var negative: Bool {
        get { rawValue & Self.negativeBit != 0 }
        set { setBit(Self.negativeBit, newValue) }
    }

    var zero: Bool {
        get { rawValue & Self.zeroBit != 0 }
        set { setBit(Self.zeroBit, newValue) }
    }

    var carry: Bool {
        get { rawValue & Self.carryBit != 0 }
        set { setBit(Self.carryBit, newValue) }
    }

    var overflow: Bool {
        get { rawValue & Self.overflowBit != 0 }
        set { setBit(Self.overflowBit, newValue) }
    }

    var irqDisabled: Bool {
        get { rawValue & Self.irqDisabledBit != 0 }
        set { setBit(Self.irqDisabledBit, newValue) }
    }

    var fiqDisabled: Bool {
        get { rawValue & Self.fiqDisabledBit != 0 }
        set { setBit(Self.fiqDisabledBit, newValue) }
    }

    var thumbState: Bool {
        get { rawValue & Self.thumbBit != 0 }
        set { setBit(Self.thumbBit, newValue) }
    }

    private mutating func setBit(_ mask: UInt32, _ value: Bool) {
        if value {
            rawValue |= mask
        } else {
            rawValue &= ~mask
        }
    }

    mutating func reset() {
        rawValue = Self.resetValue
    }

    /// Whether an instruction carrying this condition should execute,
    /// per the current flags. `.never` (0b1111) is the reserved encoding
    /// and never executes.
    func isSatisfied(_ condition: ARMCondition) -> Bool {
        switch condition {
        case .equal: return zero
        case .notEqual: return !zero
        case .carrySet: return carry
        case .carryClear: return !carry
        case .negative: return negative
        case .positiveOrZero: return !negative
        case .overflow: return overflow
        case .noOverflow: return !overflow
        case .unsignedHigher: return carry && !zero
        case .unsignedLowerOrSame: return !carry || zero
        case .greaterOrEqual: return negative == overflow
        case .lessThan: return negative != overflow
        case .greaterThan: return !zero && (negative == overflow)
        case .lessOrEqual: return zero || (negative != overflow)
        case .always: return true
        case .never: return false
        }
    }
}
