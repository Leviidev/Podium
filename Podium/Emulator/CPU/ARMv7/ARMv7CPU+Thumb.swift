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
            currentThumbInstructionIsConditional = condition != .always
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
            executeThumbLoadStoreWide(instr, instructionAddress: instructionAddress)
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
        case .smull(let instr):
            executeThumbSmull(instr)
        case .mla(let instr):
            executeThumbMla(instr)
        case .mls(let instr):
            executeThumbMls(instr)
        case .reverseBytes(let instr):
            executeThumbReverseBytes(instr)
        case .mul(let instr):
            executeThumbMul(instr)
        case .vectorMoveImmediate(let instr):
            executeThumbVectorMoveImmediate(instr)
        case .vectorLoadStoreMultiple(let instr):
            executeThumbVectorLoadStoreMultiple(instr)
        case .smmul(let instr):
            executeThumbSmmul(instr)
        case .packHalfword(let instr):
            executeThumbPackHalfword(instr)
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
        case .rbit(let instr):
            executeThumbRbit(instr)
        case .memoryBarrier:
            // A real no-op: see ThumbInstruction.memoryBarrier's doc comment.
            break
        case .clearExclusive:
            exclusiveMonitorAddress = nil
        case .hint(let hint):
            // WFE/SEV only matter between cores; on this single core, WFE
            // returning at once is architecturally allowed (spurious wake).
            if hint == .waitForInterrupt { waitForInterrupt() }
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

    /// Real hardware: this 16-bit encoding is inherently flag-setting —
    /// but only when unconditional. See `currentThumbInstructionIsConditional`'s
    /// doc comment.
    private func executeThumbShiftImmediate(_ instr: ThumbShiftImmediateInstruction) {
        let resolved = ShifterOperand.applyShift(instr.shiftType, to: registers[instr.rm], amount: instr.imm5, currentCarry: cpsr.carry)
        registers[instr.rd] = resolved.value
        guard !currentThumbInstructionIsConditional else { return }
        cpsr.negative = resolved.value.bit(31)
        cpsr.zero = resolved.value == 0
        cpsr.carry = resolved.carryOut
    }

    // MARK: - Format 3: immediate MOV/CMP/ADD/SUB

    /// `CMP` always sets flags (it has no non-flag-setting form at all);
    /// `MOV`/`ADD`/`SUB` here are like `executeThumbShiftImmediate` —
    /// flag-setting only when unconditional. See
    /// `currentThumbInstructionIsConditional`'s doc comment.
    private func executeThumbImmediate(_ instr: ThumbImmediateInstruction) {
        switch instr.op {
        case .mov:
            registers[instr.rdn] = instr.imm8
            if !currentThumbInstructionIsConditional { setNZ(instr.imm8) } // Carry/overflow unaffected — no shifter involved.
        case .cmp:
            setNZCV(ALU.subtract(registers[instr.rdn], instr.imm8))
        case .add:
            let r = ALU.add(registers[instr.rdn], instr.imm8)
            registers[instr.rdn] = r.value
            if !currentThumbInstructionIsConditional { setNZCV(r) }
        case .sub:
            let r = ALU.subtract(registers[instr.rdn], instr.imm8)
            registers[instr.rdn] = r.value
            if !currentThumbInstructionIsConditional { setNZCV(r) }
        }
    }

    // MARK: - Format 2: ADD/SUB Rd, Rn, Rm/#imm3

    /// Flag-setting only when unconditional — see
    /// `currentThumbInstructionIsConditional`'s doc comment.
    private func executeThumbAddSub(_ instr: ThumbAddSubInstruction) {
        let rn = registers[instr.rn]
        let operand2: UInt32
        switch instr.operand2 {
        case .register(let rm): operand2 = registers[rm]
        case .immediate(let imm3): operand2 = imm3
        }
        let r = instr.isSub ? ALU.subtract(rn, operand2) : ALU.add(rn, operand2)
        registers[instr.rd] = r.value
        if !currentThumbInstructionIsConditional { setNZCV(r) }
    }

    // MARK: - Format 4: two-register ALU

    /// `TST`/`CMP`/`CMN` always set flags (comparison-only, no non-`S`
    /// form exists); every other case here is flag-setting only when
    /// unconditional — see `currentThumbInstructionIsConditional`'s doc
    /// comment.
    private func executeThumbAlu(_ instr: ThumbAluInstruction) {
        let rdn = registers[instr.rdn]
        let rm = registers[instr.rm]
        let setsFlags = !currentThumbInstructionIsConditional
        switch instr.op {
        case .and:
            registers[instr.rdn] = rdn & rm
            if setsFlags { setNZ(registers[instr.rdn]) } // C/V unaffected: no shift.
        case .eor:
            registers[instr.rdn] = rdn ^ rm
            if setsFlags { setNZ(registers[instr.rdn]) }
        case .orr:
            registers[instr.rdn] = rdn | rm
            if setsFlags { setNZ(registers[instr.rdn]) }
        case .bic:
            registers[instr.rdn] = rdn & ~rm
            if setsFlags { setNZ(registers[instr.rdn]) }
        case .mvn:
            registers[instr.rdn] = ~rm
            if setsFlags { setNZ(registers[instr.rdn]) }
        case .tst:
            setNZ(rdn & rm)
        case .lsl, .lsr, .asr, .ror:
            let shiftType: ShiftType = instr.op == .lsl ? .lsl : (instr.op == .lsr ? .lsr : (instr.op == .asr ? .asr : .ror))
            let resolved = ShifterOperand.applyRegisterSpecifiedShift(shiftType, to: rdn, by: rm & 0xFF, currentCarry: cpsr.carry)
            registers[instr.rdn] = resolved.value
            if setsFlags {
                cpsr.negative = resolved.value.bit(31); cpsr.zero = resolved.value == 0; cpsr.carry = resolved.carryOut
            }
        case .adc:
            let r = ALU.addWithCarry(rdn, rm, carryIn: cpsr.carry)
            registers[instr.rdn] = r.value
            if setsFlags { setNZCV(r) }
        case .sbc:
            let r = ALU.subtractWithCarry(rdn, rm, carryIn: cpsr.carry)
            registers[instr.rdn] = r.value
            if setsFlags { setNZCV(r) }
        case .rsb: // NEG Rdn, Rm == RSB Rdn, Rm, #0
            let r = ALU.subtract(0, rm)
            registers[instr.rdn] = r.value
            if setsFlags { setNZCV(r) }
        case .cmp:
            setNZCV(ALU.subtract(rdn, rm))
        case .cmn:
            setNZCV(ALU.add(rdn, rm))
        case .mul:
            registers[instr.rdn] = rdn &* rm
            if setsFlags { setNZ(registers[instr.rdn]) } // C/V unaffected on ARMv7 (deprecated setting flags at all).
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
        case .unsignedByte16, .signedByte16:
            // The 16-bit-lane forms have no Thumb16 encoding; the 16-bit decoder never produces them.
            preconditionFailure("SXTB16/UXTB16 have no Thumb16 encoding")
        }
    }

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

    /// See `ThumbRbitInstruction`'s doc comment.
    private func executeThumbRbit(_ instr: ThumbRbitInstruction) {
        var value = registers[instr.rm]
        var result: UInt32 = 0
        for _ in 0..<32 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        registers[instr.rd] = result
    }

    /// See `ThumbExtendWideInstruction`'s doc comment.
    private func executeThumbExtendWide(_ instr: ThumbExtendWideInstruction) {
        let rotateBits = UInt32(instr.rotate * 8)
        let source = registers[instr.rm]
        let rotated = rotateBits == 0 ? source : (source >> rotateBits) | (source << (32 - rotateBits))
        let addend = instr.rn.map { registers[$0] } ?? 0

        switch instr.kind {
        case .signedHalfword:
            registers[instr.rd] = addend &+ UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: rotated))))
        case .signedByte:
            registers[instr.rd] = addend &+ UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: rotated))))
        case .unsignedHalfword:
            registers[instr.rd] = addend &+ (rotated & 0xFFFF)
        case .unsignedByte:
            registers[instr.rd] = addend &+ (rotated & 0xFF)
        case .unsignedByte16, .signedByte16:
            // Bytes 0 and 2 of the rotated value, each extended to 16 bits
            // and added to the matching halfword of Rn independently
            // (ARM DDI 0406C A8.8.271/A8.8.224).
            func lane(_ byte: UInt32) -> UInt16 {
                instr.kind == .signedByte16 ? UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: byte)))) : UInt16(byte & 0xFF)
            }
            let low = UInt16(truncatingIfNeeded: addend) &+ lane(rotated)
            let high = UInt16(truncatingIfNeeded: addend >> 16) &+ lane(rotated >> 16)
            registers[instr.rd] = UInt32(low) | (UInt32(high) << 16)
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

    /// `TBB`/`TBH`: `Rn == PC` is a special case, verified against a real
    /// kernel binary — unlike the usual Thumb "read PC as an operand"
    /// rule (`Align(instructionAddress+4,4)`, used by e.g. PC-relative
    /// `ADD`/literal loads because their data needs word alignment),
    /// `TBB`/`TBH`'s base when `Rn==PC` is simply the address right
    /// after this instruction, *not* additionally word-aligned — the
    /// byte/halfword table has no such alignment requirement and real
    /// compilers place it flush against the instruction. Rounding down
    /// here (as an earlier version of this code did) reads 0–2 bytes
    /// before the real table when the `TBB`/`TBH` itself isn't
    /// word-aligned, silently pulling in the tail of the *previous*
    /// instruction as a bogus table entry and jumping into garbage —
    /// confirmed by tracing a real early-boot Data Abort back to exactly
    /// this: a table read at `instructionAddress+4` word-aligned down
    /// landed 2 bytes early, decoded a wrong entry, and jumped into the
    /// table's own raw bytes instead of the real case handler.
    private func executeThumbTableBranch(_ instr: ThumbTableBranchInstruction, instructionAddress: UInt32) {
        let base = instr.rn == Registers.pcIndex
            ? instructionAddress &+ 4
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

    private func executeThumbSmull(_ instr: ThumbSmullInstruction) {
        let product = Int64(Int32(bitPattern: registers[instr.rn])) &* Int64(Int32(bitPattern: registers[instr.rm]))
        let bits = UInt64(bitPattern: product)
        registers[instr.rdLo] = UInt32(truncatingIfNeeded: bits)
        registers[instr.rdHi] = UInt32(truncatingIfNeeded: bits >> 32)
    }

    private func executeThumbMla(_ instr: ThumbMlaInstruction) {
        registers[instr.rd] = registers[instr.rn] &* registers[instr.rm] &+ registers[instr.ra]
    }

    private func executeThumbMls(_ instr: ThumbMlsInstruction) {
        registers[instr.rd] = registers[instr.ra] &- (registers[instr.rn] &* registers[instr.rm])
    }

    /// See `ThumbReverseBytesInstruction`'s doc comment.
    private func executeThumbReverseBytes(_ instr: ThumbReverseBytesInstruction) {
        let value = registers[instr.rm]
        let b0 = value & 0xFF, b1 = (value >> 8) & 0xFF, b2 = (value >> 16) & 0xFF, b3 = (value >> 24) & 0xFF
        registers[instr.rd] = instr.isHalfwordWise
            ? (b2 << 24) | (b3 << 16) | (b0 << 8) | b1
            : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private func executeThumbMul(_ instr: ThumbMulInstruction) {
        registers[instr.rd] = registers[instr.rn] &* registers[instr.rm]
    }

    /// See `ThumbSmmulInstruction`'s doc comment.
    private func executeThumbSmmul(_ instr: ThumbSmmulInstruction) {
        let product = Int64(Int32(bitPattern: registers[instr.rn])) &* Int64(Int32(bitPattern: registers[instr.rm]))
        registers[instr.rd] = UInt32(truncatingIfNeeded: product >> 32)
    }

    /// See `ThumbPackHalfwordInstruction`'s doc comment. `PKHTB`'s `ASR`
    /// is arithmetic (sign-extending) and, like every other ARM `ASR`
    /// shift-by-immediate, a `0` shift amount means `ASR #32` (a full
    /// sign-extend), not "no shift" — mirroring `ShifterOperand`'s own
    /// `.asr` handling elsewhere in this file.
    private func executeThumbPackHalfword(_ instr: ThumbPackHalfwordInstruction) {
        let rn = registers[instr.rn]
        let rm = registers[instr.rm]
        if instr.useTopBottom {
            let amount = instr.shiftAmount == 0 ? 32 : Int(instr.shiftAmount)
            let shifted = UInt32(bitPattern: Int32(bitPattern: rm) >> min(amount, 31))
            let signExtended = amount >= 32 ? (rm.bit(31) ? UInt32.max : 0) : shifted
            registers[instr.rd] = (rn & 0xFFFF_0000) | (signExtended & 0x0000_FFFF)
        } else {
            let shifted = rm << instr.shiftAmount
            registers[instr.rd] = (shifted & 0xFFFF_0000) | (rn & 0x0000_FFFF)
        }
    }

    /// See `ThumbVectorMoveImmediateInstruction`'s doc comment: replicates
    /// `imm8` into all four 32-bit lanes, i.e. both `D` halves of `Qd`
    /// get the identical 64-bit pattern.
    private func executeThumbVectorMoveImmediate(_ instr: ThumbVectorMoveImmediateInstruction) {
        let lane = UInt64(instr.imm8) | (UInt64(instr.imm8) << 32)
        neon[instr.qd * 2] = lane
        neon[instr.qd * 2 + 1] = lane
    }

    /// See `ThumbVectorLoadStoreMultipleInstruction`'s doc comment:
    /// increment-after transfer of `registerCount` consecutive 64-bit `D`
    /// registers starting at `vd`, 8 bytes apart, exactly like
    /// `executeThumbLoadStoreDual`'s two-word transfer but for an
    /// arbitrary (real-word-confirmed) count of 64-bit registers.
    private func executeThumbVectorLoadStoreMultiple(_ instr: ThumbVectorLoadStoreMultipleInstruction) {
        let base = registers[instr.rn]
        do {
            for i in 0..<instr.registerCount {
                let address = base &+ UInt32(i * 8)
                let lowPhysicalAddress = try translatedAddress(address, access: instr.isLoad ? .read : .write)
                let highPhysicalAddress = try translatedAddress(address &+ 4, access: instr.isLoad ? .read : .write)
                if instr.isLoad {
                    let low = try memory.readWord32(at: lowPhysicalAddress)
                    let high = try memory.readWord32(at: highPhysicalAddress)
                    neon[instr.vd + i] = UInt64(low) | (UInt64(high) << 32)
                } else {
                    let value = neon[instr.vd + i]
                    try memory.writeWord32(UInt32(truncatingIfNeeded: value), at: lowPhysicalAddress)
                    try memory.writeWord32(UInt32(truncatingIfNeeded: value >> 32), at: highPhysicalAddress)
                }
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: base) { lastError = .memoryFault(memoryError, address: base) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(base), faultAddress: base) { lastError = .memoryFault(.unmappedAddress(base), address: base) }
            return
        }
        if instr.writeback {
            registers[instr.rn] = base &+ UInt32(instr.registerCount * 8)
        }
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

    /// `Rn == PC` (the literal-load form, e.g. `LDR.W Rt, [PC, #imm12]`)
    /// reads PC through the usual Thumb "PC as operand" rule —
    /// `Align(instructionAddress+4, 4)`, the same alignment `TBB`/`TBH`
    /// and every other PC-relative computation in this file applies —
    /// not the raw, possibly-unaligned `registers.pc` (which by this
    /// point already holds `instructionAddress+4` unaligned, since
    /// `stepThumb()` advances it before dispatching). Traced back from a
    /// real, otherwise-unexplained kernel data abort during IOKit
    /// startup: a `ldr.w r8, [pc, #0x158]` at an address that wasn't
    /// 4-byte aligned read 2 bytes into the literal pool instead of at
    /// its start, silently loading the wrong 32-bit constant.
    private func executeThumbLoadStoreWide(_ instr: ThumbLoadStoreWideInstruction, instructionAddress: UInt32) {
        let base = instr.rn == Registers.pcIndex
            ? (instructionAddress &+ 4) & ~UInt32(0b11)
            : registers[instr.rn]
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
                    value = instr.isHalfword
                        ? UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value))))
                        : UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: value))))
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
                var value: UInt32
                if instr.isByte {
                    value = UInt32(try memory.readByte(at: physicalAddress))
                } else if instr.isHalfword {
                    value = UInt32(try memory.readWord16(at: physicalAddress))
                } else {
                    value = try memory.readWord32(at: physicalAddress)
                }
                if instr.isSigned {
                    value = instr.isHalfword
                        ? UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value))))
                        : UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: value))))
                }
                if instr.rt == Registers.pcIndex && !instr.isByte && !instr.isHalfword {
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
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }
}
