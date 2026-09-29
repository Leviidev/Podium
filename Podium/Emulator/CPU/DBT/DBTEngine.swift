import Foundation

/// A dynamic binary translator: guest ARMv7 code, compiled a block at a
/// time into AArch64 and run natively, several times faster than
/// interpreting it.
///
/// **Shape.** A block is a run of guest instructions from one entry
/// address to its first branch (or anything it doesn't translate), all on
/// one 4 KB page. Translated code keeps guest registers where the
/// interpreter does (`Registers.storage`) and the guest's NZCV in the
/// host's NZCV, so the two hand over with no copying beyond the flags.
/// Blocks end by jumping to a dispatcher, itself machine code, that finds
/// the next block through the CPU's instruction TLB and a direct-mapped
/// table, without returning to Swift; it returns only when the next block
/// isn't translated yet, a device is due (`nextDeviceEventAt`), or
/// something needs the interpreter.
///
/// **Memory.** Loads and stores look up the CPU's own software TLB inline
/// — the same entries the interpreter fills, extended with each page's
/// host address — and touch host memory directly. Anything else (a TLB
/// miss, a device register, a page holding translated code for a store, a
/// page-crossing access) "deopts": the block stops before that
/// instruction, with every earlier one's effects complete, and the
/// interpreter runs it, taking any fault exactly as it would anyway.
/// Instructions that touch several words check every page first, so they
/// never deopt halfway.
///
/// **Keys.** A block is found by its virtual address, Thumb state and
/// physical page together: its code embeds virtual addresses (return
/// addresses, PC-relative values), and the same physical page can be
/// mapped at different addresses in different processes (dyld's).
///
/// **Invalidation.** Pages that code was translated from are marked in a
/// bitmap the CPU checks on stores (translated stores to them deopt,
/// since the TLB withholds their host address for writes); a store to one
/// discards everything translated from it.
final class DBTEngine {
    /// Unretained, and without the checks `unowned` makes on every use —
    /// translated code calls back into the engine for every instruction
    /// it leaves to the interpreter. The CPU owns the engine.
    unowned(unsafe) let cpu: ARMv7CPU
    private let region: JITMemory

    // MARK: Context shared with generated code

    /// Byte offsets into `context`; the stubs below load these into fixed
    /// host registers.
    enum Context {
        static let registers = 0x00, nzcv = 0x08, thumb = 0x0C, retired = 0x10, limit = 0x18
        static let readTags = 0x20, readHosts = 0x28, writeTags = 0x30, writeHosts = 0x38
        static let executeTags = 0x40, executePages = 0x48, asidMix = 0x50, asidTag = 0x54
        static let table = 0x58, exitITState = 0x60, exitDeopt = 0x64
        static let engine = 0x68, interpretHelper = 0x70, exitReason = 0x78
        /// The exclusive monitor (valid flag, address), and the CP15 thread
        /// ID registers TPIDRURW/TPIDRURO/TPIDRPRW, mirrored from the CPU.
        static let monitorValid = 0x80, monitorAddress = 0x84
        static let threadID = 0x88
        /// Nonzero while translated VFP/Advanced SIMD code may run: the
        /// unit is enabled and FPSCR has the standard modes. See
        /// `BlockEmitter.requireVectorUnit`.
        static let vectorReady = 0x98
        static let size = 0x100
    }

    /// Host registers generated code relies on (x18 is the platform's).
    enum Host {
        static let registers = 19, context = 20, readTags = 21, readHosts = 22, writeTags = 23, writeHosts = 24
        static let retired = 25, limit = 26, asidMix = 27, asidTag = 28
    }

    let context: UnsafeMutableRawPointer
    /// Direct-mapped block table, `tableEntries` 16-byte entries: the
    /// virtual address with the Thumb bit (word 0), the physical page
    /// with bit 0 set (word 1), and the code's address (bytes 8...15).
    let table: UnsafeMutableRawPointer
    static let tableEntries = 1 << 16

    // MARK: Code region layout

    private var entryStub: UnsafeRawPointer!
    private var readFPCR: (@convention(c) () -> UInt64)!
    private var writeFPCR: (@convention(c) (UInt64) -> Void)!

    /// FPCR/FPSCR mode bits (DN, FZ, RMode) of the Advanced SIMD "standard
    /// FPSCR value": default NaN, flush to zero, round to nearest.
    static let standardFPCR: UInt64 = 0x0300_0000
    static let fpscrModeMask: UInt32 = 0x03C0_0000
    /// Word offsets of the shared stubs in the region.
    private(set) var dispatchWord = 0
    private(set) var exitWord = 0
    private var runtimeEnd = 0
    /// Bytes of the region in use.
    private var cursor = 0

    // MARK: Bookkeeping

    /// Every translation made since the last flush, by `key(virtual:thumb:page:)`;
    /// nil marks an address whose first instruction isn't translated.
    private var translations: [UInt64: UnsafeRawPointer?] = [:]
    /// The keys translated from each physical page, and at each virtual
    /// page.
    private var keysByPage: [UInt32: [UInt64]] = [:]
    private var keysByVirtualPage: [UInt32: [UInt64]] = [:]
    private let codePageBitmap: UnsafeMutablePointer<UInt64>
    private let ramBase: UInt32
    private let ramPages: Int

    struct Statistics {
        var blocksTranslated = 0
        var guestInstructionsTranslated = 0
        var entries = 0
        var flushes = 0
        var pagesInvalidated = 0
        var notTranslatedARM = 0
        var notTranslatedThumb = 0
        var deopts = 0
        var interpretedInPlace = 0
        /// 0 deopt or leave after an interpreted instruction, 1 limit,
        /// 2 instruction TLB miss, 3 block table miss.
        var exitReasons = [0, 0, 0, 0]
        /// Instructions the interpreter ran while translation was on
        /// (with `profileInterpreted`), by where they are: the physical
        /// address, the Thumb bit (bit 32) and why (bits 33...: 0 not
        /// translated, 1 deopt, 2 in place). See `interpretedKinds()`.
        var interpretedAt: [UInt64: Int] = [:]
    }
    private(set) var statistics = Statistics()

    /// Addresses (breakpoints, native functions) a block mustn't run
    /// through: execution has to come back to `ARMv7CPU.run` before them.
    private(set) var stopAddresses: Set<UInt32> = []

    init?(cpu: ARMv7CPU) {
        guard let region = JITMemory.shared, let ram = cpu.ramRange else { return nil }
        self.cpu = cpu
        self.region = region
        ramBase = ram.base
        ramPages = Int(ram.length >> 12)
        codePageBitmap = .allocate(capacity: (ramPages + 63) / 64)
        codePageBitmap.initialize(repeating: 0, count: (ramPages + 63) / 64)
        context = .allocate(byteCount: Context.size, alignment: 16)
        context.initializeMemory(as: UInt8.self, repeating: 0, count: Context.size)
        table = .allocate(byteCount: Self.tableEntries * 16, alignment: 16)
        table.initializeMemory(as: UInt8.self, repeating: 0, count: Self.tableEntries * 16)
        emitRuntime()
        context.storeBytes(of: UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())), toByteOffset: Context.engine, as: UInt64.self)
        context.storeBytes(of: UInt64(UInt(bitPattern: unsafeBitCast(Self.interpretHelper, to: UnsafeRawPointer.self))),
                           toByteOffset: Context.interpretHelper, as: UInt64.self)
        cpu.codePageBitmap = codePageBitmap
        cpu.codeWriteObserver = self
        cpu.hostFPCR = (readFPCR, writeFPCR)
    }

    deinit {
        codePageBitmap.deallocate()
        context.deallocate()
        table.deallocate()
    }

    // MARK: Runtime stubs

    /// The entry stub (`(context, code) -> Void`, C convention), the
    /// dispatcher (next guest pc in w0, Thumb bit in w1), and the exit.
    private func emitRuntime() {
        var a = A64Assembler()
        let C = Context.self, H = Host.self
        // Entry.
        a.stpPreIndex(x: 29, 30, sp: -96)
        a.stp(x: 19, 20, 31, offset: 16)
        a.stp(x: 21, 22, 31, offset: 32)
        a.stp(x: 23, 24, 31, offset: 48)
        a.stp(x: 25, 26, 31, offset: 64)
        a.stp(x: 27, 28, 31, offset: 80)
        a.add(x: 29, 31, imm: 0)                        // mov x29, sp
        a.mov(x: H.context, x: 0)
        a.ldr(x: H.registers, H.context, offset: C.registers)
        a.ldr(x: H.readTags, H.context, offset: C.readTags)
        a.ldr(x: H.readHosts, H.context, offset: C.readHosts)
        a.ldr(x: H.writeTags, H.context, offset: C.writeTags)
        a.ldr(x: H.writeHosts, H.context, offset: C.writeHosts)
        a.ldr(x: H.retired, H.context, offset: C.retired)
        a.ldr(x: H.limit, H.context, offset: C.limit)
        a.ldr(w: H.asidMix, H.context, offset: C.asidMix)
        a.ldr(w: H.asidTag, H.context, offset: C.asidTag)
        a.ldr(w: 9, H.context, offset: C.nzcv)
        a.msrNZCV(x: 9)
        // Floating point in the standard modes (see `VectorTranslator`),
        // left that way for the thread: switching costs more than the
        // rest of an entry.
        let modesSet = a.newLabel()
        a.mrsFPCR(x: 9)
        a.movz(x: 10, UInt16(Self.standardFPCR >> 16), shift: 16)
        a.eor(x: 11, 9, 10)
        a.cbz(x: 11, modesSet)
        a.msrFPCR(x: 10)
        a.bind(modesSet)
        a.br(x: 1)

        // Dispatch: w0 = guest pc, w1 = Thumb (0/1). Never touches NZCV.
        dispatchWord = a.position
        let exit = a.newLabel()
        let exitLimit = a.newLabel(), exitTLB = a.newLabel(), exitTable = a.newLabel()
        a.str(w: 0, H.registers, offset: 15 * 4)
        a.str(w: 1, H.context, offset: C.thumb)
        a.str(w: 31, H.context, offset: C.exitITState)
        a.str(w: 31, H.context, offset: C.exitDeopt)
        a.sub(x: 9, H.limit, H.retired)
        a.cbz(x: 9, exitLimit)
        a.tbnz(9, bit: 63, exitLimit)
        a.lsr(w: 9, 0, 12)
        a.eor(w: 9, 9, H.asidMix)
        a.and(w: 9, 9, imm: UInt32(ARMv7CPU.tlbEntries - 1), scratch: 15)
        a.ldr(x: 10, H.context, offset: C.executeTags)
        a.ldr(w: 11, 10, index: 9)
        a.and(w: 12, 0, imm: 0xFFFF_F000, scratch: 15)
        a.orr(w: 12, 12, H.asidTag)
        a.eor(w: 11, 11, 12)
        a.cbnz(w: 11, exitTLB)
        a.ldr(x: 10, H.context, offset: C.executePages)
        a.ldr(w: 11, 10, index: 9)
        a.orr(w: 11, 11, imm: 1, scratch: 15)
        a.orr(w: 12, 0, 1)
        a.eor(w: 13, 12, 12, .lsr, 15)
        a.and(w: 13, 13, imm: UInt32(Self.tableEntries - 1), scratch: 15)
        a.ldr(x: 10, H.context, offset: C.table)
        a.add(x: 10, 10, 13, lsl: 4)
        a.ldr(x: 14, 10, offset: 0)
        a.orr(x: 12, 12, 11, lsl: 32)
        a.eor(x: 14, 14, 12)
        a.cbnz(x: 14, exitTable)
        a.ldr(x: 14, 10, offset: 8)
        a.br(x: 14)
        for (label, reason) in [(exitLimit, 1), (exitTLB, 2), (exitTable, 3)] {
            a.bind(label)
            a.mov(w: 9, UInt32(reason))
            a.str(w: 9, H.context, offset: C.exitReason)
            a.b(exit)
        }

        // Exit.
        a.bind(exit)
        exitWord = a.position
        a.mrsNZCV(x: 9)
        a.str(w: 9, H.context, offset: C.nzcv)
        a.str(x: H.retired, H.context, offset: C.retired)
        a.ldp(x: 27, 28, 31, offset: 80)
        a.ldp(x: 25, 26, 31, offset: 64)
        a.ldp(x: 23, 24, 31, offset: 48)
        a.ldp(x: 21, 22, 31, offset: 32)
        a.ldp(x: 19, 20, 31, offset: 16)
        a.ldpPostIndex(x: 29, 30, sp: 96)
        a.ret()

        // For the interpreter (`ARMv7CPU.hostFPCR`).
        let readFPCRWord = a.position
        a.mrsFPCR(x: 0)
        a.ret()
        let writeFPCRWord = a.position
        a.msrFPCR(x: 0)
        a.ret()

        let words = a.finalizedWords()
        write(words, at: 0)
        entryStub = UnsafeRawPointer(region.executable)
        readFPCR = unsafeBitCast(region.executable + readFPCRWord * 4, to: (@convention(c) () -> UInt64).self)
        writeFPCR = unsafeBitCast(region.executable + writeFPCRWord * 4, to: (@convention(c) (UInt64) -> Void).self)
        runtimeEnd = (words.count * 4 + 63) & ~63
        cursor = runtimeEnd
    }

    private func write(_ words: [UInt32], at offset: Int) {
        region.write(at: offset, length: words.count * 4) { base in
            words.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
    }

    // MARK: Keys and the table

    @inline(__always)
    private static func key(virtual: UInt32, thumb: Bool, page: UInt32) -> UInt64 {
        UInt64(virtual | (thumb ? 1 : 0)) | UInt64(page | 1) << 32
    }

    @inline(__always)
    private static func tableIndex(_ virtualKey: UInt32) -> Int {
        Int((virtualKey ^ (virtualKey >> 15)) & UInt32(tableEntries - 1))
    }

    private func install(_ key: UInt64, code: UnsafeRawPointer) {
        let entry = table + Self.tableIndex(UInt32(truncatingIfNeeded: key)) * 16
        entry.storeBytes(of: key, as: UInt64.self)
        entry.storeBytes(of: UInt64(UInt(bitPattern: code)), toByteOffset: 8, as: UInt64.self)
    }

    private func uninstall(_ key: UInt64) {
        let entry = table + Self.tableIndex(UInt32(truncatingIfNeeded: key)) * 16
        if entry.load(as: UInt64.self) == key { entry.storeBytes(of: 0, as: UInt64.self) }
    }

    // MARK: Running

    enum RunResult {
        /// Nothing translated at the pc: interpret.
        case notTranslated
        /// Translated code ran up to a block it couldn't continue into.
        case ran
        /// Translated code stopped before an instruction the interpreter
        /// has to run (a TLB miss, a device, ...): interpret it next.
        case deopted
    }

    /// Runs translated code from the CPU's current pc, if any is (or can
    /// be) translated there.
    func run(budget: UInt64) -> RunResult {
        let pc = cpu.registers.pc
        let thumb = cpu.cpsr.thumbState
        guard !stopAddresses.contains(pc), let code = code(at: pc, thumb: thumb) else {
            if thumb { statistics.notTranslatedThumb += 1 } else { statistics.notTranslatedARM += 1 }
            if Self.profileInterpreted { noteInterpreted(pc: pc, thumb: thumb, reason: 0) }
            return .notTranslated
        }

        let user = cpu.cpsr.rawValue & ARMv7CPU.modeBitsMask == ARMv7CPU.userModeBits
        let bank = ARMv7CPU.tlbEntries
        let privilege = user ? 1 : 0
        let asid = cpu.cp15.contextID & 0xFF
        let deviceLimit = cpu.nextDeviceEventAt == .max ? UInt64.max : cpu.nextDeviceEventAt &- cpu.idleInstructionsSkipped
        let limit = min(deviceLimit, cpu.retiredInstructionCount &+ budget)
        let C = Context.self
        context.storeBytes(of: UInt64(UInt(bitPattern: cpu.registers.storage)), toByteOffset: C.registers, as: UInt64.self)
        context.storeBytes(of: cpu.cpsr.rawValue & 0xF000_0000, toByteOffset: C.nzcv, as: UInt32.self)
        context.storeBytes(of: thumb ? 1 : 0, toByteOffset: C.thumb, as: UInt32.self)
        context.storeBytes(of: cpu.retiredInstructionCount, toByteOffset: C.retired, as: UInt64.self)
        context.storeBytes(of: limit, toByteOffset: C.limit, as: UInt64.self)
        func tags(_ kind: Int) -> UInt64 { UInt64(UInt(bitPattern: cpu.tlbTags + (kind + privilege) * bank)) }
        func hosts(_ kind: Int) -> UInt64 { UInt64(UInt(bitPattern: UnsafeRawPointer(cpu.tlbHosts + (kind + privilege) * bank))) }
        context.storeBytes(of: tags(0), toByteOffset: C.readTags, as: UInt64.self)
        context.storeBytes(of: hosts(0), toByteOffset: C.readHosts, as: UInt64.self)
        context.storeBytes(of: tags(2), toByteOffset: C.writeTags, as: UInt64.self)
        context.storeBytes(of: hosts(2), toByteOffset: C.writeHosts, as: UInt64.self)
        context.storeBytes(of: tags(4), toByteOffset: C.executeTags, as: UInt64.self)
        context.storeBytes(of: UInt64(UInt(bitPattern: cpu.tlbPages + (4 + privilege) * bank)), toByteOffset: C.executePages, as: UInt64.self)
        context.storeBytes(of: (asid &* 0x9E37_79B1) >> 20, toByteOffset: C.asidMix, as: UInt32.self)
        context.storeBytes(of: asid << 1 | 1, toByteOffset: C.asidTag, as: UInt32.self)
        context.storeBytes(of: UInt64(UInt(bitPattern: table)), toByteOffset: C.table, as: UInt64.self)
        syncIn()
        context.storeBytes(of: 0, toByteOffset: C.exitITState, as: UInt32.self)
        context.storeBytes(of: 0, toByteOffset: C.exitDeopt, as: UInt32.self)
        context.storeBytes(of: 0, toByteOffset: C.exitReason, as: UInt32.self)

        typealias Entry = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
        unsafeBitCast(entryStub, to: Entry.self)(context, code)
        statistics.entries += 1

        statistics.exitReasons[Int(context.load(fromByteOffset: C.exitReason, as: UInt32.self) & 3)] += 1
        syncOut()
        let nzcv = context.load(fromByteOffset: C.nzcv, as: UInt32.self)
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & 0x0FFF_FFFF) | (nzcv & 0xF000_0000)
        cpu.cpsr.thumbState = context.load(fromByteOffset: C.thumb, as: UInt32.self) != 0
        cpu.itState = UInt8(truncatingIfNeeded: context.load(fromByteOffset: C.exitITState, as: UInt32.self))
        cpu.retiredInstructionCount = context.load(fromByteOffset: C.retired, as: UInt64.self)
        if context.load(fromByteOffset: C.exitDeopt, as: UInt32.self) != 0 {
            statistics.deopts += 1
            if Self.profileInterpreted { noteInterpreted(pc: cpu.registers.pc, thumb: cpu.cpsr.thumbState, reason: 1) }
            return .deopted
        }
        return .ran
    }

    // MARK: State mirrored in the context

    /// The exclusive monitor, the thread ID registers and whether vector
    /// code may run, into the context.
    private func syncIn() {
        let C = Context.self
        context.storeBytes(of: cpu.exclusiveMonitorAddress == nil ? 0 : 1, toByteOffset: C.monitorValid, as: UInt32.self)
        context.storeBytes(of: cpu.exclusiveMonitorAddress ?? 0, toByteOffset: C.monitorAddress, as: UInt32.self)
        let vectorReady = cpu.fpexc & ARMv7CPU.fpexcEnableBit != 0 && cpu.fpscr & Self.fpscrModeMask == UInt32(Self.standardFPCR)
        context.storeBytes(of: vectorReady ? 1 : 0, toByteOffset: C.vectorReady, as: UInt32.self)
        let threadIDs = cpu.cp15.threadIDs
        context.storeBytes(of: threadIDs.0, toByteOffset: C.threadID, as: UInt32.self)
        context.storeBytes(of: threadIDs.1, toByteOffset: C.threadID + 4, as: UInt32.self)
        context.storeBytes(of: threadIDs.2, toByteOffset: C.threadID + 8, as: UInt32.self)
    }

    /// The exclusive monitor, back to the CPU (translated code never
    /// writes the thread ID registers).
    private func syncOut() {
        let C = Context.self
        cpu.exclusiveMonitorAddress = context.load(fromByteOffset: C.monitorValid, as: UInt32.self) != 0
            ? context.load(fromByteOffset: C.monitorAddress, as: UInt32.self) : nil
    }

    // MARK: Interpreting in place

    /// Called from translated code to have the interpreter run the
    /// instruction at the guest pc (one the translator doesn't handle, or
    /// one whose memory access needs the interpreter), with the context's
    /// NZCV and retired count. Returns 0 if the block can carry on
    /// (execution continued at `expectedNext` in the same state), 1 if it
    /// has to leave — the context then describes where the CPU is.
    static let interpretHelper: @convention(c) (UnsafeMutableRawPointer, UInt32) -> UInt32 = { context, expectedNext in
        let engine = Unmanaged<DBTEngine>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(context.load(fromByteOffset: Context.engine, as: UInt64.self)))!)
            .takeUnretainedValue()
        return engine.interpretInPlace(expectedNext: expectedNext)
    }

    private func interpretInPlace(expectedNext: UInt32) -> UInt32 {
        let C = Context.self
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & 0x0FFF_FFFF) | (context.load(fromByteOffset: C.nzcv, as: UInt32.self) & 0xF000_0000)
        // Translated code only brings the CPU's T bit up to date when it
        // leaves; the current block's state is the dispatcher's.
        cpu.cpsr.thumbState = context.load(fromByteOffset: C.thumb, as: UInt32.self) != 0
        cpu.retiredInstructionCount = context.load(fromByteOffset: C.retired, as: UInt64.self)
        let stateBefore = cpu.cpsr.rawValue & 0x3F
        let translationBefore = (cpu.cp15.sctlr, cpu.cp15.ttbr0, cpu.cp15.ttbr1, cpu.cp15.ttbcr, cpu.cp15.dacr, cpu.cp15.contextID)
        let tlbGeneration = cpu.tlbGeneration
        let vectorReadyBefore = context.load(fromByteOffset: C.vectorReady, as: UInt32.self)
        syncOut()
        if Self.profileInterpreted { noteInterpreted(pc: cpu.registers.pc, thumb: cpu.cpsr.thumbState, reason: 2) }
        cpu.step()
        syncIn()
        statistics.interpretedInPlace += 1
        context.storeBytes(of: cpu.cpsr.rawValue & 0xF000_0000, toByteOffset: C.nzcv, as: UInt32.self)
        context.storeBytes(of: cpu.cpsr.thumbState ? 1 : 0, toByteOffset: C.thumb, as: UInt32.self)
        context.storeBytes(of: UInt32(cpu.itState), toByteOffset: C.exitITState, as: UInt32.self)
        context.storeBytes(of: 0, toByteOffset: C.exitDeopt, as: UInt32.self)
        // Devices due sooner (WFI skipped time), or an interrupt now
        // wanted: leave at the next dispatch.
        var limit = context.load(fromByteOffset: C.limit, as: UInt64.self)
        if cpu.nextDeviceEventAt != .max { limit = min(limit, cpu.nextDeviceEventAt &- cpu.idleInstructionsSkipped) }
        if (cpu.irqAsserted && !cpu.cpsr.irqDisabled) || (cpu.fiqAsserted && !cpu.cpsr.fiqDisabled) || cpu.idleBlocked { limit = 0 }
        context.storeBytes(of: limit, toByteOffset: C.limit, as: UInt64.self)
        let translationAfter = (cpu.cp15.sctlr, cpu.cp15.ttbr0, cpu.cp15.ttbr1, cpu.cp15.ttbcr, cpu.cp15.dacr, cpu.cp15.contextID)
        let carryOn = cpu.lastError == nil && cpu.itState == 0 && cpu.cpsr.rawValue & 0x3F == stateBefore
            && cpu.registers.pc == expectedNext && translationBefore == translationAfter && cpu.tlbGeneration == tlbGeneration
            && !cpu.idleBlocked && context.load(fromByteOffset: C.vectorReady, as: UInt32.self) == vectorReadyBefore
        return carryOn ? 0 : 1
    }

    /// Debugging: tally what the interpreter runs instead.
    static var profileInterpreted = false

    private func noteInterpreted(pc: UInt32, thumb: Bool, reason: UInt64) {
        guard let physical = try? cpu.translatedAddress(pc, access: .execute) else { return }
        statistics.interpretedAt[UInt64(physical) | (thumb ? 1 << 32 : 0) | reason << 33, default: 0] += 1
    }

    /// `statistics.interpretedAt` by the kind of instruction (its decoded
    /// case name, prefixed with why it was interpreted), decoding each
    /// address as it is now.
    func interpretedKinds(_ counts: [UInt64: Int]) -> [String: Int] {
        var kinds: [String: Int] = [:]
        for (key, count) in counts {
            let physical = UInt32(truncatingIfNeeded: key), thumb = key >> 32 & 1 != 0
            guard let page = ramHost(physical & 0xFFFF_F000) else { continue }
            let offset = Int(physical & 0xFFF)
            let name: String
            if thumb {
                let hw0 = page.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                let hw1: UInt16 = offset <= 0xFFC ? page.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self) : 0
                name = "T " + String("\(ThumbDecoder.decode(hw0, hw1))".prefix { $0 != "(" })
            } else {
                name = "A " + String("\(ARMDecoder.decode(page.loadUnaligned(fromByteOffset: offset & ~3, as: UInt32.self)))".prefix { $0 != "(" })
            }
            kinds[["", "deopt ", "in place "][Int(key >> 33 & 3)] + name, default: 0] += count
        }
        return kinds
    }

    /// The translated code for the block at virtual `pc`, translating it
    /// now if need be; nil if its first instruction isn't translated (or
    /// it can't be fetched — the interpreter takes that prefetch abort).
    private func code(at pc: UInt32, thumb: Bool) -> UnsafeRawPointer? {
        guard let physical = try? cpu.translatedAddress(pc, access: .execute) else { return nil }
        let page = physical & 0xFFFF_F000
        let key = Self.key(virtual: pc, thumb: thumb, page: page)
        let entry = table + Self.tableIndex(UInt32(truncatingIfNeeded: key)) * 16
        if entry.load(as: UInt64.self) == key {
            return UnsafeRawPointer(bitPattern: UInt(entry.load(fromByteOffset: 8, as: UInt64.self)))
        }
        if let known = translations[key] {
            if let known { install(key, code: known) }
            return known
        }
        guard let pageHost = ramHost(page) else {
            translations[key] = .some(nil)
            return nil
        }
        let code = translate(virtual: pc, physical: physical, thumb: thumb, page: UnsafeRawPointer(pageHost))
        translations[key] = code
        keysByPage[page, default: []].append(key)
        keysByVirtualPage[pc & 0xFFFF_F000, default: []].append(key)
        if let code { install(key, code: code) }
        return code
    }

    private func ramHost(_ physicalPage: UInt32) -> UnsafeMutableRawPointer? {
        cpu.hostAddress(ofPhysicalRAM: physicalPage)
    }

    /// Debugging: translate at most this many blocks (everything after
    /// runs interpreted), and report each one translated.
    static var translationLimit = Int.max
    static var reportTranslation: ((UInt32, Bool, Int) -> Void)?

    private func translate(virtual: UInt32, physical: UInt32, thumb: Bool, page: UnsafeRawPointer) -> UnsafeRawPointer? {
        guard statistics.blocksTranslated < Self.translationLimit else { return nil }
        let startWord = cursor / 4
        var emitter = BlockEmitter(startWord: startWord, dispatchWord: dispatchWord, exitWord: exitWord, thumb: thumb)
        let translated: Int
        if thumb {
            translated = ThumbTranslator.translate(into: &emitter, virtual: virtual, page: page, stopAddresses: stopAddresses)
        } else {
            translated = ARMTranslator.translate(into: &emitter, virtual: virtual, page: page, stopAddresses: stopAddresses)
        }
        guard translated > 0 else { return nil }
        let words = emitter.finish()
        if cursor + words.count * 4 > region.size {
            flush()
            return translate(virtual: virtual, physical: physical, thumb: thumb, page: page)
        }
        markCodePage(physical & 0xFFFF_F000)
        write(words, at: cursor)
        let code = UnsafeRawPointer(region.executable + cursor)
        cursor = (cursor + words.count * 4 + 15) & ~15
        statistics.blocksTranslated += 1
        statistics.guestInstructionsTranslated += translated
        Self.reportTranslation?(virtual, thumb, translated)
        return code
    }

    // MARK: Invalidation

    private func markCodePage(_ page: UInt32) {
        let index = Int((page &- ramBase) >> 12)
        guard index >= 0, index < ramPages else { return }
        let bit = UInt64(1) << UInt64(index & 63)
        guard codePageBitmap[index >> 6] & bit == 0 else { return }
        codePageBitmap[index >> 6] |= bit
        cpu.withholdWriteHosts(forPhysicalPage: page)
    }

    /// A store changed a page code was translated from: forget it all.
    func codeWasWritten(physicalPage page: UInt32) {
        let index = Int((page &- ramBase) >> 12)
        guard index >= 0, index < ramPages else { return }
        codePageBitmap[index >> 6] &= ~(UInt64(1) << UInt64(index & 63))
        for key in keysByPage.removeValue(forKey: page) ?? [] {
            uninstall(key)
            translations[key] = nil
        }
        cpu.restoreWriteHosts(forPhysicalPage: page)
        statistics.pagesInvalidated += 1
    }

    /// Discards every translation (the region is full, or the addresses
    /// blocks must stop at changed).
    func flush() {
        table.initializeMemory(as: UInt8.self, repeating: 0, count: Self.tableEntries * 16)
        translations.removeAll(keepingCapacity: true)
        keysByPage.removeAll(keepingCapacity: true)
        keysByVirtualPage.removeAll(keepingCapacity: true)
        codePageBitmap.update(repeating: 0, count: (ramPages + 63) / 64)
        cpu.flushTLB()
        cursor = runtimeEnd
        statistics.flushes += 1
    }

    /// Breakpoints and native functions: blocks never contain them past
    /// their first instruction, and never start at them.
    func setStopAddresses(_ addresses: Set<UInt32>) {
        guard addresses != stopAddresses else { return }
        let added = addresses.subtracting(stopAddresses)
        stopAddresses = addresses
        // Blocks that run through a new stop address: everything
        // translated at its virtual page (a removed one only means blocks
        // stop early where they needn't).
        for page in Set(added.map { $0 & 0xFFFF_F000 }) {
            for key in keysByVirtualPage.removeValue(forKey: page) ?? [] {
                uninstall(key)
                translations[key] = nil
            }
        }
    }
}
