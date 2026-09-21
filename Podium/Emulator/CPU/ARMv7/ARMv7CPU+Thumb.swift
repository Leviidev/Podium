import Foundation

/// The Thumb-state half of `ARMv7CPU`: `stepThumb()` fetches and
/// executes one Thumb instruction (16 or 32-bit), reached only via a
/// genuine interworking `BX`/`BLX`/`LDM`-into-PC from `cpsr.thumbState`
/// becoming `true` — never a separate, parallel emulation path. See
/// `ThumbDecoder`'s doc comment for exactly which instructions are
/// covered; hitting anything else sets `lastError` and halts, the same
/// discipline the ARM-state half already follows.
extension ARMv7CPU {
    /// The value an instruction sees when it reads r15 as an operand in
    /// Thumb state: the address of the current instruction + 4 (ARM
    /// state's equivalent, `Registers.pcForOperandRead`, uses +8) — ARM
    /// DDI 0406C A2.3, verified against the real "add r4, pc" /
    /// "add r7, sp, #imm" pattern the actual kernel's Thumb code uses
    /// for position-independent addressing.
    private func thumbOperandValue(for register: Int, instructionAddress: UInt32) -> UInt32 {
        register == Registers.pcIndex ? (instructionAddress &+ 4) : registers[register]
    }

    /// `ITAdvance()` (ARM DDI 0406C A2.5.2): runs after *every* Thumb
    /// instruction, whether or not an `IT` block is active. When bits
    /// [2:0] are all zero, this was the last instruction in the block
    /// (or no block was active), so the state clears; otherwise the
    /// low 5 bits shift left by one, folding the next mask bit into the
    /// position that — combined with the fixed top 3 bits of the
    /// original condition — forms the *next* instruction's condition
    /// (this is why condition codes are paired the way they are: only
    /// the LSB needs to flip to invert one).
    func advanceThumbITState() {
        guard itState & 0b111 != 0 else {
            itState = 0
            return
        }
        let low5 = itState & 0x1F
        itState = (itState & 0xE0) | ((low5 << 1) & 0x1F)
    }

    /// The condition the *next* Thumb instruction executes under: the
    /// current `ITSTATE[7:4]` if a block is active, `.always` otherwise.
    func currentThumbCondition() -> ARMCondition {
        guard itState & 0xF != 0 else { return .always }
        return ARMCondition(rawBits: UInt32(itState >> 4))
    }

    func stepThumb() {
        let instructionAddress = registers.pc
        currentInstructionAddress = instructionAddress
        let hw0: UInt16
        do {
            let physicalAddress = try translatedAddress(instructionAddress, access: .execute)
            hw0 = try memory.readWord16(at: physicalAddress)
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: instructionAddress)
            return
        } catch {
            lastError = .memoryFault(.unmappedAddress(instructionAddress), address: instructionAddress)
            return
        }

        let isWide = ThumbDecoder.isThirtyTwoBitFirstHalfword(hw0)
        var hw1: UInt16 = 0
        if isWide {
            do {
                let physicalAddress2 = try translatedAddress(instructionAddress &+ 2, access: .execute)
                hw1 = try memory.readWord16(at: physicalAddress2)
            } catch let memoryError as MemoryAccessError {
                lastError = .memoryFault(memoryError, address: instructionAddress &+ 2)
                return
            } catch {
                lastError = .memoryFault(.unmappedAddress(instructionAddress &+ 2), address: instructionAddress &+ 2)
                return
            }
        }

        registers.pc = instructionAddress &+ (isWide ? 4 : 2)

        let instruction = ThumbDecoder.decode(hw0, hw1)

        switch instruction {
        case .conditionalBranch(let instr):
            // Bcond carries its own condition — never gated by ITSTATE.
            advanceThumbITState()
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeThumbConditionalBranch(instr, instructionAddress: instructionAddress)

        case .it(let instr):
            // IT can't itself be inside a block, and sets fresh state
            // rather than being gated/advanced by prior state.
            itState = (instr.firstCondition << 4) | instr.mask

        case .compareBranch(let instr):
            // CBZ/CBNZ can't appear inside an IT block either.
            advanceThumbITState()
            executeThumbCompareBranch(instr, instructionAddress: instructionAddress)

        case .branchWide(let instr):
            // B.W (T3, conditional) carries its own real condition, the
            // same as 16-bit Bcond — never gated by ITSTATE. The
            // unconditional T4 form's `.always` here bypasses ITSTATE
            // too; real hardware would still apply an active IT block's
            // condition to it, but an unconditional B.W placed inside an
            // IT block is not a pattern real compiled code produces, so
            // this is a deliberate, narrow simplification rather than
            // being left silently wrong.
            advanceThumbITState()
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeThumbBranchWide(instr, instructionAddress: instructionAddress)

        default:
            let condition = currentThumbCondition()
            advanceThumbITState()
            guard cpsr.isSatisfied(condition) else { return }
            executeThumb(instruction, instructionAddress: instructionAddress)
        }
    }

    private func executeThumb(_ instruction: ThumbInstruction, instructionAddress: UInt32) {
        switch instruction {
        case .coprocessorRegisterTransfer(let instr):
            executeCoprocessorRegisterTransfer(instr, instructionAddress: instructionAddress)
        case .shiftImmediate(let instr):
            executeThumbShiftImmediate(instr)
        case .immediate(let instr):
            executeThumbImmediate(instr)
        case .addSub(let instr):
            executeThumbAddSub(instr)
        case .alu(let instr):
            executeThumbAlu(instr)
        case .hiRegister(let instr):
            executeThumbHiRegister(instr, instructionAddress: instructionAddress)
        case .branchExchange(let instr):
            executeThumbBranchExchange(instr, instructionAddress: instructionAddress)
        case .loadStoreImmediate(let instr):
            executeThumbLoadStoreImmediate(instr)
        case .loadPCRelative(let instr):
            executeThumbLoadPCRelative(instr, instructionAddress: instructionAddress)
        case .loadStoreRegisterOffset(let instr):
            executeThumbLoadStoreRegisterOffset(instr)
        case .address(let instr):
            executeThumbAddress(instr, instructionAddress: instructionAddress)
        case .adjustStack(let instr):
            executeThumbAdjustStack(instr)
        case .pushPop(let instr):
            executeThumbPushPop(instr)
        case .movWide(let instr):
            executeThumbMovWide(instr)
        case .bitFieldExtract(let instr):
            executeThumbBitFieldExtract(instr)
        case .addWide(let instr):
            executeThumbAddWide(instr)
        case .adr(let instr):
            executeThumbAdr(instr, instructionAddress: instructionAddress)
        case .bitFieldInsert(let instr):
            executeThumbBitFieldInsert(instr)
        case .dataProcessingImmediate(let instr):
            executeThumbDataProcessingImmediate(instr)
        case .dataProcessingShiftedRegister(let instr):
            executeThumbDataProcessingShiftedRegister(instr)
        case .branchLink(let instr):
            executeThumbBranchLink(instr, instructionAddress: instructionAddress)
        case .loadStoreWide(let instr):
            executeThumbLoadStoreWide(instr)
        case .loadStoreRegister(let instr):
            executeThumbLoadStoreRegister(instr)
        case .blockDataTransfer(let instr):
            executeThumbBlockDataTransfer(instr)
        case .tableBranch(let instr):
            executeThumbTableBranch(instr, instructionAddress: instructionAddress)
        case .loadStoreDual(let instr):
            executeThumbLoadStoreDual(instr)
        case .umull(let instr):
            executeThumbUmull(instr)
        case .mla(let instr):
            executeThumbMla(instr)
        case .mul(let instr):
            executeThumbMul(instr)
        case .branch(let instr):
            executeThumbBranch(instr, instructionAddress: instructionAddress)
        case .extend(let instr):
            executeThumbExtend(instr)
        case .extendWide(let instr):
            executeThumbExtendWide(instr)
        case .shiftRegister(let instr):
            executeThumbShiftRegister(instr)
        case .clz(let instr):
            executeThumbClz(instr)
        case .memoryBarrier:
            // A real no-op: see ThumbInstruction.memoryBarrier's doc comment.
            break
        case .conditionalBranch, .it, .compareBranch, .branchWide:
            preconditionFailure("handled in stepThumb before reaching executeThumb")
        case .unsupported(let raw, let second):
            lastError = .unsupportedInstruction(rawWord: Self.combinedRawWord(raw, second), address: instructionAddress)
        case .undefined(let raw, let second):
            lastError = .undefinedInstruction(rawWord: Self.combinedRawWord(raw, second), address: instructionAddress)
        }
    }

    /// For diagnostics only: a 32-bit instruction's halt is reported as
    /// `(hw0 << 16) | hw1` — the same order the two halfwords appear in
    /// the instruction stream — so the printed word matches what a
    /// disassembler would show, not just the first (and least
    /// informative) half of it.
    private static func combinedRawWord(_ first: UInt16, _ second: UInt16?) -> UInt32 {
        guard let second else { return UInt32(first) }
        return (UInt32(first) << 16) | UInt32(second)
    }

    // MARK: - Flags

    private func setNZ(_ result: UInt32) {
        cpsr.negative = result.bit(31)
        cpsr.zero = result == 0
    }

    private func setNZCV(_ result: ALU.AddResult) {
        cpsr.negative = result.value.bit(31)
        cpsr.zero = result.value == 0
        cpsr.carry = result.carryOut
        cpsr.overflow = result.overflow
    }

    // MARK: - Format 1: LSL/LSR/ASR by immediate

    private func executeThumbShiftImmediate(_ instr: ThumbShiftImmediateInstruction) {
        let resolved = ShifterOperand.applyShift(instr.shiftType, to: registers[instr.rm], amount: instr.imm5, currentCarry: cpsr.carry)
        registers[instr.rd] = resolved.value
        cpsr.negative = resolved.value.bit(31)
        cpsr.zero = resolved.value == 0
        cpsr.carry = resolved.carryOut
    }

    // MARK: - Format 3: immediate MOV/CMP/ADD/SUB

    private func executeThumbImmediate(_ instr: ThumbImmediateInstruction) {
        switch instr.op {
        case .mov:
            registers[instr.rdn] = instr.imm8
            setNZ(instr.imm8) // Carry/overflow unaffected — no shifter involved.
        case .cmp:
            setNZCV(ALU.subtract(registers[instr.rdn], instr.imm8))
        case .add:
            let r = ALU.add(registers[instr.rdn], instr.imm8)
            registers[instr.rdn] = r.value
            setNZCV(r)
        case .sub:
            let r = ALU.subtract(registers[instr.rdn], instr.imm8)
            registers[instr.rdn] = r.value
            setNZCV(r)
        }
    }

    // MARK: - Format 2: ADD/SUB Rd, Rn, Rm/#imm3

    private func executeThumbAddSub(_ instr: ThumbAddSubInstruction) {
        let rn = registers[instr.rn]
        let operand2: UInt32
        switch instr.operand2 {
        case .register(let rm): operand2 = registers[rm]
        case .immediate(let imm3): operand2 = imm3
        }
        let r = instr.isSub ? ALU.subtract(rn, operand2) : ALU.add(rn, operand2)
        registers[instr.rd] = r.value
        setNZCV(r)
    }

    // MARK: - Format 4: two-register ALU

    private func executeThumbAlu(_ instr: ThumbAluInstruction) {
        let rdn = registers[instr.rdn]
        let rm = registers[instr.rm]
        switch instr.op {
        case .and:
            registers[instr.rdn] = rdn & rm
            setNZ(registers[instr.rdn]) // C/V unaffected: no shift.
        case .eor:
            registers[instr.rdn] = rdn ^ rm
            setNZ(registers[instr.rdn])
        case .orr:
            registers[instr.rdn] = rdn | rm
            setNZ(registers[instr.rdn])
        case .bic:
            registers[instr.rdn] = rdn & ~rm
            setNZ(registers[instr.rdn])
        case .mvn:
            registers[instr.rdn] = ~rm
            setNZ(registers[instr.rdn])
        case .tst:
            setNZ(rdn & rm)
        case .lsl, .lsr, .asr, .ror:
            let shiftType: ShiftType = instr.op == .lsl ? .lsl : (instr.op == .lsr ? .lsr : (instr.op == .asr ? .asr : .ror))
            let resolved = ShifterOperand.applyRegisterSpecifiedShift(shiftType, to: rdn, by: rm & 0xFF, currentCarry: cpsr.carry)
            registers[instr.rdn] = resolved.value
            cpsr.negative = resolved.value.bit(31); cpsr.zero = resolved.value == 0; cpsr.carry = resolved.carryOut
        case .adc:
            let r = ALU.addWithCarry(rdn, rm, carryIn: cpsr.carry)
            registers[instr.rdn] = r.value
            setNZCV(r)
        case .sbc:
            let r = ALU.subtractWithCarry(rdn, rm, carryIn: cpsr.carry)
            registers[instr.rdn] = r.value
            setNZCV(r)
        case .rsb: // NEG Rdn, Rm == RSB Rdn, Rm, #0
            let r = ALU.subtract(0, rm)
            registers[instr.rdn] = r.value
            setNZCV(r)
        case .cmp:
            setNZCV(ALU.subtract(rdn, rm))
        case .cmn:
            setNZCV(ALU.add(rdn, rm))
        case .mul:
            registers[instr.rdn] = rdn &* rm
            setNZ(registers[instr.rdn]) // C/V unaffected on ARMv7 (deprecated setting flags at all).
        }
    }

    // MARK: - SXTH/SXTB/UXTH/UXTB

    private func executeThumbExtend(_ instr: ThumbExtendInstruction) {
        let value = registers[instr.rm]
        switch instr.kind {
        case .signedHalfword:
            registers[instr.rd] = UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value))))
        case .signedByte:
            registers[instr.rd] = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: value))))
        case .unsignedHalfword:
            registers[instr.rd] = value & 0xFFFF
        case .unsignedByte:
            registers[instr.rd] = value & 0xFF
        }
    }

    /// `SXTH.W`/`UXTH.W`/`SXTB.W`/`UXTB.W`: like `executeThumbExtend`
    /// but with `Rm` first rotated right by `rotate*8` bits.
    /// `LSL`/`LSR`/`ASR`/`ROR` (register-controlled): doesn't affect
    /// flags — see `ThumbShiftRegisterInstruction`'s doc comment for
    /// why.
    private func executeThumbShiftRegister(_ instr: ThumbShiftRegisterInstruction) {
        let amount = registers[instr.rm] & 0xFF
        let result = ShifterOperand.applyRegisterSpecifiedShift(
            instr.shiftType, to: registers[instr.rn], by: amount, currentCarry: cpsr.carry
        )
        registers[instr.rd] = result.value
    }

    private func executeThumbClz(_ instr: ThumbClzInstruction) {
        registers[instr.rd] = UInt32(registers[instr.rm].leadingZeroBitCount)
    }

    private func executeThumbExtendWide(_ instr: ThumbExtendWideInstruction) {
        let rotateBits = instr.rotate * 8
        let rotated = rotateBits == 0
            ? registers[instr.rm]
            : (registers[instr.rm] >> rotateBits) | (registers[instr.rm] << (32 - rotateBits))
        switch instr.kind {
        case .signedHalfword:
            registers[instr.rd] = UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: rotated))))
        case .signedByte:
            registers[instr.rd] = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: rotated))))
        case .unsignedHalfword:
            registers[instr.rd] = rotated & 0xFFFF
        case .unsignedByte:
            registers[instr.rd] = rotated & 0xFF
        }
    }

    // MARK: - Format 5: hi-register ADD/CMP/MOV

    private func executeThumbHiRegister(_ instr: ThumbHiRegisterInstruction, instructionAddress: UInt32) {
        let rdnValue = thumbOperandValue(for: instr.rdn, instructionAddress: instructionAddress)
        let rmValue = thumbOperandValue(for: instr.rm, instructionAddress: instructionAddress)
        switch instr.op {
        case .cmp:
            setNZCV(ALU.subtract(rdnValue, rmValue)) // Only hi-register form that sets flags.
        case .add:
            writeThumbResult(rdnValue &+ rmValue, to: instr.rdn)
        case .mov:
            writeThumbResult(rmValue, to: instr.rdn)
        }
    }

    /// Writing r15 from a hi-register `ADD`/`MOV` is a plain
    /// (non-interworking) branch, per the real ARMv7 architecture's
    /// `ALUWritePC`/`BranchWritePC` pseudocode: only `BX`/`BLX`
    /// (register), `POP {PC}`/`LDM ... PC`, and `LDR PC, [...]` use the
    /// interworking `BXWritePC` (checking the target's bit 0 the way
    /// `executeThumbBranchExchange` does) — a hi-register `MOV`/`ADD`
    /// into `PC` while already in Thumb state always *stays* in Thumb,
    /// regardless of the computed target's bit 0. Confirmed against a
    /// real, ordinary compiled switch-statement jump table in the
    /// actual kernel (`adr.w r2, #table` / `add.w r5, r2, r6, lsl #2` /
    /// `mov pc, r5`, indexing into a table of `b.w` slots at `r2`,
    /// itself not 4-byte aligned) that a bit-0 interworking check here
    /// incorrectly flips the CPU to ARM state and starts executing
    /// garbage, even though the whole function — table included — is
    /// genuinely Thumb-only code; masking bit 0 without touching
    /// `thumbState` fixes it.
    private func writeThumbResult(_ value: UInt32, to register: Int) {
        if register == Registers.pcIndex {
            registers.pc = value & ~UInt32(0b1)
        } else {
            registers[register] = value
        }
    }

    // MARK: - BX/BLX (register)

    private func executeThumbBranchExchange(_ instr: ThumbBranchExchangeInstruction, instructionAddress: UInt32) {
        let target = registers[instr.rm]
        if instr.link {
            registers.lr = registers.pc | 1
        }
        cpsr.thumbState = target.bit(0)
        registers.pc = target & ~UInt32(0b1)
    }

    // MARK: - Format 9/11: LDR/STR with immediate offset

    private func executeThumbLoadStoreImmediate(_ instr: ThumbLoadStoreImmediateInstruction) {
        let address = registers[instr.rn] &+ instr.offset
        do {
            let physicalAddress = try translatedAddress(address, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                switch instr.size {
                case .word: registers[instr.rt] = try memory.readWord32(at: physicalAddress)
                case .byte: registers[instr.rt] = UInt32(try memory.readByte(at: physicalAddress))
                case .halfword: registers[instr.rt] = UInt32(try memory.readWord16(at: physicalAddress))
                }
            } else {
                switch instr.size {
                case .word: try memory.writeWord32(registers[instr.rt], at: physicalAddress)
                case .byte: try memory.writeByte(UInt8(truncatingIfNeeded: registers[instr.rt]), at: physicalAddress)
                case .halfword: try memory.writeWord16(UInt16(truncatingIfNeeded: registers[instr.rt]), at: physicalAddress)
                }
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    /// Format 6: base is `Align(PC,4)` — this instruction's own address
    /// + 4, word-aligned down — exactly `executeThumbAddress`'s `usesSP
    /// == false` case, since both formats share the identical real ARM
    /// PC-relative-base rule.
    private func executeThumbLoadPCRelative(_ instr: ThumbLoadPCRelativeInstruction, instructionAddress: UInt32) {
        let address = ((instructionAddress &+ 4) & ~UInt32(0b11)) &+ instr.offset
        do {
            let physicalAddress = try translatedAddress(address, access: .read)
            registers[instr.rt] = try memory.readWord32(at: physicalAddress)
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    // MARK: - Formats 7/8: register-offset load/store

    private func executeThumbLoadStoreRegisterOffset(_ instr: ThumbLoadStoreRegisterOffsetInstruction) {
        let address = registers[instr.rn] &+ registers[instr.rm]
        do {
            let isLoad = instr.op != .str && instr.op != .strh && instr.op != .strb
            let physicalAddress = try translatedAddress(address, access: isLoad ? .read : .write)
            switch instr.op {
            case .str: try memory.writeWord32(registers[instr.rd], at: physicalAddress)
            case .strh: try memory.writeWord16(UInt16(truncatingIfNeeded: registers[instr.rd]), at: physicalAddress)
            case .strb: try memory.writeByte(UInt8(truncatingIfNeeded: registers[instr.rd]), at: physicalAddress)
            case .ldr: registers[instr.rd] = try memory.readWord32(at: physicalAddress)
            case .ldrh: registers[instr.rd] = UInt32(try memory.readWord16(at: physicalAddress))
            case .ldrb: registers[instr.rd] = UInt32(try memory.readByte(at: physicalAddress))
            case .ldrsb:
                registers[instr.rd] = UInt32(bitPattern: Int32(Int8(bitPattern: try memory.readByte(at: physicalAddress))))
            case .ldrsh:
                registers[instr.rd] = UInt32(bitPattern: Int32(Int16(bitPattern: try memory.readWord16(at: physicalAddress))))
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    // MARK: - Format 12: ADD Rd, PC/SP, #imm8*4

    private func executeThumbAddress(_ instr: ThumbAddressInstruction, instructionAddress: UInt32) {
        let base = instr.usesSP ? registers.sp : ((instructionAddress &+ 4) & ~UInt32(0b11))
        registers[instr.rd] = base &+ (instr.imm8 &* 4)
    }

    // MARK: - Format 13: ADD/SUB SP, #imm7*4

    private func executeThumbAdjustStack(_ instr: ThumbAdjustStackInstruction) {
        let delta = instr.imm7 &* 4
        registers.sp = instr.subtract ? registers.sp &- delta : registers.sp &+ delta
    }

    // MARK: - Format 14 / Thumb-2 T2: PUSH/POP and LDM/STM

    private func executeThumbPushPop(_ instr: ThumbPushPopInstruction) {
        executeThumbBlockDataTransfer(ThumbBlockDataTransferInstruction(
            isLoad: instr.isLoad, isIncrement: instr.isLoad, writeback: true,
            rn: Registers.spIndex, registerList: instr.registerList
        ))
    }

    /// Same ascending-register/ascending-address technique as
    /// `ARMv7CPU.executeBlockDataTransfer` — Thumb-2 only ever encodes
    /// IA (used by `POP`/`LDM`) or DB (used by `PUSH`/`STMDB`), never
    /// IB/DA, so there's no `preIndexed` axis to plumb through here.
    private func executeThumbBlockDataTransfer(_ instr: ThumbBlockDataTransferInstruction) {
        let baseValue = registers[instr.rn]
        let count = instr.registerList.nonzeroBitCount
        guard count > 0 else { return }
        let transferSize = UInt32(count) * 4
        var address = instr.isIncrement ? baseValue : (baseValue &- transferSize)

        do {
            for index in 0..<16 {
                guard (instr.registerList >> index) & 1 == 1 else { continue }
                let physicalAddress = try translatedAddress(address, access: instr.isLoad ? .read : .write)
                if instr.isLoad {
                    let value = try memory.readWord32(at: physicalAddress)
                    if index == Registers.pcIndex {
                        cpsr.thumbState = value.bit(0)
                        registers.pc = value & ~UInt32(0b1)
                    } else {
                        registers[index] = value
                    }
                } else {
                    try memory.writeWord32(registers[index], at: physicalAddress)
                }
                address = address &+ 4
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
            return
        }

        if instr.writeback {
            registers[instr.rn] = instr.isIncrement ? baseValue &+ transferSize : baseValue &- transferSize
        }
    }

    /// `TBB`/`TBH`: `Rn == PC` reads through `Align(PC,4)` (the
    /// instruction's own address rounded down to a word, +4 — the
    /// usual Thumb PC-read-as-operand rule, additionally word-aligned
    /// since the jump table follows this instruction in the code
    /// stream regardless of its own alignment); the branch target is
    /// always relative to the address just after this instruction,
    /// the same base every other Thumb branch uses.
    private func executeThumbTableBranch(_ instr: ThumbTableBranchInstruction, instructionAddress: UInt32) {
        let base = instr.rn == Registers.pcIndex
            ? (instructionAddress &+ 4) & ~UInt32(0b11)
            : registers[instr.rn]
        let indexAddress = instr.isHalfword ? base &+ (registers[instr.rm] &* 2) : base &+ registers[instr.rm]

        let tableValue: UInt32
        do {
            let physicalAddress = try translatedAddress(indexAddress, access: .read)
            tableValue = instr.isHalfword
                ? UInt32(try memory.readWord16(at: physicalAddress))
                : UInt32(try memory.readByte(at: physicalAddress))
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: indexAddress) { lastError = .memoryFault(memoryError, address: indexAddress) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(indexAddress), faultAddress: indexAddress) { lastError = .memoryFault(.unmappedAddress(indexAddress), address: indexAddress) }
            return
        }

        registers.pc = (instructionAddress &+ 4) &+ (tableValue &* 2)
    }

    // MARK: - LDRD/STRD (immediate)

    private func executeThumbLoadStoreDual(_ instr: ThumbLoadStoreDualInstruction) {
        let base = registers[instr.rn]
        let offsetAddress = instr.addOffset ? base &+ instr.offset : base &- instr.offset
        let transferAddress = instr.preIndexed ? offsetAddress : base

        do {
            let physicalAddress = try translatedAddress(transferAddress, access: instr.isLoad ? .read : .write)
            let secondAddress = transferAddress &+ 4
            let secondPhysicalAddress = try translatedAddress(secondAddress, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                registers[instr.rt] = try memory.readWord32(at: physicalAddress)
                registers[instr.rt2] = try memory.readWord32(at: secondPhysicalAddress)
            } else {
                try memory.writeWord32(registers[instr.rt], at: physicalAddress)
                try memory.writeWord32(registers[instr.rt2], at: secondPhysicalAddress)
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: transferAddress) { lastError = .memoryFault(memoryError, address: transferAddress) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(transferAddress), faultAddress: transferAddress) { lastError = .memoryFault(.unmappedAddress(transferAddress), address: transferAddress) }
            return
        }

        if instr.preIndexed {
            if instr.writeback { registers[instr.rn] = offsetAddress }
        } else {
            registers[instr.rn] = offsetAddress
        }
    }

    // MARK: - UMULL

    private func executeThumbUmull(_ instr: ThumbUmullInstruction) {
        let product = UInt64(registers[instr.rn]) &* UInt64(registers[instr.rm])
        registers[instr.rdLo] = UInt32(truncatingIfNeeded: product)
        registers[instr.rdHi] = UInt32(truncatingIfNeeded: product >> 32)
    }

    private func executeThumbMla(_ instr: ThumbMlaInstruction) {
        registers[instr.rd] = registers[instr.rn] &* registers[instr.rm] &+ registers[instr.ra]
    }

    private func executeThumbMul(_ instr: ThumbMulInstruction) {
        registers[instr.rd] = registers[instr.rn] &* registers[instr.rm]
    }

    // MARK: - Branches

    private func executeThumbConditionalBranch(_ instr: ThumbConditionalBranchInstruction, instructionAddress: UInt32) {
        registers.pc = UInt32(bitPattern: Int32(bitPattern: instructionAddress &+ 4) &+ instr.signedOffset)
    }

    private func executeThumbBranch(_ instr: ThumbBranchInstruction, instructionAddress: UInt32) {
        registers.pc = UInt32(bitPattern: Int32(bitPattern: instructionAddress &+ 4) &+ instr.signedOffset)
    }

    private func executeThumbCompareBranch(_ instr: ThumbCompareBranchInstruction, instructionAddress: UInt32) {
        let takeBranch = instr.branchIfNonZero ? (registers[instr.rn] != 0) : (registers[instr.rn] == 0)
        guard takeBranch else { return }
        registers.pc = instructionAddress &+ 4 &+ instr.offset
    }

    private func executeThumbBranchLink(_ instr: ThumbBranchLinkInstruction, instructionAddress: UInt32) {
        let base = instr.switchesToARM ? ((instructionAddress &+ 4) & ~UInt32(0b11)) : (instructionAddress &+ 4)
        let target = UInt32(bitPattern: Int32(bitPattern: base) &+ instr.signedOffset)
        registers.lr = registers.pc | 1
        if instr.switchesToARM {
            cpsr.thumbState = false
            registers.pc = target & ~UInt32(0b11)
        } else {
            registers.pc = target
        }
    }

    private func executeThumbBranchWide(_ instr: ThumbBranchWideInstruction, instructionAddress: UInt32) {
        registers.pc = UInt32(bitPattern: Int32(bitPattern: instructionAddress &+ 4) &+ instr.signedOffset)
    }

    // MARK: - Thumb-2: MOVW/MOVT

    private func executeThumbMovWide(_ instr: ThumbMovWideInstruction) {
        if instr.isTop {
            registers[instr.rd] = (registers[instr.rd] & 0x0000_FFFF) | (UInt32(instr.imm16) << 16)
        } else {
            registers[instr.rd] = UInt32(instr.imm16)
        }
    }

    /// `UBFX`/`SBFX`: zero- or sign-extending bit-field extract. Doesn't
    /// affect flags. The signed path shifts the extracted field up to
    /// the register's top bit and back down arithmetically — the
    /// standard sign-extension-by-shift idiom — rather than a
    /// mask-and-branch, so it's correct even when `width == 32` (nothing
    /// to extend, the shifts are no-ops).
    private func executeThumbBitFieldExtract(_ instr: ThumbBitFieldExtractInstruction) {
        let extracted = registers[instr.rn] >> instr.lsb
        if instr.signed {
            let shift = UInt32(32 - instr.width)
            registers[instr.rd] = UInt32(bitPattern: Int32(bitPattern: extracted << shift) >> shift)
        } else {
            let mask: UInt32 = instr.width >= 32 ? 0xFFFF_FFFF : (UInt32(1) << instr.width) - 1
            registers[instr.rd] = extracted & mask
        }
    }

    private func executeThumbAddWide(_ instr: ThumbAddWideInstruction) {
        registers[instr.rd] = registers[instr.rn] &+ UInt32(instr.imm12)
    }

    /// `ADR` (`ADDW`-based T3 form): `Rd = Align(PC, 4) + imm12`, the
    /// same PC-relative base format 12's `ADD Rd, PC, #imm8*4`
    /// (`executeThumbAddress`) uses.
    private func executeThumbAdr(_ instr: ThumbAdrInstruction, instructionAddress: UInt32) {
        let base = (instructionAddress &+ 4) & ~UInt32(0b11)
        registers[instr.rd] = base &+ UInt32(instr.imm12)
    }

    /// `BFI`/`BFC`: `sourceRegister == nil` (`BFC`) inserts zero.
    /// Doesn't affect flags.
    private func executeThumbBitFieldInsert(_ instr: ThumbBitFieldInsertInstruction) {
        let sourceValue = instr.sourceRegister.map { registers[$0] } ?? 0
        let mask: UInt32 = instr.width >= 32 ? 0xFFFF_FFFF : (UInt32(1) << instr.width) - 1
        let shiftedMask = mask << instr.lsb
        registers[instr.rd] = (registers[instr.rd] & ~shiftedMask) | ((sourceValue & mask) << instr.lsb)
    }

    // MARK: - Thumb-2: data-processing (modified immediate)

    private func executeThumbDataProcessingImmediate(_ instr: ThumbDataProcessingImmediateInstruction) {
        let rn = registers[instr.rn]
        let result: UInt32
        var arithmeticResult: ALU.AddResult?

        // AND/EOR/ADD/SUB with Rd==PC,S==1 are the TST/TEQ/CMN/CMP
        // aliases (comparisons: no result written). ORR with Rn==PC is
        // the MOV alias (result is the immediate itself, unmasked by Rn).
        let isComparison = instr.setFlags && instr.rd == Registers.pcIndex
            && (instr.op == .and || instr.op == .eor || instr.op == .add || instr.op == .sub)
        let isMove = instr.op == .orr && instr.rn == Registers.pcIndex
        let isMvn = instr.op == .orn && instr.rn == Registers.pcIndex

        switch instr.op {
        case .and: result = rn & instr.imm32
        case .bic: result = rn & ~instr.imm32
        case .orr: result = isMove ? instr.imm32 : (rn | instr.imm32)
        case .orn: result = isMvn ? ~instr.imm32 : (rn | ~instr.imm32)
        case .eor: result = rn ^ instr.imm32
        case .add:
            let r = ALU.add(rn, instr.imm32); arithmeticResult = r; result = r.value
        case .adc:
            let r = ALU.addWithCarry(rn, instr.imm32, carryIn: cpsr.carry); arithmeticResult = r; result = r.value
        case .sbc:
            let r = ALU.subtractWithCarry(rn, instr.imm32, carryIn: cpsr.carry); arithmeticResult = r; result = r.value
        case .rsb:
            let r = ALU.subtract(instr.imm32, rn); arithmeticResult = r; result = r.value
        case .sub:
            let r = ALU.subtract(rn, instr.imm32); arithmeticResult = r; result = r.value
        }
        if !isComparison {
            if instr.rd == Registers.pcIndex {
                writeThumbResult(result, to: instr.rd)
            } else {
                registers[instr.rd] = result
            }
        }

        guard instr.setFlags else { return }
        if let arithmeticResult {
            setNZCV(arithmeticResult)
        } else {
            setNZ(result) // Logical ops: C/V unaffected (no shifter carry for a modified immediate).
        }
    }

    // MARK: - Thumb-2: data-processing (shifted register)

    private func executeThumbDataProcessingShiftedRegister(_ instr: ThumbDataProcessingShiftedRegisterInstruction) {
        let rn = registers[instr.rn]
        let shifted = ShifterOperand.applyShift(instr.shiftType, to: registers[instr.rm], amount: instr.shiftAmount, currentCarry: cpsr.carry)
        let operand2 = shifted.value
        let result: UInt32
        var arithmeticResult: ALU.AddResult?

        // Same comparison/move aliasing as the modified-immediate
        // family (see `executeThumbDataProcessingImmediate`).
        let isComparison = instr.setFlags && instr.rd == Registers.pcIndex
            && (instr.op == .and || instr.op == .eor || instr.op == .add || instr.op == .sub)
        let isMove = instr.op == .orr && instr.rn == Registers.pcIndex
        let isMvn = instr.op == .orn && instr.rn == Registers.pcIndex

        switch instr.op {
        case .and: result = rn & operand2
        case .bic: result = rn & ~operand2
        case .orr: result = isMove ? operand2 : (rn | operand2)
        case .orn: result = isMvn ? ~operand2 : (rn | ~operand2)
        case .eor: result = rn ^ operand2
        case .add:
            let r = ALU.add(rn, operand2); arithmeticResult = r; result = r.value
        case .adc:
            let r = ALU.addWithCarry(rn, operand2, carryIn: cpsr.carry); arithmeticResult = r; result = r.value
        case .sbc:
            let r = ALU.subtractWithCarry(rn, operand2, carryIn: cpsr.carry); arithmeticResult = r; result = r.value
        case .rsb:
            let r = ALU.subtract(operand2, rn); arithmeticResult = r; result = r.value
        case .sub:
            let r = ALU.subtract(rn, operand2); arithmeticResult = r; result = r.value
        }
        if !isComparison {
            writeThumbResult(result, to: instr.rd)
        }

        guard instr.setFlags else { return }
        if let arithmeticResult {
            setNZCV(arithmeticResult)
        } else {
            cpsr.negative = result.bit(31)
            cpsr.zero = result == 0
            cpsr.carry = shifted.carryOut // Logical ops: C comes from the shifter, unlike the modified-immediate form.
        }
    }

    // MARK: - Thumb-2: LDR/STR (immediate, T3/T4)

    private func executeThumbLoadStoreWide(_ instr: ThumbLoadStoreWideInstruction) {
        let base = registers[instr.rn]
        let offsetAddress = instr.addOffset ? base &+ instr.offset : base &- instr.offset
        let transferAddress = instr.preIndexed ? offsetAddress : base

        do {
            let physicalAddress = try translatedAddress(transferAddress, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                var value: UInt32
                if instr.isByte {
                    value = UInt32(try memory.readByte(at: physicalAddress))
                } else if instr.isHalfword {
                    value = UInt32(try memory.readWord16(at: physicalAddress))
                } else {
                    value = try memory.readWord32(at: physicalAddress)
                }
                if instr.isSigned {
                    value = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: value))))
                }
                if instr.rt == Registers.pcIndex {
                    cpsr.thumbState = value.bit(0)
                    registers.pc = value & ~UInt32(0b1)
                } else {
                    registers[instr.rt] = value
                }
            } else if instr.isByte {
                try memory.writeByte(UInt8(truncatingIfNeeded: registers[instr.rt]), at: physicalAddress)
            } else if instr.isHalfword {
                try memory.writeWord16(UInt16(truncatingIfNeeded: registers[instr.rt]), at: physicalAddress)
            } else {
                try memory.writeWord32(registers[instr.rt], at: physicalAddress)
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: transferAddress) { lastError = .memoryFault(memoryError, address: transferAddress) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(transferAddress), faultAddress: transferAddress) { lastError = .memoryFault(.unmappedAddress(transferAddress), address: transferAddress) }
            return
        }

        if instr.preIndexed {
            if instr.writeback { registers[instr.rn] = offsetAddress }
        } else {
            registers[instr.rn] = offsetAddress
        }
    }

    // MARK: - Thumb-2: LDR/STR (register)

    /// Always pre-indexed, always adds, never writes back — see
    /// `ThumbLoadStoreRegisterInstruction`'s doc comment. The offset is
    /// `Rm LSL imm2`; `applyShift`'s carry-out is discarded since this
    /// is a data value, not a flag-setting shifter operand.
    private func executeThumbLoadStoreRegister(_ instr: ThumbLoadStoreRegisterInstruction) {
        let offset = ShifterOperand.applyShift(
            .lsl, to: registers[instr.rm], amount: UInt8(instr.shiftAmount), currentCarry: cpsr.carry
        ).value
        let address = registers[instr.rn] &+ offset

        do {
            let physicalAddress = try translatedAddress(address, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                let value = instr.isByte
                    ? UInt32(try memory.readByte(at: physicalAddress))
                    : try memory.readWord32(at: physicalAddress)
                if instr.rt == Registers.pcIndex {
                    cpsr.thumbState = value.bit(0)
                    registers.pc = value & ~UInt32(0b1)
                } else {
                    registers[instr.rt] = value
                }
            } else if instr.isByte {
                try memory.writeByte(UInt8(truncatingIfNeeded: registers[instr.rt]), at: physicalAddress)
            } else {
                try memory.writeWord32(registers[instr.rt], at: physicalAddress)
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }
}
