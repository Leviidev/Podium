import Foundation

/// The 16 ARM data-processing opcodes, numbered exactly as the ARM ARM's
/// bits[24:21] opcode field, so `DataProcessingOp(rawValue:)` maps
/// straight from the encoding with no translation table.
enum DataProcessingOp: UInt8 {
    case and = 0b0000
    case eor = 0b0001
    case sub = 0b0010
    case rsb = 0b0011
    case add = 0b0100
    case adc = 0b0101
    case sbc = 0b0110
    case rsc = 0b0111
    case tst = 0b1000
    case teq = 0b1001
    case cmp = 0b1010
    case cmn = 0b1011
    case orr = 0b1100
    case mov = 0b1101
    case bic = 0b1110
    case mvn = 0b1111

    /// TST/TEQ/CMP/CMN only ever compute flags, never write a result.
    var isComparison: Bool {
        switch self {
        case .tst, .teq, .cmp, .cmn: return true
        default: return false
        }
    }

    /// MOV/MVN ignore Rn entirely — there's no first operand.
    var usesRn: Bool {
        switch self {
        case .mov, .mvn: return false
        default: return true
        }
    }

    /// Logical ops take carry-out straight from the barrel shifter and
    /// leave V (overflow) untouched; arithmetic ops compute both from the
    /// ALU add/subtract itself. This distinction is straight from the ARM
    /// ARM's data-processing flag-setting rules.
    var isLogical: Bool {
        switch self {
        case .and, .eor, .orr, .bic, .mov, .mvn, .tst, .teq: return true
        case .sub, .rsb, .add, .adc, .sbc, .rsc, .cmp, .cmn: return false
        }
    }
}

struct DataProcessingInstruction {
    let condition: ARMCondition
    let op: DataProcessingOp
    let setFlags: Bool
    let rn: Int
    let rd: Int
    let operand2: ShifterOperand
}

struct BranchInstruction {
    let condition: ARMCondition
    let link: Bool
    /// Signed byte offset, already sign-extended and ×4 from the raw
    /// 24-bit field. The branch target is this added to the *instruction
    /// address + 8* (`Registers.pcForOperandRead`), per the ARM ARM.
    let signedOffset: Int32
}

/// `BLX <label>` (immediate form — always lives in the unconditional-
/// instruction-extension space, so there's no real condition to carry,
/// unlike `BranchInstruction`): branches with link, *always* switching
/// to Thumb state — the mirror image of Thumb state's own `BLX`
/// (immediate), which always switches to ARM (see
/// `ThumbBranchLinkInstruction`). Fully executable now that
/// `ARMv7CPU+Thumb.swift` provides a real Thumb decoder to switch into
/// (see `ARMv7CPU.executeBranchLinkExchangeImmediate`).
struct BranchLinkExchangeImmediateInstruction: Equatable {
    /// Signed byte offset from the instruction address + 8, same
    /// convention as `BranchInstruction.signedOffset`.
    let signedOffset: Int32
}

/// `BX Rm`: branches to the address in `Rm`, and — on real hardware —
/// switches to Thumb state if `Rm`'s bit 0 is set (that's the whole
/// point of the name: Branch and *Exchange* instruction sets). Fully
/// executable — see `ARMv7CPU.executeBranchExchange` — now that a real
/// Thumb decoder exists to switch into. `link` covers `BLX` (register)
/// too — identical encoding (`0x12FFF3` vs plain `BX`'s `0x12FFF1`,
/// differing only in bits[7:4]) with `LR` additionally set to the
/// return address, verified against a real `blx r0` word from the
/// actual kernel.
struct BranchExchangeInstruction: Equatable {
    let condition: ARMCondition
    let link: Bool
    let rm: Int
}

/// A load/store's address offset — either a plain immediate, or a
/// (possibly shifted) register, reusing the exact same shift encoding
/// data-processing's register operand2 uses (bits[11:4] mean the same
/// thing in both instruction families).
enum LoadStoreOffset: Equatable {
    case immediate(UInt32)
    case register(rm: Int, shiftType: ShiftType, shiftAmount: UInt8)
}

struct LoadStoreInstruction {
    let condition: ARMCondition
    let isLoad: Bool
    let isByte: Bool
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let rn: Int
    let rd: Int
    let offset: LoadStoreOffset
}

/// `LDM`/`STM` (block data transfer): moves a contiguous run of words
/// between memory and every register named in `registerList`, in
/// ascending register-number order regardless of `addOffset`/
/// `preIndexed` (which only choose where in memory that ascending run
/// starts — see `ARMv7CPU.executeBlockDataTransfer`). The `S`-bit form
/// (user-bank register transfer, or CPSR-from-SPSR exception return when
/// `PC` is in the list) isn't decoded — no processor-mode banking or
/// SPSR exists for it to mean anything (see `CPSR`'s doc comment) — so
/// it's refused rather than silently treated as the ordinary form.
struct BlockDataTransferInstruction: Equatable {
    let condition: ARMCondition
    let isLoad: Bool
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let rn: Int
    /// Bit *i* set means register *i* is included in the transfer.
    let registerList: UInt16
}

/// The three "extra load/store" transfer widths/signednesses — `STRH`
/// only ever uses `.unsignedHalfword` (there's no such thing as a signed
/// *store* — sign only matters when a narrower value is widened back
/// into a 32-bit register on load).
enum HalfwordTransferKind: Equatable {
    case unsignedHalfword
    case signedByte
    case signedHalfword
}

/// The "extra load/store" instructions' addressing offset — always a
/// plain (unshifted) register or an 8-bit immediate, unlike ordinary
/// load/store's register offset, which allows a shift.
enum HalfwordTransferOffset: Equatable {
    case immediate(UInt32)
    case register(Int)
}

/// `LDRH`/`STRH`/`LDRSB`/`LDRSH`: ARM's "extra load/store" instructions,
/// a structurally distinct encoding from ordinary single-register
/// load/store (see `ARMDecoder`'s doc comment on the bit4/bit7 check
/// that identifies this space) despite sharing the same top-level
/// instruction-class bits.
struct HalfwordDataTransferInstruction: Equatable {
    let condition: ARMCondition
    let isLoad: Bool
    let kind: HalfwordTransferKind
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let rn: Int
    let rd: Int
    let offset: HalfwordTransferOffset
}

/// `LDRD`/`STRD` (ARM state): transfers `Rt`/`Rt+1` to/from consecutive
/// words at `[Rn, #offset]` — a different encoding from Thumb's
/// `ThumbLoadStoreDualInstruction`, sharing this decoder's "extra
/// load/store" bit4/bit7 gate with `HalfwordDataTransferInstruction`,
/// but a genuine architectural quirk of that shared space: with
/// `bit20 (L) == 0`, `SH == 10` means `LDRD` (a *load*, despite `L`
/// being clear) and `SH == 11` means `STRD`, rather than following the
/// normal L-bit convention `LDRH`/`STRH`/`LDRSB`/`LDRSH` use. Verified
/// against a real `ldrd r0, r1, [r0]` word from the actual kernel.
struct LoadStoreDualInstruction: Equatable {
    let condition: ARMCondition
    let isLoad: Bool
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let rn: Int
    let rt: Int
    let offset: HalfwordTransferOffset
}

/// `MRS Rd, CPSR`/`MRS Rd, SPSR` (`isSPSR`, the R bit): reads the whole
/// CPSR, or the current mode's banked SPSR, into a register. Real
/// hardware calls SPSR access UNPREDICTABLE in User/System mode (no
/// SPSR exists there) — see `ARMv7CPU.executeMoveFromStatusRegister`.
struct MRSInstruction: Equatable {
    let condition: ARMCondition
    let isSPSR: Bool
    let rd: Int
}

enum MSRSource: Equatable {
    case register(Int)
    /// Already resolved at decode time, same as data-processing's
    /// immediate operand2 — a rotated 8-bit constant needs nothing from
    /// register state to compute.
    case immediate(UInt32)
}

/// `MSR CPSR_<fields>, Rm`/`#imm` or `MSR SPSR_<fields>, ...` (`isSPSR`,
/// the R bit): writes selected *bytes* of the CPSR, or of the current
/// mode's banked SPSR. `fieldMask` bit0=c(control, bits[7:0]),
/// bit1=x(extension, [15:8]), bit2=s(status, [23:16]), bit3=f(flags,
/// [31:24]) — the same order and meaning as the real mask field, so it
/// can be used directly to build a byte-granular write mask at execute
/// time.
struct MSRInstruction: Equatable {
    let condition: ARMCondition
    let isSPSR: Bool
    let fieldMask: UInt8
    let source: MSRSource
}

/// `MOVW`/`MOVT` (ARMv6T2+): load a 16-bit immediate into a register's
/// low or high half, the other half left alone (`MOVT`) or zeroed
/// (`MOVW`). Distinct from classic data-processing `MOV` — no rotation,
/// no shifter carry-out, any 16-bit value representable directly.
struct MovWideInstruction: Equatable {
    let condition: ARMCondition
    let isTop: Bool
    let rd: Int
    let imm16: UInt16
}

/// `MCR`/`MRC`: transfers one 32-bit value between an ARM register and a
/// coprocessor register, identified by (coprocessor, opc1, CRn, CRm,
/// opc2) — there's no ALU operation or flag effect, just the transfer.
///
/// Podium models this as a real, addressable register file (`CP15State`)
/// rather than refusing every coprocessor instruction outright, but does
/// **not** implement the hardware behavior CP15 registers are actually
/// for — cache maintenance, MMU/TLB control, and so on. A write here is
/// honestly just "the guest wrote this value to this coprocessor
/// register slot", not "Podium invalidated a cache" or "the MMU
/// reconfigured itself". See `CP15State`'s own doc comment.
struct CoprocessorRegisterTransferInstruction: Equatable {
    let condition: ARMCondition
    let isLoad: Bool // MRC (coprocessor -> ARM register) vs MCR (ARM register -> coprocessor)
    let coprocessor: Int
    let opc1: Int
    let rt: Int
    let crn: Int
    let crm: Int
    let opc2: Int
}

/// `CPS`: sets or clears the CPSR's interrupt/abort mask bits directly —
/// always unconditional (it lives in ARM's "unconditional instruction
/// extension" space, not the normal conditional encoding, hence no
/// `ARMCondition` here).
struct ChangeProcessorStateInstruction: Equatable {
    let enable: Bool
    let affectsAbort: Bool
    let affectsIRQ: Bool
    let affectsFIQ: Bool
}

/// `UQSUB8 Rd, Rn, Rm`: four parallel unsigned 8-bit saturating
/// subtractions (`Rd.byte[i] = max(0, Rn.byte[i] - Rm.byte[i])`), one of
/// ARMv6's "media instructions" (parallel addition/subtraction) —
/// verified via Capstone against a real word from the actual kernel.
/// Only this one instruction from that whole extension space is
/// decoded; the rest (dozens of signed/unsigned ×
/// simple/saturating/halving × ADD16/ASX/SAX/SUB16/ADD8/SUB8
/// combinations, plus SEL/USAD8/PKH/REV/SSAT/USAT/SXTB and friends,
/// which all share this same bit4==1 space) stay `.unsupported` until a
/// real word confirms one is needed. Doesn't affect any flags (unlike
/// the non-saturating `SUB8`, this doesn't set the GE bits either).
struct UQSub8Instruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let rn: Int
    let rm: Int
}

/// `CLZ Rd, Rm`: counts leading zero bits (32 if `Rm` is zero). Lives in
/// the "miscellaneous instructions" region of the data-processing block
/// — the exact same top-level shape (`!setFlags && op.isComparison`)
/// `MRS`/`MSR` already decode from, disambiguated by the full
/// bits[27:20]/[19:16]/[11:4] pattern rather than the `op`/`S` fields
/// alone, which aren't enough on their own to tell them apart. Verified
/// against a real word from the actual kernel via Capstone.
struct ClzInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let rm: Int
}

/// `LDREX Rt, [Rn]`: an ordinary word load architecturally paired with
/// tagging the address for exclusive access, checked by a later
/// `STREX` (see `StoreExclusiveInstruction`'s doc comment for why that
/// check is unconditional success here rather than a modeled tag).
/// Lives in
/// the "synchronization primitives" space, sharing the multiply/extra-
/// load-store gate's `!I && bit7 && bit4` shape with `SH == 0` (the
/// other three `SH` values are the halfword/signed-byte transfers
/// already decoded there); disambiguated by the full bits[27:20]/
/// [11:8]/[3:0] pattern, verified against a real `ldrex r0, [ip]` word
/// from the actual kernel.
/// `MUL Rd, Rm, Rs`: `Rd = Rm * Rs`, low 32 bits only. Lives in the
/// multiply/extra-load-store space this decoder already carves
/// `LDREX`/`STREX` out of (bits[27:22]==0, `SH`==00, bit7==1, bit4==1)
/// — disambiguated from those by requiring bits[15:12]==0 (`MUL`'s
/// fixed zero field, where `LDREX`/`STREX` instead have a real
/// bits[27:20] opcode). `MLA` (the accumulate form, `A`==1) and the
/// `S`-bit (flag-setting) aren't decoded — no real word has confirmed
/// either yet. Verified against a real `mul r0, r3, r4` word from the
/// actual kernel. Doesn't affect flags.
struct MultiplyInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let rm: Int
    let rs: Int
}

struct LoadExclusiveInstruction: Equatable {
    let condition: ARMCondition
    let rt: Int
    let rn: Int
}

/// `STREX Rd, Rt, [Rn]`: stores `Rt` to `[Rn]` and sets `Rd` to the
/// exclusive-access status (`0` success, `1` fail). This emulator runs
/// a single interpreter thread with no concurrent agent that could
/// ever invalidate the exclusive tag `LDREX` would set between the two
/// instructions, so unconditional success is the architecturally
/// correct outcome here, not a shortcut — there is nothing to fail
/// against. Verified against a real `strex r3, r0, [ip]` word from the
/// actual kernel, sharing `LoadExclusiveInstruction`'s decode gate.
struct StoreExclusiveInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let rt: Int
    let rn: Int
}

/// `REV Rd, Rm`: reverses the byte order of a word (`Rd.byte[i] =
/// Rm.byte[3-i]`) — also lives in the media-instructions space (a
/// unary sibling of `UQSUB8`, hence no `Rn`), verified against a real
/// word from the actual kernel via Capstone. `REV16`/`REVSH` (halfword
/// and signed-halfword variants sharing this same top-level shape)
/// aren't decoded yet.
struct RevInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let rm: Int
}

/// `BFI Rd, Rn, #lsb, #width` / `BFC Rd, #lsb, #width` (ARM state):
/// copies `width` low bits of `Rn` into `Rd` starting at bit `lsb`,
/// leaving the rest of `Rd` untouched — `BFC` is the same encoding with
/// `Rn == 1111` (no source register field is actually read; those bits
/// are architecturally just cleared to zero, not filled with `R15`'s
/// value, hence `sourceRegister: nil` rather than `15`). Not part of
/// ARMv6's other "media instructions" (parallel add/sub, `REV`) but
/// shares that same bits[27:25]==011,bit4==1 decode gate — bits[27:21]
/// == `0b0111110` (`SBFX`'s sibling at `0b0111101`/`0b0111010` isn't
/// decoded). `width = msb - lsb + 1`, where `msb`/`lsb` are the real
/// word's own field names. Verified against a real `bfi r0, r2, #0x10,
/// #4` word from the actual kernel. Doesn't affect flags.
struct BitFieldInsertInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let sourceRegister: Int?
    let lsb: Int
    let width: Int
}

/// `UBFX Rd, Rn, #lsb, #width` (ARM state): unsigned bit-field extract —
/// this is a *different* encoding from Thumb-2's `UBFX`
/// (`ThumbUbfxInstruction`), sharing ARM state's "media instructions"
/// bits[27:25]==011,bit4==1 gate with `BFI`/`BFC`/`REV`/`UQSUB8` rather
/// than Thumb's "data-processing plain binary immediate" space. Keyed
/// on bits[27:21] == `0b0111111` (one more than `BFI`/`BFC`'s
/// `0b0111110`) and bits[6:4] == `0b101`. `width = widthm1 + 1`.
/// Verified against a real `ubfx r3, r0, #3, #0xa` word from the actual
/// kernel. Doesn't affect flags.
struct BitFieldExtractInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
    let rn: Int
    let lsb: Int
    let width: Int
}

enum ARMInstruction: Equatable {
    case dataProcessing(DataProcessingInstruction)
    case branch(BranchInstruction)
    case branchExchange(BranchExchangeInstruction)
    case branchLinkExchangeImmediate(BranchLinkExchangeImmediateInstruction)
    case blockDataTransfer(BlockDataTransferInstruction)
    case halfwordDataTransfer(HalfwordDataTransferInstruction)
    case loadStoreDual(LoadStoreDualInstruction)
    case loadStore(LoadStoreInstruction)
    case movWide(MovWideInstruction)
    case moveFromStatusRegister(MRSInstruction)
    case moveToStatusRegister(MSRInstruction)
    case coprocessorRegisterTransfer(CoprocessorRegisterTransferInstruction)
    case changeProcessorState(ChangeProcessorStateInstruction)
    case uqsub8(UQSub8Instruction)
    case bitFieldInsert(BitFieldInsertInstruction)
    case bitFieldExtract(BitFieldExtractInstruction)
    case multiply(MultiplyInstruction)
    case rev(RevInstruction)
    case clz(ClzInstruction)
    case loadExclusive(LoadExclusiveInstruction)
    case storeExclusive(StoreExclusiveInstruction)
    /// `DSB`/`DMB`/`ISB` (memory/instruction ordering barriers) and
    /// `PLD` (immediate, a cache-prefetch hint). Podium's interpreter
    /// executes everything strictly in program order with no caching,
    /// reordering, or pipelining to synchronize or prefetch for — so for
    /// this CPU, correctly implementing any of these *is* treating them
    /// as a no-op, not a missing feature.
    case memoryBarrier
    /// A recognized-but-not-yet-implemented instruction family: multiply
    /// and the "extra load/store" SWP/reserved encodings (SH==00), the
    /// `S`-bit form of block data transfer (see
    /// `BlockDataTransferInstruction`'s doc comment), register-shifted-
    /// by-register operand2, most of the coprocessor space (anything but
    /// MCR/MRC), SWI, and most of the unconditional-instruction-extension
    /// space (anything but CPS and the DSB/DMB/ISB barriers).
    case unsupported(rawWord: UInt32)
    /// A genuinely undefined/reserved encoding.
    case undefined(rawWord: UInt32)
}

extension DataProcessingInstruction: Equatable {
    static func == (lhs: DataProcessingInstruction, rhs: DataProcessingInstruction) -> Bool {
        lhs.condition == rhs.condition && lhs.op == rhs.op && lhs.setFlags == rhs.setFlags
            && lhs.rn == rhs.rn && lhs.rd == rhs.rd && lhs.operand2 == rhs.operand2
    }
}

extension BranchInstruction: Equatable {}
extension LoadStoreInstruction: Equatable {}

extension ShifterOperand: Equatable {
    static func == (lhs: ShifterOperand, rhs: ShifterOperand) -> Bool {
        switch (lhs, rhs) {
        case (.immediate(let lv, let lc), .immediate(let rv, let rc)):
            return lv == rv && lc == rc
        case (.shiftedRegister(let lrm, let lst, let lsa), .shiftedRegister(let rrm, let rst, let rsa)):
            return lrm == rrm && lst == rst && lsa == rsa
        case (.shiftedRegisterByRegister(let lrm, let lst, let lrs), .shiftedRegisterByRegister(let rrm, let rst, let rrs)):
            return lrm == rrm && lst == rst && lrs == rrs
        default:
            return false
        }
    }
}
