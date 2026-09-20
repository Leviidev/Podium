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

struct LoadStoreInstruction {
    let condition: ARMCondition
    let isLoad: Bool
    let isByte: Bool
    let preIndexed: Bool
    let addOffset: Bool
    let writeback: Bool
    let rn: Int
    let rd: Int
    let immediateOffset: UInt32
}

enum ARMInstruction: Equatable {
    case dataProcessing(DataProcessingInstruction)
    case branch(BranchInstruction)
    case loadStore(LoadStoreInstruction)
    /// A recognized-but-not-yet-implemented instruction family: multiply,
    /// block data transfer (LDM/STM), register-shifted-by-register
    /// operand2, register-offset load/store, MSR/MRS, coprocessor, SWI.
    case unsupported(rawWord: UInt32)
    /// The reserved `NV` (0b1111) condition, or another genuinely
    /// undefined encoding.
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
