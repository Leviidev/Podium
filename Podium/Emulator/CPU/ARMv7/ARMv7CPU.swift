import Foundation

enum CPUError: Error, Equatable {
    case unsupportedInstruction(rawWord: UInt32, address: UInt32)
    case undefinedInstruction(rawWord: UInt32, address: UInt32)
    case memoryFault(MemoryAccessError, address: UInt32)
}

/// The ARM-state ARMv7 interpreter: `ARMDecoder` turns each fetched word
/// into an `ARMInstruction`, this executes it against `Registers`/`CPSR`,
/// with all memory access going through the injected `MemoryBus`.
///
/// What this does *not* do yet, honestly: Thumb decode, exceptions and
/// interrupts (the `I`/`F` CPSR mask bits `CPS` sets are tracked, but
/// nothing actually raises an interrupt for them to gate), MMU-mediated
/// addressing (reads/writes go straight to physical addresses, and
/// `MCR`/`MRC` transfers to/from CP15 are stored/returned as a plain
/// register file — see `CP15State` — not acted on), and several
/// ARM-state instruction families: multiply, block transfer (LDM/STM),
/// register-shifted-by-register operands, MSR/MRS, most of the
/// coprocessor and unconditional-instruction spaces, SWI (see
/// `ARMDecoder`'s doc comment for the exact list). Hitting any of those
/// sets `lastError` and halts rather than skipping the instruction or
/// guessing at its effect — silently pressing on past something this
/// CPU doesn't actually understand would make broken execution look
/// like progress.
///
/// `jit`, if provided, lets `run()` (not `step()` — single-stepping
/// always interprets, which is what you want while debugging) execute
/// eligible straight-line runs as compiled native code instead of one
/// interpreted instruction at a time. See `JITEngine`/`JITTranslator`
/// for exactly what's eligible and why a missing/unavailable JIT is a
/// normal, handled outcome rather than a failure.
final class ARMv7CPU: CPU {
    private(set) var registers = Registers()
    private(set) var cpsr = CPSR()
    private(set) var lastError: CPUError?
    private(set) var cp15 = CP15State()

    let jit: JITEngine?

    private let memory: MemoryBus
    private var isRunning = false

    init(memory: MemoryBus, jit: JITEngine? = nil) {
        self.memory = memory
        self.jit = jit
    }

    func reset() {
        registers.reset()
        cpsr.reset()
        lastError = nil
        isRunning = false
    }

    /// Sets all 16 registers at once — how a kernel image's
    /// `LC_UNIXTHREAD` initial state (see `MachOLoader`) gets installed
    /// before execution starts. A dedicated method rather than exposing
    /// `registers` for direct external mutation, since "load a specific
    /// architectural state" is the actual operation callers need, not
    /// general read-write access to the register file.
    func loadInitialRegisters(_ values: [UInt32]) {
        precondition(values.count == 16, "expected exactly 16 register values")
        for index in 0..<16 {
            registers[index] = values[index]
        }
    }

    func step() {
        guard lastError == nil else { return }

        let instructionAddress = registers.pc
        let word: UInt32
        do {
            word = try memory.readWord32(at: instructionAddress)
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: instructionAddress)
            return
        } catch {
            lastError = .memoryFault(.unmappedAddress(instructionAddress), address: instructionAddress)
            return
        }

        // Advance to the next instruction *before* executing — this is
        // what makes `Registers.pcForOperandRead` (instruction address +
        // 8) fall out of `pc + 4` below. A taken branch overwrites this.
        registers.pc = instructionAddress &+ 4

        execute(ARMDecoder.decode(word), rawWord: word, instructionAddress: instructionAddress)
    }

    func run() {
        isRunning = true
        while isRunning && lastError == nil {
            runOneUnit()
        }
    }

    /// Runs until `lastError` is set, `stop()` is called, or `maxUnits`
    /// fetch-decode-execute units (one interpreted instruction, or one
    /// JIT-compiled block) have run — whichever comes first. Returns how
    /// many units actually ran. Exists so a first boot attempt can be
    /// bounded rather than either blocking indefinitely on code this CPU
    /// doesn't support yet, or never exercising the JIT path the way
    /// plain `step()`-in-a-loop would.
    @discardableResult
    func run(maxUnits: Int) -> Int {
        isRunning = true
        var unitsRun = 0
        while isRunning && lastError == nil && unitsRun < maxUnits {
            runOneUnit()
            unitsRun += 1
        }
        return unitsRun
    }

    func stop() {
        isRunning = false
    }

    private func runOneUnit() {
        if let jit, let block = jit.block(at: registers.pc, memory: memory) {
            registers.withUnsafeMutableStorage { block.run(registers: $0) }
            registers.pc = registers.pc &+ UInt32(4 * block.instructionCount)
        } else {
            step()
        }
    }

    // MARK: - Execute

    private func execute(_ instruction: ARMInstruction, rawWord: UInt32, instructionAddress: UInt32) {
        switch instruction {
        case .dataProcessing(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeDataProcessing(instr)

        case .branch(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeBranch(instr)

        case .loadStore(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeLoadStore(instr)

        case .movWide(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeMovWide(instr)

        case .coprocessorRegisterTransfer(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeCoprocessorRegisterTransfer(instr)

        case .changeProcessorState(let instr):
            executeChangeProcessorState(instr)

        case .memoryBarrier:
            // A real no-op: see ARMInstruction.memoryBarrier's doc comment.
            break

        case .unsupported:
            lastError = .unsupportedInstruction(rawWord: rawWord, address: instructionAddress)

        case .undefined:
            lastError = .undefinedInstruction(rawWord: rawWord, address: instructionAddress)
        }
    }

    private func executeMovWide(_ instr: MovWideInstruction) {
        if instr.isTop {
            registers[instr.rd] = (registers[instr.rd] & 0x0000_FFFF) | (UInt32(instr.imm16) << 16)
        } else {
            registers[instr.rd] = UInt32(instr.imm16)
        }
    }

    private func executeCoprocessorRegisterTransfer(_ instr: CoprocessorRegisterTransferInstruction) {
        if instr.isLoad {
            let value = cp15.read(coprocessor: instr.coprocessor, opc1: instr.opc1, crn: instr.crn, crm: instr.crm, opc2: instr.opc2)
            if instr.rt == Registers.pcIndex {
                // MRC into r15 updates just the NZCV flags on real
                // hardware (an oddity of that one encoding); not
                // meaningful without real CP15 semantics behind it, so
                // this is simply not modeled rather than guessed at.
                return
            }
            registers[instr.rt] = value
        } else {
            let value = operandValue(for: instr.rt)
            cp15.write(coprocessor: instr.coprocessor, opc1: instr.opc1, crn: instr.crn, crm: instr.crm, opc2: instr.opc2, value: value)
        }
    }

    private func executeChangeProcessorState(_ instr: ChangeProcessorStateInstruction) {
        if instr.affectsIRQ { cpsr.irqDisabled = !instr.enable }
        if instr.affectsFIQ { cpsr.fiqDisabled = !instr.enable }
        // affectsAbort (the 'A' bit) isn't modeled: CPSR doesn't expose
        // an abort mask bit yet, and nothing raises an abort exception
        // for it to gate.
    }

    private func operandValue(for register: Int) -> UInt32 {
        register == Registers.pcIndex ? registers.pcForOperandRead : registers[register]
    }

    private func executeDataProcessing(_ instr: DataProcessingInstruction) {
        let shifted = instr.operand2.resolve(registers: registers, currentCarry: cpsr.carry)
        let rnValue = instr.op.usesRn ? operandValue(for: instr.rn) : 0

        let result: UInt32
        var arithmeticCarry = shifted.carryOut
        var arithmeticOverflow = cpsr.overflow

        switch instr.op {
        case .and, .tst:
            result = rnValue & shifted.value
        case .eor, .teq:
            result = rnValue ^ shifted.value
        case .orr:
            result = rnValue | shifted.value
        case .bic:
            result = rnValue & ~shifted.value
        case .mov:
            result = shifted.value
        case .mvn:
            result = ~shifted.value
        case .add, .cmn:
            let r = ALU.add(rnValue, shifted.value)
            result = r.value; arithmeticCarry = r.carryOut; arithmeticOverflow = r.overflow
        case .adc:
            let r = ALU.addWithCarry(rnValue, shifted.value, carryIn: cpsr.carry)
            result = r.value; arithmeticCarry = r.carryOut; arithmeticOverflow = r.overflow
        case .sub, .cmp:
            let r = ALU.subtract(rnValue, shifted.value)
            result = r.value; arithmeticCarry = r.carryOut; arithmeticOverflow = r.overflow
        case .sbc:
            let r = ALU.subtractWithCarry(rnValue, shifted.value, carryIn: cpsr.carry)
            result = r.value; arithmeticCarry = r.carryOut; arithmeticOverflow = r.overflow
        case .rsb:
            let r = ALU.subtract(shifted.value, rnValue)
            result = r.value; arithmeticCarry = r.carryOut; arithmeticOverflow = r.overflow
        case .rsc:
            let r = ALU.subtractWithCarry(shifted.value, rnValue, carryIn: cpsr.carry)
            result = r.value; arithmeticCarry = r.carryOut; arithmeticOverflow = r.overflow
        }

        if !instr.op.isComparison {
            registers[instr.rd] = result
        }

        if instr.setFlags {
            // S==1 writing r15 would be an exception return (CPSR restored
            // from SPSR) on real hardware. SPSR isn't modeled, so that
            // combination just doesn't touch the flags rather than
            // corrupting them — comparisons (which never write r15 for
            // real) are unaffected by this.
            if instr.rd != Registers.pcIndex || instr.op.isComparison {
                cpsr.negative = result.bit(31)
                cpsr.zero = result == 0
                cpsr.carry = instr.op.isLogical ? shifted.carryOut : arithmeticCarry
                if !instr.op.isLogical {
                    cpsr.overflow = arithmeticOverflow
                }
            }
        }

        if instr.rd == Registers.pcIndex && !instr.op.isComparison {
            // Simplification: real ARMv7 can interwork to Thumb via bit 0
            // here (BX-style). Only ARM-state word-aligned targets are
            // handled — that's the whole CPU state right now.
            registers.pc = result & ~UInt32(0b11)
        }
    }

    private func executeBranch(_ instr: BranchInstruction) {
        let target = UInt32(bitPattern: Int32(bitPattern: registers.pcForOperandRead) &+ instr.signedOffset)
        if instr.link {
            // `registers.pc` already holds the address of the instruction
            // after this branch (see `step()`) — exactly what LR should hold.
            registers.lr = registers.pc
        }
        registers.pc = target
    }

    private func executeLoadStore(_ instr: LoadStoreInstruction) {
        let base = operandValue(for: instr.rn)
        let offsetValue: UInt32
        switch instr.offset {
        case .immediate(let value):
            offsetValue = value
        case .register(let rm, let shiftType, let shiftAmount):
            let operand = ShifterOperand.shiftedRegister(rm: rm, shiftType: shiftType, shiftAmount: shiftAmount)
            offsetValue = operand.resolve(registers: registers, currentCarry: cpsr.carry).value
        }
        let offsetAddress = instr.addOffset ? base &+ offsetValue : base &- offsetValue
        let transferAddress = instr.preIndexed ? offsetAddress : base

        do {
            if instr.isLoad {
                let value = instr.isByte
                    ? UInt32(try memory.readByte(at: transferAddress))
                    : try memory.readWord32(at: transferAddress)
                if instr.rd == Registers.pcIndex {
                    registers.pc = value & ~UInt32(0b11)
                } else {
                    registers[instr.rd] = value
                }
            } else {
                let value = operandValue(for: instr.rd)
                if instr.isByte {
                    try memory.writeByte(UInt8(truncatingIfNeeded: value), at: transferAddress)
                } else {
                    try memory.writeWord32(value, at: transferAddress)
                }
            }
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: transferAddress)
            return
        } catch {
            lastError = .memoryFault(.unmappedAddress(transferAddress), address: transferAddress)
            return
        }

        // Post-indexed addressing always writes the base register back,
        // regardless of the W bit (which instead selects privileged-vs-
        // user access there — not modeled). Pre-indexed only writes back
        // when W is set.
        if instr.preIndexed {
            if instr.writeback {
                registers[instr.rn] = offsetAddress
            }
        } else {
            registers[instr.rn] = offsetAddress
        }
    }
}
