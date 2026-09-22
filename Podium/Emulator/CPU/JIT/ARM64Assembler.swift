import Foundation

/// Encodes the small, fixed subset of AArch64 instructions the JIT
/// translator needs, as real machine code words — not a simulation of
/// them. Each base constant here is a documented AArch64 encoding (ARM's
/// own Architecture Reference Manual), used at 32-bit (`W`-register)
/// width throughout so ARMv7's 32-bit wraparound arithmetic falls out
/// naturally from the host's own 32-bit operations.
///
/// Scope is deliberately narrow: enough to move an immediate into a
/// register, copy a register, combine two registers with the basic
/// logical/arithmetic ops (`AND`/`BIC`/`ORR`/`EOR`/`ADD`/`SUB`/`MVN`,
/// always unshifted — every caller here only ever needs shift==0), and
/// load/store a 32-bit word at a small unsigned offset from a base
/// pointer — which is exactly what `JITTranslator`/`ThumbJITTranslator`
/// need to operate on the guest register file through a pointer passed
/// in `x0`. Nothing here does control flow; generated blocks are always
/// straight-line code ending in `ret`.
enum ARM64Assembler {
    /// `MOVZ Wd, #imm16` — imm16 must fit in 16 bits unsigned.
    static func movz32(rd: Int, imm16: UInt16, shiftBy16: Bool = false) -> UInt32 {
        0x5280_0000 | (shiftBy16 ? 1 << 21 : 0) | (UInt32(imm16) << 5) | reg(rd)
    }

    /// `MOVK Wd, #imm16{, LSL #16}` — merges `imm16` into the upper or
    /// lower halfword of `Wd`, leaving the other half untouched. Paired
    /// with `movz32` (lower half first, `shiftBy16: false`, then this
    /// with `shiftBy16: true`) to materialize an arbitrary 32-bit
    /// immediate into a scratch register in two instructions.
    static func movk32(rd: Int, imm16: UInt16, shiftBy16: Bool) -> UInt32 {
        0x7280_0000 | (shiftBy16 ? 1 << 21 : 0) | (UInt32(imm16) << 5) | reg(rd)
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

    /// `AND Wd, Wn, Wm` (shifted register, no shift).
    static func and32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x0A00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    /// `BIC Wd, Wn, Wm` (`Wn AND NOT Wm`, shifted register, no shift).
    static func bic32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x0A20_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    /// `ORR Wd, Wn, Wm` (shifted register, no shift).
    static func orr32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x2A00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    /// `EOR Wd, Wn, Wm` (shifted register, no shift).
    static func eor32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x4A00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    /// `MVN Wd, Wm` (the standard alias for `ORN Wd, WZR, Wm`).
    static func mvn32(rd: Int, rm: Int) -> UInt32 {
        0x2A20_03E0 | (reg(rm) << 16) | reg(rd)
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

    /// `ADD Wd, Wn, #imm12` (immediate, no shift). `imm12` must fit
    /// unsigned in 12 bits (0...4095) — the small positive immediate
    /// offsets real load/store instructions carry are comfortably
    /// within that range.
    static func addImmediate32(rd: Int, rn: Int, imm12: UInt32) -> UInt32 {
        precondition(imm12 <= 0xFFF, "imm12 out of encodable range")
        return 0x1100_0000 | (imm12 << 10) | (reg(rn) << 5) | reg(rd)
    }

    /// `CMP Wn, Wm` (the standard alias for `SUBS WZR, Wn, Wm`) — sets
    /// flags only, discards the result.
    static func cmp32(rn: Int, rm: Int) -> UInt32 {
        0x6B00_001F | (reg(rm) << 16) | (reg(rn) << 5)
    }

    /// `B.HS #(instructionsForward*4)` — branches forward past
    /// `instructionsForward` instructions (this one included in the
    /// count, i.e. `1` branches to the very next word) when the last
    /// flag-setting compare found the left operand unsigned `>=` the
    /// right (`HS`/`CS`) — used for the "address in bounds" check in
    /// `ThumbJITTranslator`'s load/store fast path (`CMP` against the
    /// region length first negates the sense, so this fires exactly when
    /// the address is *out* of bounds). `instructionsForward` must be
    /// positive — only forward branches are needed here, since every
    /// compiled block is straight-line code laid out in one pass.
    static func branchIfHS(instructionsForward: Int) -> UInt32 {
        precondition(instructionsForward > 0 && instructionsForward < (1 << 18), "branch target out of encodable/expected range")
        let imm19 = UInt32(instructionsForward) & 0x7_FFFF
        return 0x5400_0000 | (imm19 << 5) | 0b0010
    }

    static func branchIfLO(instructionsForward: Int) -> UInt32 {
        precondition(instructionsForward > 0 && instructionsForward < (1 << 18), "branch target out of encodable/expected range")
        let imm19 = UInt32(instructionsForward) & 0x7_FFFF
        return 0x5400_0000 | (imm19 << 5) | 0b0011
    }

    /// `B #(instructionsForward*4)` (unconditional) — same forward-only,
    /// self-inclusive counting convention as `branchIfHS`.
    static func branch(instructionsForward: Int) -> UInt32 {
        precondition(instructionsForward > 0 && instructionsForward < (1 << 25), "branch target out of encodable/expected range")
        return 0x1400_0000 | (UInt32(instructionsForward) & 0x3FF_FFFF)
    }

    /// `LDR Wt, [Xn, Wm, UXTW]` (register offset, 32-bit, zero-extended
    /// 32-bit index) — the fast-path guest-memory read `ThumbJITTranslator`
    /// uses once a load's guest address has been range-checked and turned
    /// into a host-relative offset in `rm`.
    static func ldrWordRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0xB860_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `STR Wt, [Xn, Wm, UXTW]` — the store counterpart of
    /// `ldrWordRegisterOffsetUXTW`.
    static func strWordRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0xB820_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `LDRB Wt, [Xn, Wm, UXTW]` (zero-extends the loaded byte to 32 bits).
    static func ldrbRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0x3860_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `STRB Wt, [Xn, Wm, UXTW]`.
    static func strbRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0x3820_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `LDRH Wt, [Xn, Wm, UXTW]` (zero-extends the loaded halfword to 32 bits).
    static func ldrhRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0x7860_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `STRH Wt, [Xn, Wm, UXTW]`.
    static func strhRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0x7820_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `LDRSB Wt, [Xn, Wm, UXTW]` (sign-extends the loaded byte to 32 bits).
    static func ldrsbRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0x38E0_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    /// `LDRSH Wt, [Xn, Wm, UXTW]` (sign-extends the loaded halfword to 32 bits).
    static func ldrshRegisterOffsetUXTW(rt: Int, rn: Int, rm: Int) -> UInt32 {
        0x78E0_4800 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rt)
    }

    private static func reg(_ index: Int) -> UInt32 {
        precondition((0...31).contains(index), "AArch64 register index out of range: \(index)")
        return UInt32(index)
    }

    static func msr_nzcv(xt: Int) -> UInt32 {
        0xD51B_4200 | reg(xt)
    }

    static func mrs_nzcv(xt: Int) -> UInt32 {
        0xD53B_4200 | reg(xt)
    }

    static func adds32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x2B00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    static func subs32(rd: Int, rn: Int, rm: Int) -> UInt32 {
        0x6B00_0000 | (reg(rm) << 16) | (reg(rn) << 5) | reg(rd)
    }

    static func addsImmediate32(rd: Int, rn: Int, imm12: UInt32) -> UInt32 {
        precondition(imm12 <= 0xFFF, "imm12 out of encodable range")
        return 0x3100_0000 | (imm12 << 10) | (reg(rn) << 5) | reg(rd)
    }

    static func subsImmediate32(rd: Int, rn: Int, imm12: UInt32) -> UInt32 {
        precondition(imm12 <= 0xFFF, "imm12 out of encodable range")
        return 0x7100_0000 | (imm12 << 10) | (reg(rn) << 5) | reg(rd)
    }
}
