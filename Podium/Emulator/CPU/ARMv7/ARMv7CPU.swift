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
/// IRQ/FIQ are real: the platform's interrupt controller drives
/// `irqAsserted`/`fiqAsserted`, and the run loop takes the exception
/// between instructions when unmasked (see `serviceDevicesAndInterrupts`).
/// Devices keep time from `virtualTime`, not the host clock. What this
/// does *not* do yet, honestly: Prefetch Abort/Undefined-Instruction
/// exception entry (an instruction-fetch fault or an unsupported/undefined
/// instruction still halts `lastError`-style). Data Abort *is* real now —
/// see `raiseDataAbort` — dispatching into the guest's own vector table
/// with real SP/LR/SPSR banking (`switchProcessorMode`) exactly like real
/// hardware, including a real "S==1, Rd==PC" exception return
/// (`executeDataProcessing`) restoring CPSR from SPSR to unwind back out.
/// Address translation, once the
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
    var neon = NEONRegisters()
    /// VFP system registers — see `ARMv7CPU+VFP.swift`. Both reset to 0:
    /// FPEXC.EN clear, so the unit starts disabled, as on real hardware.
    var fpscr: UInt32 = 0
    var fpexc: UInt32 = 0

    /// Addresses `run(maxUnits:)` stops at (before executing the
    /// instruction there), leaving `registers` exactly as they were on
    /// entry to that address — e.g. reading a function's arguments right
    /// as it's called, which sampling the PC only every N units can't
    /// reliably catch (a tight loop after the address of interest is very
    /// unlikely to land back exactly on it at a sampled boundary).
    var breakpoints: Set<UInt32> = []
    private(set) var hitBreakpoint: UInt32?
    /// Real guest instructions retired so far. Differs from `run(maxUnits:)`'s
    /// unit count once the JIT is involved, since one compiled block is one
    /// unit but many instructions — this is the honest progress/speed figure.
    private(set) var retiredInstructionCount: UInt64 = 0

    let jit: JITEngine?

    let memory: MemoryBus
    private var isRunning = false

    /// The address of the instruction currently executing — real
    /// hardware's pipeline always knows this; here it's captured once per
    /// `step()`/`stepThumb()` so exception entry (`raiseDataAbort`) can
    /// compute the real `LR_abt = instructionAddress + 8` (ARM DDI 0406C
    /// Table B1-7 — fixed at +8 for Data Abort regardless of ARM/Thumb
    /// state) without threading it through every individual `executeXxx`
    /// call site. Not `private(set)`: `stepThumb()` in
    /// `ARMv7CPU+Thumb.swift` sets this too (Swift's `private` is
    /// file-scoped, not type-scoped).
    var currentInstructionAddress: UInt32 = 0

    static let modeBitsMask: UInt32 = 0x1F
    static let userModeBits: UInt32 = 0b10000
    static let svcModeBits: UInt32 = 0b10011
    static let systemModeBits: UInt32 = 0b11111
    static let abortModeBits: UInt32 = 0b10111
    static let irqModeBits: UInt32 = 0b10010
    static let fiqModeBits: UInt32 = 0b10001
    static let undefinedModeBits: UInt32 = 0b11011

    /// SP/LR banked per processor mode (ARM DDI 0406C B1.3.3) — User and
    /// System share one bank (key `userModeBits`), the other five modes
    /// each have their own. Populated lazily: a mode's bank simply reads
    /// back 0 until either the guest's own boot code switches into it (via
    /// `MSR CPSR_c`) to set up its stack, or exception entry visits it.
    private(set) var bankedSP: [UInt32: UInt32] = [:]
    private(set) var bankedLR: [UInt32: UInt32] = [:]

    /// SPSR per mode (ARM DDI 0406C B1.3.3) — only FIQ/IRQ/SVC/Abort/Undef
    /// have one; User/System don't and are never keyed here. Written by
    /// exception entry, read back by the "S==1, Rd==PC" exception-return
    /// idiom (`executeDataProcessing`).
    private var spsrForMode: [UInt32: UInt32] = [:]

    private static func bankKey(forModeBits modeBits: UInt32) -> UInt32 {
        switch modeBits {
        case userModeBits, systemModeBits: return userModeBits
        default: return modeBits
        }
    }

    /// Swaps the live `registers.sp`/`registers.lr` between the outgoing
    /// and incoming mode's bank — the real effect of a CPSR mode change,
    /// whether triggered by `MSR CPSR_c` (`executeMoveToStatusRegister`),
    /// exception entry (`raiseDataAbort`), or exception return
    /// (`executeDataProcessing`'s "S==1, Rd==PC" case).
    func switchProcessorMode(from oldModeBits: UInt32, to newModeBits: UInt32) {
        let oldKey = Self.bankKey(forModeBits: oldModeBits)
        let newKey = Self.bankKey(forModeBits: newModeBits)
        guard oldKey != newKey else { return }
        bankedSP[oldKey] = registers.sp
        bankedLR[oldKey] = registers.lr
        registers.sp = bankedSP[newKey] ?? 0
        registers.lr = bankedLR[newKey] ?? 0

        // FIQ mode additionally banks r8-r12 (every other mode shares one
        // copy of them).
        let leavingFIQ = oldKey == Self.fiqModeBits
        let enteringFIQ = newKey == Self.fiqModeBits
        if leavingFIQ != enteringFIQ {
            for index in 0..<5 {
                let register = 8 + index
                if enteringFIQ {
                    sharedR8toR12[index] = registers[register]
                    registers[register] = fiqR8toR12[index]
                } else {
                    fiqR8toR12[index] = registers[register]
                    registers[register] = sharedR8toR12[index]
                }
            }
        }
    }

    private(set) var fiqR8toR12 = [UInt32](repeating: 0, count: 5)
    private(set) var sharedR8toR12 = [UInt32](repeating: 0, count: 5)

    // MARK: - Interrupts and device time

    /// The IRQ/FIQ input pins, driven by the platform's interrupt
    /// controller. Level-sensitive: asserted for as long as a source is
    /// pending, exactly like the real CPU's nIRQ/nFIQ inputs.
    var irqAsserted = false
    var fiqAsserted = false

    /// Instructions' worth of time skipped while idle in WFI — see
    /// `waitForInterrupt()`.
    private(set) var idleInstructionsSkipped: UInt64 = 0

    /// Deterministic virtual time, in instructions: the platform's
    /// devices derive their clocks from this (retired instructions plus
    /// skipped idle time), not from the host's wall clock, so every run
    /// — JIT or interpreter — sees identical device timing.
    var virtualTime: UInt64 { retiredInstructionCount &+ idleInstructionsSkipped }

    /// When the platform next needs to update device state (e.g. a timer
    /// expiring), in `virtualTime` units, and who to tell. Checked before
    /// every unit; a JIT block is never allowed to run past it, so an
    /// event fires at exactly the same instruction boundary as it would
    /// under the interpreter.
    var nextDeviceEventAt: UInt64 = .max
    weak var deviceEventHandler: DeviceEventHandler?

    /// Brings devices up to date and takes a pending, unmasked interrupt,
    /// if any — once per unit, i.e. between instructions (including inside
    /// a Thumb IT block: exception entry saves ITSTATE in SPSR and the
    /// return restores it, as on real hardware).
    @inline(__always)
    private func serviceDevicesAndInterrupts() {
        if virtualTime >= nextDeviceEventAt {
            deviceEventHandler?.deviceEventDue(at: virtualTime)
        }
        if fiqAsserted && !cpsr.fiqDisabled {
            takeInterrupt(isFIQ: true)
        } else if irqAsserted && !cpsr.irqDisabled {
            takeInterrupt(isFIQ: false)
        }
    }

    /// IRQ/FIQ exception entry (ARM DDI 0406C B1.8.10/B1.8.11): the
    /// preferred return address is the next instruction not yet executed
    /// (`registers.pc`, since this runs between instructions), and
    /// `LR_irq`/`LR_fiq` is that plus 4 in both ARM and Thumb state — the
    /// handler returns with `SUBS PC, LR, #4`. I (and for FIQ, F) are
    /// masked, A is masked, and execution continues in ARM state at the
    /// IRQ (+0x18) or FIQ (+0x1C) vector.
    private func takeInterrupt(isFIQ: Bool) {
        let savedCPSR = Self.cpsr(cpsr.rawValue, withITState: itState)
        let newModeBits = isFIQ ? Self.fiqModeBits : Self.irqModeBits
        let returnAddress = registers.pc

        switchProcessorMode(from: savedCPSR & Self.modeBitsMask, to: newModeBits)
        setSavedProgramStatus(savedCPSR, forModeBits: newModeBits)

        registers.lr = returnAddress &+ 4
        cpsr.rawValue = (savedCPSR & ~Self.modeBitsMask & ~Self.itBitsMask) | newModeBits
        itState = 0
        cpsr.thumbState = false
        cpsr.irqDisabled = true
        cpsr.rawValue |= Self.asyncAbortDisabledBit
        if isFIQ { cpsr.fiqDisabled = true }

        registers.pc = exceptionVectorBaseAddress &+ (isFIQ ? 0x1C : 0x18)
    }

    static let asyncAbortDisabledBit: UInt32 = 1 << 8

    /// WFI: nothing happens until an interrupt is asserted (masked or
    /// not — WFI wakes on the pin, ARM DDI 0406C B1.8.13). With nothing
    /// pending, virtual time jumps straight to the next device event, so
    /// an idle guest costs no host time at all. With no event scheduled
    /// either, nothing could ever wake the CPU; time stays put and the
    /// guest simply re-executes its idle loop.
    func waitForInterrupt() {
        guard !irqAsserted, !fiqAsserted, nextDeviceEventAt != .max, nextDeviceEventAt > virtualTime else { return }
        idleInstructionsSkipped &+= nextDeviceEventAt - virtualTime
    }

    func savedProgramStatus(forModeBits modeBits: UInt32) -> UInt32? {
        spsrForMode[modeBits]
    }

    func setSavedProgramStatus(_ value: UInt32, forModeBits modeBits: UInt32) {
        spsrForMode[modeBits] = value
    }

    /// Thumb's `ITSTATE`: bits[7:4] hold the condition for the
    /// instruction about to execute, bits[3:0] the remaining mask —
    /// `0` means no `IT` block is active. See `ARMv7CPU+Thumb.swift`'s
    /// `currentThumbCondition()`/`advanceThumbITState()` for the state
    /// machine, verified against real `it`/`itt`/`ittt` words from the
    /// actual kernel (ARM DDI 0406C A2.5.2).
    var itState: UInt8 = 0

    /// `itState` as it was when the current instruction started, before
    /// `stepThumb` advanced it. An exception this instruction raises must
    /// save *this* in SPSR, since the instruction re-executes under it.
    var currentInstructionITState: UInt8 = 0

    /// CPSR's ITSTATE fields: IT[1:0] in bits [26:25], IT[7:2] in [15:10].
    /// `itState` is the live copy; these bits only ever hold it inside an
    /// SPSR, across an exception.
    static let itBitsMask: UInt32 = 0b11 << 25 | 0x3F << 10

    static func cpsr(_ raw: UInt32, withITState it: UInt8) -> UInt32 {
        (raw & ~itBitsMask) | UInt32(it & 0b11) << 25 | UInt32(it >> 2) << 10
    }

    static func itState(fromCPSR raw: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: (raw >> 25) & 0b11 | ((raw >> 10) & 0x3F) << 2)
    }

    /// Whether the Thumb instruction currently executing is the
    /// conditional target of an active `IT` block (as opposed to running
    /// unconditionally with no block active) — set once per instruction
    /// in `stepThumb()`, mirroring how `currentInstructionAddress` is
    /// captured once per step rather than threaded through every execute
    /// call. Several 16-bit Thumb encodings (`ADD`/`SUB`/`MOV`/`AND`/
    /// `EOR`/`ORR`/`BIC`/`MVN`/`LSL`/`LSR`/`ASR`/`ROR`/`ADC`/`SBC`/`NEG`/
    /// `MUL`, per ARM DDI 0406C A6.7 and the unified assembler syntax
    /// rules) implicitly set flags only when unconditional — inside an
    /// `IT` block their assembly form drops the `S` suffix and they must
    /// leave `CPSR` alone, unlike their always-flag-setting 32-bit
    /// (`.w`, explicit `S` bit) counterparts or comparison-only
    /// instructions (`CMP`/`CMN`/`TST`, which have no non-flag-setting
    /// form at all). Traced back from a real early-boot kernel panic: an
    /// `andne r0, r6` inside an `itttt ne` block was clobbering the `Z`
    /// flag the preceding `cmp` had set for `NE`, causing the block's
    /// 4th instruction (also conditioned on `NE`) to be wrongly skipped.
    var currentThumbInstructionIsConditional = false

    init(memory: MemoryBus, jit: JITEngine? = nil) {
        self.memory = memory
        self.jit = jit
        flushTLB()
    }

    deinit {
        tlbTags.deallocate()
        tlbPages.deallocate()
    }

    func reset() {
        registers.reset()
        cpsr.reset()
        lastError = nil
        isRunning = false
        itState = 0
        flushTLB()
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
        currentInstructionAddress = instructionAddress
        currentInstructionITState = 0
        let word: UInt32
        do {
            let physicalAddress = try translatedAddress(instructionAddress, access: .execute)
            word = try readPhysical32(physicalAddress)
        } catch let memoryError as MemoryAccessError {
            if !raisePrefetchAbort(memoryError) { lastError = .memoryFault(memoryError, address: instructionAddress) }
            return
        } catch {
            lastError = .memoryFault(.unmappedAddress(instructionAddress), address: instructionAddress)
            return
        }

        // Advance to the next instruction *before* executing — this is
        // what makes `Registers.pcForOperandRead` (instruction address +
        // 8) fall out of `pc + 4` below. A taken branch overwrites this.
        registers.pc = instructionAddress &+ 4
        currentInstructionITState = 0

        execute(ARMDecoder.decode(word), rawWord: word, instructionAddress: instructionAddress)
    }

    func run() {
        isRunning = true
        while isRunning && lastError == nil {
            serviceDevicesAndInterrupts()
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
        hitBreakpoint = nil
        var unitsRun = 0
        while isRunning && lastError == nil && unitsRun < maxUnits {
            serviceDevicesAndInterrupts()
            if !breakpoints.isEmpty, breakpoints.contains(registers.pc) {
                hitBreakpoint = registers.pc
                break
            }
            runOneUnit()
            unitsRun += 1
        }
        return unitsRun
    }

    func stop() {
        isRunning = false
    }

    /// The kernel's linear map of DRAM: XNU maps all of it contiguously
    /// from `virtBase` (see `GuestMemoryLayout`). The JIT relies on it — a
    /// compiled block reads its code, and its loads/stores go straight to
    /// host memory, without a page-table walk, so with the MMU on the JIT
    /// only runs code inside this window and only fast-paths accesses
    /// inside it, where virtual and physical addresses differ by a
    /// constant. Everything else (user space, `kernel_map` allocations)
    /// takes the interpreter's real translation.
    var linearMap: (virtualBase: UInt32, physicalBase: UInt32, length: UInt32)? {
        didSet { linearMapHostPointer = nil }
    }
    private var linearMapHostPointer: UnsafeMutableRawPointer?

    /// Where the JIT may find the code at virtual `address`: the same
    /// address while the MMU is off, its linear-map image while it's on;
    /// `nil` (interpret) outside the linear window.
    @inline(__always)
    private func jitPhysicalAddress(_ address: UInt32) -> UInt32? {
        guard mmuEnabled else { return address }
        guard let map = linearMap, address &- map.virtualBase < map.length else { return nil }
        return address &- map.virtualBase &+ map.physicalBase
    }

    /// The RAM window a compiled load/store may access directly, in the
    /// addresses the code uses: physical DRAM while the MMU is off, the
    /// linear map's virtual window while it's on.
    private func fastPathWindow() -> (pointer: UnsafeMutableRawPointer, guestBase: UInt32, length: UInt32)? {
        guard let map = linearMap else {
            guard !mmuEnabled, let region = memory.fastPathRegion(for: registers.pc) else { return nil }
            return (region.pointer, region.regionBaseAddress, UInt32(region.regionLength))
        }
        if linearMapHostPointer == nil, let region = memory.fastPathRegion(for: map.physicalBase),
           UInt64(map.physicalBase - region.regionBaseAddress) + UInt64(map.length) <= UInt64(region.regionLength) {
            linearMapHostPointer = region.pointer + Int(map.physicalBase - region.regionBaseAddress)
        }
        guard let pointer = linearMapHostPointer else { return nil }
        return (pointer, mmuEnabled ? map.virtualBase : map.physicalBase, map.length)
    }

    private func runOneUnit() {
        // `JITEngine` picks the right decoder/translator internally based
        // on `thumbState` (ARM-state `DataProcessingInstruction`s via
        // `JITTranslator`, Thumb-state instructions via
        // `ThumbJITTranslator`) and keys its cache on both address *and*
        // state — passing the wrong state here would make it silently
        // misinterpret real instruction bytes as the other ISA's encoding
        // (a real, previously-latent risk; see `JITEngine`'s own history
        // for why this state check matters). `block.totalByteLength`, not
        // `4 * block.instructionCount`, is what actually advances `pc`
        // correctly — Thumb instructions are 2 or 4 bytes each, not a
        // fixed 4.
        //
        // `itState != 0` (an active Thumb IT-block) additionally blocks
        // the JIT attempt outright, regardless of thumbState: every
        // Thumb-state instruction the JIT can compile
        // (`dataProcessingShiftedRegister`/`hiRegister`) goes through
        // `stepThumb()`'s `default` case in the interpreter, which
        // conditionally executes it against `currentThumbCondition()` (or
        // skips it, register-write and all, leaving only `pc` advanced,
        // when that condition fails) — see `stepThumb()`'s doc comment.
        // `ThumbJITTranslator`'s compiled code has no representation of
        // that conditional skip at all; it always executes the operation
        // unconditionally. Compiling and running such an instruction
        // while a real IT block is predicating it produces a silently
        // wrong register write whenever the guest condition is actually
        // false — found via a real, reproducible false kernel panic this
        // session (a bogus `sleh_abort at interrupt context`, traced back
        // to exactly this: a conditionally-skipped `MOV r0, r2` inside an
        // IT block that the JIT executed anyway). Falling back to the
        // interpreter for the (at most 4) instructions an IT block can
        // cover is a small, bounded cost next to getting this wrong.
        if let jit, itState == 0, let codeAddress = jitPhysicalAddress(registers.pc),
           let block = jit.block(at: codeAddress, thumbState: cpsr.thumbState, memory: memory),
           virtualTime &+ UInt64(block.instructionCount) <= nextDeviceEventAt {
            // Gated on `containsMemoryAccess`: most compiled blocks are
            // register-only and never read `x1`/`w2`/`w3` at all.
            let completed: Int
            if block.containsMemoryAccess {
                let window = fastPathWindow()
                completed = registers.withUnsafeMutableStorage { regPtr in
                    withUnsafeMutablePointer(to: &cpsr.rawValue) { cpsrPtr in
                        block.run(registers: regPtr, ramHostPointer: window?.pointer, ramGuestBase: window?.guestBase ?? 0, ramGuestLength: window?.length ?? 0, cpsr: cpsrPtr)
                    }
                }
                // See `JITEngine.reportMemoryBlockOutcome`'s doc comment: a
                // block whose load/store address is chronically outside
                // the fast-path region (`completed == 0` every time) costs
                // more than it saves, so this reports the outcome back for
                // eviction bookkeeping.
                jit.reportMemoryBlockOutcome(at: codeAddress, thumbState: cpsr.thumbState, madeProgress: completed > 0)
            } else {
                completed = registers.withUnsafeMutableStorage { regPtr in
                    withUnsafeMutablePointer(to: &cpsr.rawValue) { cpsrPtr in
                        block.run(registers: regPtr, cpsr: cpsrPtr)
                    }
                }
            }
            registers.pc = registers.pc &+ UInt32(block.byteLength(afterCompleting: completed))
            retiredInstructionCount &+= UInt64(completed)
            // A load/store's runtime address can fall outside the offered
            // fast-path region (or no region was offered at all) even
            // though the *instruction* was JIT-eligible — see
            // `ThumbJITTranslator`'s doc comment. `completed == 0` means
            // this call's block did nothing at all (its very first
            // instruction bailed), so `pc` hasn't moved; run one real
            // interpreted step right now so this call still makes
            // guaranteed forward progress, instead of leaving the next
            // `runOneUnit()` call to re-discover the same block, get the
            // same cache hit, and bail at the same address again.
            if completed == 0 {
                step()
                retiredInstructionCount &+= 1
            }
        } else {
            step()
            retiredInstructionCount &+= 1
        }
    }

    // MARK: - Execute

    /// Internal (not private) so Thumb's Advanced SIMD instructions, which
    /// decode to their ARM-state form, run through this same executor.
    func execute(_ instruction: ARMInstruction, rawWord: UInt32, instructionAddress: UInt32) {
        // See ARMv7CPU+VFP.swift on XNU's lazy VFP switching.
        if fpexc & Self.fpexcEnableBit == 0, let condition = instruction.floatingPointUnitCondition {
            if cpsr.isSatisfied(condition) { raiseUndefinedInstruction() }
            return
        }
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

        case .loadStoreDual(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeLoadStoreDual(instr)

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

        case .loadExclusiveDouble(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeLoadExclusiveDouble(instr)
        case .storeExclusiveDouble(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeStoreExclusiveDouble(instr)

        case .loadExclusive(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeLoadExclusive(instr)

        case .storeExclusive(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeStoreExclusive(instr)

        case .memoryBarrier:
            // A real no-op: see ARMInstruction.memoryBarrier's doc comment.
            break

        case .clearExclusive:
            exclusiveMonitorAddress = nil


        case .bitwiseExclusiveOr(let instr):
            executeBitwiseExclusiveOr(instr)
        case .neonModifiedImmediate(let instr):
            executeNEONModifiedImmediate(instr)

        case .bitwiseOr(let instr):
            executeBitwiseOr(instr)

        case .integerAdd(let instr):
            executeIntegerAdd(instr)

        case .vectorExtract(let instr):
            executeVectorExtract(instr)

        case .vectorShiftImmediate(let instr):
            executeVectorShiftImmediate(instr)

        case .elementLoadStore(let instr):
            executeElementLoadStore(instr)

        case .reverseElements(let instr):
            executeReverseElements(instr)

        case .extensionRegisterLoadStore(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeExtensionRegisterLoadStore(instr)

        case .vfpTwoRegisterTransfer(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeVFPTwoRegisterTransfer(instr)

        case .vfpDataProcessing(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeVFPDataProcessing(instr)

        case .neon(let instr):
            executeNEON(instr)

        case .media(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            executeMedia(instr)

        case .neonStructureLoadStore(let instr):
            executeNEONStructureLoadStore(instr)

        case .hint(let instr):
            // WFE/SEV only matter between cores; see the Thumb executor.
            guard cpsr.isSatisfied(instr.condition), instr.hint == .waitForInterrupt else { return }
            waitForInterrupt()

        case .supervisorCall(let instr):
            guard cpsr.isSatisfied(instr.condition) else { return }
            takeSupervisorCall()

        case .storeReturnState(let instr):
            executeStoreReturnState(instr)

        case .returnFromException(let instr):
            executeReturnFromException(instr)

        case .unsupported:
            if !trapInUserMode(rawWord: rawWord, address: instructionAddress) {
                lastError = .unsupportedInstruction(rawWord: rawWord, address: instructionAddress)
            }

        case .undefined:
            if !trapInUserMode(rawWord: rawWord, address: instructionAddress) {
                lastError = .undefinedInstruction(rawWord: rawWord, address: instructionAddress)
            }
        }
    }

    /// Reports each user-mode instruction this CPU couldn't execute before
    /// it becomes an Undefined Instruction exception (see
    /// `trapInUserMode`), so a decoder gap in user code stays visible
    /// instead of silently becoming a process crash.
    var userUndefinedInstructionHandler: ((_ address: UInt32, _ rawWord: UInt32) -> Void)?

    /// A user process executing an instruction this CPU can't run gets the
    /// Undefined Instruction exception, as on real hardware — the guest
    /// kernel then kills just that process (SIGILL) and boot carries on.
    /// Found on a real boot: a daemon jumped through a corrupted function
    /// pointer into the middle of Thumb code, ran it as ARM and hit an
    /// architecturally UNDEFINED word, and halting the whole emulator there
    /// turned one crashing process into a dead boot. Privileged code still
    /// halts: the kernel hitting one means a gap in this CPU, not the guest.
    func trapInUserMode(rawWord: UInt32, address: UInt32) -> Bool {
        guard cpsr.rawValue & Self.modeBitsMask == Self.userModeBits else { return false }
        userUndefinedInstructionHandler?(address, rawWord)
        raiseUndefinedInstruction()
        return true
    }

    private func executeMovWide(_ instr: MovWideInstruction) {
        if instr.isTop {
            registers[instr.rd] = (registers[instr.rd] & 0x0000_FFFF) | (UInt32(instr.imm16) << 16)
        } else {
            registers[instr.rd] = UInt32(instr.imm16)
        }
    }

    /// `MRS Rd, SPSR` reads the *current mode's* banked SPSR — real
    /// hardware calls this UNPREDICTABLE in User/System mode (neither has
    /// one); Podium reads back 0 there, the same "unpopulated bank" stance
    /// `switchProcessorMode`'s SP/LR banks already take, rather than
    /// fabricating a value real hardware wouldn't define.
    private func executeMoveFromStatusRegister(_ instr: MRSInstruction) {
        if instr.isSPSR {
            registers[instr.rd] = savedProgramStatus(forModeBits: cpsr.rawValue & Self.modeBitsMask) ?? 0
        } else {
            registers[instr.rd] = cpsr.rawValue
        }
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

        // `MSR SPSR_<fields>` writes the *current mode's* banked SPSR —
        // never the live CPSR, and never changes processor mode itself
        // (only a real mode change, via CPSR's own control byte below or
        // exception entry/return, banks a different SPSR in).
        if instr.isSPSR {
            let modeBits = cpsr.rawValue & Self.modeBitsMask
            let old = savedProgramStatus(forModeBits: modeBits) ?? 0
            setSavedProgramStatus((old & ~writeMask) | (value & writeMask), forModeBits: modeBits)
            return
        }

        let oldModeBits = cpsr.rawValue & Self.modeBitsMask
        cpsr.rawValue = (cpsr.rawValue & ~writeMask) | (value & writeMask)
        // The control byte (bits[7:0]) carries the mode field — only an
        // `MSR` that actually writes it (real boot code does this once per
        // mode very early, to give each a real stack) can change mode.
        if writeMask & 0x0000_00FF != 0 {
            switchProcessorMode(from: oldModeBits, to: cpsr.rawValue & Self.modeBitsMask)
        }
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
        cp15.sctlr & Self.sctlrMMUEnableBit != 0
    }

    func translatedAddress(_ virtualAddress: UInt32, access: ARMv7MMU.Access) throws -> UInt32 {
        guard mmuEnabled else { return virtualAddress }
        let user = cpsr.rawValue & Self.modeBitsMask == Self.userModeBits
        let kind: Int
        switch access {
        case .read: kind = 0
        case .write: kind = 2
        case .execute: kind = 4
        }
        // CONTEXTIDR's low 8 bits are the ASID XNU tags each address
        // space with — folded into both the slot index (so two processes'
        // entries for "the same" virtual page don't fight over one
        // direct-mapped slot) and the tag itself (so a collision is only
        // ever a cache miss, never a wrong answer).
        let asid = cp15.contextID & 0xFF
        let asidMix = asid &* 0x9E37_79B1 // Knuth multiplicative hash constant
        let pageIndex = ((virtualAddress >> 12) ^ (asidMix >> 20)) & UInt32(Self.tlbEntries - 1)
        let slot = (kind + (user ? 1 : 0)) &* Self.tlbEntries &+ Int(pageIndex)
        let tag = (virtualAddress & 0xFFFF_F000) | (asid << 1) | 1
        if tlbTags[slot] == tag {
            return tlbPages[slot] | (virtualAddress & 0xFFF)
        }
        let physical = try ARMv7MMU.translate(
            virtualAddress: virtualAddress, access: access, ttbcr: cp15.ttbcr, ttbr0: cp15.ttbr0, ttbr1: cp15.ttbr1,
            dacr: cp15.dacr, memory: memory, privileged: !user
        )
        tlbTags[slot] = tag
        tlbPages[slot] = physical & 0xFFFF_F000
        return physical
    }

    // MARK: - TLB

    /// A software TLB in front of `ARMv7MMU.translate`: successful walks
    /// cached per 4 KB virtual page, per access kind (read/write/execute),
    /// privilege and ASID; faults are never cached. It follows real
    /// hardware's contract — the guest must invalidate (CP15 c8) after
    /// changing a valid mapping — and is emptied whenever SCTLR, TTBR1,
    /// TTBCR or DACR change.
    ///
    /// TTBR0 and CONTEXTIDR are deliberately *not* on that list, even
    /// though they change on every context switch (a new address space
    /// means a new page table base and a new ASID) — unlike the others,
    /// entries are tagged with the ASID they were created under (see
    /// `translatedAddress`), so switching back to a process whose
    /// mappings are still cached is a hit, not a guaranteed re-walk. Real
    /// ARM MMUs work the same way for the same reason: without ASID
    /// tagging, ordinary multitasking would thrash a TLB flushed on every
    /// switch — measured as real cost here too, on a real kernel/user-
    /// space trace with many processes starting and being scheduled.
    /// This relies on the same contract real hardware does: software must
    /// never reuse an ASID for a genuinely different address space
    /// without an explicit invalidate, which XNU already has to get right
    /// to work on real silicon.
    private static let tlbEntries = 8192
    private let tlbTags = UnsafeMutablePointer<UInt32>.allocate(capacity: 6 * tlbEntries)
    private let tlbPages = UnsafeMutablePointer<UInt32>.allocate(capacity: 6 * tlbEntries)

    func flushTLB() {
        tlbTags.initialize(repeating: 0, count: 6 * Self.tlbEntries)
    }

    /// CP15 writes that change translation and need a full flush: SCTLR
    /// (c1), TTBR1/TTBCR (c2, opc2 1/2 — not opc2 0, TTBR0, which the ASID
    /// tag already handles), DACR (c3), the TLB maintenance operations
    /// (c8). CONTEXTIDR (c13, opc2 1) isn't here for the same reason.
    private static func cp15WriteAffectsTranslation(crn: Int, opc2: Int) -> Bool {
        crn == 1 || crn == 3 || crn == 8 || (crn == 2 && opc2 != 0)
    }

    // MARK: - Guest RAM fast path

    /// Physical DRAM as a host pointer, found once through the bus: loads
    /// and stores that land in it skip the bus's region search and its
    /// protocol dispatch, which dominated host time once user space ran.
    private var ramFastPath: (pointer: UnsafeMutableRawPointer, base: UInt32, length: UInt32)?
    private var ramFastPathResolved = false

    @inline(__always)
    private func ramPointer(_ physical: UInt32, width: UInt32) -> UnsafeMutableRawPointer? {
        if !ramFastPathResolved {
            ramFastPathResolved = true
            if let map = linearMap, let region = memory.fastPathRegion(for: map.physicalBase) {
                ramFastPath = (region.pointer, region.regionBaseAddress, UInt32(region.regionLength))
            }
        }
        guard let ram = ramFastPath, physical &- ram.base <= ram.length &- width else { return nil }
        return ram.pointer + Int(physical &- ram.base)
    }

    func readPhysical32(_ physical: UInt32) throws -> UInt32 {
        if let p = ramPointer(physical, width: 4) { return UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)) }
        return try memory.readWord32(at: physical)
    }

    func readPhysical16(_ physical: UInt32) throws -> UInt16 {
        if let p = ramPointer(physical, width: 2) { return UInt16(littleEndian: p.loadUnaligned(as: UInt16.self)) }
        return try memory.readWord16(at: physical)
    }

    func readPhysical8(_ physical: UInt32) throws -> UInt8 {
        if let p = ramPointer(physical, width: 1) { return p.load(as: UInt8.self) }
        return try memory.readByte(at: physical)
    }

    func writePhysical32(_ value: UInt32, _ physical: UInt32) throws {
        if let p = ramPointer(physical, width: 4) { p.storeBytes(of: value.littleEndian, as: UInt32.self); return }
        try memory.writeWord32(value, at: physical)
    }

    func writePhysical16(_ value: UInt16, _ physical: UInt32) throws {
        if let p = ramPointer(physical, width: 2) { p.storeBytes(of: value.littleEndian, as: UInt16.self); return }
        try memory.writeWord16(value, at: physical)
    }

    func writePhysical8(_ value: UInt8, _ physical: UInt32) throws {
        if let p = ramPointer(physical, width: 1) { p.storeBytes(of: value, as: UInt8.self); return }
        try memory.writeByte(value, at: physical)
    }

    // MARK: - Data accesses that may cross a page

    /// Physical addresses for each byte of a `width`-byte access at
    /// `virtualAddress`. An unaligned access (legal for LDR/STR/LDRH/STRH
    /// with SCTLR.A clear) can straddle a 4 KB page boundary, and the next
    /// virtual page is almost never the next physical one — translating
    /// only the first byte read or wrote the tail in the wrong page. That
    /// silently corrupted the kernel's zlib output (its inflate reads the
    /// input with unaligned loads), so exec of launchd failed with
    /// "failed to inflate in one pass". Every page is translated (and
    /// permission-checked) before anything is written.
    @inline(__always)
    private func splitsAcrossPages(_ virtualAddress: UInt32, width: Int) -> Bool {
        mmuEnabled && Int(virtualAddress & 0xFFF) + width > 0x1000
    }

    private func bytePhysicalAddresses(_ virtualAddress: UInt32, width: Int, access: ARMv7MMU.Access) throws -> [UInt32] {
        let first = try translatedAddress(virtualAddress, access: access)
        let boundary = 0x1000 - Int(virtualAddress & 0xFFF)
        let second = try translatedAddress(virtualAddress &+ UInt32(boundary), access: access)
        return (0..<width).map { $0 < boundary ? first &+ UInt32($0) : second &+ UInt32($0 - boundary) }
    }

    func readData(_ virtualAddress: UInt32, width: Int) throws -> UInt32 {
        if splitsAcrossPages(virtualAddress, width: width) {
            var value: UInt32 = 0
            for (i, physical) in try bytePhysicalAddresses(virtualAddress, width: width, access: .read).enumerated() {
                value |= UInt32(try readPhysical8(physical)) << UInt32(8 * i)
            }
            return value
        }
        let physical = try translatedAddress(virtualAddress, access: .read)
        switch width {
        case 1: return UInt32(try readPhysical8(physical))
        case 2: return UInt32(try readPhysical16(physical))
        default: return try readPhysical32(physical)
        }
    }

    func writeData(_ value: UInt32, _ virtualAddress: UInt32, width: Int) throws {
        if splitsAcrossPages(virtualAddress, width: width) {
            for (i, physical) in try bytePhysicalAddresses(virtualAddress, width: width, access: .write).enumerated() {
                try writePhysical8(UInt8(truncatingIfNeeded: value >> UInt32(8 * i)), physical)
            }
            return
        }
        let physical = try translatedAddress(virtualAddress, access: .write)
        switch width {
        case 1: try writePhysical8(UInt8(truncatingIfNeeded: value), physical)
        case 2: try writePhysical16(UInt16(truncatingIfNeeded: value), physical)
        default: try writePhysical32(value, physical)
        }
    }

    /// SCTLR.V (bit 13): selects the real ARM low-vectors (0x00000000) or
    /// high-vectors (0xFFFF0000) exception vector table base — whichever
    /// the guest itself configured, not assumed. Read the same way
    /// `mmuEnabled` reads SCTLR.M.
    private static let sctlrHighVectorsBit: UInt32 = 1 << 13
    var exceptionVectorBaseAddress: UInt32 {
        let sctlr = cp15.read(coprocessor: Self.sctlrCoprocessor, opc1: Self.sctlrOpc1, crn: Self.sctlrCRn, crm: Self.sctlrCRm, opc2: Self.sctlrOpc2)
        return sctlr & Self.sctlrHighVectorsBit != 0 ? 0xFFFF_0000 : 0x0000_0000
    }

    /// Supervisor Call exception entry (ARM DDI 0406C B1.9.4): SVC mode,
    /// `LR_svc` = the next instruction (the call has completed — so SPSR
    /// gets the IT state already advanced past it), IRQs masked, ARM state,
    /// vector +0x08.
    func takeSupervisorCall() {
        let savedCPSR = Self.cpsr(cpsr.rawValue, withITState: cpsr.thumbState ? itState : 0)
        switchProcessorMode(from: savedCPSR & Self.modeBitsMask, to: Self.svcModeBits)
        setSavedProgramStatus(savedCPSR, forModeBits: Self.svcModeBits)
        registers.lr = registers.pc
        cpsr.rawValue = (savedCPSR & ~Self.modeBitsMask & ~Self.itBitsMask) | Self.svcModeBits
        itState = 0
        cpsr.thumbState = false
        cpsr.irqDisabled = true
        registers.pc = exceptionVectorBaseAddress &+ 0x08
    }

    /// Exception return: CPSR (mode, flags, masks, T, ITSTATE) from
    /// `savedCPSR`, banking in the restored mode's registers, then a
    /// jump to `address` aligned for the restored instruction set.
    private func returnFromException(to address: UInt32, restoring savedCPSR: UInt32) {
        let oldModeBits = cpsr.rawValue & Self.modeBitsMask
        cpsr.rawValue = savedCPSR & ~Self.itBitsMask
        itState = Self.itState(fromCPSR: savedCPSR)
        switchProcessorMode(from: oldModeBits, to: cpsr.rawValue & Self.modeBitsMask)
        registers.pc = address & (cpsr.thumbState ? ~UInt32(1) : ~UInt32(3))
    }

    /// The User/System-mode copy of a register while executing in another
    /// mode — what `STM`/`LDM` with `^` transfer. r13/r14 live in the
    /// User bank; r8-r12 are banked away only while in FIQ mode.
    private func userBankRegister(_ index: Int) -> UInt32 {
        let mode = cpsr.rawValue & Self.modeBitsMask
        guard Self.bankKey(forModeBits: mode) != Self.userModeBits else { return registers[index] }
        switch index {
        case 13: return bankedSP[Self.userModeBits] ?? 0
        case 14: return bankedLR[Self.userModeBits] ?? 0
        case 8...12 where mode == Self.fiqModeBits: return sharedR8toR12[index - 8]
        default: return registers[index]
        }
    }

    private func setUserBankRegister(_ index: Int, _ value: UInt32) {
        let mode = cpsr.rawValue & Self.modeBitsMask
        guard Self.bankKey(forModeBits: mode) != Self.userModeBits else {
            registers[index] = value
            return
        }
        switch index {
        case 13: bankedSP[Self.userModeBits] = value
        case 14: bankedLR[Self.userModeBits] = value
        case 8...12 where mode == Self.fiqModeBits: sharedR8toR12[index - 8] = value
        default: registers[index] = value
        }
    }

    /// A mode's stack pointer, whether or not that mode is current.
    private func stackPointer(forMode modeBits: UInt32) -> UInt32 {
        Self.bankKey(forModeBits: modeBits) == Self.bankKey(forModeBits: cpsr.rawValue & Self.modeBitsMask)
            ? registers.sp : bankedSP[Self.bankKey(forModeBits: modeBits)] ?? 0
    }

    private func setStackPointer(_ value: UInt32, forMode modeBits: UInt32) {
        if Self.bankKey(forModeBits: modeBits) == Self.bankKey(forModeBits: cpsr.rawValue & Self.modeBitsMask) {
            registers.sp = value
        } else {
            bankedSP[Self.bankKey(forModeBits: modeBits)] = value
        }
    }

    /// The first address an `SRS`/`RFE` transfers, for its two words.
    private static func returnStateAddress(base: UInt32, increment: Bool, before: Bool) -> UInt32 {
        increment ? (before ? base &+ 4 : base) : (before ? base &- 8 : base &- 4)
    }

    /// `SRS`: see `StoreReturnStateInstruction`. UNPREDICTABLE in User and
    /// System modes (no SPSR) — ignored there.
    private func executeStoreReturnState(_ instr: StoreReturnStateInstruction) {
        let currentMode = cpsr.rawValue & Self.modeBitsMask
        guard let spsr = savedProgramStatus(forModeBits: currentMode) else { return }
        let base = stackPointer(forMode: instr.mode)
        let address = Self.returnStateAddress(base: base, increment: instr.increment, before: instr.before)
        do {
            try memory.writeWord32(registers.lr, at: try translatedAddress(address, access: .write))
            try memory.writeWord32(spsr, at: try translatedAddress(address &+ 4, access: .write))
        } catch {
            let memoryError = error as? MemoryAccessError ?? .unmappedAddress(address)
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
            return
        }
        if instr.writeback {
            setStackPointer(instr.increment ? base &+ 8 : base &- 8, forMode: instr.mode)
        }
    }

    /// `RFE`: see `ReturnFromExceptionInstruction`.
    private func executeReturnFromException(_ instr: ReturnFromExceptionInstruction) {
        guard cpsr.rawValue & Self.modeBitsMask != Self.userModeBits else { return }
        let base = registers[instr.rn]
        let address = Self.returnStateAddress(base: base, increment: instr.increment, before: instr.before)
        let newPC: UInt32, newCPSR: UInt32
        do {
            newPC = try memory.readWord32(at: try translatedAddress(address, access: .read))
            newCPSR = try memory.readWord32(at: try translatedAddress(address &+ 4, access: .read))
        } catch {
            let memoryError = error as? MemoryAccessError ?? .unmappedAddress(address)
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
            return
        }
        if instr.writeback {
            registers[instr.rn] = instr.increment ? base &+ 8 : base &- 8
        }
        returnFromException(to: newPC, restoring: newCPSR)
    }

    /// Undefined Instruction exception entry (ARM DDI 0406C B1.9.6):
    /// Undefined mode, `LR_und` = the instruction's address + 4 in ARM
    /// state and + 2 in Thumb state whatever the instruction's width (so
    /// for a 32-bit Thumb instruction it points at the second halfword —
    /// the handler reads `[LR-2]` to find it), SPSR_und with the
    /// instruction's own ITSTATE, IRQs masked, ARM state, vector +0x04.
    /// Raised for VFP/Advanced SIMD instructions while FPEXC.EN is clear.
    func raiseUndefinedInstruction() {
        let thumb = cpsr.thumbState
        let savedCPSR = Self.cpsr(cpsr.rawValue, withITState: thumb ? currentInstructionITState : 0)
        switchProcessorMode(from: savedCPSR & Self.modeBitsMask, to: Self.undefinedModeBits)
        setSavedProgramStatus(savedCPSR, forModeBits: Self.undefinedModeBits)
        registers.lr = currentInstructionAddress &+ (thumb ? 2 : 4)
        cpsr.rawValue = (savedCPSR & ~Self.modeBitsMask & ~Self.itBitsMask) | Self.undefinedModeBits
        itState = 0
        cpsr.thumbState = false
        cpsr.irqDisabled = true
        registers.pc = exceptionVectorBaseAddress &+ 0x04
    }

    /// Prefetch Abort exception entry (ARM DDI 0406C B1.9.7) for an
    /// instruction fetch the MMU refused: Abort mode, `LR_abt` = the
    /// instruction's address + 4 in either state, IFSR/IFAR (CP15 c5/c6,
    /// opc2 1/2) describing the fault, IRQs and asynchronous aborts
    /// masked, vector +0x0C. The same conditions as `raiseDataAbort`
    /// decide whether it's raised at all. `faultAddress` is the halfword
    /// that failed (the second one, for a 32-bit Thumb instruction
    /// straddling a page boundary).
    func raisePrefetchAbort(_ error: MemoryAccessError) -> Bool {
        guard case .translationFault(let virtualAddress, let reason, _) = error else { return false }
        guard mmuEnabled else { return false }

        let savedCPSR = Self.cpsr(cpsr.rawValue, withITState: cpsr.thumbState ? currentInstructionITState : 0)
        switchProcessorMode(from: savedCPSR & Self.modeBitsMask, to: Self.abortModeBits)
        setSavedProgramStatus(savedCPSR, forModeBits: Self.abortModeBits)
        registers.lr = currentInstructionAddress &+ 4
        cpsr.rawValue = (savedCPSR & ~Self.modeBitsMask & ~Self.itBitsMask) | Self.abortModeBits | Self.asyncAbortDisabledBit
        itState = 0
        cpsr.thumbState = false
        cpsr.irqDisabled = true

        cp15.write(coprocessor: 15, opc1: 0, crn: 6, crm: 0, opc2: 2, value: virtualAddress)
        cp15.write(coprocessor: 15, opc1: 0, crn: 5, crm: 0, opc2: 1, value: Self.dataFaultStatus(for: reason))

        registers.pc = exceptionVectorBaseAddress &+ 0x0C
        return true
    }

    /// A real ARMv7 Data Abort exception entry (ARM DDI 0406C B1.6.10,
    /// Table B1-7): banks SP/LR into Abort mode, saves the interrupted
    /// CPSR to SPSR_abt, sets `LR_abt = instructionAddress + 8` (the fixed
    /// Data Abort offset — unlike Prefetch Abort/IRQ, it doesn't vary by
    /// ARM/Thumb state), switches to ARM state with IRQs masked, and
    /// jumps to the Data-Abort vector. Real hardware would enter this
    /// exception for a page fault like this — the guest's own abort
    /// handler is what decides whether it's recoverable (e.g. faulting in
    /// a lazily-backed page) or a genuine panic, exactly as it would on
    /// real hardware. Only `.translationFault` (Podium's stand-in for
    /// every real MMU-detected reason a data access can abort — see that
    /// case's doc comment) is treated this way; the other
    /// `MemoryAccessError` cases represent gaps in Podium's own memory
    /// modeling, not something real hardware would raise this exception
    /// for, so those still halt honestly via `lastError`. Returns whether
    /// dispatch happened — false leaves the caller's own `lastError` halt
    /// in place, which happens if the MMU isn't even on yet (no real
    /// vector table can exist to jump to before the guest has set one up).
    func raiseDataAbort(_ error: MemoryAccessError, faultAddress: UInt32) -> Bool {
        guard case .translationFault(let virtualAddress, let reason, let isWrite) = error else { return false }
        guard mmuEnabled else { return false }

        // The faulting instruction re-executes on return, so SPSR gets the
        // IT state it started with (stepThumb has already advanced the
        // live copy past it).
        let savedCPSR = Self.cpsr(cpsr.rawValue, withITState: cpsr.thumbState ? currentInstructionITState : 0)
        let oldModeBits = savedCPSR & Self.modeBitsMask

        switchProcessorMode(from: oldModeBits, to: Self.abortModeBits)
        setSavedProgramStatus(savedCPSR, forModeBits: Self.abortModeBits)

        registers.lr = currentInstructionAddress &+ 8
        cpsr.rawValue = (savedCPSR & ~Self.modeBitsMask & ~Self.itBitsMask) | Self.abortModeBits | Self.asyncAbortDisabledBit
        itState = 0
        cpsr.thumbState = false
        cpsr.irqDisabled = true

        // DFAR/DFSR (CP15 c6/c5) — the guest's own abort handler reads
        // these to decide what faulted and why, exactly as it would read
        // real hardware's fault registers.
        cp15.write(coprocessor: 15, opc1: 0, crn: 6, crm: 0, opc2: 0, value: virtualAddress)
        cp15.write(coprocessor: 15, opc1: 0, crn: 5, crm: 0, opc2: 0, value: Self.dataFaultStatus(for: reason) | (isWrite ? Self.dfsrWriteNotReadBit : 0))

        registers.pc = exceptionVectorBaseAddress &+ 0x10
        return true
    }

    /// Maps a `TranslationFaultReason` to the real DFSR status-field
    /// encoding the guest's data-abort handler reads (ARM DDI 0406C Table
    /// B3-23, short-descriptor format). Domain is reported as 0, since
    /// Podium doesn't surface which domain faulted.
    private static func dataFaultStatus(for reason: TranslationFaultReason) -> UInt32 {
        switch reason {
        case .sectionTranslation: return 0b00101
        case .pageTranslation: return 0b00111
        case .domainFault(let isPage): return isPage ? 0b01011 : 0b01001
        case .permissionFault(let isPage): return isPage ? 0b01111 : 0b01101
        }
    }

    /// DFSR.WnR: the aborting access was a write.
    private static let dfsrWriteNotReadBit: UInt32 = 1 << 11

    // Not `private`: Thumb-2's coprocessor instructions reuse this exact
    // same field layout and semantics (see `ARMv7CPU+Thumb.swift`'s
    // `.coprocessorRegisterTransfer` case) — condition checking already
    // happened in the caller before this runs, in both states, so
    // there's real logic worth sharing here rather than duplicating.
    func executeCoprocessorRegisterTransfer(_ instr: CoprocessorRegisterTransferInstruction, instructionAddress: UInt32) {
        if executeVFPRegisterTransfer(instr) { return }
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
            if instr.coprocessor == 15, Self.cp15WriteAffectsTranslation(crn: instr.crn, opc2: instr.opc2) {
                flushTLB()
            }
        }
    }

    private func executeChangeProcessorState(_ instr: ChangeProcessorStateInstruction) {
        // A NOP in User mode (ARM DDI 0406C B9.3.2): unprivileged code
        // can't touch the masks or the mode.
        guard cpsr.rawValue & Self.modeBitsMask != Self.userModeBits else { return }
        if instr.affectsIRQ { cpsr.irqDisabled = !instr.enable }
        if instr.affectsFIQ { cpsr.fiqDisabled = !instr.enable }
        // Nothing raises an asynchronous abort, but the A bit itself is
        // real CPSR state (saved to SPSR and read back by MRS).
        if instr.affectsAbort {
            cpsr.rawValue = instr.enable ? cpsr.rawValue & ~Self.asyncAbortDisabledBit : cpsr.rawValue | Self.asyncAbortDisabledBit
        }

        // Real ARM boot code's per-mode-stack-setup idiom: `CPS #<mode>`
        // (mode-only) or `CPSID if, #<mode>` (masks + mode together) to
        // enter each exception mode just long enough to give it a real
        // `SP` via a following `LDR SP, =...` /`MOV SP, ...`, exactly like
        // `executeMoveToStatusRegister`'s `MSR CPSR_c` mode-change path.
        if instr.changesMode {
            let oldModeBits = cpsr.rawValue & Self.modeBitsMask
            cpsr.rawValue = (cpsr.rawValue & ~Self.modeBitsMask) | (instr.mode & Self.modeBitsMask)
            switchProcessorMode(from: oldModeBits, to: instr.mode & Self.modeBitsMask)
        }
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

    /// `VLD1`/`VST1` (multiple single elements). See
    /// `ElementLoadStoreInstruction`'s doc comment: each `D` register
    /// transfers as its 8 raw bytes in address order (the low/high-word
    /// split matches `LDRD`/`STRD`'s convention), with no deinterleave.
    private func executeElementLoadStore(_ instr: ElementLoadStoreInstruction) {
        let base = operandValue(for: instr.rn)
        var address = base
        do {
            // Through readData/writeData, which split a word that straddles
            // a page into per-byte translations: VLD1/VST1 of 8-bit elements
            // may sit at any alignment, and translating just a word's first
            // byte let its tail spill into whatever *physical* page came
            // next. Found as real cross-process corruption: a NEON memset's
            // `vst1.8 {d0-d3}, [ip]` two bytes before a page boundary zeroed
            // the first halfword of another process's private page — its
            // libsystem_kernel errno hook — which later sent that process
            // jumping into the middle of Thumb code as ARM.
            for offset in 0..<instr.registerCount {
                let register = instr.firstRegister + offset
                if instr.isLoad {
                    let low = try readData(address, width: 4)
                    let high = try readData(address &+ 4, width: 4)
                    neon[register] = UInt64(low) | (UInt64(high) << 32)
                } else {
                    let value = neon[register]
                    try writeData(UInt32(truncatingIfNeeded: value), address, width: 4)
                    try writeData(UInt32(truncatingIfNeeded: value >> 32), address &+ 4, width: 4)
                }
                address = address &+ 8
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
            return
        }

        switch instr.writeback {
        case .none: break
        case .byTransferSize: registers[instr.rn] = base &+ UInt32(instr.registerCount) * 8
        case .register(let rm): registers[instr.rn] = base &+ operandValue(for: rm)
        }
    }

    /// `VREV16`/`VREV32`/`VREV64`: reverses `elementBits`-wide elements
    /// within each `groupSize`-wide group, mechanically per ARM DDI
    /// 0406C A8.8.291–293 — see `VREVInstruction`'s doc comment.
    private func executeReverseElements(_ instr: VREVInstruction) {
        let groupBits: Int
        switch instr.groupSize {
        case .bits64: groupBits = 64
        case .bits32: groupBits = 32
        case .bits16: groupBits = 16
        }
        let elementBits = instr.elementBits
        let elementsPerGroup = groupBits / elementBits
        let groupsPerLane = 64 / groupBits
        let elementMask: UInt64 = elementBits == 64 ? .max : (UInt64(1) << elementBits) - 1

        let dCount = instr.isQuad ? 2 : 1
        let dd = instr.isQuad ? instr.vd * 2 : instr.vd
        let dm = instr.isQuad ? instr.vm * 2 : instr.vm
        for lane in 0..<dCount {
            let source = neon[dm + lane]
            var result: UInt64 = 0
            for group in 0..<groupsPerLane {
                for element in 0..<elementsPerGroup {
                    let sourceShift = group * groupBits + element * elementBits
                    let destinationElement = elementsPerGroup - 1 - element
                    let destinationShift = group * groupBits + destinationElement * elementBits
                    let value = (source >> sourceShift) & elementMask
                    result |= value << destinationShift
                }
            }
            neon[dd + lane] = result
        }
    }

    private func executeNEONModifiedImmediate(_ instr: NEONModifiedImmediateInstruction) {
        for d in instr.vd..<(instr.vd + (instr.isQuad ? 2 : 1)) {
            switch instr.operation {
            case .move: neon[d] = instr.imm64
            case .moveNot: neon[d] = ~instr.imm64
            case .orr: neon[d] |= instr.imm64
            case .bic: neon[d] &= ~instr.imm64
            }
        }
    }

    private func executeBitwiseExclusiveOr(_ instr: VEORInstruction) {
        if instr.isQuad {
            let dn = instr.vn * 2
            let dm = instr.vm * 2
            let dd = instr.vd * 2
            neon[dd] = neon[dn] ^ neon[dm]
            neon[dd + 1] = neon[dn + 1] ^ neon[dm + 1]
        } else {
            neon[instr.vd] = neon[instr.vn] ^ neon[instr.vm]
        }
    }

    private func executeBitwiseOr(_ instr: VORRInstruction) {
        if instr.isQuad {
            let dn = instr.vn * 2
            let dm = instr.vm * 2
            let dd = instr.vd * 2
            neon[dd] = neon[dn] | neon[dm]
            neon[dd + 1] = neon[dn + 1] | neon[dm + 1]
        } else {
            neon[instr.vd] = neon[instr.vn] | neon[instr.vm]
        }
    }

    private func executeIntegerAdd(_ instr: VADDInstruction) {
        let laneBits: Int
        switch instr.size {
        case .bits8: laneBits = 8
        case .bits16: laneBits = 16
        case .bits32: laneBits = 32
        case .bits64: laneBits = 64
        }
        let laneCount = 64 / laneBits
        let laneMask: UInt64 = laneBits == 64 ? .max : (UInt64(1) << laneBits) - 1

        let dCount = instr.isQuad ? 2 : 1
        let dd = instr.isQuad ? instr.vd * 2 : instr.vd
        let dn = instr.isQuad ? instr.vn * 2 : instr.vn
        let dm = instr.isQuad ? instr.vm * 2 : instr.vm
        for lane in 0..<dCount {
            let a = neon[dn + lane]
            let b = neon[dm + lane]
            var result: UInt64 = 0
            for element in 0..<laneCount {
                let offset = element * laneBits
                let sum = ((a >> offset) &+ (b >> offset)) & laneMask
                result |= sum << offset
            }
            neon[dd + lane] = result
        }
    }

    /// `VEXT`: extracts consecutive bytes starting at `byteOffset` from
    /// the logical concatenation of `Vn` (low) then `Vm` (high) — see
    /// `VEXTInstruction`'s doc comment.
    private func executeVectorExtract(_ instr: VEXTInstruction) {
        func bytes(of value: UInt64) -> [UInt8] {
            (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        func value(from slice: ArraySlice<UInt8>) -> UInt64 {
            var result: UInt64 = 0
            for (index, byte) in slice.enumerated() {
                result |= UInt64(byte) << (8 * index)
            }
            return result
        }

        let dCount = instr.isQuad ? 2 : 1
        let dn = instr.isQuad ? instr.vn * 2 : instr.vn
        let dm = instr.isQuad ? instr.vm * 2 : instr.vm
        let dd = instr.isQuad ? instr.vd * 2 : instr.vd

        var nBytes: [UInt8] = []
        var mBytes: [UInt8] = []
        for lane in 0..<dCount {
            nBytes += bytes(of: neon[dn + lane])
            mBytes += bytes(of: neon[dm + lane])
        }
        let concatenated = nBytes + mBytes
        let resultBytes = Array(concatenated[instr.byteOffset..<(instr.byteOffset + dCount * 8)])
        for lane in 0..<dCount {
            neon[dd + lane] = value(from: resultBytes[(lane * 8)..<(lane * 8 + 8)])
        }
    }

    /// `VSHL`/`VSHR` (immediate) — see
    /// `VectorShiftImmediateInstruction`'s doc comment.
    private func executeVectorShiftImmediate(_ instr: VectorShiftImmediateInstruction) {
        let laneMask: UInt64 = instr.elementBits == 64 ? .max : (UInt64(1) << instr.elementBits) - 1
        let laneCount = 64 / instr.elementBits
        let dCount = instr.isQuad ? 2 : 1
        let dd = instr.isQuad ? instr.vd * 2 : instr.vd
        let dm = instr.isQuad ? instr.vm * 2 : instr.vm

        for lane in 0..<dCount {
            let source = neon[dm + lane]
            var result: UInt64 = 0
            for element in 0..<laneCount {
                let offset = element * instr.elementBits
                let value = (source >> offset) & laneMask
                let shifted: UInt64
                switch instr.direction {
                case .left:
                    shifted = (value << instr.shiftAmount) & laneMask
                case .right:
                    if instr.unsigned {
                        shifted = value >> instr.shiftAmount
                    } else {
                        let signBitSet = value & (UInt64(1) << (instr.elementBits - 1)) != 0
                        let signExtended = signBitSet ? (value | ~laneMask) : value
                        let shiftedSigned = Int64(bitPattern: signExtended) >> instr.shiftAmount
                        shifted = UInt64(bitPattern: shiftedSigned) & laneMask
                    }
                }
                result |= shifted << offset
            }
            neon[dd + lane] = result
        }
    }

    /// `Shift()`'s rounding-shift-left helper (ARM DDI 0406C A8.8.316,
    /// used by `VRSHL`/`VRSHR`/friends): a non-negative `shiftAmount`
    /// shifts left with no rounding (nothing is lost); a negative one
    /// shifts right by its magnitude with a rounding constant added
    /// first, arithmetically for a signed element or logically for an
    /// unsigned one. A magnitude at or beyond `laneBits` shifts every
    /// value bit out, so the result is 0 (or, for the signed rounding
    /// path, the sign bit replicated) regardless of the operand.
    private static func roundingShiftLeft(_ element: UInt64, by shiftAmount: Int, laneBits: Int, unsigned: Bool) -> UInt64 {
        if shiftAmount >= 0 {
            guard shiftAmount < laneBits else { return 0 }
            return element << shiftAmount
        }

        let magnitude = -shiftAmount
        let roundConst: UInt64 = magnitude > 0 && magnitude <= 64 ? (UInt64(1) << (magnitude - 1)) : 0

        if unsigned {
            guard magnitude < 64 else { return 0 }
            let sum = element &+ roundConst
            return magnitude >= laneBits + 1 ? 0 : sum >> magnitude
        }

        let signExtended: Int64
        if laneBits >= 64 {
            signExtended = Int64(bitPattern: element)
        } else {
            let signBit = UInt64(1) << (laneBits - 1)
            signExtended = element & signBit != 0
                ? Int64(bitPattern: element | ~((UInt64(1) << laneBits) - 1))
                : Int64(bitPattern: element)
        }
        let sum = signExtended &+ Int64(bitPattern: roundConst)
        guard magnitude < 64 else { return sum < 0 ? UInt64.max : 0 }
        return UInt64(bitPattern: sum >> magnitude)
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

    /// See `MultiplyInstruction`'s doc comment.
    private func executeMultiply(_ instr: MultiplyInstruction) {
        let m = registers[instr.rm]
        let s = registers[instr.rs]

        guard instr.kind.isLong else {
            let product = m &* s
            let result: UInt32
            switch instr.kind {
            case .mla: result = product &+ registers[instr.ra]
            case .mls: result = registers[instr.ra] &- product
            default: result = product
            }
            registers[instr.rd] = result
            if instr.setFlags {
                cpsr.negative = result.bit(31)
                cpsr.zero = result == 0
            }
            return
        }

        let accumulator = UInt64(registers[instr.rd]) << 32 | UInt64(registers[instr.ra])
        let unsignedProduct = UInt64(m) &* UInt64(s)
        let signedProduct = UInt64(bitPattern: Int64(Int32(bitPattern: m)) &* Int64(Int32(bitPattern: s)))
        let result: UInt64
        switch instr.kind {
        case .umull: result = unsignedProduct
        case .umlal: result = unsignedProduct &+ accumulator
        case .smull: result = signedProduct
        case .smlal: result = signedProduct &+ accumulator
        default: result = unsignedProduct &+ UInt64(registers[instr.rd]) &+ UInt64(registers[instr.ra]) // UMAAL
        }
        registers[instr.ra] = UInt32(truncatingIfNeeded: result)
        registers[instr.rd] = UInt32(truncatingIfNeeded: result >> 32)
        if instr.setFlags {
            cpsr.negative = result >> 63 == 1
            cpsr.zero = result == 0
        }
    }

    private func executeClz(_ instr: ClzInstruction) {
        registers[instr.rd] = UInt32(registers[instr.rm].leadingZeroBitCount)
    }

    /// `LDREX`: a word load that also opens the local exclusive monitor
    /// on `address` — see `exclusiveMonitorAddress`.
    private func executeLoadExclusive(_ instr: LoadExclusiveInstruction) {
        let address = operandValue(for: instr.rn) &+ instr.offset
        do {
            let physicalAddress = try translatedAddress(address, access: .read)
            switch instr.size {
            case 1: registers[instr.rt] = UInt32(try memory.readByte(at: physicalAddress))
            case 2: registers[instr.rt] = UInt32(try memory.readWord16(at: physicalAddress))
            default: registers[instr.rt] = try memory.readWord32(at: physicalAddress)
            }
            exclusiveMonitorAddress = address
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    /// See `LoadExclusiveDoubleInstruction`'s doc comment. Little-endian:
    /// `Rt` gets the word at `[Rn]`, `Rt2` (`Rt+1`) gets `[Rn+4]` — the
    /// same low/high split every other doubleword transfer in this file
    /// uses.
    private func executeLoadExclusiveDouble(_ instr: LoadExclusiveDoubleInstruction) {
        let address = operandValue(for: instr.rn)
        do {
            let lowPhysicalAddress = try translatedAddress(address, access: .read)
            let highPhysicalAddress = try translatedAddress(address &+ 4, access: .read)
            registers[instr.rt] = try memory.readWord32(at: lowPhysicalAddress)
            registers[instr.rt2] = try memory.readWord32(at: highPhysicalAddress)
            exclusiveMonitorAddress = address
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    /// See `exclusiveMonitorAddress`: stores and reports 0 only if the
    /// monitor is still open on this address, otherwise reports 1.
    private func executeStoreExclusive(_ instr: StoreExclusiveInstruction) {
        let address = operandValue(for: instr.rn) &+ instr.offset
        guard takeExclusiveMonitor(for: address) else {
            registers[instr.rd] = 1
            return
        }
        do {
            let physicalAddress = try translatedAddress(address, access: .write)
            let value = registers[instr.rt]
            switch instr.size {
            case 1: try memory.writeByte(UInt8(truncatingIfNeeded: value), at: physicalAddress)
            case 2: try memory.writeWord16(UInt16(truncatingIfNeeded: value), at: physicalAddress)
            default: try memory.writeWord32(value, at: physicalAddress)
            }
            registers[instr.rd] = 0
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    /// See `StoreExclusiveDoubleInstruction`'s doc comment.
    private func executeStoreExclusiveDouble(_ instr: StoreExclusiveDoubleInstruction) {
        let address = operandValue(for: instr.rn)
        guard takeExclusiveMonitor(for: address) else {
            registers[instr.rd] = 1
            return
        }
        do {
            let lowPhysicalAddress = try translatedAddress(address, access: .write)
            let highPhysicalAddress = try translatedAddress(address &+ 4, access: .write)
            try memory.writeWord32(registers[instr.rt], at: lowPhysicalAddress)
            try memory.writeWord32(registers[instr.rt2], at: highPhysicalAddress)
            registers[instr.rd] = 0
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
        }
    }

    /// The local exclusive monitor (ARM DDI 0406C A3.4.1): `LDREX` opens
    /// it on an address, and `STREX` succeeds — storing and writing 0 —
    /// only if it's still open on that same address, closing it either
    /// way. `CLREX` closes it. This matters now that interrupts exist: an
    /// interrupt handler doing its own `LDREX`/`STREX` (and XNU's `CLREX`
    /// on exception entry) must make the interrupted thread's pending
    /// `STREX` fail so it retries, instead of silently overwriting the
    /// handler's update.
    var exclusiveMonitorAddress: UInt32?

    private func takeExclusiveMonitor(for address: UInt32) -> Bool {
        defer { exclusiveMonitorAddress = nil }
        return exclusiveMonitorAddress == address
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

        // S==1 writing r15 is an exception return on real hardware (ARM
        // DDI 0406C A2.6.7): CPSR is restored from the current mode's
        // SPSR instead of the flags being set from `result`. Only
        // meaningful outside User/System mode, which have no SPSR.
        let modeBitsBeforeWrite = cpsr.rawValue & Self.modeBitsMask
        let isExceptionReturn = instr.setFlags && instr.rd == Registers.pcIndex && !instr.op.isComparison
            && modeBitsBeforeWrite != Self.userModeBits && modeBitsBeforeWrite != Self.systemModeBits
            && savedProgramStatus(forModeBits: modeBitsBeforeWrite) != nil

        if instr.setFlags && !isExceptionReturn {
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
            if isExceptionReturn, let savedCPSR = savedProgramStatus(forModeBits: modeBitsBeforeWrite) {
                cpsr.rawValue = savedCPSR & ~Self.itBitsMask
                itState = Self.itState(fromCPSR: savedCPSR)
                switchProcessorMode(from: modeBitsBeforeWrite, to: cpsr.rawValue & Self.modeBitsMask)
                registers.pc = result
            } else {
                // ALUWritePC: on ARMv7, a data-processing instruction that
                // writes r15 interworks exactly like BX (checking bit 0),
                // not just a plain same-state jump.
                cpsr.thumbState = result.bit(0)
                registers.pc = result & ~UInt32(0b1)
            }
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
        if instr.link {
            // `registers.pc` already holds the address of the
            // instruction after this one (see `step()`) — exactly what
            // LR should hold, the same convention
            // `executeBranchLinkExchangeImmediate` uses.
            registers.lr = registers.pc
        }
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

        // `^`: with PC loaded it's an exception return; otherwise the
        // transfer uses the User-mode registers.
        let isExceptionReturn = instr.userRegisters && instr.isLoad && instr.registerList & (1 << Registers.pcIndex) != 0
        let usesUserBank = instr.userRegisters && !isExceptionReturn
        var loadedPC: UInt32?

        var address = startAddress
        do {
            for index in 0..<16 {
                guard (instr.registerList >> index) & 1 == 1 else { continue }
                let physicalAddress = try translatedAddress(address, access: instr.isLoad ? .read : .write)
                if instr.isLoad {
                    let value = try memory.readWord32(at: physicalAddress)
                    if index == Registers.pcIndex {
                        loadedPC = value
                    } else if usesUserBank {
                        setUserBankRegister(index, value)
                    } else {
                        registers[index] = value
                    }
                } else {
                    try memory.writeWord32(usesUserBank ? userBankRegister(index) : operandValue(for: index), at: physicalAddress)
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
            registers[instr.rn] = instr.addOffset ? baseValue &+ transferSize : baseValue &- transferSize
        }

        if let loadedPC {
            let currentMode = cpsr.rawValue & Self.modeBitsMask
            if isExceptionReturn, let spsr = savedProgramStatus(forModeBits: currentMode) {
                returnFromException(to: loadedPC, restoring: spsr)
            } else {
                // Real interworking, same as BX — see
                // `ARMv7CPU+Thumb.swift`'s `executeThumbBlockDataTransfer`
                // for the Thumb-side `LDM`-into-PC equivalent.
                cpsr.thumbState = loadedPC.bit(0)
                registers.pc = loadedPC & ~UInt32(0b1)
            }
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
            if instr.isLoad {
                let value = try readData(transferAddress, width: instr.isByte ? 1 : 4)
                if instr.rd == Registers.pcIndex {
                    // LDRWritePC: real interworking, same as BX.
                    cpsr.thumbState = value.bit(0)
                    registers.pc = value & ~UInt32(0b1)
                } else {
                    registers[instr.rd] = value
                }
            } else {
                try writeData(operandValue(for: instr.rd), transferAddress, width: instr.isByte ? 1 : 4)
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: transferAddress) { lastError = .memoryFault(memoryError, address: transferAddress) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(transferAddress), faultAddress: transferAddress) { lastError = .memoryFault(.unmappedAddress(transferAddress), address: transferAddress) }
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
            if instr.isLoad {
                let value: UInt32
                switch instr.kind {
                case .unsignedHalfword:
                    value = try readData(transferAddress, width: 2)
                case .signedByte:
                    value = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: try readData(transferAddress, width: 1))))
                case .signedHalfword:
                    value = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: try readData(transferAddress, width: 2))))
                }
                registers[instr.rd] = value
            } else {
                try writeData(operandValue(for: instr.rd), transferAddress, width: 2)
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: transferAddress) { lastError = .memoryFault(memoryError, address: transferAddress) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(transferAddress), faultAddress: transferAddress) { lastError = .memoryFault(.unmappedAddress(transferAddress), address: transferAddress) }
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

    /// `LDRD`/`STRD` (ARM state): transfers `Rt`/`Rt+1` to/from
    /// consecutive words. `rt2 = rt + 1` (never `PC`, per the real
    /// architecture's `Rt<0>==0` constraint — not separately checked
    /// here since no confirmed real word has violated it).
    private func executeLoadStoreDual(_ instr: LoadStoreDualInstruction) {
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
        let rt2 = instr.rt + 1

        do {
            let physicalAddress = try translatedAddress(transferAddress, access: instr.isLoad ? .read : .write)
            let secondAddress = transferAddress &+ 4
            let secondPhysicalAddress = try translatedAddress(secondAddress, access: instr.isLoad ? .read : .write)
            if instr.isLoad {
                registers[instr.rt] = try memory.readWord32(at: physicalAddress)
                registers[rt2] = try memory.readWord32(at: secondPhysicalAddress)
            } else {
                try memory.writeWord32(registers[instr.rt], at: physicalAddress)
                try memory.writeWord32(registers[rt2], at: secondPhysicalAddress)
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

    /// `Rn`'s value as an address base, where `Rn == PC` means the
    /// word-aligned PC as the executing instruction set sees it — the
    /// instruction's address + 8 in ARM state, + 4 in Thumb (a `VLDR`
    /// literal decoded through its ARM form still runs in Thumb state).
    private func addressBase(for rn: Int) -> UInt32 {
        guard rn == Registers.pcIndex else { return registers[rn] }
        return (currentInstructionAddress &+ (cpsr.thumbState ? 4 : 8)) & ~3
    }

    /// See `ExtensionRegisterLoadStoreInstruction`'s doc comment.
    private func executeExtensionRegisterLoadStore(_ instr: ExtensionRegisterLoadStoreInstruction) {
        let base = addressBase(for: instr.rn)
        let span = UInt32(instr.wordCount) * 4
        let startAddress: UInt32
        switch instr.addressing {
        case .offset(let offset, let add): startAddress = add ? base &+ offset : base &- offset
        case .incrementAfter: startAddress = base
        case .decrementBefore: startAddress = base &- span
        }

        var address = startAddress
        do {
            for index in instr.firstRegister..<(instr.firstRegister + instr.registerCount) {
                let access: ARMv7MMU.Access = instr.isLoad ? .read : .write
                let low = try translatedAddress(address, access: access)
                if instr.isDouble {
                    let high = try translatedAddress(address &+ 4, access: access)
                    if instr.isLoad {
                        neon[index] = UInt64(try memory.readWord32(at: low)) | UInt64(try memory.readWord32(at: high)) << 32
                    } else {
                        try memory.writeWord32(UInt32(truncatingIfNeeded: neon[index]), at: low)
                        try memory.writeWord32(UInt32(truncatingIfNeeded: neon[index] >> 32), at: high)
                    }
                    address = address &+ 8
                } else {
                    if instr.isLoad {
                        neon.setSingle(index, try memory.readWord32(at: low))
                    } else {
                        try memory.writeWord32(neon.single(index), at: low)
                    }
                    address = address &+ 4
                }
            }
        } catch let memoryError as MemoryAccessError {
            if !raiseDataAbort(memoryError, faultAddress: address) { lastError = .memoryFault(memoryError, address: address) }
            return
        } catch {
            if !raiseDataAbort(.unmappedAddress(address), faultAddress: address) { lastError = .memoryFault(.unmappedAddress(address), address: address) }
            return
        }

        switch instr.addressing {
        case .incrementAfter(writeback: true): registers[instr.rn] = base &+ span
        case .decrementBefore: registers[instr.rn] = base &- span
        default: break
        }
    }

    /// See `VFPTwoRegisterTransferInstruction`'s doc comment.
    private func executeVFPTwoRegisterTransfer(_ instr: VFPTwoRegisterTransferInstruction) {
        if instr.isDouble {
            if instr.toCore {
                registers[instr.rt] = UInt32(truncatingIfNeeded: neon[instr.extensionRegister])
                registers[instr.rt2] = UInt32(truncatingIfNeeded: neon[instr.extensionRegister] >> 32)
            } else {
                neon[instr.extensionRegister] = UInt64(registers[instr.rt]) | UInt64(registers[instr.rt2]) << 32
            }
        } else {
            if instr.toCore {
                registers[instr.rt] = neon.single(instr.extensionRegister)
                registers[instr.rt2] = neon.single(instr.extensionRegister + 1)
            } else {
                neon.setSingle(instr.extensionRegister, registers[instr.rt])
                neon.setSingle(instr.extensionRegister + 1, registers[instr.rt2])
            }
        }
    }
}
