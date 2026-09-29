import Foundation

/// Translates Thumb/Thumb-2 guest code for `DBTEngine`. Each case mirrors
/// the interpreter's (`ARMv7CPU+Thumb.swift`) to the bit: which value a
/// read of r15 gives (the next instruction's address, or `Align(pc+4)`),
/// when 16-bit instructions set flags (only outside a conditional IT
/// slot), the order registers are written in, interworking on loads into
/// the pc. Anything not handled here ends the block before it, and the
/// interpreter runs it.
///
/// An `IT` instruction is translated together with the instructions it
/// covers, each under its own condition, or not at all.
enum ThumbTranslator {
    static let maxInstructions = 96

    private enum Outcome {
        case continued
        /// The block ended with this instruction.
        case ended
        case unsupported
    }

    /// Emits the block starting at `virtual`; returns how many guest
    /// instructions it covers (0 if not even the first could be).
    static func translate(into e: inout BlockEmitter, virtual: UInt32, page: UnsafeRawPointer, stopAddresses: Set<UInt32>) -> Int {
        let code = Page(base: virtual & 0xFFFF_F000, host: page)
        var address = virtual
        while e.count < maxInstructions {
            if address != virtual, stopAddresses.contains(address) { break }
            guard let (instruction, size) = code.fetch(address) else { break }

            if case .it(let it) = instruction {
                guard let group = itGroup(after: address, it: it, code: code, stopAddresses: stopAddresses) else { break }
                // The IT instruction itself: nothing to do but count it.
                e.count += 1
                var cursor = address &+ 2
                var ended = false
                for (index, member) in group.enumerated() {
                    let outcome = emit(member.instruction, at: cursor, size: member.size, condition: member.condition,
                                       itState: member.itState, isLast: index == group.count - 1, into: &e)
                    precondition(outcome != .unsupported, "checked by itGroup")
                    e.count += 1
                    cursor = cursor &+ UInt32(member.size)
                    if outcome == .ended { ended = true }
                }
                if ended { return e.count }
                address = cursor
                continue
            }

            var outcome = emit(instruction, at: address, size: size, condition: .always, itState: 0, isLast: false, into: &e)
            if outcome == .unsupported {
                // The interpreter runs it in place; the block goes on
                // unless it changed course.
                e.interpret(pc: address, next: address &+ UInt32(size))
                outcome = .continued
            }
            e.count += 1
            if outcome == .ended { return e.count }
            address = address &+ UInt32(size)
        }
        guard e.count > 0 else { return 0 }
        e.fallThrough(to: address, thumb: true)
        return e.count
    }

    /// The page a block is translated from: blocks never leave it.
    private struct Page {
        let base: UInt32
        let host: UnsafeRawPointer

        /// The instruction at `address`, if it lies wholly on this page.
        func fetch(_ address: UInt32) -> (ThumbInstruction, Int)? {
            guard address & 0xFFFF_F000 == base else { return nil }
            let offset = Int(address & 0xFFF)
            guard offset <= 0xFFE else { return nil }
            let hw0 = UInt16(littleEndian: host.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard ThumbDecoder.isThirtyTwoBitFirstHalfword(hw0) else { return (ThumbDecoder.decode(hw0, 0), 2) }
            guard offset <= 0xFFC else { return nil }
            let hw1 = UInt16(littleEndian: host.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self))
            return (ThumbDecoder.decode(hw0, hw1), 4)
        }
    }

    // MARK: IT blocks

    private struct ITMember {
        let instruction: ThumbInstruction
        let size: Int
        let condition: ARMCondition
        /// ITSTATE while it executes (before the interpreter advances it).
        let itState: UInt8
    }

    /// The instructions an `IT` covers, with their conditions — nil if
    /// any can't be translated in place (then the interpreter runs the
    /// whole group, since blocks never start inside one).
    private static func itGroup(after address: UInt32, it: ThumbItInstruction, code: Page, stopAddresses: Set<UInt32>) -> [ITMember]? {
        var state = (it.firstCondition << 4) | it.mask
        var cursor = address &+ 2
        var members: [ITMember] = []
        while state != 0 {
            guard !stopAddresses.contains(cursor), let (instruction, size) = code.fetch(cursor) else { return nil }
            let condition = state & 0xF != 0 ? ARMCondition(rawBits: UInt32(state >> 4)) : .always
            guard supportedInIT(instruction) else { return nil }
            members.append(ITMember(instruction: instruction, size: size, condition: condition, itState: state))
            state = advance(state)
            cursor = cursor &+ UInt32(size)
        }
        // A branch may only be the last instruction of the group.
        for member in members.dropLast() where endsBlock(member.instruction) { return nil }
        return members.isEmpty ? nil : members
    }

    /// The interpreter's `advanceThumbITState`.
    private static func advance(_ state: UInt8) -> UInt8 {
        guard state & 0b111 != 0 else { return 0 }
        return (state & 0xE0) | (((state & 0x1F) << 1) & 0x1F)
    }

    private static func supportedInIT(_ instruction: ThumbInstruction) -> Bool {
        switch instruction {
        case .it, .conditionalBranch, .compareBranch: return false
        case .branchWide(let b): return b.condition == .always && isSupported(instruction)
        default: return isSupported(instruction)
        }
    }

    /// Whether the instruction always leaves the block (so it can't be
    /// followed by more of an IT group).
    private static func endsBlock(_ instruction: ThumbInstruction) -> Bool {
        switch instruction {
        case .branch, .branchLink, .branchExchange, .tableBranch, .branchWide: return true
        case .hiRegister(let i): return i.rdn == 15 && i.op != .cmp
        case .pushPop(let i): return i.isLoad && i.registerList & 0x8000 != 0
        case .blockDataTransfer(let i): return i.isLoad && i.registerList & 0x8000 != 0
        case .loadStoreWide(let i): return i.isLoad && i.rt == 15
        case .loadStoreRegister(let i): return i.isLoad && i.rt == 15
        case .dataProcessingImmediate(let i): return i.rd == 15
        case .dataProcessingShiftedRegister(let i): return i.rd == 15
        case .addWide(let i): return i.rd == 15
        default: return false
        }
    }

    private static func isSupported(_ instruction: ThumbInstruction) -> Bool {
        guard !writesPCOddly(instruction) else { return false }
        switch instruction {
        case .shiftImmediate, .immediate, .addSub, .alu, .hiRegister, .branchExchange, .loadStoreImmediate,
             .loadPCRelative, .loadStoreRegisterOffset, .address, .adjustStack, .pushPop, .conditionalBranch,
             .branch, .compareBranch, .extend, .movWide, .addWide, .adr, .dataProcessingImmediate,
             .dataProcessingShiftedRegister, .branchLink, .branchWide, .loadStoreWide, .loadStoreRegister,
             .blockDataTransfer, .tableBranch, .loadStoreDual, .umull, .smull, .mla, .mls, .mul, .clz, .rbit,
             .reverseBytes, .shiftRegister, .smmul, .packHalfword, .memoryBarrier:
            return true
        case .bitFieldExtract(let i): return i.width >= 1 && i.lsb + i.width <= 32
        case .bitFieldInsert(let i): return i.width >= 1 && i.lsb + i.width <= 32
        case .extendWide(let i): return i.kind != .unsignedByte16 && i.kind != .signedByte16
        case .hint(let hint): return hint != .waitForInterrupt
        case .armEquivalent(let arm): return ARMTranslator.isSupportedExclusive(arm)
        case .clearExclusive: return true
        case .coprocessorRegisterTransfer(let i): return ARMTranslator.isThreadIDRead(i)
        default: return false
        }
    }

    /// Forms that would write r15 as an ordinary register (UNPREDICTABLE
    /// encodings, in practice never used): left to the interpreter.
    private static func writesPCOddly(_ instruction: ThumbInstruction) -> Bool {
        switch instruction {
        case .movWide(let i): return i.rd == 15
        case .addWide(let i): return i.rd == 15
        case .bitFieldExtract(let i): return i.rd == 15
        case .bitFieldInsert(let i): return i.rd == 15
        case .adr(let i): return i.rd == 15
        case .extend(let i): return i.rd == 15
        case .extendWide(let i): return i.rd == 15
        case .clz(let i): return i.rd == 15
        case .rbit(let i): return i.rd == 15
        case .reverseBytes(let i): return i.rd == 15
        case .mul(let i): return i.rd == 15
        case .mla(let i): return i.rd == 15
        case .mls(let i): return i.rd == 15
        case .smmul(let i): return i.rd == 15
        case .umull(let i): return i.rdLo == 15 || i.rdHi == 15
        case .smull(let i): return i.rdLo == 15 || i.rdHi == 15
        case .shiftRegister(let i): return i.rd == 15
        case .packHalfword(let i): return i.rd == 15
        case .loadStoreDual(let i): return i.rt == 15 || i.rt2 == 15 || (i.rn == 15 && (!i.preIndexed || i.writeback))
        case .loadStoreWide(let i): return i.rn == 15 && (!i.preIndexed || i.writeback)
        case .loadStoreRegister(let i): return i.isLoad && i.rt == 15 && (i.isByte || i.isHalfword)
        case .blockDataTransfer(let i): return i.rn == 15
        case .immediate(let i): return i.rdn == 15
        case .addSub(let i): return i.rd == 15
        default: return false
        }
    }

    // MARK: Instructions

    private static func emit(_ instruction: ThumbInstruction, at pc: UInt32, size: Int, condition: ARMCondition,
                             itState: UInt8, isLast: Bool, into e: inout BlockEmitter) -> Outcome {
        guard isSupported(instruction) else { return .unsupported }
        // 16-bit data processing sets flags only when unconditional.
        let conditional = condition != .always
        let next = pc &+ UInt32(size)
        e.pcRead = next
        let skip = e.skipUnless(condition)
        var outcome = Outcome.continued

        switch instruction {
        case .shiftImmediate(let i):
            e.load(0, guest: i.rm)
            let carry = shiftImmediate(i.shiftType, value: 0, amount: i.imm5, result: 1, carry: 2, into: &e)
            e.store(guest: i.rd, 1)
            if !conditional { e.setNZ(1, carry: carry) }

        case .immediate(let i):
            switch i.op {
            case .mov:
                e.constant(0, i.imm8)
                e.store(guest: i.rdn, 0)
                if !conditional { e.setNZ(0, carry: .keep) }
            case .cmp:
                e.load(0, guest: i.rdn)
                e.a.cmp(w: 0, imm: i.imm8)
            case .add, .sub:
                e.load(0, guest: i.rdn)
                switch (i.op == .add, conditional) {
                case (true, false): e.a.adds(w: 0, 0, imm: i.imm8)
                case (true, true): e.a.add(w: 0, 0, imm: i.imm8)
                case (false, false): e.a.subs(w: 0, 0, imm: i.imm8)
                case (false, true): e.a.sub(w: 0, 0, imm: i.imm8)
                }
                e.store(guest: i.rdn, 0)
            }

        case .addSub(let i):
            e.load(0, guest: i.rn)
            switch i.operand2 {
            case .register(let rm):
                e.load(1, guest: rm)
                switch (i.isSub, conditional) {
                case (false, false): e.a.adds(w: 2, 0, 1)
                case (false, true): e.a.add(w: 2, 0, 1)
                case (true, false): e.a.subs(w: 2, 0, 1)
                case (true, true): e.a.sub(w: 2, 0, 1)
                }
            case .immediate(let imm):
                switch (i.isSub, conditional) {
                case (false, false): e.a.adds(w: 2, 0, imm: imm)
                case (false, true): e.a.add(w: 2, 0, imm: imm)
                case (true, false): e.a.subs(w: 2, 0, imm: imm)
                case (true, true): e.a.sub(w: 2, 0, imm: imm)
                }
            }
            e.store(guest: i.rd, 2)

        case .alu(let i):
            emitAlu(i, conditional: conditional, into: &e)

        case .hiRegister(let i):
            e.read(0, guest: i.rdn, pcValue: pc &+ 4)
            e.read(1, guest: i.rm, pcValue: pc &+ 4)
            switch i.op {
            case .cmp:
                e.a.cmp(w: 0, 1)
            case .add, .mov:
                if i.op == .add { e.a.add(w: 2, 0, 1) } else { e.a.mov(w: 2, w: 1) }
                if i.rdn == 15 {
                    e.a.and(w: 0, 2, imm: 0xFFFF_FFFE, scratch: 15)
                    e.constant(1, 1)
                    e.jumpDynamic()
                    outcome = .ended
                } else {
                    e.store(guest: i.rdn, 2)
                }
            }

        case .branchExchange(let i):
            e.read(2, guest: i.rm, pcValue: next)
            if i.link { e.constant(3, next | 1); e.store(guest: 14, 3) }
            e.a.and(w: 0, 2, imm: 0xFFFF_FFFE, scratch: 15)
            e.a.and(w: 1, 2, imm: 1, scratch: 15)
            e.jumpDynamic()
            outcome = .ended

        case .loadStoreImmediate(let i):
            let width = i.size == .word ? 4 : (i.size == .byte ? 1 : 2)
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            e.load(1, guest: i.rn)
            e.a.add(w: 1, 1, anyImm: i.offset, scratch: 15)
            if i.isLoad {
                e.loadMemory(0, address: 1, width: width, signed: false, deopt: deopt)
                e.store(guest: i.rt, 0)
            } else {
                e.load(0, guest: i.rt)
                e.storeMemory(0, address: 1, width: width, deopt: deopt)
            }

        case .loadPCRelative(let i):
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            e.constant(1, ((pc &+ 4) & ~3) &+ i.offset)
            e.loadMemory(0, address: 1, width: 4, signed: false, deopt: deopt)
            e.store(guest: i.rt, 0)

        case .loadStoreRegisterOffset(let i):
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            e.load(1, guest: i.rn)
            e.load(2, guest: i.rm)
            e.a.add(w: 1, 1, 2)
            switch i.op {
            case .str, .strh, .strb:
                e.load(0, guest: i.rd)
                e.storeMemory(0, address: 1, width: i.op == .str ? 4 : (i.op == .strh ? 2 : 1), deopt: deopt)
            case .ldr: e.loadMemory(0, address: 1, width: 4, signed: false, deopt: deopt); e.store(guest: i.rd, 0)
            case .ldrh: e.loadMemory(0, address: 1, width: 2, signed: false, deopt: deopt); e.store(guest: i.rd, 0)
            case .ldrb: e.loadMemory(0, address: 1, width: 1, signed: false, deopt: deopt); e.store(guest: i.rd, 0)
            case .ldrsb: e.loadMemory(0, address: 1, width: 1, signed: true, deopt: deopt); e.store(guest: i.rd, 0)
            case .ldrsh: e.loadMemory(0, address: 1, width: 2, signed: true, deopt: deopt); e.store(guest: i.rd, 0)
            }

        case .address(let i):
            if i.usesSP {
                e.load(0, guest: 13)
                e.a.add(w: 0, 0, anyImm: i.imm8 &* 4, scratch: 15)
            } else {
                e.constant(0, ((pc &+ 4) & ~3) &+ i.imm8 &* 4)
            }
            e.store(guest: i.rd, 0)

        case .adjustStack(let i):
            e.load(0, guest: 13)
            e.a.add(w: 0, 0, anyImm: i.subtract ? 0 &- i.imm7 &* 4 : i.imm7 &* 4, scratch: 15)
            e.store(guest: 13, 0)

        case .pushPop(let i):
            outcome = emitBlockTransfer(ThumbBlockDataTransferInstruction(isLoad: i.isLoad, isIncrement: i.isLoad, writeback: true,
                                                                           rn: 13, registerList: i.registerList),
                                        pc: pc, next: next, itState: itState, into: &e)

        case .blockDataTransfer(let i):
            outcome = emitBlockTransfer(i, pc: pc, next: next, itState: itState, into: &e)

        case .conditionalBranch(let i):
            let target = UInt32(bitPattern: Int32(bitPattern: pc &+ 4) &+ i.signedOffset)
            emitConditionalExit(i.condition, to: target, into: &e)

        case .branch(let i):
            e.jump(to: UInt32(bitPattern: Int32(bitPattern: pc &+ 4) &+ i.signedOffset), thumb: true)
            outcome = .ended

        case .compareBranch(let i):
            e.load(0, guest: i.rn)
            let taken = e.jumpLabel(to: pc &+ 4 &+ i.offset, thumb: true)
            if i.branchIfNonZero { e.a.cbnz(w: 0, taken) } else { e.a.cbz(w: 0, taken) }

        case .extend(let i):
            e.load(0, guest: i.rm)
            switch i.kind {
            case .signedHalfword: e.a.sxth(w: 0, 0)
            case .signedByte: e.a.sxtb(w: 0, 0)
            case .unsignedHalfword: e.a.uxth(w: 0, 0)
            default: e.a.uxtb(w: 0, 0)
            }
            e.store(guest: i.rd, 0)

        case .hint, .memoryBarrier:
            break

        case .armEquivalent(let arm):
            ARMTranslator.emitExclusive(arm, pc: pc, next: next, itState: itState, into: &e)

        case .clearExclusive:
            e.clearExclusive()

        case .coprocessorRegisterTransfer(let i):
            _ = e.readThreadID(i)

        case .movWide(let i):
            if i.isTop {
                e.load(0, guest: i.rd)
                e.a.movk(w: 0, i.imm16, shift: 16)
            } else {
                e.constant(0, UInt32(i.imm16))
            }
            e.store(guest: i.rd, 0)

        case .bitFieldExtract(let i):
            e.read(0, guest: i.rn, pcValue: next)
            if i.signed { e.a.sbfx(w: 0, 0, lsb: i.lsb, width: i.width) } else { e.a.ubfx(w: 0, 0, lsb: i.lsb, width: i.width) }
            e.store(guest: i.rd, 0)

        case .addWide(let i):
            e.read(0, guest: i.rn, pcValue: next)
            if i.subtract { e.a.sub(w: 0, 0, imm: UInt32(i.imm12)) } else { e.a.add(w: 0, 0, imm: UInt32(i.imm12)) }
            if i.rd == 15 {
                e.a.and(w: 0, 0, imm: 0xFFFF_FFFE, scratch: 15); e.constant(1, 1); e.jumpDynamic(); outcome = .ended
            } else {
                e.store(guest: i.rd, 0)
            }

        case .adr(let i):
            let base = (pc &+ 4) & ~3
            e.constant(0, i.subtract ? base &- UInt32(i.imm12) : base &+ UInt32(i.imm12))
            e.store(guest: i.rd, 0)

        case .bitFieldInsert(let i):
            e.load(0, guest: i.rd)
            if let source = i.sourceRegister { e.read(1, guest: source, pcValue: next) } else { e.constant(1, 0) }
            e.a.bfi(w: 0, 1, lsb: i.lsb, width: i.width)
            e.store(guest: i.rd, 0)

        case .dataProcessingImmediate(let i):
            outcome = emitDataProcessing(op: i.op, setFlags: i.setFlags, rn: i.rn, rd: i.rd, next: next, into: &e) { e in
                e.constant(1, i.imm32)
                return i.immediateCarryOut.map { .constant($0) } ?? .keep
            }

        case .dataProcessingShiftedRegister(let i):
            outcome = emitDataProcessing(op: i.op, setFlags: i.setFlags, rn: i.rn, rd: i.rd, next: next, into: &e) { e in
                e.read(4, guest: i.rm, pcValue: next)
                return shiftImmediate(i.shiftType, value: 4, amount: i.shiftAmount, result: 1, carry: 5, into: &e)
            }

        case .branchLink(let i):
            let base = i.switchesToARM ? (pc &+ 4) & ~3 : pc &+ 4
            let target = UInt32(bitPattern: Int32(bitPattern: base) &+ i.signedOffset)
            e.constant(0, next | 1)
            e.store(guest: 14, 0)
            e.jump(to: i.switchesToARM ? target & ~3 : target, thumb: !i.switchesToARM)
            outcome = .ended

        case .branchWide(let i):
            let target = UInt32(bitPattern: Int32(bitPattern: pc &+ 4) &+ i.signedOffset)
            if i.condition == .always {
                e.jump(to: target, thumb: true)
                outcome = .ended
            } else {
                emitConditionalExit(i.condition, to: target, into: &e)
            }

        case .loadStoreWide(let i):
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            let width = i.isByte ? 1 : (i.isHalfword ? 2 : 4)
            if i.rn == 15 { e.constant(2, (pc &+ 4) & ~3) } else { e.load(2, guest: i.rn) }
            // w2 base, w3 offset address, w1 transfer address.
            if i.addOffset { e.a.add(w: 3, 2, anyImm: i.offset, scratch: 15) } else { e.a.add(w: 3, 2, anyImm: 0 &- i.offset, scratch: 15) }
            e.a.mov(w: 1, w: i.preIndexed ? 3 : 2)
            let writesBack = !i.preIndexed || i.writeback
            if i.isLoad {
                e.loadMemory(0, address: 1, width: width, signed: i.isSigned, deopt: deopt)
                if i.rt == 15 {
                    e.a.mov(w: 6, w: 0)
                    if writesBack { e.store(guest: i.rn, 3) }
                    e.a.and(w: 0, 6, imm: 0xFFFF_FFFE, scratch: 15)
                    e.a.and(w: 1, 6, imm: 1, scratch: 15)
                    e.jumpDynamic()
                    outcome = .ended
                } else {
                    e.store(guest: i.rt, 0)
                    if writesBack { e.store(guest: i.rn, 3) }
                }
            } else {
                e.read(0, guest: i.rt, pcValue: next)
                e.storeMemory(0, address: 1, width: width, deopt: deopt)
                if writesBack { e.store(guest: i.rn, 3) }
            }

        case .loadStoreRegister(let i):
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            let width = i.isByte ? 1 : (i.isHalfword ? 2 : 4)
            e.read(1, guest: i.rn, pcValue: next)
            e.read(2, guest: i.rm, pcValue: next)
            e.a.add(w: 1, 1, 2, .lsl, i.shiftAmount)
            if i.isLoad {
                e.loadMemory(0, address: 1, width: width, signed: i.isSigned, deopt: deopt)
                if i.rt == 15 && width == 4 {
                    e.a.mov(w: 6, w: 0)
                    e.a.and(w: 0, 6, imm: 0xFFFF_FFFE, scratch: 15)
                    e.a.and(w: 1, 6, imm: 1, scratch: 15)
                    e.jumpDynamic()
                    outcome = .ended
                } else {
                    e.store(guest: i.rt, 0)
                }
            } else {
                e.read(0, guest: i.rt, pcValue: next)
                e.storeMemory(0, address: 1, width: width, deopt: deopt)
            }

        case .tableBranch(let i):
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            e.read(1, guest: i.rn, pcValue: pc &+ 4)
            e.read(2, guest: i.rm, pcValue: next)
            e.a.add(w: 1, 1, 2, .lsl, i.isHalfword ? 1 : 0)
            e.loadMemory(0, address: 1, width: i.isHalfword ? 2 : 1, signed: false, deopt: deopt)
            e.constant(2, pc &+ 4)
            e.a.add(w: 0, 2, 0, .lsl, 1)
            e.constant(1, 1)
            e.jumpDynamic()
            outcome = .ended

        case .loadStoreDual(let i):
            let deopt = e.slowPath(pc: pc, next: next, itState: itState)
            e.read(2, guest: i.rn, pcValue: next)
            if i.addOffset { e.a.add(w: 3, 2, anyImm: i.offset, scratch: 15) } else { e.a.add(w: 3, 2, anyImm: 0 &- i.offset, scratch: 15) }
            e.a.mov(w: 1, w: i.preIndexed ? 3 : 2)
            e.locateRun(1, width: 8, access: i.isLoad ? .read : .write, deopt: deopt)
            if i.isLoad {
                e.a.ldr(w: 4, 10, offset: 0)
                e.a.ldr(w: 5, 10, offset: 4)
                e.store(guest: i.rt, 4)
                e.store(guest: i.rt2, 5)
            } else {
                e.read(4, guest: i.rt, pcValue: next)
                e.read(5, guest: i.rt2, pcValue: next)
                e.a.str(w: 4, 10, offset: 0)
                e.a.str(w: 5, 10, offset: 4)
            }
            if !i.preIndexed || i.writeback { e.store(guest: i.rn, 3) }

        case .umull(let i):
            e.load(0, guest: i.rn); e.load(1, guest: i.rm)
            e.a.umaddl(x: 2, 0, 1, 31)
            e.store(guest: i.rdLo, 2)
            e.a.lsr(x: 2, 2, 32)
            e.store(guest: i.rdHi, 2)

        case .smull(let i):
            e.load(0, guest: i.rn); e.load(1, guest: i.rm)
            e.a.smaddl(x: 2, 0, 1, 31)
            e.store(guest: i.rdLo, 2)
            e.a.lsr(x: 2, 2, 32)
            e.store(guest: i.rdHi, 2)

        case .smmul(let i):
            e.load(0, guest: i.rn); e.load(1, guest: i.rm)
            e.a.smaddl(x: 2, 0, 1, 31)
            e.a.lsr(x: 2, 2, 32)
            e.store(guest: i.rd, 2)

        case .mla(let i):
            e.load(0, guest: i.rn); e.load(1, guest: i.rm); e.load(2, guest: i.ra)
            e.a.madd(w: 3, 0, 1, 2)
            e.store(guest: i.rd, 3)

        case .mls(let i):
            e.load(0, guest: i.rn); e.load(1, guest: i.rm); e.load(2, guest: i.ra)
            e.a.msub(w: 3, 0, 1, 2)
            e.store(guest: i.rd, 3)

        case .mul(let i):
            e.load(0, guest: i.rn); e.load(1, guest: i.rm)
            e.a.mul(w: 2, 0, 1)
            e.store(guest: i.rd, 2)

        case .clz(let i):
            e.load(0, guest: i.rm); e.a.clz(w: 0, 0); e.store(guest: i.rd, 0)

        case .rbit(let i):
            e.load(0, guest: i.rm); e.a.rbit(w: 0, 0); e.store(guest: i.rd, 0)

        case .reverseBytes(let i):
            e.load(0, guest: i.rm)
            switch i.kind {
            case .word: e.a.rev(w: 0, 0)
            case .halfwordWise: e.a.rev16(w: 0, 0)
            case .signedHalfword: e.a.rev16(w: 0, 0); e.a.sxth(w: 0, 0)
            }
            e.store(guest: i.rd, 0)

        case .extendWide(let i):
            e.load(0, guest: i.rm)
            if i.rotate != 0 { e.a.ror(w: 0, 0, i.rotate * 8) }
            switch i.kind {
            case .signedHalfword: e.a.sxth(w: 0, 0)
            case .signedByte: e.a.sxtb(w: 0, 0)
            case .unsignedHalfword: e.a.uxth(w: 0, 0)
            default: e.a.uxtb(w: 0, 0)
            }
            if let rn = i.rn { e.read(1, guest: rn, pcValue: next); e.a.add(w: 0, 1, 0) }
            e.store(guest: i.rd, 0)

        case .shiftRegister(let i):
            e.saveFlags()
            e.read(0, guest: i.rn, pcValue: next)
            e.read(1, guest: i.rm, pcValue: next)
            registerShift(i.shiftType, value: 0, amount: 1, result: 2, carry: nil, into: &e)
            e.restoreFlags()
            e.store(guest: i.rd, 2)

        case .packHalfword(let i):
            e.read(0, guest: i.rn, pcValue: next)
            e.read(1, guest: i.rm, pcValue: next)
            if i.useTopBottom {
                e.a.asr(w: 1, 1, i.shiftAmount == 0 ? 31 : min(Int(i.shiftAmount), 31))
                e.a.bfi(w: 0, 1, lsb: 0, width: 16)
                e.store(guest: i.rd, 0)
            } else {
                if i.shiftAmount != 0 { e.a.lsl(w: 1, 1, Int(i.shiftAmount)) }
                e.a.bfi(w: 1, 0, lsb: 0, width: 16)
                e.store(guest: i.rd, 1)
            }

        default:
            preconditionFailure("unsupported Thumb form reached translation")
        }

        // Slow paths resume here, after the instruction.
        let resumes = e.bindResumes()
        e.bind(skip)
        // A conditional exit that wasn't taken continues after it, as does
        // one the interpreter ran without leaving the block.
        if outcome == .ended, skip != nil || resumes { e.jump(to: next, thumb: true) }
        return outcome
    }

    // MARK: Pieces

    /// Leaves the block for `target` when `condition` holds; otherwise the
    /// block goes on with the next instruction.
    private static func emitConditionalExit(_ condition: ARMCondition, to target: UInt32, into e: inout BlockEmitter) {
        guard condition != .never else { return }
        let taken = e.jumpLabel(to: target, thumb: true)
        if condition == .always {
            e.a.b(taken)
        } else {
            e.a.b(A64Assembler.Condition(rawValue: UInt32(condition.rawValue))!, taken)
        }
    }

    /// `ShifterOperand.applyShift` for a shift fixed at translation time:
    /// `result = shift(value)`, and the carry-out (bit 0 of `carry`, when
    /// it isn't simply the old C).
    static func shiftImmediate(_ type: ShiftType, value: Int, amount: UInt8, result: Int, carry: Int, into e: inout BlockEmitter) -> BlockEmitter.Carry {
        let n = Int(amount)
        switch type {
        case .lsl:
            if n == 0 { e.a.mov(w: result, w: value); return .keep }
            if n >= 32 {
                e.a.and(w: carry, value, imm: 1, scratch: 15)
                if n > 32 { e.constant(carry, 0) }
                e.constant(result, 0)
                return .register(carry)
            }
            e.a.ubfx(w: carry, value, lsb: 32 - n, width: 1)
            e.a.lsl(w: result, value, n)
        case .lsr:
            let effective = n == 0 ? 32 : n
            if effective >= 32 {
                e.a.lsr(w: carry, value, 31)
                if effective > 32 { e.constant(carry, 0) }
                e.constant(result, 0)
                return .register(carry)
            }
            e.a.ubfx(w: carry, value, lsb: effective - 1, width: 1)
            e.a.lsr(w: result, value, effective)
        case .asr:
            let effective = n == 0 ? 32 : n
            if effective >= 32 {
                e.a.lsr(w: carry, value, 31)
                e.a.asr(w: result, value, 31)
                return .register(carry)
            }
            e.a.ubfx(w: carry, value, lsb: effective - 1, width: 1)
            e.a.asr(w: result, value, effective)
        case .ror:
            if n == 0 {
                // RRX: through the carry.
                e.carryFlag(into: 16)
                e.a.and(w: carry, value, imm: 1, scratch: 15)
                e.a.lsr(w: result, value, 1)
                e.a.orr(w: result, result, 16, .lsl, 31)
                return .register(carry)
            }
            e.a.ror(w: result, value, n % 32)
            e.a.lsr(w: carry, result, 31)
        }
        return .register(carry)
    }

    /// `ShifterOperand.applyRegisterSpecifiedShift`: `result` =
    /// `value` shifted by the low byte of `amount`, and — if `carry` is
    /// given — its carry-out, which for a zero amount is the old C.
    /// Uses the host's flags: the caller has saved the guest's (x13).
    static func registerShift(_ type: ShiftType, value: Int, amount: Int, result: Int, carry: Int?, into e: inout BlockEmitter) {
        e.a.and(w: amount, amount, imm: 0xFF, scratch: 15)
        switch type {
        case .lsl:
            e.a.lslv(w: result, value, amount)
            e.a.cmp(w: amount, imm: 32)
            e.a.csel(w: result, result, 31, .lo)
            if let carry {
                e.a.mov(w: 16, w: value)                  // zero-extends into x16
                e.a.lslv(x: carry, 16, amount)
                e.a.ubfx(x: carry, carry, lsb: 32, width: 1)
                e.a.cmp(w: amount, imm: 33)
                e.a.csel(w: carry, carry, 31, .lo)
            }
        case .lsr:
            e.a.lsrv(w: result, value, amount)
            e.a.cmp(w: amount, imm: 32)
            e.a.csel(w: result, result, 31, .lo)
            if let carry {
                e.a.mov(w: 16, w: value)
                e.a.lsl(x: 16, 16, 1)
                e.a.lsrv(x: carry, 16, amount)
                e.a.and(w: carry, carry, imm: 1, scratch: 15)
                e.a.cmp(w: amount, imm: 33)
                e.a.csel(w: carry, carry, 31, .lo)
            }
        case .asr:
            e.constant(17, 31)
            e.a.cmp(w: amount, imm: 31)
            e.a.csel(w: 17, amount, 17, .lo)
            e.a.asrv(w: result, value, 17)
            if let carry {
                e.a.sxtw(x: 16, value)
                e.a.lsl(x: 16, 16, 1)
                e.constant(17, 63)
                e.a.cmp(w: amount, imm: 63)
                e.a.csel(w: 17, amount, 17, .lo)
                e.a.asrv(x: carry, 16, 17)
                e.a.and(w: carry, carry, imm: 1, scratch: 15)
            }
        case .ror:
            e.a.rorv(w: result, value, amount)
            if let carry { e.a.lsr(w: carry, result, 31) }
        }
        if let carry {
            // A zero amount leaves C as it was.
            e.a.ubfx(w: 16, 13, lsb: 29, width: 1)
            e.a.cmp(w: amount, imm: 0)
            e.a.csel(w: carry, carry, 16, .ne)
        }
    }

    /// Thumb format 4.
    private static func emitAlu(_ i: ThumbAluInstruction, conditional: Bool, into e: inout BlockEmitter) {
        let setsFlags = !conditional
        e.load(0, guest: i.rdn)
        e.load(1, guest: i.rm)
        switch i.op {
        case .and, .eor, .orr, .bic, .mvn, .mul:
            switch i.op {
            case .and: e.a.and(w: 2, 0, 1)
            case .eor: e.a.eor(w: 2, 0, 1)
            case .orr: e.a.orr(w: 2, 0, 1)
            case .bic: e.a.bic(w: 2, 0, 1)
            case .mvn: e.a.mvn(w: 2, 1)
            default: e.a.mul(w: 2, 0, 1)
            }
            e.store(guest: i.rdn, 2)
            if setsFlags { e.setNZ(2, carry: .keep) }
        case .tst:
            e.a.and(w: 2, 0, 1)
            e.setNZ(2, carry: .keep)
        case .lsl, .lsr, .asr, .ror:
            let type: ShiftType = i.op == .lsl ? .lsl : (i.op == .lsr ? .lsr : (i.op == .asr ? .asr : .ror))
            e.saveFlags()
            registerShift(type, value: 0, amount: 1, result: 2, carry: setsFlags ? 3 : nil, into: &e)
            e.restoreFlags()
            e.store(guest: i.rdn, 2)
            if setsFlags { e.setNZ(2, carry: .register(3)) }
        case .adc:
            if setsFlags { e.a.adcs(w: 2, 0, 1) } else { e.a.adc(w: 2, 0, 1) }
            e.store(guest: i.rdn, 2)
        case .sbc:
            if setsFlags { e.a.sbcs(w: 2, 0, 1) } else { e.a.sbc(w: 2, 0, 1) }
            e.store(guest: i.rdn, 2)
        case .rsb:
            if setsFlags { e.a.subs(w: 2, 31, 1) } else { e.a.neg(w: 2, 1) }
            e.store(guest: i.rdn, 2)
        case .cmp:
            e.a.cmp(w: 0, 1)
        case .cmn:
            e.a.adds(w: 31, 0, 1)
        }
    }

    /// Thumb-2 data processing, with an immediate or shifted-register
    /// second operand that `operand2` puts in w1 (returning the
    /// logical ops' carry-out).
    private static func emitDataProcessing(op: ThumbModifiedImmediateOp, setFlags: Bool, rn: Int, rd: Int, next: UInt32,
                                           into e: inout BlockEmitter,
                                           operand2: (inout BlockEmitter) -> BlockEmitter.Carry) -> Outcome {
        let isComparison = setFlags && rd == 15 && (op == .and || op == .eor || op == .add || op == .sub)
        let isMove = op == .orr && rn == 15
        let isMvn = op == .orn && rn == 15
        e.read(0, guest: rn, pcValue: next)
        let carry = operand2(&e)
        var arithmetic = true
        switch op {
        case .and: e.a.and(w: 2, 0, 1); arithmetic = false
        case .bic: e.a.bic(w: 2, 0, 1); arithmetic = false
        case .orr: if isMove { e.a.mov(w: 2, w: 1) } else { e.a.orr(w: 2, 0, 1) }; arithmetic = false
        case .orn: if isMvn { e.a.mvn(w: 2, 1) } else { e.a.orn(w: 2, 0, 1) }; arithmetic = false
        case .eor: e.a.eor(w: 2, 0, 1); arithmetic = false
        case .add: if setFlags { e.a.adds(w: 2, 0, 1) } else { e.a.add(w: 2, 0, 1) }
        case .adc: if setFlags { e.a.adcs(w: 2, 0, 1) } else { e.a.adc(w: 2, 0, 1) }
        case .sbc: if setFlags { e.a.sbcs(w: 2, 0, 1) } else { e.a.sbc(w: 2, 0, 1) }
        case .rsb: if setFlags { e.a.subs(w: 2, 1, 0) } else { e.a.sub(w: 2, 1, 0) }
        case .sub: if setFlags { e.a.subs(w: 2, 0, 1) } else { e.a.sub(w: 2, 0, 1) }
        }
        if setFlags && !arithmetic { e.setNZ(2, carry: carry) }
        if isComparison { return .continued }
        if rd == 15 {
            e.a.and(w: 0, 2, imm: 0xFFFF_FFFE, scratch: 15)
            e.constant(1, 1)
            e.jumpDynamic()
            return .ended
        }
        e.store(guest: rd, 2)
        return .continued
    }

    /// LDM/STM/PUSH/POP: every word on one page (checked first), so the
    /// instruction runs whole or not at all.
    private static func emitBlockTransfer(_ i: ThumbBlockDataTransferInstruction, pc: UInt32, next: UInt32, itState: UInt8,
                                          into e: inout BlockEmitter) -> Outcome {
        let count = i.registerList.nonzeroBitCount
        guard count > 0 else { return .continued }
        let size = UInt32(count * 4)
        let deopt = e.slowPath(pc: pc, next: next, itState: itState)
        e.load(2, guest: i.rn)
        if i.isIncrement { e.a.mov(w: 1, w: 2) } else { e.a.add(w: 1, 2, anyImm: 0 &- size, scratch: 15) }
        e.locateRun(1, width: Int(size), access: i.isLoad ? .read : .write, deopt: deopt)
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
                e.read(3, guest: index, pcValue: next)
                e.a.str(w: 3, 10, offset: slot * 4)
            }
            slot += 1
        }
        if i.writeback {
            e.a.add(w: 3, 2, anyImm: i.isIncrement ? size : 0 &- size, scratch: 15)
            e.store(guest: i.rn, 3)
        }
        guard loadsPC else { return .continued }
        e.a.and(w: 0, 6, imm: 0xFFFF_FFFE, scratch: 15)
        e.a.and(w: 1, 6, imm: 1, scratch: 15)
        e.jumpDynamic()
        return .ended
    }
}
