import Foundation

/// Encodes the small, fixed subset of AArch64 instructions the JIT
/// translator needs, as real machine code words — not a simulation of
/// them. Each base constant here is a documented AArch64 encoding (ARM's
/// own Architecture Reference Manual), used at 32-bit (`W`-register)
/// width throughout so ARMv7's 32-bit wraparound arithmetic falls out
/// naturally from the host's own 32-bit operations.
///
/// Scope is deliberately narrow: enough to move an immediate into a
/// register, copy a register, add/subtract two registers, and load/store
/// a 32-bit word at a small unsigned offset from a base pointer — which
/// is exactly what `JITTranslator` needs to operate on the guest register
/// file through a pointer passed in `x0`. Nothing here does control flow;
/// generated blocks are always straight-line code ending in `ret`.
enum ARM64Assembler {
    /// `MOVZ Wd, #imm16` — imm16 must fit in 16 bits unsigned.
    static func movz32(rd: Int, imm16: UInt16) -> UInt32 {
        0x5280_0000 | (UInt32(imm16) << 5) | reg(rd)
    }

    /// `MOV Wd, Wm` (the standard alias for `ORR Wd, WZR, Wm`).
    static func movRegister32(rd: Int, rm: Int) -> UInt32 {
        0x2A00_03E0 | (reg(rm) << 16) | reg(rd)
    }

    /// `ADD Wd, Wn, Wm` (shifted register, no shift).
    static func add32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x0B00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    /// `SUB Wd, Wn, Wm` (shifted register, no shift).
    static func sub32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x4B00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    /// `LDR Wt, [Xn, #byteOffset]` — unsigned offset form; `byteOffset`
    /// must be a non-negative multiple of 4, and small enough to fit the
    /// 12-bit scaled immediate (0...16380). Guest register-array offsets
    /// (0, 4, 8, ... 60) are comfortably within that range.
    static func ldrWordUnsignedOffset(rt: Int, rn: Int, byteOffset: Int) -> UInt32 {
        precondition(byteOffset >= 0 && byteOffset % 4 == 0 && byteOffset / 4 <= 0xFFF, "offset out of encodable range")
        let scaled = UInt32(byteOffset / 4)
        return 0xB940_0000 | (scaled << 10) | (reg(rn) << 5) | reg(rt)
    }

    /// `STR Wt, [Xn, #byteOffset]` — same offset constraints as `ldrWordUnsignedOffset`.
    static func strWordUnsignedOffset(rt: Int, rn: Int, byteOffset: Int) -> UInt32 {
        precondition(byteOffset >= 0 && byteOffset % 4 == 0 && byteOffset / 4 <= 0xFFF, "offset out of encodable range")
        let scaled = UInt32(byteOffset / 4)
        return 0xB900_0000 | (scaled << 10) | (reg(rn) << 5) | reg(rt)
    }

    /// `RET` (implicitly via `x30`/LR, as set by the caller's `blr`).
    static let ret: UInt32 = 0xD65F_03C0

    private static func reg(_ index: Int) -> UInt32 {
        precondition((0...31).contains(index), "AArch64 register index out of range: \(index)")
        return UInt32(index)
    }
}
