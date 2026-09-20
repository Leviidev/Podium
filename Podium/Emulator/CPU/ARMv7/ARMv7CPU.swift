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
/// interrupts, MMU-mediated addressing (reads/writes go straight to
/// physical addresses), and several ARM-state instruction families —
/// multiply, block transfer (LDM/STM), register-offset/register-shifted
/// operands, MSR/MRS, coprocessor, SWI (see `ARMDecoder`'s doc comment
/// for the exact list). Hitting any of those sets `lastError` and halts
/// rather than skipping the instruction or guessing at its effect —
/// silently pressing on past something this CPU doesn't actually
/// understand would make broken execution look like progress.
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
            if let jit, let block = jit.block(at: registers.pc, memory: memory) {
                registers.withUnsafeMutableStorage { block.run(registers: $0) }
                registers.pc = registers.pc &+ UInt32(4 * block.instructionCount)
            } else {
                step()
            }
        }
    }

    func stop() {
        isRunning = false
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

        case .unsupported:
            lastError = .unsupportedInstruction(rawWord: rawWord, address: instructionAddress)

        case .undefined:
            lastError = .undefinedInstruction(rawWord: rawWord, address: instructionAddress)
        }
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
        let offsetAddress = instr.addOffset ? base &+ instr.immediateOffset : base &- instr.immediateOffset
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
