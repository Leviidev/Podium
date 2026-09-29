import Foundation

/// Translates VFP and Advanced SIMD (NEON) instructions for both
/// translators — Thumb-2 decodes them to their ARM forms — mirroring
/// `ARMv7CPU+VFP.swift`, `ARMv7CPU+NEON.swift` and the NEON cases in
/// `ARMv7CPU.swift`. What isn't handled here the interpreter runs in
/// place, as for any other instruction.
///
/// Guest `D` registers live beside the core ones (see
/// `Registers.extensionOffset`); each instruction loads its operands into
/// host vector registers, computes, and stores the result back. Only
/// `v0`–`v7` are used: the host's calling convention lets translated code
/// clobber them, and nothing lives in them across instructions.
///
/// Floating point runs in the Advanced SIMD "standard FPSCR" modes —
/// flush to zero, default NaN, round to nearest — which NEON always uses
/// and iOS gives every thread for VFP too (its compiler emits NEON for
/// scalar float arithmetic on that basis, as the code this was written
/// for does). The host's FPCR is set to match when translated code is
/// entered (see `DBTEngine`), and a block checks, before its first
/// instruction that uses the unit, that it's enabled (FPEXC.EN: XNU
/// switches VFP state lazily, trapping a thread's first use) and that
/// the guest's FPSCR is in those modes; if not, it leaves for the
/// interpreter there (`BlockEmitter.requireVectorUnit`). With those modes
/// the host's IEEE arithmetic, NaN selection and compare flags are the
/// guest's.
enum VectorTranslator {
    typealias H = DBTEngine.Host

    // MARK: What's translated

    /// Whether `instruction` uses the VFP/Advanced SIMD unit and is
    /// translated here.
    static func isSupported(_ instruction: ARMInstruction) -> Bool {
        switch instruction {
        case .vfpDataProcessing:
            return true
        case .extensionRegisterLoadStore(let i):
            guard i.registerCount >= 1, i.firstRegister + i.registerCount <= 32 else { return false }
            if case .offset = i.addressing { return true }
            return i.rn != 15
        case .vfpTwoRegisterTransfer(let i):
            return i.rt != 15 && i.rt2 != 15 && (i.isDouble || i.extensionRegister < 31)
        case .bitwiseExclusiveOr, .bitwiseOr, .integerAdd:
            return true
        case .vectorExtract(let i):
            // A D-form offset past 7 is UNDEFINED (A64 reserves it too).
            return i.isQuad || i.byteOffset < 8
        case .neonModifiedImmediate(let i):
            return i.vd + (i.isQuad ? 2 : 1) <= 32
        case .vectorShiftImmediate(let i):
            guard [8, 16, 32].contains(i.elementBits) else { return false }
            return i.direction == .right ? (1...i.elementBits).contains(i.shiftAmount) : (0..<i.elementBits).contains(i.shiftAmount)
        case .reverseElements(let i):
            let group: Int
            switch i.groupSize {
            case .bits64: group = 64
            case .bits32: group = 32
            case .bits16: group = 16
            }
            return [8, 16, 32].contains(i.elementBits) && i.elementBits < group
        case .elementLoadStore(let i):
            guard i.rn != 15, i.registerCount >= 1, i.firstRegister + i.registerCount <= 32 else { return false }
            if case .register(let rm) = i.writeback { return rm != 15 }
            return true
        case .neon(let i):
            return isSupported(i)
        case .neonStructureLoadStore(let i):
            return isSupported(i)
        default:
            return false
        }
    }

    /// The condition of an instruction `isSupported` accepts (Advanced
    /// SIMD ones are unconditional).
    static func condition(of instruction: ARMInstruction) -> ARMCondition? {
        switch instruction {
        case .vfpDataProcessing(let i): return i.condition
        case .extensionRegisterLoadStore(let i): return i.condition
        case .vfpTwoRegisterTransfer(let i): return i.condition
        default: return isSupported(instruction) ? .always : nil
        }
    }

    /// The coprocessor 10/11 transfers translated here: `VMOV` between a
    /// core register and an `S` register or a `D` scalar, `VDUP` from a
    /// core register, and `VMRS` from FPSCR. (Writing FPSCR or FPEXC is
    /// left to the interpreter, which ends the block if that changes
    /// whether translated vector code may run.)
    static func isSupported(_ i: CoprocessorRegisterTransferInstruction) -> Bool {
        guard i.coprocessor == 10 || i.coprocessor == 11 else { return false }
        if i.coprocessor == 10, i.opc1 == 0b111 { return i.isLoad && i.crn == 0b0001 }
        guard i.rt != 15 else { return false }
        if i.coprocessor == 10 { return i.opc1 == 0 && i.opc2 & 0b11 == 0 && i.crm == 0 }
        return scalarTransfer(i) != nil
    }

    /// A cp11 transfer's shape, as `ARMv7CPU.executeVFPRegisterTransfer`
    /// decodes it; nil where that raises UNDEFINED.
    private enum ScalarTransfer {
        case element(register: Int, size: Int, lane: Int, signed: Bool)
        case duplicate(register: Int, size: Int, quad: Bool)
    }

    private static func scalarTransfer(_ i: CoprocessorRegisterTransferInstruction) -> ScalarTransfer? {
        let register = (i.opc2 >> 2 & 1) << 4 | i.crn
        if !i.isLoad, i.opc1 & 0b100 != 0 {
            let b = i.opc1 >> 1 & 1, e = i.opc2 & 1, quad = i.opc1 & 1 != 0
            let size: Int
            switch (b, e) {
            case (0, 0): size = 32
            case (0, 1): size = 16
            case (1, 0): size = 8
            default: return nil
            }
            guard !quad || register & 1 == 0 else { return nil }
            return .duplicate(register: register, size: size, quad: quad)
        }
        let selector = (i.opc1 & 0b11) << 2 | (i.opc2 & 0b11)
        let size: Int, lane: Int
        if selector & 0b1000 != 0 {
            size = 8; lane = selector & 0b111
        } else if selector & 0b0001 != 0 {
            size = 16; lane = selector >> 1 & 0b11
        } else if selector & 0b0011 == 0 {
            size = 32; lane = selector >> 2 & 1
        } else {
            return nil
        }
        let unsigned = i.opc1 & 0b100 != 0
        if i.isLoad, unsigned, size == 32 { return nil }
        return .element(register: register, size: size, lane: lane, signed: i.isLoad && !unsigned && size < 32)
    }

    private static func isSupported(_ i: NEONInstruction) -> Bool {
        let esize = i.esize
        let narrow = [8, 16, 32].contains(esize)
        switch i.operation {
        case .same(let op):
            switch op {
            case .add, .subtract:
                return true
            case .multiply, .multiplyAccumulate, .multiplySubtract, .halvingAdd, .roundingHalvingAdd, .halvingSubtract,
                 .compareGreater, .compareGreaterOrEqual, .compareEqual, .test, .maximum, .minimum,
                 .absoluteDifference, .absoluteDifferenceAccumulate:
                return narrow
            case .polynomialMultiply:
                return esize == 8
            case .shiftLeft, .roundingShiftLeft:
                return narrow || (esize == 64 && i.isQuad && op == .shiftLeft)
            case .pairwiseMaximum, .pairwiseMinimum, .pairwiseAdd:
                return narrow && !i.isQuad
            case .and, .bitClear, .or, .orNot, .exclusiveOr, .bitwiseSelect, .bitwiseInsertIfTrue, .bitwiseInsertIfFalse:
                return true
            case .floatAdd, .floatSubtract, .floatMultiply, .floatAbsoluteDifference, .floatMultiplyAccumulate,
                 .floatMultiplySubtract, .floatMaximum, .floatMinimum, .floatCompareEqual, .floatCompareGreaterOrEqual,
                 .floatCompareGreater, .floatAbsoluteCompareGreaterOrEqual, .floatAbsoluteCompareGreater:
                return esize == 32
            case .floatPairwiseAdd, .floatPairwiseMaximum, .floatPairwiseMinimum:
                return esize == 32 && !i.isQuad
            default:
                // Saturating (FPSCR.QC), and the fused reciprocal steps.
                return false
            }
        case .long(let op):
            switch op {
            case .add, .subtract, .absoluteDifference, .absoluteDifferenceAccumulate, .multiply, .multiplyAccumulate, .multiplySubtract:
                return narrow
            case .polynomialMultiply:
                return esize == 8
            default:
                return false
            }
        case .wide, .narrowHigh:
            return narrow
        case .byScalar(let op, let index):
            switch op {
            case .multiply, .multiplyAccumulate, .multiplySubtract, .multiplyLong, .multiplyAccumulateLong, .multiplySubtractLong:
                return (esize == 16 && index < 4) || (esize == 32 && index < 2)
            case .floatMultiply, .floatMultiplyAccumulate, .floatMultiplySubtract:
                return esize == 32 && index < 2
            default:
                return false
            }
        case .shift(let op, let amount):
            switch op {
            case .shiftRight, .shiftRightAccumulate, .shiftRightInsert:
                return (narrow || (esize == 64 && i.isQuad)) && (1...esize).contains(amount)
            case .roundingShiftRight, .roundingShiftRightAccumulate:
                return narrow && (1...esize).contains(amount)
            case .shiftLeft, .shiftLeftInsert:
                return (narrow || (esize == 64 && i.isQuad)) && (0..<esize).contains(amount)
            case .shiftRightNarrow, .roundingShiftRightNarrow:
                return narrow && (1...esize).contains(amount)
            case .shiftLeftLong:
                return narrow && (0..<esize).contains(amount)
            default:
                return false
            }
        case .misc(let op):
            switch op {
            case .reverse64: return narrow
            case .reverse32: return esize == 8 || esize == 16
            case .reverse16: return esize == 8
            case .pairwiseAddLong, .pairwiseAddAccumulateLong, .countLeadingSignBits, .countLeadingZeros, .moveNarrow,
                 .shiftLeftLongByElementSize:
                return narrow
            case .countOnes: return esize == 8
            case .not: return true
            case .compareGreaterThanZero(let float), .compareGreaterOrEqualZero(let float), .compareEqualZero(let float),
                 .compareLessOrEqualZero(let float), .compareLessThanZero(let float), .absolute(let float), .negate(let float):
                return float ? esize == 32 : narrow
            case .convertToFloat, .convertFromFloat:
                return esize == 32
            default:
                return false
            }
        case .tableLookup(let extends, let length):
            // An odd-length table is padded with zeros to whole host
            // registers; VTBX must leave lanes indexing the padding alone.
            return !extends || length % 2 == 0
        case .duplicateScalar:
            return narrow
        }
    }

    private static func isSupported(_ i: NEONStructureLoadStoreInstruction) -> Bool {
        guard i.rn != 15, i.elements == 1, [8, 16, 32, 64].contains(i.esize) else { return false }
        switch i.form {
        case .multiple(let registers, _):
            return i.d + registers <= 32
        case .singleLane(let index, _):
            return i.esize < 64 && index < 64 / i.esize && i.d < 32
        case .allLanes(_, let registers):
            return i.esize < 64 && i.d + registers <= 32
        }
    }

    // MARK: Emitting

    /// Emits `instruction` (after its condition check). `pc`/`next`/
    /// `itState` place its slow path; `thumb` is the instruction set, for
    /// a PC-relative `VLDR`.
    static func emit(_ instruction: ARMInstruction, pc: UInt32, next: UInt32, itState: UInt8, thumb: Bool, into e: inout BlockEmitter) {
        switch instruction {
        case .vfpDataProcessing(let i):
            emitDataProcessing(i, into: &e)
        case .extensionRegisterLoadStore(let i):
            emitLoadStore(i, pc: pc, next: next, itState: itState, thumb: thumb, into: &e)
        case .vfpTwoRegisterTransfer(let i):
            emitTwoRegisterTransfer(i, into: &e)
        case .bitwiseExclusiveOr(let i):
            emitBitwise(.eor, d: i.vd, n: i.vn, m: i.vm, quad: i.isQuad, into: &e)
        case .bitwiseOr(let i):
            emitBitwise(.orr, d: i.vd, n: i.vn, m: i.vm, quad: i.isQuad, into: &e)
        case .integerAdd(let i):
            let scale = i.isQuad ? 2 : 1
            emitAdd(subtract: false, esize: 8 << Int(i.size.rawValue), d: i.vd * scale, n: i.vn * scale, m: i.vm * scale, quad: i.isQuad, into: &e)
        case .vectorExtract(let i):
            let scale = i.isQuad ? 2 : 1
            e.loadVector(1, i.vn * scale, quad: i.isQuad)
            e.loadVector(2, i.vm * scale, quad: i.isQuad)
            e.a.ext(q: i.isQuad, 0, 1, 2, index: i.byteOffset)
            e.storeVector(i.vd * scale, 0, quad: i.isQuad)
        case .vectorShiftImmediate(let i):
            let scale = i.isQuad ? 2 : 1
            e.loadVector(1, i.vm * scale, quad: i.isQuad)
            let op: A64Assembler.VectorShift = i.direction == .left ? .shl : (i.unsigned ? .ushr : .sshr)
            e.a.vector(op, q: i.isQuad, esize: i.elementBits, amount: i.shiftAmount, 0, 1)
            e.storeVector(i.vd * scale, 0, quad: i.isQuad)
        case .reverseElements(let i):
            let scale = i.isQuad ? 2 : 1
            let op: A64Assembler.VectorUnaryOperation
            switch i.groupSize {
            case .bits64: op = .rev64
            case .bits32: op = .rev32
            case .bits16: op = .rev16
            }
            e.loadVector(1, i.vm * scale, quad: i.isQuad)
            e.a.vector(op, q: i.isQuad, size: sizeField(i.elementBits), 0, 1)
            e.storeVector(i.vd * scale, 0, quad: i.isQuad)
        case .neonModifiedImmediate(let i):
            emitModifiedImmediate(i, into: &e)
        case .elementLoadStore(let i):
            emitElementLoadStore(i, pc: pc, next: next, itState: itState, into: &e)
        case .neon(let i):
            emitNEON(i, into: &e)
        case .neonStructureLoadStore(let i):
            emitStructureLoadStore(i, pc: pc, next: next, itState: itState, into: &e)
        default:
            preconditionFailure("not a translated vector instruction")
        }
    }

    /// The A64 size field for `esize`-bit elements.
    private static func sizeField(_ esize: Int) -> Int {
        switch esize {
        case 8: return 0
        case 16: return 1
        case 32: return 2
        default: return 3
        }
    }

    // MARK: VFP

    private static func loadFloat(_ v: Int, _ index: Int, double: Bool, into e: inout BlockEmitter) {
        if double { e.loadD(v, index) } else { e.loadS(v, index) }
    }

    private static func storeFloat(_ index: Int, _ v: Int, double: Bool, into e: inout BlockEmitter) {
        if double { e.storeD(index, v) } else { e.storeS(index, v) }
    }

    private static func sOffset(_ s: Int) -> Int { Registers.extensionOffset + 4 * s }
    private static func dOffset(_ d: Int) -> Int { Registers.extensionOffset + 8 * d }

    private static func emitDataProcessing(_ i: VFPDataProcessingInstruction, into e: inout BlockEmitter) {
        let double = i.isDouble
        func binary(_ op: A64Assembler.FloatOperation) {
            loadFloat(1, i.n, double: double, into: &e)
            loadFloat(2, i.m, double: double, into: &e)
            e.a.float(op, double: double, 0, 1, 2)
            storeFloat(i.d, 0, double: double, into: &e)
        }
        func unary(_ op: A64Assembler.FloatOperation) {
            loadFloat(1, i.m, double: double, into: &e)
            e.a.float(op, double: double, 0, 1)
            storeFloat(i.d, 0, double: double, into: &e)
        }
        switch i.operation {
        case .multiplyAccumulate(let negateProduct, let negateAccumulator):
            // Rounded product, then the add — not fused, as VMLA isn't.
            loadFloat(1, i.n, double: double, into: &e)
            loadFloat(2, i.m, double: double, into: &e)
            e.a.float(.mul, double: double, 1, 1, 2)
            if negateProduct { e.a.float(.neg, double: double, 1, 1) }
            loadFloat(0, i.d, double: double, into: &e)
            if negateAccumulator { e.a.float(.neg, double: double, 0, 0) }
            e.a.float(.add, double: double, 0, 0, 1)
            storeFloat(i.d, 0, double: double, into: &e)
        case .multiply: binary(.mul)
        case .negatedMultiply: binary(.nmul)
        case .add: binary(.add)
        case .subtract: binary(.sub)
        case .divide: binary(.div)
        case .moveImmediate(let bits):
            if double {
                e.a.mov(x: 0, bits)
                e.a.str(x: 0, H.registers, offset: dOffset(i.d))
            } else {
                e.a.mov(w: 0, UInt32(truncatingIfNeeded: bits))
                e.a.str(w: 0, H.registers, offset: sOffset(i.d))
            }
        case .move:
            if double {
                e.a.ldr(x: 0, H.registers, offset: dOffset(i.m))
                e.a.str(x: 0, H.registers, offset: dOffset(i.d))
            } else {
                e.a.ldr(w: 0, H.registers, offset: sOffset(i.m))
                e.a.str(w: 0, H.registers, offset: sOffset(i.d))
            }
        case .absolute: unary(.abs)
        case .negate: unary(.neg)
        case .squareRoot: unary(.sqrt)
        case .compare(let withZero):
            // Into FPSCR's flags; the guest's own stay in the host's NZCV.
            loadFloat(1, i.d, double: double, into: &e)
            if !withZero { loadFloat(2, i.m, double: double, into: &e) }
            e.saveFlags()
            e.a.fcmp(double: double, 1, withZero ? nil : 2)
            e.a.mrsNZCV(x: 14)
            e.restoreFlags()
            e.a.ldr(w: 9, H.registers, offset: Registers.fpscrOffset)
            e.a.and(w: 9, 9, imm: 0x0FFF_FFFF, scratch: 15)
            e.a.orr(w: 9, 9, 14)
            e.a.str(w: 9, H.registers, offset: Registers.fpscrOffset)
        case .convertPrecision:
            // `isDouble` is the source's precision.
            loadFloat(1, i.m, double: double, into: &e)
            e.a.fcvt(toDouble: !double, 0, 1)
            storeFloat(i.d, 0, double: !double, into: &e)
        case .convertFromInteger(let signed):
            e.a.ldr(w: 0, H.registers, offset: sOffset(i.m))
            e.a.convert(signed ? .scvtf : .ucvtf, double: double, 0, 0)
            storeFloat(i.d, 0, double: double, into: &e)
        case .convertToInteger(let signed, let roundTowardZero):
            // Otherwise FPSCR's rounding, which is to nearest here.
            loadFloat(1, i.m, double: double, into: &e)
            let op: A64Assembler.Conversion = roundTowardZero ? (signed ? .fcvtzs : .fcvtzu) : (signed ? .fcvtns : .fcvtnu)
            e.a.convert(op, double: double, 0, 1)
            e.a.str(w: 0, H.registers, offset: sOffset(i.d))
        }
    }

    private static func emitLoadStore(_ i: ExtensionRegisterLoadStoreInstruction, pc: UInt32, next: UInt32, itState: UInt8,
                                      thumb: Bool, into e: inout BlockEmitter) {
        let slow = e.slowPath(pc: pc, next: next, itState: itState)
        if i.rn == 15 { e.constant(2, (pc &+ (thumb ? 4 : 8)) & ~3) } else { e.load(2, guest: i.rn) }
        let span = UInt32(i.wordCount) * 4
        switch i.addressing {
        case .offset(let offset, let add): e.a.add(w: 3, 2, anyImm: add ? offset : 0 &- offset, scratch: 15)
        case .incrementAfter: e.a.mov(w: 3, w: 2)
        case .decrementBefore: e.a.add(w: 3, 2, anyImm: 0 &- span, scratch: 15)
        }
        let size = i.isDouble ? 8 : 4
        let bytes = i.registerCount * size
        let file = Registers.extensionOffset + i.firstRegister * size
        if bytes == 4 {
            if i.isLoad {
                e.loadMemory(0, address: 3, width: 4, signed: false, deopt: slow)
                e.a.str(w: 0, H.registers, offset: file)
            } else {
                e.a.ldr(w: 0, H.registers, offset: file)
                e.storeMemory(0, address: 3, width: 4, deopt: slow)
            }
        } else {
            e.locateRun(3, width: bytes, access: i.isLoad ? .read : .write, deopt: slow)
            copy(bytes: bytes, file: file, load: i.isLoad, into: &e)
        }
        switch i.addressing {
        case .incrementAfter(writeback: true):
            e.a.add(w: 4, 2, anyImm: span, scratch: 15)
            e.store(guest: i.rn, 4)
        case .decrementBefore:
            e.store(guest: i.rn, 3)
        default:
            break
        }
    }

    /// Copies `bytes` between guest memory at `x10` and the register file
    /// from byte `file` — a multiple of 4, as `bytes` is.
    private static func copy(bytes: Int, file: Int, load: Bool, into e: inout BlockEmitter) {
        var offset = 0
        while offset < bytes {
            if file % 8 == 0, offset % 8 == 0, bytes - offset >= 8 {
                if load {
                    e.a.ldr(x: 0, 10, offset: offset)
                    e.a.str(x: 0, H.registers, offset: file + offset)
                } else {
                    e.a.ldr(x: 0, H.registers, offset: file + offset)
                    e.a.str(x: 0, 10, offset: offset)
                }
                offset += 8
            } else {
                if load {
                    e.a.ldr(w: 0, 10, offset: offset)
                    e.a.str(w: 0, H.registers, offset: file + offset)
                } else {
                    e.a.ldr(w: 0, H.registers, offset: file + offset)
                    e.a.str(w: 0, 10, offset: offset)
                }
                offset += 4
            }
        }
    }

    private static func emitTwoRegisterTransfer(_ i: VFPTwoRegisterTransferInstruction, into e: inout BlockEmitter) {
        let file = i.isDouble ? dOffset(i.extensionRegister) : sOffset(i.extensionRegister)
        if i.toCore {
            e.a.ldr(w: 0, H.registers, offset: file)
            e.a.ldr(w: 1, H.registers, offset: file + 4)
            e.store(guest: i.rt, 0)
            e.store(guest: i.rt2, 1)
        } else {
            e.load(0, guest: i.rt)
            e.load(1, guest: i.rt2)
            e.a.str(w: 0, H.registers, offset: file)
            e.a.str(w: 1, H.registers, offset: file + 4)
        }
    }

    /// Emits a transfer `isSupported(_: CoprocessorRegisterTransferInstruction)` accepted.
    static func emit(_ i: CoprocessorRegisterTransferInstruction, into e: inout BlockEmitter) {
        if i.coprocessor == 10, i.opc1 == 0b111 {
            e.a.ldr(w: 0, H.registers, offset: Registers.fpscrOffset)
            if i.rt == 15 {
                // VMRS APSR_nzcv, FPSCR: the comparison result.
                e.a.and(w: 0, 0, imm: 0xF000_0000, scratch: 15)
                e.a.msrNZCV(x: 0)
            } else {
                e.store(guest: i.rt, 0)
            }
            return
        }
        if i.coprocessor == 10 {
            let s = i.crn << 1 | (i.opc2 >> 2 & 1)
            if i.isLoad {
                e.a.ldr(w: 0, H.registers, offset: sOffset(s))
                e.store(guest: i.rt, 0)
            } else {
                e.load(0, guest: i.rt)
                e.a.str(w: 0, H.registers, offset: sOffset(s))
            }
            return
        }
        switch scalarTransfer(i)! {
        case .element(let register, let size, let lane, let signed):
            let offset = dOffset(register) + lane * size / 8
            if i.isLoad {
                switch (size, signed) {
                case (8, false): e.a.ldrb(w: 0, H.registers, offset: offset)
                case (8, true): e.a.ldrsb(w: 0, H.registers, offset: offset)
                case (16, false): e.a.ldrh(w: 0, H.registers, offset: offset)
                case (16, true): e.a.ldrsh(w: 0, H.registers, offset: offset)
                default: e.a.ldr(w: 0, H.registers, offset: offset)
                }
                e.store(guest: i.rt, 0)
            } else {
                e.load(0, guest: i.rt)
                switch size {
                case 8: e.a.strb(w: 0, H.registers, offset: offset)
                case 16: e.a.strh(w: 0, H.registers, offset: offset)
                default: e.a.str(w: 0, H.registers, offset: offset)
                }
            }
        case .duplicate(let register, let size, let quad):
            e.load(0, guest: i.rt)
            e.a.dup(q: quad, 0, general: 0, imm5: size / 8)
            e.storeVector(register, 0, quad: quad)
        }
    }

    // MARK: Advanced SIMD

    private static func emitBitwise(_ op: A64Assembler.VectorOperation, d: Int, n: Int, m: Int, quad: Bool, into e: inout BlockEmitter) {
        let scale = quad ? 2 : 1
        e.loadVector(1, n * scale, quad: quad)
        e.loadVector(2, m * scale, quad: quad)
        e.a.vector(op, q: quad, 0, 1, 2)
        e.storeVector(d * scale, 0, quad: quad)
    }

    /// Integer add or subtract of `D`-indexed operands.
    private static func emitAdd(subtract: Bool, esize: Int, d: Int, n: Int, m: Int, quad: Bool, into e: inout BlockEmitter) {
        e.loadVector(1, n, quad: quad)
        e.loadVector(2, m, quad: quad)
        if esize == 64, !quad {
            if subtract { e.a.subScalar(d: 0, 1, 2) } else { e.a.addScalar(d: 0, 1, 2) }
        } else {
            e.a.vector(subtract ? .sub : .add, q: quad, size: sizeField(esize), 0, 1, 2)
        }
        e.storeVector(d, 0, quad: quad)
    }

    private static func emitModifiedImmediate(_ i: NEONModifiedImmediateInstruction, into e: inout BlockEmitter) {
        e.a.mov(x: 1, i.imm64)
        for register in i.vd..<(i.vd + (i.isQuad ? 2 : 1)) {
            let offset = dOffset(register)
            switch i.operation {
            case .move:
                e.a.str(x: 1, H.registers, offset: offset)
            case .moveNot:
                e.a.mov(x: 0, ~i.imm64)
                e.a.str(x: 0, H.registers, offset: offset)
            case .orr:
                e.a.ldr(x: 0, H.registers, offset: offset)
                e.a.orr(x: 0, 0, 1)
                e.a.str(x: 0, H.registers, offset: offset)
            case .bic:
                e.a.ldr(x: 0, H.registers, offset: offset)
                e.a.bic(x: 0, 0, 1)
                e.a.str(x: 0, H.registers, offset: offset)
            }
        }
    }

    private static func emitElementLoadStore(_ i: ElementLoadStoreInstruction, pc: UInt32, next: UInt32, itState: UInt8, into e: inout BlockEmitter) {
        let slow = e.slowPath(pc: pc, next: next, itState: itState)
        e.load(2, guest: i.rn)
        let bytes = i.registerCount * 8
        e.locateRun(2, width: bytes, access: i.isLoad ? .read : .write, deopt: slow)
        copy(bytes: bytes, file: dOffset(i.firstRegister), load: i.isLoad, into: &e)
        switch i.writeback {
        case .none:
            break
        case .byTransferSize:
            e.a.add(w: 4, 2, imm: UInt32(bytes))
            e.store(guest: i.rn, 4)
        case .register(let rm):
            e.load(4, guest: rm)
            e.a.add(w: 4, 2, 4)
            e.store(guest: i.rn, 4)
        }
    }

    private static func emitStructureLoadStore(_ i: NEONStructureLoadStoreInstruction, pc: UInt32, next: UInt32, itState: UInt8,
                                               into e: inout BlockEmitter) {
        let slow = e.slowPath(pc: pc, next: next, itState: itState)
        let ebytes = i.esize / 8
        e.load(2, guest: i.rn)
        let transferred: Int
        switch i.form {
        case .multiple(let registers, _):
            transferred = registers * 8
            e.locateRun(2, width: transferred, access: i.isLoad ? .read : .write, deopt: slow)
            copy(bytes: transferred, file: dOffset(i.d), load: i.isLoad, into: &e)
        case .singleLane(let index, _):
            transferred = ebytes
            let file = dOffset(i.d) + index * ebytes
            if i.isLoad {
                e.loadMemory(0, address: 2, width: ebytes, signed: false, deopt: slow)
                switch ebytes {
                case 1: e.a.strb(w: 0, H.registers, offset: file)
                case 2: e.a.strh(w: 0, H.registers, offset: file)
                default: e.a.str(w: 0, H.registers, offset: file)
                }
            } else {
                switch ebytes {
                case 1: e.a.ldrb(w: 0, H.registers, offset: file)
                case 2: e.a.ldrh(w: 0, H.registers, offset: file)
                default: e.a.ldr(w: 0, H.registers, offset: file)
                }
                e.storeMemory(0, address: 2, width: ebytes, deopt: slow)
            }
        case .allLanes(_, let registers):
            transferred = ebytes
            e.loadMemory(0, address: 2, width: ebytes, signed: false, deopt: slow)
            e.a.dup(q: false, 0, general: 0, imm5: ebytes)
            for r in 0..<registers { e.storeD(i.d + r, 0) }
        }
        switch i.rm {
        case 15:
            break
        case 13:
            e.a.add(w: 4, 2, imm: UInt32(transferred))
            e.store(guest: i.rn, 4)
        default:
            e.load(4, guest: i.rm)
            e.a.add(w: 4, 2, 4)
            e.store(guest: i.rn, 4)
        }
    }

    private static func emitNEON(_ i: NEONInstruction, into e: inout BlockEmitter) {
        let q = i.isQuad
        let size = sizeField(i.esize)
        let esize = i.esize
        let u = i.unsigned

        /// `op(n, m)` into d at the operation's own width.
        func same(_ op: A64Assembler.VectorOperation, accumulate: Bool = false, withSize: Bool = true) {
            e.loadVector(1, i.n, quad: q)
            e.loadVector(2, i.m, quad: q)
            if accumulate { e.loadVector(0, i.d, quad: q) }
            e.a.vector(op, q: q, size: withSize ? size : 0, 0, 1, 2)
            e.storeVector(i.d, 0, quad: q)
        }

        switch i.operation {
        case .same(let op):
            switch op {
            case .add: emitAdd(subtract: false, esize: esize, d: i.d, n: i.n, m: i.m, quad: q, into: &e)
            case .subtract: emitAdd(subtract: true, esize: esize, d: i.d, n: i.n, m: i.m, quad: q, into: &e)
            case .multiply: same(.mul)
            case .polynomialMultiply: same(.pmul)
            case .multiplyAccumulate: same(.mla, accumulate: true)
            case .multiplySubtract: same(.mls, accumulate: true)
            case .halvingAdd: same(u ? .uhadd : .shadd)
            case .roundingHalvingAdd: same(u ? .urhadd : .srhadd)
            case .halvingSubtract: same(u ? .uhsub : .shsub)
            case .compareGreater: same(u ? .cmhi : .cmgt)
            case .compareGreaterOrEqual: same(u ? .cmhs : .cmge)
            case .compareEqual: same(.cmeq)
            case .test: same(.cmtst)
            case .maximum: same(u ? .umax : .smax)
            case .minimum: same(u ? .umin : .smin)
            case .absoluteDifference: same(u ? .uabd : .sabd)
            case .absoluteDifferenceAccumulate: same(u ? .uaba : .saba, accumulate: true)
            case .pairwiseMaximum: same(u ? .umaxp : .smaxp)
            case .pairwiseMinimum: same(u ? .uminp : .sminp)
            case .pairwiseAdd: same(.addp)
            case .shiftLeft, .roundingShiftLeft:
                // VSHL Dd, Dm, Dn: Dm shifted by Dn's bytes.
                e.loadVector(1, i.m, quad: q)
                e.loadVector(2, i.n, quad: q)
                let rounding = op == .roundingShiftLeft
                e.a.vector(rounding ? (u ? .urshl : .srshl) : (u ? .ushl : .sshl), q: q, size: size, 0, 1, 2)
                e.storeVector(i.d, 0, quad: q)
            case .and: same(.and, withSize: false)
            case .bitClear: same(.bic, withSize: false)
            case .or: same(.orr, withSize: false)
            case .orNot: same(.orn, withSize: false)
            case .exclusiveOr: same(.eor, withSize: false)
            case .bitwiseSelect: same(.bsl, accumulate: true, withSize: false)
            case .bitwiseInsertIfTrue: same(.bit, accumulate: true, withSize: false)
            case .bitwiseInsertIfFalse: same(.bif, accumulate: true, withSize: false)
            case .floatAdd: same(.fadd, withSize: false)
            case .floatSubtract: same(.fsub, withSize: false)
            case .floatMultiply: same(.fmul, withSize: false)
            case .floatAbsoluteDifference: same(.fabd, withSize: false)
            case .floatPairwiseAdd: same(.faddp, withSize: false)
            case .floatMaximum: same(.fmax, withSize: false)
            case .floatMinimum: same(.fmin, withSize: false)
            case .floatPairwiseMaximum: same(.fmaxp, withSize: false)
            case .floatPairwiseMinimum: same(.fminp, withSize: false)
            case .floatCompareEqual: same(.fcmeq, withSize: false)
            case .floatCompareGreaterOrEqual: same(.fcmge, withSize: false)
            case .floatCompareGreater: same(.fcmgt, withSize: false)
            case .floatAbsoluteCompareGreaterOrEqual: same(.facge, withSize: false)
            case .floatAbsoluteCompareGreater: same(.facgt, withSize: false)
            case .floatMultiplyAccumulate, .floatMultiplySubtract:
                // Rounded product, then the add (VMLA.F32 isn't fused).
                e.loadVector(1, i.n, quad: q)
                e.loadVector(2, i.m, quad: q)
                e.loadVector(0, i.d, quad: q)
                e.a.vector(.fmul, q: q, 3, 1, 2)
                e.a.vector(op == .floatMultiplyAccumulate ? .fadd : .fsub, q: q, 0, 0, 3)
                e.storeVector(i.d, 0, quad: q)
            default:
                preconditionFailure("unsupported")
            }

        case .long(let op):
            // Qd = op(Dn, Dm), elements widened.
            let a64: A64Assembler.VectorOperation
            var accumulate = false
            switch op {
            case .add: a64 = u ? .uaddl : .saddl
            case .subtract: a64 = u ? .usubl : .ssubl
            case .absoluteDifference: a64 = u ? .uabdl : .sabdl
            case .absoluteDifferenceAccumulate: a64 = u ? .uabal : .sabal; accumulate = true
            case .multiply: a64 = u ? .umull : .smull
            case .multiplyAccumulate: a64 = u ? .umlal : .smlal; accumulate = true
            case .multiplySubtract: a64 = u ? .umlsl : .smlsl; accumulate = true
            case .polynomialMultiply: a64 = .pmull
            default: preconditionFailure("unsupported")
            }
            e.loadD(1, i.n)
            e.loadD(2, i.m)
            if accumulate { e.loadVector(0, i.d, quad: true) }
            e.a.vector(a64, q: false, size: size, 0, 1, 2)
            e.storeVector(i.d, 0, quad: true)

        case .wide(let op):
            // Qd = Qn op Dm, Dm's elements widened.
            e.loadVector(1, i.n, quad: true)
            e.loadD(2, i.m)
            e.a.vector(op == .add ? (u ? .uaddw : .saddw) : (u ? .usubw : .ssubw), q: false, size: size, 0, 1, 2)
            e.storeVector(i.d, 0, quad: true)

        case .narrowHigh(let op):
            // Dd = the high halves of Qn op Qm.
            let a64: A64Assembler.VectorOperation
            switch op {
            case .add: a64 = .addhn
            case .roundingAdd: a64 = .raddhn
            case .subtract: a64 = .subhn
            case .roundingSubtract: a64 = .rsubhn
            }
            e.loadVector(1, i.n, quad: true)
            e.loadVector(2, i.m, quad: true)
            e.a.vector(a64, q: false, size: size, 0, 1, 2)
            e.storeD(i.d, 0)

        case .byScalar(let op, let index):
            // Scalar: element `index` of Dm, held in v2.
            e.loadD(2, i.m)
            switch op {
            case .multiply, .multiplyAccumulate, .multiplySubtract:
                e.loadVector(1, i.n, quad: q)
                if op != .multiply { e.loadVector(0, i.d, quad: q) }
                let a64: A64Assembler.VectorByElement = op == .multiply ? .mul : op == .multiplyAccumulate ? .mla : .mls
                e.a.vector(a64, q: q, size: size, 0, 1, 2, index: index)
                e.storeVector(i.d, 0, quad: q)
            case .floatMultiply:
                e.loadVector(1, i.n, quad: q)
                e.a.vector(.fmul, q: q, size: 2, 0, 1, 2, index: index)
                e.storeVector(i.d, 0, quad: q)
            case .floatMultiplyAccumulate, .floatMultiplySubtract:
                e.loadVector(1, i.n, quad: q)
                e.loadVector(0, i.d, quad: q)
                e.a.vector(.fmul, q: q, size: 2, 3, 1, 2, index: index)
                e.a.vector(op == .floatMultiplyAccumulate ? .fadd : .fsub, q: q, 0, 0, 3)
                e.storeVector(i.d, 0, quad: q)
            case .multiplyLong, .multiplyAccumulateLong, .multiplySubtractLong:
                // Qd = Dn * scalar, widened.
                e.loadD(1, i.n)
                if op != .multiplyLong { e.loadVector(0, i.d, quad: true) }
                let a64: A64Assembler.VectorByElement
                switch op {
                case .multiplyLong: a64 = u ? .umull : .smull
                case .multiplyAccumulateLong: a64 = u ? .umlal : .smlal
                default: a64 = u ? .umlsl : .smlsl
                }
                e.a.vector(a64, q: false, size: size, 0, 1, 2, index: index)
                e.storeVector(i.d, 0, quad: true)
            default:
                preconditionFailure("unsupported")
            }

        case .shift(let op, let amount):
            switch op {
            case .shiftRightNarrow, .roundingShiftRightNarrow:
                // Dd = Qm >> amount, narrowed to esize.
                e.loadVector(1, i.m, quad: true)
                e.a.vector(op == .shiftRightNarrow ? .shrn : .rshrn, q: false, esize: esize, amount: amount, 0, 1)
                e.storeD(i.d, 0)
            case .shiftLeftLong:
                // Qd = Dm << amount, widened from esize.
                e.loadD(1, i.m)
                e.a.vector(u ? .ushll : .sshll, q: false, esize: esize, amount: amount, 0, 1)
                e.storeVector(i.d, 0, quad: true)
            default:
                let a64: A64Assembler.VectorShift
                var accumulate = false
                switch op {
                case .shiftRight: a64 = u ? .ushr : .sshr
                case .shiftRightAccumulate: a64 = u ? .usra : .ssra; accumulate = true
                case .roundingShiftRight: a64 = u ? .urshr : .srshr
                case .roundingShiftRightAccumulate: a64 = u ? .ursra : .srsra; accumulate = true
                case .shiftRightInsert: a64 = .sri; accumulate = true
                case .shiftLeft: a64 = .shl
                case .shiftLeftInsert: a64 = .sli; accumulate = true
                default: preconditionFailure("unsupported")
                }
                e.loadVector(1, i.m, quad: q)
                if accumulate { e.loadVector(0, i.d, quad: q) }
                e.a.vector(a64, q: q, esize: esize, amount: amount, 0, 1)
                e.storeVector(i.d, 0, quad: q)
            }

        case .misc(let op):
            func unary(_ a64: A64Assembler.VectorUnaryOperation, size: Int, accumulate: Bool = false) {
                e.loadVector(1, i.m, quad: q)
                if accumulate { e.loadVector(0, i.d, quad: q) }
                e.a.vector(a64, q: q, size: size, 0, 1)
                e.storeVector(i.d, 0, quad: q)
            }
            switch op {
            case .reverse64: unary(.rev64, size: size)
            case .reverse32: unary(.rev32, size: size)
            case .reverse16: unary(.rev16, size: size)
            case .pairwiseAddLong: unary(u ? .uaddlp : .saddlp, size: size)
            case .pairwiseAddAccumulateLong: unary(u ? .uadalp : .sadalp, size: size, accumulate: true)
            case .countLeadingSignBits: unary(.cls, size: size)
            case .countLeadingZeros: unary(.clz, size: size)
            case .countOnes: unary(.cnt, size: 0)
            case .not: unary(.not, size: 0)
            case .compareGreaterThanZero(let float): unary(float ? .fcmgt0 : .cmgt0, size: float ? 0 : size)
            case .compareGreaterOrEqualZero(let float): unary(float ? .fcmge0 : .cmge0, size: float ? 0 : size)
            case .compareEqualZero(let float): unary(float ? .fcmeq0 : .cmeq0, size: float ? 0 : size)
            case .compareLessOrEqualZero(let float): unary(float ? .fcmle0 : .cmle0, size: float ? 0 : size)
            case .compareLessThanZero(let float): unary(float ? .fcmlt0 : .cmlt0, size: float ? 0 : size)
            case .absolute(let float): unary(float ? .fabs : .abs, size: float ? 0 : size)
            case .negate(let float): unary(float ? .fneg : .neg, size: float ? 0 : size)
            case .convertToFloat: unary(u ? .ucvtf : .scvtf, size: 0)
            case .convertFromFloat: unary(u ? .fcvtzu : .fcvtzs, size: 0)
            case .moveNarrow:
                // Dd = Qm's elements narrowed to esize.
                e.loadVector(1, i.m, quad: true)
                e.a.vector(.xtn, q: false, size: size, 0, 1)
                e.storeD(i.d, 0)
            case .shiftLeftLongByElementSize:
                e.loadD(1, i.m)
                e.a.vector(.shll, q: false, size: size, 0, 1)
                e.storeVector(i.d, 0, quad: true)
            default:
                preconditionFailure("unsupported")
            }

        case .tableLookup(let extends, let length):
            // The table's D registers are consecutive in the register file:
            // loaded as Q registers, with anything past the table zeroed
            // (an index into it must find nothing, as it would on the guest).
            for k in 0..<((length + 1) / 2) {
                let first = i.n + 2 * k
                if 2 * k + 1 == length {
                    e.loadD(4 + k, first)
                } else if first % 2 == 0 {
                    e.loadVector(4 + k, first, quad: true)
                } else {
                    e.a.add(x: 9, H.registers, imm: UInt32(dOffset(first)))
                    e.a.ldr(q: 4 + k, 9, offset: 0)
                }
            }
            e.loadD(2, i.m)
            if extends { e.loadD(0, i.d) }
            e.a.tbl(q: false, extends: extends, 0, 4, length: (length + 1) / 2, 2)
            e.storeD(i.d, 0)

        case .duplicateScalar(let index):
            e.loadD(1, i.m)
            let ebytes = esize / 8
            e.a.dup(q: q, 0, element: 1, imm5: (index << 1 | 1) * ebytes)
            e.storeVector(i.d, 0, quad: q)
        }
    }
}
