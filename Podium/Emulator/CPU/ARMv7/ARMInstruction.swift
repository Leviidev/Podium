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
/// Thumb decoder exists to switch into.
struct BranchExchangeInstruction: Equatable {
    let condition: ARMCondition
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

/// `MRS Rd, CPSR`: reads the whole CPSR into a register. SPSR access
/// (the same instruction shape with R==1) isn't decoded — there's no
/// exception entry/exit yet for a saved SPSR to matter to.
struct MRSInstruction: Equatable {
    let condition: ARMCondition
    let rd: Int
}

enum MSRSource: Equatable {
    case register(Int)
    /// Already resolved at decode time, same as data-processing's
    /// immediate operand2 — a rotated 8-bit constant needs nothing from
    /// register state to compute.
    case immediate(UInt32)
}

/// `MSR CPSR_<fields>, Rm`/`#imm`: writes selected *bytes* of the CPSR.
/// `fieldMask` bit0=c(control, bits[7:0]), bit1=x(extension, [15:8]),
/// bit2=s(status, [23:16]), bit3=f(flags, [31:24]) — the same order and
/// meaning as the real mask field, so it can be used directly to build a
/// byte-granular write mask at execute time.
struct MSRInstruction: Equatable {
    let condition: ARMCondition
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

enum ARMInstruction: Equatable {
    case dataProcessing(DataProcessingInstruction)
    case branch(BranchInstruction)
    case branchExchange(BranchExchangeInstruction)
    case branchLinkExchangeImmediate(BranchLinkExchangeImmediateInstruction)
    case blockDataTransfer(BlockDataTransferInstruction)
    case halfwordDataTransfer(HalfwordDataTransferInstruction)
    case loadStore(LoadStoreInstruction)
    case movWide(MovWideInstruction)
    case moveFromStatusRegister(MRSInstruction)
    case moveToStatusRegister(MSRInstruction)
    case coprocessorRegisterTransfer(CoprocessorRegisterTransferInstruction)
    case changeProcessorState(ChangeProcessorStateInstruction)
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
    /// by-register operand2, SPSR access (the MRS/MSR encodings with
    /// R==1 — there's no exception entry/exit yet for a saved SPSR to
    /// matter to), most of the coprocessor space (anything but MCR/MRC),
    /// SWI, and most of the unconditional-instruction-extension space
    /// (anything but CPS and the DSB/DMB/ISB barriers).
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
