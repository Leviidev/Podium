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
    case loadStore(LoadStoreInstruction)
    case movWide(MovWideInstruction)
    case coprocessorRegisterTransfer(CoprocessorRegisterTransferInstruction)
    case changeProcessorState(ChangeProcessorStateInstruction)
    /// `DSB`/`DMB`/`ISB`: memory/instruction ordering barriers. Podium's
    /// interpreter executes everything strictly in program order with no
    /// caching, reordering, or pipelining to synchronize — so for this
    /// CPU, correctly implementing a barrier *is* treating it as a no-op,
    /// not a missing feature.
    case memoryBarrier
    /// A recognized-but-not-yet-implemented instruction family: multiply,
    /// block data transfer (LDM/STM), register-shifted-by-register
    /// operand2, MSR/MRS (full CPSR/SPSR access — distinct from `CPS`,
    /// which only touches the interrupt/abort mask bits), most of the
    /// coprocessor space (anything but MCR/MRC), SWI, and most of the
    /// unconditional-instruction-extension space (anything but CPS and
    /// the DSB/DMB/ISB barriers).
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
        default:
            return false
        }
    }
}
