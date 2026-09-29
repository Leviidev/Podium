import Foundation

/// Translates ARM-state guest code for `DBTEngine`, mirroring the
/// interpreter's `ARMv7CPU.execute` case by case: an operand read of r15
/// is the instruction's address + 8 (`operandValue`), a plain register
/// read + 4 (`registers[15]`, already advanced); ALU and load writes to
/// the pc interwork like `BX`. Every instruction carries its own
/// condition. What isn't handled here (status-register and coprocessor
/// access, exception returns, the user-bank `LDM`/`STM ^` forms, VFP and
/// NEON, ...) the interpreter runs in place from the block, or — as a
/// block's first instruction — directly.
enum ARMTranslator {
    static let maxInstructions = 96

    private enum Outcome { case continued, ended, unsupported }

    static func translate(into e: inout BlockEmitter, virtual: UInt32, page: UnsafeRawPointer, stopAddresses: Set<UInt32>) -> Int {
        guard virtual & 3 == 0 else { return 0 }
        let base = virtual & 0xFFFF_F000
        var address = virtual
        while e.count < maxInstructions, address & 0xFFFF_F000 == base {
            if address != virtual, stopAddresses.contains(address) { break }
            let word = UInt32(littleEndian: page.loadUnaligned(fromByteOffset: Int(address & 0xFFF), as: UInt32.self))
            let instruction = ARMDecoder.decode(word)
            var outcome = emit(instruction, at: address, into: &e)
            if outcome == .unsupported {
                e.interpret(pc: address, next: address &+ 4)
                outcome = .continued
            }
            e.count += 1
            if outcome == .ended { return e.count }
            address = address &+ 4
        }
        guard e.count > 0 else { return 0 }
        e.fallThrough(to: address, thumb: false)
        return e.count
    }

    // MARK: Support

    private static func condition(of instruction: ARMInstruction) -> ARMCondition? {
        switch instruction {
        case .dataProcessing(let i): return i.condition
        case .branch(let i): return i.condition
        case .branchExchange(let i): return i.condition
        case .branchLinkExchangeImmediate: return .always
        case .loadStore(let i): return i.condition
        case .blockDataTransfer(let i): return i.condition
        case .halfwordDataTransfer(let i): return i.condition
        case .loadStoreDual(let i): return i.condition
        case .movWide(let i): return i.condition
        case .rev(let i): return i.condition
        case .bitFieldInsert(let i): return i.condition
        case .bitFieldExtract(let i): return i.condition
        case .multiply(let i): return i.condition
        case .clz(let i): return i.condition
        case .memoryBarrier: return .always
        default: return nil
        }
    }

    private static func isSupported(_ instruction: ARMInstruction) -> Bool {
        switch instruction {
        case .dataProcessing(let i):
            // S with rd = pc is an exception return.
            return !(i.setFlags && i.rd == 15 && !i.op.isComparison)
        case .branch, .branchExchange, .branchLinkExchangeImmediate, .memoryBarrier:
            return true
        case .loadStore(let i):
            return !(i.rn == 15 && (!i.preIndexed || i.writeback)) && !(i.rn == i.rd && (!i.preIndexed || i.writeback))
        case .blockDataTransfer(let i):
            return !i.userRegisters && i.rn != 15 && i.registerList != 0
        case .halfwordDataTransfer(let i):
            return i.rd != 15 && !(i.rn == 15 && (!i.preIndexed || i.writeback))
        case .loadStoreDual(let i):
            return i.rt < 14 && !(i.rn == 15 && (!i.preIndexed || i.writeback))
        case .movWide(let i): return i.rd != 15
        case .rev(let i): return i.rd != 15
        case .bitFieldInsert(let i): return i.rd != 15 && i.width >= 1 && i.lsb + i.width <= 32
        case .bitFieldExtract(let i): return i.rd != 15 && i.width >= 1 && i.lsb + i.width <= 32
        case .multiply(let i): return i.rd != 15 && i.ra != 15
        case .clz(let i): return i.rd != 15
        default: return false
        }
    }

    // MARK: Instructions

    private static func emit(_ instruction: ARMInstruction, at pc: UInt32, into e: inout BlockEmitter) -> Outcome {
        guard isSupported(instruction), let condition = condition(of: instruction) else { return .unsupported }
        let next = pc &+ 4
        let operandPC = pc &+ 8
        e.pcRead = next
        let skip = e.skipUnless(condition)
        var outcome = Outcome.continued

        switch instruction {
        case .dataProcessing(let i):
            outcome = emitDataProcessing(i, operandPC: operandPC, into: &e)

        case .branch(let i):
            let target = UInt32(bitPattern: Int32(bitPattern: operandPC) &+ i.signedOffset)
            if i.link { e.constant(0, next); e.store(guest: 14, 0) }
            if condition == .always && !i.link {
                e.jump(to: target, thumb: false)
                outcome = .ended
            } else if condition == .always {
                e.jump(to: target, thumb: false)
                outcome = .ended
            } else if !i.link {
                // A conditional branch: the block goes on along the other way.
                let taken = e.jumpLabel(to: target, thumb: false)
                e.a.b(taken)
            } else {
                e.jump(to: target, thumb: false)
                outcome = .ended
            }

        case .branchExchange(let i):
            e.read(2, guest: i.rm, pcValue: operandPC)
            if i.link { e.constant(3, next); e.store(guest: 14, 3) }
            e.a.and(w: 0, 2, imm: 0xFFFF_FFFE, scratch: 15)
            e.a.and(w: 1, 2, imm: 1, scratch: 15)
            e.jumpDynamic()
            outcome = .ended

        case .branchLinkExchangeImmediate(let i):
            e.constant(0, next)
            e.store(guest: 14, 0)
            e.jump(to: UInt32(bitPattern: Int32(bitPattern: operandPC) &+ i.signedOffset), thumb: true)
            outcome = .ended

        case .memoryBarrier:
            break

        case .loadStore(let i):
            let slow = e.slowPath(pc: pc, next: next, itState: 0)
            e.read(2, guest: i.rn, pcValue: operandPC)
            switch i.offset {
            case .immediate(let value):
                e.a.add(w: 3, 2, anyImm: i.addOffset ? value : 0 &- value, scratch: 15)
            case .register(let rm, let type, let amount):
                e.read(4, guest: rm, pcValue: operandPC)
                _ = ThumbTranslator.shiftImmediate(type, value: 4, amount: amount, result: 5, carry: 6, into: &e)
                if i.addOffset { e.a.add(w: 3, 2, 5) } else { e.a.sub(w: 3, 2, 5) }
            }
            e.a.mov(w: 1, w: i.preIndexed ? 3 : 2)
            let writesBack = !i.preIndexed || i.writeback
            if i.isLoad {
                e.loadMemory(0, address: 1, width: i.isByte ? 1 : 4, signed: false, deopt: slow)
                if i.rd == 15 {
                    e.a.mov(w: 6, w: 0)
                    if writesBack { e.store(guest: i.rn, 3) }
                    e.a.and(w: 0, 6, imm: 0xFFFF_FFFE, scratch: 15)
                    e.a.and(w: 1, 6, imm: 1, scratch: 15)
                    e.jumpDynamic()
                    outcome = .ended
                } else {
                    e.store(guest: i.rd, 0)
                    if writesBack { e.store(guest: i.rn, 3) }
                }
            } else {
                e.read(0, guest: i.rd, pcValue: operandPC)
                e.storeMemory(0, address: 1, width: i.isByte ? 1 : 4, deopt: slow)
                if writesBack { e.store(guest: i.rn, 3) }
            }

        case .halfwordDataTransfer(let i):
            let slow = e.slowPath(pc: pc, next: next, itState: 0)
            e.read(2, guest: i.rn, pcValue: operandPC)
            switch i.offset {
            case .immediate(let value): e.a.add(w: 3, 2, anyImm: i.addOffset ? value : 0 &- value, scratch: 15)
            case .register(let rm):
                e.read(4, guest: rm, pcValue: operandPC)
                if i.addOffset { e.a.add(w: 3, 2, 4) } else { e.a.sub(w: 3, 2, 4) }
            }
            e.a.mov(w: 1, w: i.preIndexed ? 3 : 2)
            if i.isLoad {
                switch i.kind {
                case .unsignedHalfword: e.loadMemory(0, address: 1, width: 2, signed: false, deopt: slow)
                case .signedByte: e.loadMemory(0, address: 1, width: 1, signed: true, deopt: slow)
                case .signedHalfword: e.loadMemory(0, address: 1, width: 2, signed: true, deopt: slow)
                }
                e.store(guest: i.rd, 0)
            } else {
                e.read(0, guest: i.rd, pcValue: operandPC)
                e.storeMemory(0, address: 1, width: 2, deopt: slow)
            }
            if !i.preIndexed || i.writeback { e.store(guest: i.rn, 3) }

        case .loadStoreDual(let i):
            let slow = e.slowPath(pc: pc, next: next, itState: 0)
            e.read(2, guest: i.rn, pcValue: operandPC)
            switch i.offset {
            case .immediate(let value): e.a.add(w: 3, 2, anyImm: i.addOffset ? value : 0 &- value, scratch: 15)
            case .register(let rm):
                e.read(4, guest: rm, pcValue: operandPC)
                if i.addOffset { e.a.add(w: 3, 2, 4) } else { e.a.sub(w: 3, 2, 4) }
            }
            e.a.mov(w: 1, w: i.preIndexed ? 3 : 2)
            e.locateRun(1, width: 8, access: i.isLoad ? .read : .write, deopt: slow)
            if i.isLoad {
                e.a.ldr(w: 4, 10, offset: 0)
                e.a.ldr(w: 5, 10, offset: 4)
                e.store(guest: i.rt, 4)
                e.store(guest: i.rt + 1, 5)
            } else {
                e.load(4, guest: i.rt)
                e.load(5, guest: i.rt + 1)
                e.a.str(w: 4, 10, offset: 0)
                e.a.str(w: 5, 10, offset: 4)
            }
            if !i.preIndexed || i.writeback { e.store(guest: i.rn, 3) }

        case .blockDataTransfer(let i):
            outcome = emitBlockTransfer(i, pc: pc, next: next, operandPC: operandPC, into: &e)

        case .movWide(let i):
            if i.isTop {
                e.load(0, guest: i.rd)
                e.a.movk(w: 0, i.imm16, shift: 16)
            } else {
                e.constant(0, UInt32(i.imm16))
            }
            e.store(guest: i.rd, 0)

        case .rev(let i):
            e.load(0, guest: i.rm); e.a.rev(w: 0, 0); e.store(guest: i.rd, 0)

        case .clz(let i):
            e.load(0, guest: i.rm); e.a.clz(w: 0, 0); e.store(guest: i.rd, 0)

        case .bitFieldInsert(let i):
            e.load(0, guest: i.rd)
            if let source = i.sourceRegister { e.load(1, guest: source) } else { e.constant(1, 0) }
            e.a.bfi(w: 0, 1, lsb: i.lsb, width: i.width)
            e.store(guest: i.rd, 0)

        case .bitFieldExtract(let i):
            e.load(0, guest: i.rn)
            e.a.ubfx(w: 0, 0, lsb: i.lsb, width: i.width)
            e.store(guest: i.rd, 0)

        case .multiply(let i):
            e.load(0, guest: i.rm)
            e.load(1, guest: i.rs)
            switch i.kind {
            case .mul, .mla, .mls:
                switch i.kind {
                case .mla: e.load(2, guest: i.ra); e.a.madd(w: 3, 0, 1, 2)
                case .mls: e.load(2, guest: i.ra); e.a.msub(w: 3, 0, 1, 2)
                default: e.a.mul(w: 3, 0, 1)
                }
                e.store(guest: i.rd, 3)
                if i.setFlags { e.setNZ(3, carry: .keep) }
            case .umull, .umlal, .smull, .smlal, .umaal:
                // The accumulator is RdHi:RdLo (rd:ra); UMAAL adds both.
                let signed = i.kind == .smull || i.kind == .smlal
                switch i.kind {
                case .umlal, .smlal:
                    e.load(4, guest: i.ra)                 // zero-extends into x4
                    e.load(5, guest: i.rd)
                    e.a.orr(x: 4, 4, 5, lsl: 32)
                case .umaal:
                    e.load(4, guest: i.ra)
                    e.load(5, guest: i.rd)
                    e.a.add(x: 4, 4, 5)
                default:
                    e.a.mov(x: 4, x: 31)
                }
                if signed { e.a.smaddl(x: 2, 0, 1, 4) } else { e.a.umaddl(x: 2, 0, 1, 4) }
                e.store(guest: i.ra, 2)
                e.a.lsr(x: 3, 2, 32)
                e.store(guest: i.rd, 3)
                if i.setFlags {
                    // N from bit 63, Z from all 64 bits; C and V kept.
                    e.a.orr(w: 4, 2, 3)
                    e.a.mrsNZCV(x: 13)
                    e.a.and(w: 13, 13, imm: 0x3000_0000, scratch: 15)
                    e.a.tst(w: 4, 4)
                    e.a.mrsNZCV(x: 14)
                    e.a.and(w: 14, 14, imm: 0x4000_0000, scratch: 15)
                    e.a.lsr(w: 5, 3, 31)
                    e.a.orr(w: 14, 14, 5, .lsl, 31)
                    e.a.orr(w: 14, 14, 13)
                    e.a.msrNZCV(x: 14)
                }
            }

        default:
            preconditionFailure("unsupported ARM form reached translation")
        }

        let resumes = e.bindResumes()
        e.bind(skip)
        if outcome == .ended, skip != nil || resumes { e.jump(to: next, thumb: false) }
        return outcome
    }

    // MARK: Pieces

    private static func emitDataProcessing(_ i: DataProcessingInstruction, operandPC: UInt32, into e: inout BlockEmitter) -> Outcome {
        // Operand 2 into w1, with the shifter's carry-out.
        let carry: BlockEmitter.Carry
        switch i.operand2 {
        case .immediate(let value, let forcedCarryOut):
            e.constant(1, value)
            carry = forcedCarryOut.map { .constant($0) } ?? .keep
        case .shiftedRegister(let rm, let type, let amount):
            e.read(4, guest: rm, pcValue: operandPC)
            carry = ThumbTranslator.shiftImmediate(type, value: 4, amount: amount, result: 1, carry: 5, into: &e)
        case .shiftedRegisterByRegister(let rm, let type, let rs):
            e.read(4, guest: rm, pcValue: operandPC)
            e.load(6, guest: rs)
            e.saveFlags()
            let needsCarry = i.setFlags && i.op.isLogical
            ThumbTranslator.registerShift(type, value: 4, amount: 6, result: 1, carry: needsCarry ? 5 : nil, into: &e)
            e.restoreFlags()
            carry = needsCarry ? .register(5) : .keep
        }
        if i.op.usesRn { e.read(0, guest: i.rn, pcValue: operandPC) }

        let s = i.setFlags
        switch i.op {
        case .and, .tst: e.a.and(w: 2, 0, 1)
        case .eor, .teq: e.a.eor(w: 2, 0, 1)
        case .orr: e.a.orr(w: 2, 0, 1)
        case .bic: e.a.bic(w: 2, 0, 1)
        case .mov: e.a.mov(w: 2, w: 1)
        case .mvn: e.a.mvn(w: 2, 1)
        case .add, .cmn: if s { e.a.adds(w: 2, 0, 1) } else { e.a.add(w: 2, 0, 1) }
        case .adc: if s { e.a.adcs(w: 2, 0, 1) } else { e.a.adc(w: 2, 0, 1) }
        case .sub, .cmp: if s { e.a.subs(w: 2, 0, 1) } else { e.a.sub(w: 2, 0, 1) }
        case .sbc: if s { e.a.sbcs(w: 2, 0, 1) } else { e.a.sbc(w: 2, 0, 1) }
        case .rsb: if s { e.a.subs(w: 2, 1, 0) } else { e.a.sub(w: 2, 1, 0) }
        case .rsc: if s { e.a.sbcs(w: 2, 1, 0) } else { e.a.sbc(w: 2, 1, 0) }
        }
        if s && i.op.isLogical { e.setNZ(2, carry: carry) }
        if i.op.isComparison { return .continued }
        if i.rd == 15 {
            // ALUWritePC interworks like BX.
            e.a.and(w: 0, 2, imm: 0xFFFF_FFFE, scratch: 15)
            e.a.and(w: 1, 2, imm: 1, scratch: 15)
            e.jumpDynamic()
            return .ended
        }
        e.store(guest: i.rd, 2)
        return .continued
    }

    private static func emitBlockTransfer(_ i: BlockDataTransferInstruction, pc: UInt32, next: UInt32, operandPC: UInt32,
                                          into e: inout BlockEmitter) -> Outcome {
        let count = i.registerList.nonzeroBitCount
        let size = UInt32(count * 4)
        let slow = e.slowPath(pc: pc, next: next, itState: 0)
        e.load(2, guest: i.rn)
        let start: UInt32 = i.addOffset ? (i.preIndexed ? 4 : 0) : (i.preIndexed ? 0 &- size : 0 &- size &+ 4)
        e.a.add(w: 1, 2, anyImm: start, scratch: 15)
        e.locateRun(1, width: Int(size), access: i.isLoad ? .read : .write, deopt: slow)
        var slot = 0
        var loadsPC = false
        for index in 0..<16 where (i.registerList >> index) & 1 == 1 {
            if i.isLoad {
                if index == 15 {
                    e.a.ldr(w: 6, 10, offset: slot * 4)
                    loadsPC = true
                } else {
                    e.a.ldr(w: 3, 10, offset: slot * 4)
                    e.store(guest: index, 3)
                }
            } else {
                e.read(3, guest: index, pcValue: operandPC)
                e.a.str(w: 3, 10, offset: slot * 4)
            }
            slot += 1
        }
        if i.writeback {
            e.a.add(w: 3, 2, anyImm: i.addOffset ? size : 0 &- size, scratch: 15)
            e.store(guest: i.rn, 3)
        }
        guard loadsPC else { return .continued }
        e.a.and(w: 0, 6, imm: 0xFFFF_FFFE, scratch: 15)
        e.a.and(w: 1, 6, imm: 1, scratch: 15)
        e.jumpDynamic()
        return .ended
    }
}
