import Foundation

/// What translators emit a block through: the assembler, plus the
/// conventions every block follows (see `DBTEngine`) — guest registers at
/// `x19`, the guest's NZCV in the host's, the TLB banks and ASID in fixed
/// registers, exits through the shared dispatcher and exit stubs.
///
/// Scratch registers: `w0`–`w8` and `x16`/`x17` for instruction
/// semantics; `x9`–`x12` belong to the memory-access sequence; `x13`/`x14`
/// to flag updates; `x15` to constants the assembler materializes.
struct BlockEmitter {
    typealias Label = A64Assembler.Label
    typealias H = DBTEngine.Host

    var a = A64Assembler()
    /// Where the block starts in the code region, and the shared stubs, as
    /// word offsets — branches out of the block are relative to these.
    let startWord: Int
    let dispatchWord: Int
    let dispatchLinkWord: Int
    let exitWord: Int
    let thumb: Bool
    /// The block's virtual page: exits to other addresses on it, in the
    /// same instruction set, can be chained (see `exit(to:thumb:executed:)`).
    let page: UInt32
    /// Word offsets, in the region, of this block's link slots.
    private(set) var linkSlots: [Int] = []

    /// Guest instructions emitted so far: while emitting instruction `i`,
    /// `count == i`.
    var count = 0
    /// What a plain read of r15 gives in the instruction being emitted —
    /// the interpreter's `registers[15]`, which by then holds the next
    /// instruction's address. Reads that see `Align(pc + 4)` or `pc + 8`
    /// instead use `read(_:guest:pcValue:)`.
    var pcRead: UInt32 = 0

    private enum Stub {
        /// Leave for the interpreter at `pc`, before the instruction there.
        case deopt(label: Label, pc: UInt32, itState: UInt8, executed: Int)
        /// Have the interpreter run the instruction at `pc`, then carry on
        /// at `resume` if it went on to `next`.
        case interpret(label: Label, pc: UInt32, next: UInt32, executed: Int, resume: Label)
        /// Continue at a known guest address.
        case jump(label: Label, pc: UInt32, thumb: Bool, executed: Int)
        /// Leave, with the context already describing the CPU (after an
        /// interpreted instruction that changed course).
        case leave(label: Label, executed: Int)
    }
    private var stubs: [Stub] = []
    /// Resume points of this instruction's slow paths, bound after it.
    private var pendingResumes: [Label] = []

    /// `counter`: debugging, a count the block adds one to each time
    /// it's entered.
    init(startWord: Int, dispatchWord: Int, dispatchLinkWord: Int, exitWord: Int, thumb: Bool, page: UInt32,
         counter: UnsafeMutablePointer<UInt64>? = nil) {
        self.startWord = startWord
        self.dispatchWord = dispatchWord
        self.dispatchLinkWord = dispatchLinkWord
        self.exitWord = exitWord
        self.thumb = thumb
        self.page = page
        if let counter {
            a.mov(x: 9, UInt64(UInt(bitPattern: counter)))
            a.ldr(x: 10, 9, offset: 0)
            a.add(x: 10, 10, imm: 1)
            a.str(x: 10, 9, offset: 0)
        }
    }

    private mutating func branch(toWord word: Int) {
        a.b(wordDelta: word - (startWord + a.position))
    }

    // MARK: Guest registers

    mutating func load(_ host: Int, guest: Int) {
        if guest == 15 { a.mov(w: host, pcRead) } else { a.ldr(w: host, H.registers, offset: guest * 4) }
    }

    mutating func store(guest: Int, _ host: Int) {
        precondition(guest != 15, "r15 writes are branches")
        a.str(w: host, H.registers, offset: guest * 4)
    }

    /// `host = guest`, where reading r15 gives `pcValue`.
    mutating func read(_ host: Int, guest: Int, pcValue: UInt32) {
        if guest == 15 { a.mov(w: host, pcValue) } else { load(host, guest: guest) }
    }

    mutating func constant(_ host: Int, _ value: UInt32) { a.mov(w: host, value) }

    // MARK: Flags

    enum Carry {
        case keep
        /// The new C is bit 0 of this host register.
        case register(Int)
        case constant(Bool)
    }

    /// N and Z from `result`, C as given, V unchanged — what the
    /// guest's logical operations do.
    mutating func setNZ(_ result: Int, carry: Carry) {
        a.mrsNZCV(x: 13)
        a.and(w: 13, 13, imm: 0x3000_0000, scratch: 15)
        switch carry {
        case .keep: break
        case .register(let r): a.bfi(w: 13, r, lsb: 29, width: 1)
        case .constant(true): a.orr(w: 13, 13, imm: 0x2000_0000, scratch: 15)
        case .constant(false): a.and(w: 13, 13, imm: 0x1000_0000, scratch: 15)
        }
        a.tst(w: result, result)
        a.mrsNZCV(x: 14)
        a.and(w: 14, 14, imm: 0xC000_0000, scratch: 15)
        a.orr(w: 14, 14, 13)
        a.msrNZCV(x: 14)
    }

    /// The guest's C flag, into bit 0 of `host`.
    mutating func carryFlag(into host: Int) {
        a.mrsNZCV(x: host)
        a.ubfx(w: host, host, lsb: 29, width: 1)
    }

    /// Saves the guest's NZCV around code that needs the host's flags.
    mutating func saveFlags() { a.mrsNZCV(x: 13) }
    mutating func restoreFlags() { a.msrNZCV(x: 13) }

    // MARK: Conditions

    /// Branches past what follows when `condition` fails (the caller binds
    /// the returned label after it); nil if it always holds.
    mutating func skipUnless(_ condition: ARMCondition) -> Label? {
        guard condition != .always else { return nil }
        let skip = a.newLabel()
        if condition == .never {
            a.b(skip)
        } else {
            a.b(A64Assembler.Condition(rawValue: UInt32(condition.rawValue))!.inverted, skip)
        }
        return skip
    }

    mutating func bind(_ label: Label?) {
        if let label { a.bind(label) }
    }

    // MARK: Leaving the block

    /// Where an instruction goes when it can't finish in translated code
    /// (its memory needs the interpreter): outside an IT block, the
    /// interpreter runs it and the block carries on after it; inside
    /// one, the block leaves for the interpreter at `pc` (with
    /// `itState`). The instruction mustn't have changed anything yet.
    mutating func slowPath(pc: UInt32, next: UInt32, itState: UInt8) -> Label {
        let label = a.newLabel()
        if itState == 0 {
            let resume = a.newLabel()
            pendingResumes.append(resume)
            stubs.append(.interpret(label: label, pc: pc, next: next, executed: count, resume: resume))
        } else {
            stubs.append(.deopt(label: label, pc: pc, itState: itState, executed: count))
        }
        return label
    }

    /// Binds the resume points of the slow paths made while emitting the
    /// current instruction; true if there were any.
    mutating func bindResumes() -> Bool {
        let any = !pendingResumes.isEmpty
        for label in pendingResumes { a.bind(label) }
        pendingResumes.removeAll()
        return any
    }

    /// Has the interpreter run the instruction at `pc` (one not
    /// translated), in line; the block leaves if it didn't simply go on
    /// to `next`.
    mutating func interpret(pc: UInt32, next: UInt32) {
        let leave = a.newLabel()
        stubs.append(.leave(label: leave, executed: count + 1))
        emitInterpretCall(pc: pc, next: next, executed: count, leave: leave)
    }

    private mutating func emitInterpretCall(pc: UInt32, next: UInt32, executed: Int, leave: Label) {
        let C = DBTEngine.Context.self
        a.mrsNZCV(x: 9)
        a.str(w: 9, H.context, offset: C.nzcv)
        a.mov(w: 9, pc)
        a.str(w: 9, H.registers, offset: 15 * 4)
        a.add(x: 9, H.retired, imm: UInt32(executed))
        a.str(x: 9, H.context, offset: C.retired)
        a.mov(x: 0, x: H.context)
        a.mov(w: 1, next)
        a.ldr(x: 16, H.context, offset: C.interpretHelper)
        a.blr(x: 16)
        a.ldr(w: 9, H.context, offset: C.nzcv)
        a.msrNZCV(x: 9)
        a.ldr(x: H.limit, H.context, offset: C.limit)
        a.cbnz(w: 0, leave)
    }

    /// Continues at `pc` once this instruction (included) has run.
    mutating func jump(to pc: UInt32, thumb: Bool) {
        exit(to: pc, thumb: thumb, executed: count + 1)
    }

    /// Leaves for a known guest address with `executed` instructions of
    /// the block run. On the block's own page and in its instruction set,
    /// through a link slot: a branch that goes on to the dispatcher until
    /// `DBTEngine.link` points it at the translation there, so the jump
    /// then costs a limit check (for device events and interrupts) rather
    /// than a lookup. Elsewhere the mapping could change without this
    /// block knowing, so those always go through the dispatcher.
    private mutating func exit(to pc: UInt32, thumb: Bool, executed: Int) {
        if executed > 0 { a.add(x: H.retired, H.retired, imm: UInt32(executed)) }
        guard pc & 0xFFFF_F000 == page, thumb == self.thumb else {
            a.mov(w: 0, pc)
            a.mov(w: 1, thumb ? 1 : 0)
            branch(toWord: dispatchWord)
            return
        }
        let unlinked = a.newLabel()
        a.sub(x: 9, H.limit, H.retired)
        a.cbz(x: 9, unlinked)
        a.tbnz(9, bit: 63, unlinked)
        let slot = startWord + a.position
        linkSlots.append(slot)
        a.b(unlinked) // the link slot: to the next instruction until linked
        a.bind(unlinked)
        a.mov(w: 0, pc)
        a.mov(w: 1, thumb ? 1 : 0)
        a.mov(w: 2, UInt32(slot))
        branch(toWord: dispatchLinkWord)
    }

    /// Like `jump(to:thumb:)`, from an out-of-line stub; for a branch
    /// that's taken while the block continues along the other path.
    mutating func jumpLabel(to pc: UInt32, thumb: Bool) -> Label {
        let label = a.newLabel()
        stubs.append(.jump(label: label, pc: pc, thumb: thumb, executed: count + 1))
        return label
    }

    /// Continues at the address in `w0` (bit 0 already clear) in the
    /// state in `w1` (0 ARM, 1 Thumb), once this instruction has run.
    mutating func jumpDynamic() {
        a.add(x: H.retired, H.retired, imm: UInt32(count + 1))
        branch(toWord: dispatchWord)
    }

    /// Ends the block before instruction `count` (at `pc`): the block's
    /// work so far is done, and the dispatcher takes it from `pc`.
    mutating func fallThrough(to pc: UInt32, thumb: Bool) {
        exit(to: pc, thumb: thumb, executed: count)
    }

    // MARK: Memory

    enum Access { case read, write }

    /// Finds guest `address` (a host W register) in host memory through
    /// the TLB: afterwards the bytes are at `[x10, x11]`. Branches to
    /// `deopt` when they can't be reached directly — a miss, a page
    /// that isn't plain RAM (or, for writes, holds translated code), or
    /// `width` bytes that run into the next page.
    mutating func locate(_ address: Int, width: Int, access: Access, deopt: Label) {
        let tags = access == .read ? H.readTags : H.writeTags
        let hosts = access == .read ? H.readHosts : H.writeHosts
        a.lsr(w: 9, address, 12)
        a.eor(w: 9, 9, H.asidMix)
        a.and(w: 9, 9, imm: UInt32(ARMv7CPU.tlbEntries - 1), scratch: 15)
        a.ldr(w: 10, tags, index: 9)
        a.and(w: 11, address, imm: 0xFFFF_F000, scratch: 15)
        a.orr(w: 11, 11, H.asidTag)
        a.eor(w: 10, 10, 11)
        a.cbnz(w: 10, deopt)
        a.ldr(x: 10, hosts, index: 9)
        a.cbz(x: 10, deopt)
        a.and(w: 11, address, imm: 0xFFF, scratch: 15)
        if width > 1 {
            a.add(w: 12, 11, imm: UInt32(width - 1))
            a.tbnz(12, bit: 12, deopt)
        }
    }

    /// `host` = the `width`-byte value at guest `address`, sign-extended
    /// if `signed`.
    mutating func loadMemory(_ host: Int, address: Int, width: Int, signed: Bool, deopt: Label) {
        locate(address, width: width, access: .read, deopt: deopt)
        switch (width, signed) {
        case (1, false): a.ldrb(w: host, 10, 11)
        case (1, true): a.ldrsb(w: host, 10, 11)
        case (2, false): a.ldrh(w: host, 10, 11)
        case (2, true): a.ldrsh(w: host, 10, 11)
        default: a.ldr(w: host, 10, 11)
        }
    }

    mutating func storeMemory(_ host: Int, address: Int, width: Int, deopt: Label) {
        locate(address, width: width, access: .write, deopt: deopt)
        switch width {
        case 1: a.strb(w: host, 10, 11)
        case 2: a.strh(w: host, 10, 11)
        default: a.str(w: host, 10, 11)
        }
    }

    /// For multi-word transfers: after this, `x10` points at guest
    /// `address` in host memory, all `width` bytes on one page.
    mutating func locateRun(_ address: Int, width: Int, access: Access, deopt: Label) {
        locate(address, width: width, access: access, deopt: deopt)
        a.add(x: 10, 10, 11)
    }

    // MARK: Exclusives and thread ID registers

    /// `LDREX{B,H,D}`: loads, and opens the monitor on the address.
    mutating func loadExclusive(rt: Int, rt2: Int?, rn: Int, offset: UInt32, size: Int, slow: Label) {
        let C = DBTEngine.Context.self
        load(1, guest: rn)
        a.add(w: 1, 1, anyImm: offset, scratch: 15)
        if let rt2 {
            locateRun(1, width: 8, access: .read, deopt: slow)
            a.ldr(w: 4, 10, offset: 0)
            a.ldr(w: 5, 10, offset: 4)
            store(guest: rt, 4)
            store(guest: rt2, 5)
        } else {
            loadMemory(0, address: 1, width: size, signed: false, deopt: slow)
            store(guest: rt, 0)
        }
        a.str(w: 1, H.context, offset: C.monitorAddress)
        a.mov(w: 9, 1)
        a.str(w: 9, H.context, offset: C.monitorValid)
    }

    /// `STREX{B,H,D}`: stores only if the monitor is open on the address,
    /// reporting 0 (stored) or 1 in `rd`; closes the monitor either way.
    mutating func storeExclusive(rd: Int, rt: Int, rt2: Int?, rn: Int, offset: UInt32, size: Int, slow: Label) {
        let C = DBTEngine.Context.self
        let fail = a.newLabel(), done = a.newLabel()
        load(1, guest: rn)
        a.add(w: 1, 1, anyImm: offset, scratch: 15)
        a.ldr(w: 9, H.context, offset: C.monitorValid)
        a.cbz(w: 9, fail)
        a.ldr(w: 9, H.context, offset: C.monitorAddress)
        a.eor(w: 9, 9, 1)
        a.cbnz(w: 9, fail)
        if let rt2 {
            locateRun(1, width: 8, access: .write, deopt: slow)
            load(4, guest: rt)
            load(5, guest: rt2)
            a.str(w: 4, 10, offset: 0)
            a.str(w: 5, 10, offset: 4)
        } else {
            load(0, guest: rt)
            storeMemory(0, address: 1, width: size, deopt: slow)
        }
        a.str(w: 31, H.context, offset: C.monitorValid)
        store(guest: rd, 31)
        a.b(done)
        a.bind(fail)
        a.str(w: 31, H.context, offset: C.monitorValid)
        a.mov(w: 2, 1)
        store(guest: rd, 2)
        a.bind(done)
    }

    mutating func clearExclusive() {
        a.str(w: 31, H.context, offset: DBTEngine.Context.monitorValid)
    }

    /// `MRC p15, 0, rt, c13, c0, opc2` for the thread ID registers
    /// (`opc2` 2...4); false for anything else.
    mutating func readThreadID(_ instruction: CoprocessorRegisterTransferInstruction) -> Bool {
        guard instruction.isLoad, instruction.coprocessor == 15, instruction.opc1 == 0, instruction.crn == 13,
              instruction.crm == 0, (2...4).contains(instruction.opc2), instruction.rt != 15 else { return false }
        a.ldr(w: 0, H.context, offset: DBTEngine.Context.threadID + (instruction.opc2 - 2) * 4)
        store(guest: instruction.rt, 0)
        return true
    }

    // MARK: VFP and Advanced SIMD registers

    /// Guest `S`, `D` and `Q` registers at their place beside the core
    /// ones (see `Registers.extensionOffset`); `v` a host vector register.
    /// A `Q` operand is named by its first `D` register (even).
    mutating func loadS(_ v: Int, _ s: Int) { a.ldr(s: v, H.registers, offset: Registers.extensionOffset + 4 * s) }
    mutating func storeS(_ s: Int, _ v: Int) { a.str(s: v, H.registers, offset: Registers.extensionOffset + 4 * s) }
    mutating func loadD(_ v: Int, _ d: Int) { a.ldr(d: v, H.registers, offset: Registers.extensionOffset + 8 * d) }
    mutating func storeD(_ d: Int, _ v: Int) { a.str(d: v, H.registers, offset: Registers.extensionOffset + 8 * d) }
    mutating func loadVector(_ v: Int, _ d: Int, quad: Bool) {
        if quad { a.ldr(q: v, H.registers, offset: Registers.extensionOffset + 8 * d) } else { loadD(v, d) }
    }
    mutating func storeVector(_ d: Int, _ v: Int, quad: Bool) {
        if quad { a.str(q: v, H.registers, offset: Registers.extensionOffset + 8 * d) } else { storeD(d, v) }
    }

    /// Whether this block has checked, before an earlier instruction, that
    /// translated VFP/Advanced SIMD code may run (see `requireVectorUnit`).
    private var vectorUnitChecked = false

    /// Before the block's first instruction that uses the VFP/Advanced
    /// SIMD unit: leaves for the interpreter at `pc` unless the unit is
    /// enabled and the guest's FPSCR is the standard one translated code
    /// assumes (`DBTEngine.Context.vectorReady`). Emitted ahead of the
    /// instruction's condition, so it covers the rest of the block —
    /// anything that could change either leaves the block first.
    mutating func requireVectorUnit(pc: UInt32, itState: UInt8) {
        guard !vectorUnitChecked else { return }
        vectorUnitChecked = true
        let leave = deopt(pc: pc, itState: itState)
        a.ldr(w: 9, H.context, offset: DBTEngine.Context.vectorReady)
        a.cbz(w: 9, leave)
    }

    /// A stub that leaves for the interpreter at `pc`, before the
    /// instruction there, whether or not it's in an IT block.
    mutating func deopt(pc: UInt32, itState: UInt8) -> Label {
        let label = a.newLabel()
        stubs.append(.deopt(label: label, pc: pc, itState: itState, executed: count))
        return label
    }

    // MARK: Native snippets

    /// See `DBTEngine.registerSnippet`: by address with the Thumb bit.
    var snippets: [UInt32: (index: Int, exit: UInt32)] = [:]

    /// Before the instruction at `pc`, where snippet `index` replaces the
    /// guest code up to `exit`: runs it, and goes on at `exit` if it did
    /// the work; otherwise falls through to the guest code's translation.
    /// The snippet counts as one instruction.
    mutating func callSnippet(_ index: Int, exit: UInt32, pc: UInt32) {
        let C = DBTEngine.Context.self
        let fallback = a.newLabel()
        a.mrsNZCV(x: 9)
        a.str(w: 9, H.context, offset: C.nzcv)
        a.mov(w: 9, pc)
        a.str(w: 9, H.registers, offset: 15 * 4)
        a.mov(x: 0, x: H.context)
        a.mov(w: 1, UInt32(index))
        a.ldr(x: 16, H.context, offset: C.snippetHelper)
        a.blr(x: 16)
        a.ldr(w: 9, H.context, offset: C.nzcv)
        a.msrNZCV(x: 9)
        a.cbz(w: 0, fallback)
        self.exit(to: exit, thumb: thumb, executed: count + 1)
        a.bind(fallback)
    }

    // MARK: Finishing

    mutating func finish() -> [UInt32] {
        for stub in stubs {
            switch stub {
            case .deopt(let label, let pc, let itState, let executed):
                a.bind(label)
                if executed > 0 { a.add(x: H.retired, H.retired, imm: UInt32(executed)) }
                a.mov(w: 0, pc)
                a.str(w: 0, H.registers, offset: 15 * 4)
                a.mov(w: 0, thumb ? 1 : 0)
                a.str(w: 0, H.context, offset: DBTEngine.Context.thumb)
                a.mov(w: 0, UInt32(itState))
                a.str(w: 0, H.context, offset: DBTEngine.Context.exitITState)
                a.mov(w: 0, 1)
                a.str(w: 0, H.context, offset: DBTEngine.Context.exitDeopt)
                branch(toWord: exitWord)
            case .interpret(let label, let pc, let next, let executed, let resume):
                a.bind(label)
                let leave = a.newLabel()
                emitInterpretCall(pc: pc, next: next, executed: executed, leave: leave)
                a.b(resume)
                a.bind(leave)
                a.add(x: H.retired, H.retired, imm: UInt32(executed + 1))
                branch(toWord: exitWord)
            case .leave(let label, let executed):
                a.bind(label)
                a.add(x: H.retired, H.retired, imm: UInt32(executed))
                branch(toWord: exitWord)
            case .jump(let label, let pc, let thumb, let executed):
                a.bind(label)
                exit(to: pc, thumb: thumb, executed: executed)
            }
        }
        return a.finalizedWords()
    }
}
