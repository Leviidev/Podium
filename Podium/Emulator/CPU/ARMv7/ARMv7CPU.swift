import Foundation

enum CPUError: Error, Equatable {
    case unsupportedInstruction(rawWord: UInt32, address: UInt32)
    case undefinedInstruction(rawWord: UInt32, address: UInt32)
    case memoryFault(MemoryAccessError, address: UInt32)
    /// The guest executed and decoded fine, but asked for real hardware
    /// behavior this CPU doesn't implement and can't safely pretend to —
    /// right now, just SCTLR.AFE (the access-flag AP model; see
    /// `ARMv7MMU`'s doc comment for why that one specifically isn't
    /// implemented, unlike MMU translation itself, which is). `BX`/`BLX`
    /// interworking to Thumb state no longer halts here — see
    /// `ARMv7CPU+Thumb.swift` — now that a real Thumb decoder exists.
    /// Halting here is the honest choice; a normal "unsupported
    /// instruction" halt wouldn't be accurate, since the instruction
    /// *is* understood.
    case unimplementedHardwareFeature(description: String, address: UInt32)
}

/// The ARMv7 interpreter: `ARMDecoder` turns each fetched ARM-state word
/// into an `ARMInstruction`, this executes it against `Registers`/`CPSR`,
/// with all memory access going through the injected `MemoryBus`. Thumb
/// state (`cpsr.thumbState`) is real too — see `ARMv7CPU+Thumb.swift`
/// for `stepThumb()`/`ThumbDecoder`/`ThumbInstruction` — reached via a
/// genuine interworking `BX`/`BLX`, not a separate, disconnected mode.
///
/// What this does *not* do yet, honestly: exceptions and interrupts (the
/// `I`/`F` CPSR mask bits `CPS` sets are tracked, but nothing actually
/// raises an interrupt for them to gate). Address translation, once the
/// guest sets SCTLR.M, *is* real — see `ARMv7MMU` — walking the guest's
/// own translation tables for every instruction fetch and data access
/// rather than leaving memory untranslated; CP15 registers other than
/// the ones that walk directly reads (like SCTLR, TTBR0/1, TTBCR, DACR)
/// are still just a stored value — see `CP15State` — not acted on (cache
/// maintenance, TLB invalidation, etc). Several ARM-state instruction
/// families are also unimplemented: multiply, SPSR access, most of the
/// coprocessor and unconditional-instruction spaces, SWI (see
/// `ARMDecoder`'s doc comment for the exact list); Thumb has its own,
/// separate coverage gaps (see `ThumbDecoder`'s doc comment). Hitting
/// any of those sets `lastError`
/// and halts rather than skipping the instruction or guessing at its
/// effect — silently pressing on past something this CPU doesn't
/// actually understand would make broken execution look like progress.
///
/// `jit`, if provided, lets `run()` (not `step()` — single-stepping
/// always interprets, which is what you want while debugging) execute
/// eligible straight-line runs as compiled native code instead of one
/// interpreted instruction at a time. See `JITEngine`/`JITTranslator`
/// for exactly what's eligible and why a missing/unavailable JIT is a
/// normal, handled outcome rather than a failure.
final class ARMv7CPU: CPU {
    // Not `private(set)`: `ARMv7CPU+Thumb.swift` (in the same module)
    // needs to mutate these directly, the same way every ARM-state
    // execute method in this file already does. External modules still
    // can't write to them, only read.
    var registers = Registers()
    var cpsr = CPSR()
    var lastError: CPUError?
    var cp15 = CP15State()

    let jit: JITEngine?

    let memory: MemoryBus
    private var isRunning = false

    /// Thumb's `ITSTATE`: bits[7:4] hold the condition for the
    /// instruction about to execute, bits[3:0] the remaining mask —
    /// `0` means no `IT` block is active. See `ARMv7CPU+Thumb.swift`'s
    /// `currentThumbCondition()`/`advanceThumbITState()` for the state
    /// machine, verified against real `it`/`itt`/`ittt` words from the
    /// actual kernel (ARM DDI 0406C A2.5.2).
    var itState: UInt8 = 0

    init(memory: MemoryBus, jit: JITEngine? = nil) {
        self.memory = memory
        self.jit = jit
    }

    func reset() {
        registers.reset()
        cpsr.reset()
        lastError = nil
        isRunning = false
        itState = 0
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

        if cpsr.thumbState {
            stepThumb()
            return
        }

        let instructionAddress = registers.pc
        let word: UInt32
        do {
            let physicalAddress = try translatedAddress(instructionAddress, access: .execute)
            word = try memory.readWord32(at: physicalAddress)
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

        case .branchExchange(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeBranchExchange(instr, instructionAddress: instructionAddress)

        case .branchLinkExchangeImmediate(let instr):
            // Always unconditional — see the struct's doc comment.
            executeBranchLinkExchangeImmediate(instr, instructionAddress: instructionAddress)

        case .loadStore(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeLoadStore(instr)

        case .blockDataTransfer(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeBlockDataTransfer(instr, instructionAddress: instructionAddress)

        case .halfwordDataTransfer(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeHalfwordDataTransfer(instr)

        case .movWide(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeMovWide(instr)

        case .moveFromStatusRegister(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeMoveFromStatusRegister(instr)

        case .moveToStatusRegister(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeMoveToStatusRegister(instr)

        case .coprocessorRegisterTransfer(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeCoprocessorRegisterTransfer(instr, instructionAddress: instructionAddress)

        case .changeProcessorState(let instr):
            executeChangeProcessorState(instr)

        case .uqsub8(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeUqsub8(instr)

        case .rev(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeRev(instr)

        case .bitFieldInsert(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeBitFieldInsert(instr)

        case .bitFieldExtract(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeBitFieldExtract(instr)

        case .multiply(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeMultiply(instr)

        case .clz(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeClz(instr)

        case .loadExclusive(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeLoadExclusive(instr)

        case .storeExclusive(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeStoreExclusive(instr)

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

    private func executeMoveFromStatusRegister(_ instr: MRSInstruction) {
        registers[instr.rd] = cpsr.rawValue
    }

    /// `fieldMask` bytes that are clear leave the corresponding CPSR byte
    /// untouched — a real `MSR` only ever writes the byte lanes it names.
    private static let msrByteMasks: [UInt32] = [0x0000_00FF, 0x0000_FF00, 0x00FF_0000, 0xFF00_0000]

    private func executeMoveToStatusRegister(_ instr: MSRInstruction) {
        let value: UInt32
        switch instr.source {
        case .register(let rm): value = operandValue(for: rm)
        case .immediate(let imm): value = imm
        }

        var writeMask: UInt32 = 0
        for bit in 0..<4 where instr.fieldMask & (1 << bit) != 0 {
            writeMask |= Self.msrByteMasks[bit]
        }

        cpsr.rawValue = (cpsr.rawValue & ~writeMask) | (value & writeMask)
    }

    /// CP15 (coprocessor, opc1, CRn, CRm, opc2) for the register real
    /// ARMv7 calls SCTLR (System Control Register) — where the MMU-enable
    /// and access-flag-enable bits live.
    private static let sctlrCoprocessor = 15
    private static let sctlrOpc1 = 0
    private static let sctlrCRn = 1
    private static let sctlrCRm = 0
    private static let sctlrOpc2 = 0
    private static let sctlrMMUEnableBit: UInt32 = 1 << 0
    private static let sctlrAccessFlagEnableBit: UInt32 = 1 << 29

    /// Whether address translation is currently active, read straight
    /// from the live SCTLR value rather than tracked as separate state —
    /// SCTLR.M is the one real source of truth for this, and deriving it
    /// keeps a plain CP15 write (`cp15.write` below) sufficient to turn
    /// the MMU on or off, exactly like real hardware.
    var mmuEnabled: Bool {
        cp15.read(coprocessor: Self.sctlrCoprocessor, opc1: Self.sctlrOpc1, crn: Self.sctlrCRn, crm: Self.sctlrCRm, opc2: Self.sctlrOpc2)
            & Self.sctlrMMUEnableBit != 0
    }

    func translatedAddress(_ virtualAddress: UInt32, access: ARMv7MMU.Access) throws -> UInt32 {
        guard mmuEnabled else { return virtualAddress }
        return try ARMv7MMU.translate(virtualAddress: virtualAddress, access: access, cp15: cp15, memory: memory)
    }

    // Not `private`: Thumb-2's coprocessor instructions reuse this exact
    // same field layout and semantics (see `ARMv7CPU+Thumb.swift`'s
    // `.coprocessorRegisterTransfer` case) — condition checking already
    // happened in the caller before this runs, in both states, so
    // there's real logic worth sharing here rather than duplicating.
    func executeCoprocessorRegisterTransfer(_ instr: CoprocessorRegisterTransferInstruction, instructionAddress: UInt32) {
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

            if instr.coprocessor == Self.sctlrCoprocessor, instr.opc1 == Self.sctlrOpc1,
               instr.crn == Self.sctlrCRn, instr.crm == Self.sctlrCRm, instr.opc2 == Self.sctlrOpc2,
               value & Self.sctlrAccessFlagEnableBit != 0 {
                // AFE repurposes the AP encoding `ARMv7MMU` implements
                // (the legacy 3-bit {APX,AP} permission model) into a
                // different one built around a hardware-managed Access
                // Flag — silently reusing the same bits under that model
                // would misinterpret real permission data. No guest code
                // Podium has run so far sets this, so it's refused
                // outright rather than guessed at.
                lastError = .unimplementedHardwareFeature(
                    description: "guest enabled SCTLR.AFE (access-flag AP model) — only the legacy 3-bit AP model is implemented",
                    address: instructionAddress
                )
                return
            }

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

    private func executeUqsub8(_ instr: UQSub8Instruction) {
        let rn = registers[instr.rn]
        let rm = registers[instr.rm]
        var result: UInt32 = 0
        for byteIndex in 0..<4 {
            let shift = byteIndex * 8
            let a = Int32((rn >> shift) & 0xFF)
            let b = Int32((rm >> shift) & 0xFF)
            let clamped = UInt32(max(0, a - b))
            result |= clamped << shift
        }
        registers[instr.rd] = result
    }

    private func executeRev(_ instr: RevInstruction) {
        registers[instr.rd] = registers[instr.rm].byteSwapped
    }

    /// `BFI`/`BFC`: doesn't affect flags. `sourceRegister == nil`
    /// (`BFC`) inserts zero, matching real ARM semantics rather than
    /// reading `R15`'s value.
    private func executeBitFieldInsert(_ instr: BitFieldInsertInstruction) {
        let sourceValue = instr.sourceRegister.map { registers[$0] } ?? 0
        let mask: UInt32 = instr.width >= 32 ? 0xFFFF_FFFF : (UInt32(1) << instr.width) - 1
        let shiftedMask = mask << instr.lsb
        registers[instr.rd] = (registers[instr.rd] & ~shiftedMask) | ((sourceValue & mask) << instr.lsb)
    }

    /// `UBFX` (ARM state): zero-extending unsigned bit-field extract.
    /// Doesn't affect flags.
    private func executeBitFieldExtract(_ instr: BitFieldExtractInstruction) {
        let mask: UInt32 = instr.width >= 32 ? 0xFFFF_FFFF : (UInt32(1) << instr.width) - 1
        registers[instr.rd] = (registers[instr.rn] >> instr.lsb) & mask
    }

    private func executeMultiply(_ instr: MultiplyInstruction) {
        registers[instr.rd] = registers[instr.rm] &* registers[instr.rs]
    }

    private func executeClz(_ instr: ClzInstruction) {
        registers[instr.rd] = UInt32(registers[instr.rm].leadingZeroBitCount)
    }

    /// `LDREX`: an ordinary word load. Tagging the address for a later
    /// `STREX` to check isn't modeled yet — no real word has confirmed
    /// `STREX`, so there is nothing yet that would read that tag.
    private func executeLoadExclusive(_ instr: LoadExclusiveInstruction) {
        let address = operandValue(for: instr.rn)
        do {
            let physicalAddress = try translatedAddress(address, access: .read)
            registers[instr.rt] = try memory.readWord32(at: physicalAddress)
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: address)
        } catch {
            lastError = .memoryFault(.unmappedAddress(address), address: address)
        }
    }

    /// See `StoreExclusiveInstruction`'s doc comment for why
    /// unconditional success is correct, not a simplification, in this
    /// single-threaded emulator.
    private func executeStoreExclusive(_ instr: StoreExclusiveInstruction) {
        let address = operandValue(for: instr.rn)
        do {
            let physicalAddress = try translatedAddress(address, access: .write)
            try memory.writeWord32(registers[instr.rt], at: physicalAddress)
            registers[instr.rd] = 0
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: address)
        } catch {
            lastError = .memoryFault(.unmappedAddress(address), address: address)
        }
    }

    func operandValue(for register: Int) -> UInt32 {
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
            // ALUWritePC: on ARMv7, a data-processing instruction that
            // writes r15 interworks exactly like BX (checking bit 0),
            // not just a plain same-state jump.
            cpsr.thumbState = result.bit(0)
            registers.pc = result & ~UInt32(0b1)
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

    private func executeBranchExchange(_ instr: BranchExchangeInstruction, instructionAddress: UInt32) {
        let target = operandValue(for: instr.rm)
        // Real interworking: bit 0 of the target selects the resulting
        // state (1 = Thumb, 0 = ARM) — both are genuinely executable now
        // that `ARMv7CPU+Thumb.swift` exists, so this never halts.
        cpsr.thumbState = target.bit(0)
        registers.pc = target & ~UInt32(0b1)
    }

    private func executeBranchLinkExchangeImmediate(_ instr: BranchLinkExchangeImmediateInstruction, instructionAddress: UInt32) {
        let target = UInt32(bitPattern: Int32(bitPattern: registers.pcForOperandRead) &+ instr.signedOffset)
        // `registers.pc` already holds the address of the instruction
        // after this one (see `step()`) — exactly what LR should hold;
        // it's already word-aligned (ARM instructions always are), so no
        // interworking bit needs to be forced into it here. `BLX`
        // (immediate), executed from ARM state, always switches *to*
        // Thumb — the mirror image of Thumb state's own `BLX`
        // (immediate), which always switches to ARM (see
        // `ARMv7CPU+Thumb.swift`'s `executeThumbBranchLink`). The target
        // only needs halfword alignment, already folded into
        // `signedOffset` via the H bit at decode time — unlike the
        // Thumb-side form, this one must not force 4-byte alignment.
        registers.lr = registers.pc
        cpsr.thumbState = true
        registers.pc = target
    }

    /// ARM ARM's block-transfer addressing modes (IA/IB/DA/DB) only
    /// choose *where in memory* the transfer starts — registers are
    /// always moved in ascending register-number order into ascending
    /// addresses from that point, regardless of direction. Deriving the
    /// start address from `addOffset`/`preIndexed` and then always
    /// walking the register list low-to-high, rather than special-casing
    /// each of the four named modes separately, is both the standard
    /// technique and the one least likely to get a direction/off-by-one
    /// wrong.
    private func executeBlockDataTransfer(_ instr: BlockDataTransferInstruction, instructionAddress: UInt32) {
        let baseValue = operandValue(for: instr.rn)
        let count = instr.registerList.nonzeroBitCount
        guard count > 0 else { return } // Empty register list: UNPREDICTABLE on real hardware; nothing to do.
        let transferSize = UInt32(count) * 4

        let startAddress: UInt32
        if instr.addOffset {
            startAddress = instr.preIndexed ? baseValue &+ 4 : baseValue
        } else {
            startAddress = instr.preIndexed ? baseValue &- transferSize : baseValue &- transferSize &+ 4
        }

        var address = startAddress
        do {
            for index in 0..<16 {
                guard (instr.registerList >> index) & 1 == 1 else { continue }
                let physicalAddress = try translatedAddress(address, access: instr.isLoad ? .read : .write)
                if instr.isLoad {
                    let value = try memory.readWord32(at: physicalAddress)
                    if index == Registers.pcIndex {
                        // Real interworking, same as BX — see
                        // `ARMv7CPU+Thumb.swift`'s `executeThumbBlockDataTransfer`
                        // for the Thumb-side `LDM`-into-PC equivalent.
                        cpsr.thumbState = value.bit(0)
                        registers.pc = value & ~UInt32(0b1)
                    } else {
                        registers[index] = value
                    }
                } else {
                    try memory.writeWord32(operandValue(for: index), at: physicalAddress)
                }
                address = address &+ 4
            }
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: address)
            return
        } catch {
            lastError = .memoryFault(.unmappedAddress(address), address: address)
            return
        }

        if instr.writeback {
            registers[instr.rn] = instr.addOffset ? baseValue &+ transferSize : baseValue &- transferSize
        }
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
            let physicalAddress = try translatedAddress(transferAddress, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                let value = instr.isByte
                    ? UInt32(try memory.readByte(at: physicalAddress))
                    : try memory.readWord32(at: physicalAddress)
                if instr.rd == Registers.pcIndex {
                    // LDRWritePC: real interworking, same as BX.
                    cpsr.thumbState = value.bit(0)
                    registers.pc = value & ~UInt32(0b1)
                } else {
                    registers[instr.rd] = value
                }
            } else {
                let value = operandValue(for: instr.rd)
                if instr.isByte {
                    try memory.writeByte(UInt8(truncatingIfNeeded: value), at: physicalAddress)
                } else {
                    try memory.writeWord32(value, at: physicalAddress)
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

    private func executeHalfwordDataTransfer(_ instr: HalfwordDataTransferInstruction) {
        let base = operandValue(for: instr.rn)
        let offsetValue: UInt32
        switch instr.offset {
        case .immediate(let value):
            offsetValue = value
        case .register(let rm):
            offsetValue = operandValue(for: rm)
        }
        let offsetAddress = instr.addOffset ? base &+ offsetValue : base &- offsetValue
        let transferAddress = instr.preIndexed ? offsetAddress : base

        do {
            let physicalAddress = try translatedAddress(transferAddress, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                let value: UInt32
                switch instr.kind {
                case .unsignedHalfword:
                    value = UInt32(try memory.readWord16(at: physicalAddress))
                case .signedByte:
                    let raw = try memory.readByte(at: physicalAddress)
                    value = UInt32(bitPattern: Int32(Int8(bitPattern: raw)))
                case .signedHalfword:
                    let raw = try memory.readWord16(at: physicalAddress)
                    value = UInt32(bitPattern: Int32(Int16(bitPattern: raw)))
                }
                registers[instr.rd] = value
            } else {
                try memory.writeWord16(UInt16(truncatingIfNeeded: operandValue(for: instr.rd)), at: physicalAddress)
            }
        } catch let memoryError as MemoryAccessError {
            lastError = .memoryFault(memoryError, address: transferAddress)
            return
        } catch {
            lastError = .memoryFault(.unmappedAddress(transferAddress), address: transferAddress)
            return
        }

        if instr.preIndexed {
            if instr.writeback {
                registers[instr.rn] = offsetAddress
            }
        } else {
            registers[instr.rn] = offsetAddress
        }
    }
}
