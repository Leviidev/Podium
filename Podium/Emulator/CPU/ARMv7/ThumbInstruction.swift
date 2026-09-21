import Foundation

/// Thumb's 16 data-processing opcodes for the "modified immediate" and
/// register-register (format 4) families, numbered so they line up with
/// `DataProcessingOp` conceptually even though Thumb's own bit encoding
/// differs from ARM's. Only the subset actually decoded is listed as
/// meaningful; `ThumbDecoder` restricts which values it accepts per
/// instruction family.
enum ThumbDataProcessingOp: UInt8 {
    case and = 0b0000
    case eor = 0b0001
    case lsl = 0b0010 // format 4 only (register-shift by register)
    case lsr = 0b0011 // format 4 only
    case asr = 0b0100 // format 4 only
    case adc = 0b0101
    case sbc = 0b0110
    case ror = 0b0111 // format 4 only
    case tst = 0b1000
    case rsb = 0b1001 // format 4 "NEG" (Rd = 0 - Rm)
    case cmp = 0b1010
    case cmn = 0b1011
    case orr = 0b1100
    case mul = 0b1101 // format 4 only
    case bic = 0b1110
    case mvn = 0b1111
}

/// `MOVS`/`CMP Rd/Rn, #imm8` (format 3) and, sharing the same shape,
/// `ADDS`/`SUBS Rd, #imm8` — the four two-bit-`op`-selected 16-bit
/// immediate instructions.
struct ThumbImmediateInstruction: Equatable {
    enum Op: UInt8 { case mov = 0b00, cmp = 0b01, add = 0b10, sub = 0b11 }
    let op: Op
    let rdn: Int
    let imm8: UInt32
}

/// Format 2: `ADDS`/`SUBS Rd, Rn, Rm` (register) and `ADDS`/`SUBS Rd,
/// Rn, #imm3` (3-bit immediate) — always flag-setting, like every
/// other low-register Thumb-1 data-processing form. Verified against a
/// real `subs r4, r7, #4` word from the actual kernel.
struct ThumbAddSubInstruction: Equatable {
    enum Operand2: Equatable {
        case register(Int)
        case immediate(UInt32)
    }
    let isSub: Bool
    let rd: Int
    let rn: Int
    let operand2: Operand2
}

/// Format 4: two-register ALU operations (`AND`/`EOR`/.../`MVN`),
/// always flag-setting, always `Rdn = Rdn OP Rm`.
struct ThumbAluInstruction: Equatable {
    let op: ThumbDataProcessingOp
    let rdn: Int
    let rm: Int
}

/// Format 5: hi-register `ADD`/`CMP`/`MOV` (`Rdn`/`Rm` can address
/// r8–r15, unlike most 16-bit Thumb encodings, which is exactly why
/// these exist as a separate format) and `BX`/`BLX` (register).
struct ThumbHiRegisterInstruction: Equatable {
    enum Op: UInt8 { case add = 0b00, cmp = 0b01, mov = 0b10 }
    let op: Op
    let rdn: Int
    let rm: Int
}

/// `BX`/`BLX` (register, format 5's third `op` value): branches to
/// `rm`, switching to ARM state when its bit 0 is clear. `link` selects
/// `BLX` (sets `LR`) vs plain `BX`.
struct ThumbBranchExchangeInstruction: Equatable {
    let rm: Int
    let link: Bool
}

/// Format 9/10/11: `LDR`/`STR` (word or byte) with a 5-bit immediate
/// offset (`Rn` base) or `Rn = SP` (format 11's own 8-bit immediate,
/// normalized into the same shape here).
enum ThumbLoadStoreSize: Equatable {
    case word
    case byte
    case halfword
}

/// Formats 7 and 8 (they share one contiguous 3-bit opcode field, so
/// this codebase decodes them together): register-offset `STR`/
/// `STRH`/`STRB`/`LDRSB`/`LDR`/`LDRH`/`LDRB`/`LDRSH Rd, [Rn, Rm]`.
/// Verified against a real `ldrb r0, [r1, r0]` word from the actual
/// kernel.
struct ThumbLoadStoreRegisterOffsetInstruction: Equatable {
    enum Op: UInt8 {
        case str = 0b000
        case strh = 0b001
        case strb = 0b010
        case ldrsb = 0b011
        case ldr = 0b100
        case ldrh = 0b101
        case ldrb = 0b110
        case ldrsh = 0b111
    }
    let op: Op
    let rd: Int
    let rn: Int
    let rm: Int
}

struct ThumbLoadStoreImmediateInstruction: Equatable {
    let isLoad: Bool
    let size: ThumbLoadStoreSize
    let rn: Int
    let rt: Int
    /// Already scaled (×4 word, ×1 byte, ×2 halfword) — the raw field's
    /// own scale factor differs per format, resolved at decode time.
    let offset: UInt32
}

/// Format 12: `ADD Rd, PC/SP, #imm8*4` — an address-formation add, not
/// a flag-setting one.
struct ThumbAddressInstruction: Equatable {
    let usesSP: Bool
    let rd: Int
    let imm8: UInt32
}

/// Format 13: `ADD`/`SUB SP, SP, #imm7*4`.
struct ThumbAdjustStackInstruction: Equatable {
    let subtract: Bool
    let imm7: UInt32
}

/// Format 14: `PUSH`/`POP`, 16-bit form (low registers only, plus
/// `LR`/`PC`). See `ThumbBlockDataTransferInstruction` for the 32-bit
/// form covering the full register file.
struct ThumbPushPopInstruction: Equatable {
    let isLoad: Bool // POP
    let registerList: UInt16 // bits 0-7 = r0-r7; bit 8 = LR (push) or PC (pop), pre-shifted into place by the decoder
}

/// Format 16: conditional branch (`B<cond>`).
struct ThumbConditionalBranchInstruction: Equatable {
    let condition: ARMCondition
    let signedOffset: Int32
}

/// Format 18: unconditional branch (`B`), 16-bit, ±2KB range.
struct ThumbBranchInstruction: Equatable {
    let signedOffset: Int32
}

/// `CBZ`/`CBNZ`: branch if `rn` is (not) zero, unconditionally
/// available regardless of `ITSTATE` (these can't appear inside an `IT`
/// block per the ARM ARM, so unlike every other Thumb instruction here
/// they're never condition-gated).
struct ThumbCompareBranchInstruction: Equatable {
    let branchIfNonZero: Bool
    let rn: Int
    let offset: UInt32
}

/// Format 1: `LSL`/`LSR`/`ASR Rd, Rm, #imm5` — shift by an immediate,
/// always flag-setting. Uses ARM state's own immediate-shift
/// conventions (an encoded `LSR`/`ASR #0` means `#32`; `ROR` isn't part
/// of this format), so it shares `ShiftType`/`ShifterOperand.applyShift`
/// rather than a Thumb-specific shift representation.
struct ThumbShiftImmediateInstruction: Equatable {
    let shiftType: ShiftType
    let rd: Int
    let rm: Int
    let imm5: UInt8
}

/// `SXTH`/`SXTB`/`UXTH`/`UXTB`: sign- or zero-extend the bottom
/// halfword/byte of `Rm` into `Rd` (no rotation — the rotated-source
/// form is a 32-bit Thumb-2 encoding this CPU doesn't decode).
enum ThumbExtendKind: UInt8 {
    case signedHalfword = 0b00
    case signedByte = 0b01
    case unsignedHalfword = 0b10
    case unsignedByte = 0b11
}

struct ThumbExtendInstruction: Equatable {
    let kind: ThumbExtendKind
    let rm: Int
    let rd: Int
}

/// `IT`: begins a 1-4 instruction conditional-execution block. See
/// `ARMv7CPU.ThumbITState` for how `firstCondition`/`mask` drive the
/// per-instruction condition that follows.
struct ThumbItInstruction: Equatable {
    let firstCondition: UInt8 // 4-bit condition field, not yet an ARMCondition (bit0 can flip per mask)
    let mask: UInt8
}

/// `MOVW`/`MOVT` (Thumb-2, 32-bit): identical purpose to their ARM-state
/// counterparts (`MovWideInstruction`) — a real 16-bit immediate into a
/// register half — just a different host encoding.
struct ThumbMovWideInstruction: Equatable {
    let isTop: Bool
    let rd: Int
    let imm16: UInt16
}

/// `UBFX` (Thumb-2, 32-bit): unsigned bit-field extract — copies
/// `width` bits starting at bit `lsb` of `Rn` into `Rd`'s low bits,
/// zero-extending the rest. Doesn't affect flags. Shares the same
/// top-level 32-bit "data-processing (plain binary immediate)" op
/// field as `MOVW`/`MOVT` (`hw0` bits[9:4]) — verified against a real
/// `ubfx r0, r0, #1, #1` word from the actual kernel (`hw0=0xF3C0`,
/// `hw1=0x0040`): op field `0b111100`, `lsb = (imm3<<2)|imm2`,
/// `width = widthm1+1`.
struct ThumbUbfxInstruction: Equatable {
    let rd: Int
    let rn: Int
    let lsb: Int
    let width: Int
}

/// The 32-bit "data-processing (modified immediate)" op-field table —
/// distinct from `ThumbDataProcessingOp` (format 4's table): the two
/// share no bit-value in common (confirmed against real kernel words:
/// `BIC` here is `0b0001`, not format 4's `0b1110`). `ORR`/`RSB` with
/// `Rn == 1111` are `MOV`/`MVN`; `AND`/`EOR`/`ADD`/`SUB` with
/// `Rd == 1111, S == 1` are `TST`/`TEQ`/`CMN`/`CMP` — real ARM ARM
/// aliases, not separate encodings, so `ThumbDecoder` doesn't need a
/// distinct case for them.
enum ThumbModifiedImmediateOp: UInt8 {
    case and = 0b0000
    case bic = 0b0001
    case orr = 0b0010
    case eor = 0b0100
    case add = 0b1000
    case adc = 0b1010
    case sbc = 0b1011
    case sub = 0b1101
    case rsb = 0b1110
}

/// Thumb-2 "data-processing (modified immediate)" — the 32-bit family
/// covering `AND`/`BIC`/`ORR`/`MOV`/`ADD`/`ADC`/`SBC`/`RSB`/`SUB` with a
/// 12-bit "modified immediate" (see
/// `ThumbDecoder.expandModifiedImmediate`), sharing one op-field table
/// with the CMP/CMN/TST/TEQ comparison forms (`Rd == 1111, S == 1`).
struct ThumbDataProcessingImmediateInstruction: Equatable {
    let op: ThumbModifiedImmediateOp
    let setFlags: Bool
    let rn: Int
    let rd: Int
    let imm32: UInt32
}

/// Thumb-2 "data-processing (shifted register)" — the 32-bit sibling of
/// `ThumbDataProcessingImmediateInstruction`, sharing the exact same
/// `ThumbModifiedImmediateOp` table (ARM DDI 0406C table A5-11 uses the
/// same op-field encoding as the modified-immediate family's table
/// A5-6), except operand2 is `Rm` shifted by an immediate amount
/// instead of a 12-bit modified immediate. Verified against a real
/// `sub.w r1, r3, sb` word from the actual kernel. `Rd == 1111, S == 1`
/// is `TST`/`TEQ`/`CMN`/`CMP` (register) the same way as the immediate
/// family; `ORR` with `Rn == 1111` is the `MOV`/`ASR`/`LSL`/`LSR`/`ROR`
/// (register-shifted) alias.
struct ThumbDataProcessingShiftedRegisterInstruction: Equatable {
    let op: ThumbModifiedImmediateOp
    let setFlags: Bool
    let rn: Int
    let rd: Int
    let rm: Int
    let shiftType: ShiftType
    let shiftAmount: UInt8
}

/// `BL`/`BLX` (immediate, 32-bit): always unconditional (see
/// `ARMv7CPU.executeThumbBranchLinkImmediate` for why — matches
/// `BranchLinkExchangeImmediateInstruction`'s ARM-state reasoning in
/// spirit, except `BLX` here is fully executable, switching state to
/// ARM, since Thumb decode now exists).
struct ThumbBranchLinkInstruction: Equatable {
    let switchesToARM: Bool // true = BLX, false = BL (stays in Thumb)
    let signedOffset: Int32
}

/// `B` (32-bit forms, T3 conditional / T4 unconditional) — the wide
/// counterpart of `ThumbConditionalBranchInstruction`/
/// `ThumbBranchInstruction` for out-of-range targets.
struct ThumbBranchWideInstruction: Equatable {
    let condition: ARMCondition // .always for the unconditional T4 form
    let signedOffset: Int32
}

/// Thumb-2 `LDR`/`STR`/`LDRB`/`STRB`/`LDRSB` (immediate), the T3
/// (12-bit unsigned, always pre-indexed, never writeback) and T4
/// (8-bit signed, pre/post-indexed, optional writeback) sub-forms,
/// unified the same way `LoadStoreInstruction` unifies ARM's
/// equivalents — `isSigned` (verified against a real
/// `ldrsb r0, [r5, #1]!` word) is always paired with `isLoad == true`
/// and `isByte == true`, since no signed-store or signed-word encoding
/// exists. Halfword (`LDRH`/`STRH`) and `LDRSH` share this same
/// encoding space but aren't decoded yet.
struct ThumbLoadStoreWideInstruction: Equatable {
    let isLoad: Bool
    let isByte: Bool
    let isSigned: Bool
    let rn: Int
    let rt: Int
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let offset: UInt32
}

/// Thumb-2 `LDR`/`STR`/`LDRB`/`STRB` (register) — the register-offset
/// sibling of `ThumbLoadStoreWideInstruction`'s immediate forms, verified
/// against a real `ldr.w r3, [r5, r0, lsl #3]` word from the actual
/// kernel. Always pre-indexed, always adds, never writes back (per ARM
/// DDI 0406C A8.8.66/A8.8.204: `index=TRUE, add=TRUE, wback=FALSE`), and
/// the offset is always `Rm LSL imm2` — no other shift type is encodable
/// here.
struct ThumbLoadStoreRegisterInstruction: Equatable {
    let isLoad: Bool
    let isByte: Bool
    let rn: Int
    let rt: Int
    let rm: Int
    let shiftAmount: Int
}

/// Thumb-2 `LDM`/`STM`/`PUSH.W`/`POP.W` (32-bit block data transfer):
/// same semantics as `BlockDataTransferInstruction`, just IA/DB only
/// (Thumb-2 doesn't encode IB/DA) — see
/// `ARMv7CPU.executeThumbBlockDataTransfer`.
struct ThumbBlockDataTransferInstruction: Equatable {
    let isLoad: Bool
    let isIncrement: Bool // true = IA (used by POP/LDM), false = DB (used by PUSH/STMDB)
    let writeback: Bool
    let rn: Int
    let registerList: UInt16
}

/// `TBB`/`TBH` (table branch) — verified against a real
/// `tbh [pc, r1, lsl #1]` word from the actual kernel. Reads a
/// byte (`TBB`) or halfword (`TBH`) from `[Rn, Rm]` (`Rm` scaled by 2
/// for `TBH`), doubles it, and adds it to the address just after this
/// instruction — a compiler-emitted jump table, always staying in
/// Thumb state (unlike `BX`/`BLX`, this never switches ISA).
/// `UMULL RdLo, RdHi, Rn, Rm`: 32×32→64-bit unsigned multiply, never
/// flag-setting (this Thumb-2 T1 encoding has no `S` bit at all, unlike
/// ARM state's classical `UMULL`). Lives in the "long multiply, long
/// multiply accumulate, and divide" space (fixed hw0 bits[15:8] ==
/// `0xFB`), disambiguated from its siblings (`SMULL`/`UMLAL`/`SMLAL`/
/// `SDIV`/`UDIV`, none decoded yet) by hw0 bits[7:4] == `1010`.
/// Verified against a real `umull r5, r2, r0, r3` word from the actual
/// kernel.
struct ThumbUmullInstruction: Equatable {
    let rdLo: Int
    let rdHi: Int
    let rn: Int
    let rm: Int
}

/// `MLA Rd, Rn, Rm, Ra`: `Rd = Rn * Rm + Ra`, never flag-setting.
/// Shares `ThumbUmullInstruction`'s `0xFB` outer prefix but a
/// different sub-table (hw0 bits[7:4] == `0000`, vs `UMULL`'s `1010`)
/// and field layout (hw1 bits[15:12] == `Ra`, bits[11:8] == `Rd`, the
/// reverse order from `UMULL`'s `RdLo`/`RdHi`). `Ra == 1111` is the
/// no-accumulate `MUL` alias, not decoded here (no real word has
/// confirmed it, so it isn't silently treated as `MLA` with `Ra` tied
/// to the program counter). Verified against a real
/// `mla r4, r1, r3, r2` word from the actual kernel.
struct ThumbMlaInstruction: Equatable {
    let rd: Int
    let rn: Int
    let rm: Int
    let ra: Int
}

/// `LDRD`/`STRD` (immediate): transfers `Rt`/`Rt2` to/from consecutive
/// words at `[Rn, #offset]` and `[Rn, #offset+4]`. Shares
/// `ThumbTableBranchInstruction`'s decode space (see
/// `ThumbDecoder.decode32TableBranch`'s doc comment); verified against
/// a real `strd r0, r1, [r8]` word from the actual kernel.
struct ThumbLoadStoreDualInstruction: Equatable {
    let isLoad: Bool
    let rn: Int
    let rt: Int
    let rt2: Int
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let offset: UInt32
}

struct ThumbTableBranchInstruction: Equatable {
    let rn: Int
    let rm: Int
    let isHalfword: Bool
}

enum ThumbInstruction: Equatable {
    /// `MCR`/`MRC`: Thumb-2's coprocessor instructions reuse ARM state's
    /// exact same (opc1, L, CRn, Rt, coproc, opc2, CRm) field layout —
    /// confirmed against a real `mrc p15, #0, r0, c13, c0, #4` word from
    /// the actual kernel — so this reuses `CoprocessorRegisterTransferInstruction`
    /// directly rather than a near-identical duplicate. Its `condition`
    /// field is unused here (always `.always`): Thumb gates instructions
    /// via `ITSTATE`, already checked by the time this executes, not a
    /// per-instruction condition field the way ARM state's real
    /// conditional execution works.
    case coprocessorRegisterTransfer(CoprocessorRegisterTransferInstruction)
    case shiftImmediate(ThumbShiftImmediateInstruction)
    case immediate(ThumbImmediateInstruction)
    case addSub(ThumbAddSubInstruction)
    case alu(ThumbAluInstruction)
    case hiRegister(ThumbHiRegisterInstruction)
    case branchExchange(ThumbBranchExchangeInstruction)
    case loadStoreImmediate(ThumbLoadStoreImmediateInstruction)
    case loadStoreRegisterOffset(ThumbLoadStoreRegisterOffsetInstruction)
    case address(ThumbAddressInstruction)
    case adjustStack(ThumbAdjustStackInstruction)
    case pushPop(ThumbPushPopInstruction)
    case conditionalBranch(ThumbConditionalBranchInstruction)
    case branch(ThumbBranchInstruction)
    case compareBranch(ThumbCompareBranchInstruction)
    case extend(ThumbExtendInstruction)
    case it(ThumbItInstruction)
    case movWide(ThumbMovWideInstruction)
    case bitFieldExtract(ThumbUbfxInstruction)
    case dataProcessingImmediate(ThumbDataProcessingImmediateInstruction)
    case dataProcessingShiftedRegister(ThumbDataProcessingShiftedRegisterInstruction)
    case branchLink(ThumbBranchLinkInstruction)
    case branchWide(ThumbBranchWideInstruction)
    case loadStoreWide(ThumbLoadStoreWideInstruction)
    case loadStoreRegister(ThumbLoadStoreRegisterInstruction)
    case blockDataTransfer(ThumbBlockDataTransferInstruction)
    case tableBranch(ThumbTableBranchInstruction)
    case loadStoreDual(ThumbLoadStoreDualInstruction)
    case umull(ThumbUmullInstruction)
    case mla(ThumbMlaInstruction)
    /// A recognized-but-not-yet-implemented Thumb instruction family —
    /// see `ThumbDecoder`'s doc comment for what's covered so far.
    case unsupported(rawHalfword: UInt16, secondHalfword: UInt16?)
    /// A genuinely undefined/reserved 16 or 32-bit Thumb encoding.
    case undefined(rawHalfword: UInt16, secondHalfword: UInt16?)
}
