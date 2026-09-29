import Foundation

/// An AArch64 code buffer with the instruction encodings the binary
/// translator emits, and labels for forward and backward branches.
///
/// Register numbers are 0...31; 31 means the zero register (`wzr`/`xzr`)
/// or `sp`, as each instruction's encoding defines. `W` forms operate on
/// the low 32 bits and zero the upper half, the natural width for guest
/// ARMv7 values; `X` forms are 64-bit, for host pointers.
struct A64Assembler {
    struct Label: Hashable { fileprivate let id: Int }

    enum Condition: UInt32 {
        case eq = 0, ne, hs, lo, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al
        var inverted: Condition { Condition(rawValue: rawValue ^ 1)! }
    }

    enum Shift: UInt32 { case lsl = 0, lsr, asr, ror }

    private(set) var words: [UInt32] = []
    private var labelOffsets: [Int?] = []
    /// (instruction index, label, kind) awaiting the label's position.
    private var fixups: [(index: Int, label: Label, kind: FixupKind)] = []
    private enum FixupKind { case branch26, branch19, branch14 }

    var count: Int { words.count }

    mutating func emit(_ word: UInt32) { words.append(word) }

    // MARK: Labels

    mutating func newLabel() -> Label {
        labelOffsets.append(nil)
        return Label(id: labelOffsets.count - 1)
    }

    mutating func bind(_ label: Label) {
        labelOffsets[label.id] = words.count
    }

    /// Resolves every branch to its label. Call once, after the last
    /// instruction.
    mutating func finalize() {
        for fixup in fixups {
            guard let target = labelOffsets[fixup.label.id] else { preconditionFailure("unbound label") }
            let delta = Int32(target - fixup.index)
            switch fixup.kind {
            case .branch26: words[fixup.index] |= UInt32(bitPattern: delta) & 0x03FF_FFFF
            case .branch19: words[fixup.index] |= (UInt32(bitPattern: delta) & 0x7FFFF) << 5
            case .branch14: words[fixup.index] |= (UInt32(bitPattern: delta) & 0x3FFF) << 5
            }
        }
        fixups.removeAll()
    }

    // MARK: Branches

    mutating func b(_ label: Label) {
        fixups.append((words.count, label, .branch26))
        emit(0x1400_0000)
    }

    mutating func b(_ condition: Condition, _ label: Label) {
        fixups.append((words.count, label, .branch19))
        emit(0x5400_0000 | condition.rawValue)
    }

    mutating func cbz(w rt: Int, _ label: Label) {
        fixups.append((words.count, label, .branch19))
        emit(0x3400_0000 | UInt32(rt))
    }

    mutating func cbnz(w rt: Int, _ label: Label) {
        fixups.append((words.count, label, .branch19))
        emit(0x3500_0000 | UInt32(rt))
    }

    mutating func tbz(_ rt: Int, bit: Int, _ label: Label) {
        fixups.append((words.count, label, .branch14))
        emit(0x3600_0000 | UInt32(bit & 0x20) << 26 | UInt32(bit & 0x1F) << 19 | UInt32(rt))
    }

    mutating func tbnz(_ rt: Int, bit: Int, _ label: Label) {
        fixups.append((words.count, label, .branch14))
        emit(0x3700_0000 | UInt32(bit & 0x20) << 26 | UInt32(bit & 0x1F) << 19 | UInt32(rt))
    }

    mutating func cbz(x rt: Int, _ label: Label) {
        fixups.append((words.count, label, .branch19))
        emit(0xB400_0000 | UInt32(rt))
    }

    mutating func cbnz(x rt: Int, _ label: Label) {
        fixups.append((words.count, label, .branch19))
        emit(0xB500_0000 | UInt32(rt))
    }

    mutating func blr(x rn: Int) { emit(0xD63F_0000 | UInt32(rn) << 5) }
    mutating func ret() { emit(0xD65F_03C0) }

    // MARK: Moves and constants

    mutating func movz(w rd: Int, _ imm16: UInt16, shift: Int = 0) { emit(0x5280_0000 | UInt32(shift / 16) << 21 | UInt32(imm16) << 5 | UInt32(rd)) }
    mutating func movk(w rd: Int, _ imm16: UInt16, shift: Int = 0) { emit(0x7280_0000 | UInt32(shift / 16) << 21 | UInt32(imm16) << 5 | UInt32(rd)) }
    mutating func movz(x rd: Int, _ imm16: UInt16, shift: Int = 0) { emit(0xD280_0000 | UInt32(shift / 16) << 21 | UInt32(imm16) << 5 | UInt32(rd)) }
    mutating func movk(x rd: Int, _ imm16: UInt16, shift: Int = 0) { emit(0xF280_0000 | UInt32(shift / 16) << 21 | UInt32(imm16) << 5 | UInt32(rd)) }

    /// Loads any 32-bit constant in one or two instructions.
    mutating func mov(w rd: Int, _ value: UInt32) {
        if value & 0xFFFF_0000 == 0 {
            movz(w: rd, UInt16(value))
        } else if value & 0xFFFF == 0 {
            movz(w: rd, UInt16(value >> 16), shift: 16)
        } else if ~value & 0xFFFF_0000 == 0 {
            emit(0x1280_0000 | UInt32(UInt16(~value & 0xFFFF)) << 5 | UInt32(rd)) // movn
        } else {
            movz(w: rd, UInt16(value & 0xFFFF))
            movk(w: rd, UInt16(value >> 16), shift: 16)
        }
    }

    /// Loads a 64-bit constant (a host address) in up to four instructions.
    mutating func mov(x rd: Int, _ value: UInt64) {
        movz(x: rd, UInt16(value & 0xFFFF))
        for shift in stride(from: 16, to: 64, by: 16) where (value >> UInt64(shift)) & 0xFFFF != 0 {
            movk(x: rd, UInt16((value >> UInt64(shift)) & 0xFFFF), shift: shift)
        }
    }

    mutating func mov(w rd: Int, w rm: Int) { emit(0x2A00_03E0 | UInt32(rm) << 16 | UInt32(rd)) } // orr wd, wzr, wm
    mutating func mov(x rd: Int, x rm: Int) { emit(0xAA00_03E0 | UInt32(rm) << 16 | UInt32(rd)) }

    // MARK: Arithmetic

    /// `op` 0 ADD, 1 ADDS, 2 SUB, 3 SUBS on shifted registers (32-bit).
    private mutating func addSub(_ op: UInt32, _ rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift, _ amount: Int) {
        precondition(shift != .ror)
        emit(0x0B00_0000 | op << 29 | shift.rawValue << 22 | UInt32(rm) << 16 | UInt32(amount & 31) << 10 | UInt32(rn) << 5 | UInt32(rd))
    }

    mutating func add(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { addSub(0, rd, rn, rm, shift, amount) }
    mutating func adds(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { addSub(1, rd, rn, rm, shift, amount) }
    mutating func sub(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { addSub(2, rd, rn, rm, shift, amount) }
    mutating func subs(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { addSub(3, rd, rn, rm, shift, amount) }

    /// 32-bit add/sub of a 12-bit immediate (optionally shifted by 12).
    private mutating func addSubImmediate(_ op: UInt32, _ rd: Int, _ rn: Int, _ imm: UInt32) {
        precondition(imm < 4096)
        emit(0x1100_0000 | op << 29 | imm << 10 | UInt32(rn) << 5 | UInt32(rd))
    }

    mutating func add(w rd: Int, _ rn: Int, imm: UInt32) { addSubImmediate(0, rd, rn, imm) }
    mutating func adds(w rd: Int, _ rn: Int, imm: UInt32) { addSubImmediate(1, rd, rn, imm) }
    mutating func sub(w rd: Int, _ rn: Int, imm: UInt32) { addSubImmediate(2, rd, rn, imm) }
    mutating func subs(w rd: Int, _ rn: Int, imm: UInt32) { addSubImmediate(3, rd, rn, imm) }

    mutating func add(x rd: Int, _ rn: Int, imm: UInt32) { precondition(imm < 4096); emit(0x9100_0000 | imm << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func sub(x rd: Int, _ rn: Int, imm: UInt32) { precondition(imm < 4096); emit(0xD100_0000 | imm << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    /// `xd = xn + zero-extended wm` (a host pointer plus a guest offset).
    mutating func add(x rd: Int, _ rn: Int, uxtw rm: Int) { emit(0x8B20_4000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func add(x rd: Int, _ rn: Int, _ rm: Int) { emit(0x8B00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

    mutating func adc(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1A00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func adcs(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x3A00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func sbc(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x5A00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func sbcs(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x7A00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

    mutating func cmp(w rn: Int, _ rm: Int) { subs(w: 31, rn, rm) }
    mutating func cmp(w rn: Int, imm: UInt32) { subs(w: 31, rn, imm: imm) }

    // MARK: Logical (shifted register)

    /// `opc` 0 AND, 1 ORR, 2 EOR, 3 ANDS; `invert` gives BIC, ORN, EON, BICS.
    private mutating func logical(_ opc: UInt32, invert: Bool, _ rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift, _ amount: Int) {
        emit(0x0A00_0000 | opc << 29 | shift.rawValue << 22 | (invert ? 1 << 21 : 0) | UInt32(rm) << 16 | UInt32(amount & 31) << 10 | UInt32(rn) << 5 | UInt32(rd))
    }

    mutating func and(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(0, invert: false, rd, rn, rm, shift, amount) }
    mutating func orr(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(1, invert: false, rd, rn, rm, shift, amount) }
    mutating func eor(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(2, invert: false, rd, rn, rm, shift, amount) }
    mutating func ands(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(3, invert: false, rd, rn, rm, shift, amount) }
    mutating func bic(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(0, invert: true, rd, rn, rm, shift, amount) }
    mutating func orn(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(1, invert: true, rd, rn, rm, shift, amount) }
    mutating func eon(w rd: Int, _ rn: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { logical(2, invert: true, rd, rn, rm, shift, amount) }
    mutating func mvn(w rd: Int, _ rm: Int, _ shift: Shift = .lsl, _ amount: Int = 0) { orn(w: rd, 31, rm, shift, amount) }
    mutating func tst(w rn: Int, _ rm: Int) { ands(w: 31, rn, rm) }
    mutating func and(x rd: Int, _ rn: Int, _ rm: Int) { emit(0x8A00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func orr(x rd: Int, _ rn: Int, _ rm: Int, lsl amount: Int = 0) { emit(0xAA00_0000 | UInt32(rm) << 16 | UInt32(amount & 63) << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func eor(x rd: Int, _ rn: Int, _ rm: Int) { emit(0xCA00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

    // MARK: Shifts, bitfields, extends

    mutating func lslv(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1AC0_2000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func lsrv(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1AC0_2400 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func asrv(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1AC0_2800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func rorv(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1AC0_2C00 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func lsrv(x rd: Int, _ rn: Int, _ rm: Int) { emit(0x9AC0_2400 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func lslv(x rd: Int, _ rn: Int, _ rm: Int) { emit(0x9AC0_2000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

    /// UBFM/SBFM/BFM, 32-bit: `op` 0 SBFM, 1 BFM, 2 UBFM.
    private mutating func bitfield(_ op: UInt32, _ rd: Int, _ rn: Int, immr: Int, imms: Int) {
        emit(0x1300_0000 | op << 29 | UInt32(immr & 31) << 16 | UInt32(imms & 31) << 10 | UInt32(rn) << 5 | UInt32(rd))
    }
    private mutating func bitfield64(_ op: UInt32, _ rd: Int, _ rn: Int, immr: Int, imms: Int) {
        emit(0x9340_0000 | op << 29 | UInt32(immr & 63) << 16 | UInt32(imms & 63) << 10 | UInt32(rn) << 5 | UInt32(rd))
    }

    mutating func lsl(w rd: Int, _ rn: Int, _ amount: Int) { bitfield(2, rd, rn, immr: (32 - amount) & 31, imms: 31 - amount) }
    mutating func lsr(w rd: Int, _ rn: Int, _ amount: Int) { bitfield(2, rd, rn, immr: amount, imms: 31) }
    mutating func asr(w rd: Int, _ rn: Int, _ amount: Int) { bitfield(0, rd, rn, immr: amount, imms: 31) }
    mutating func ror(w rd: Int, _ rn: Int, _ amount: Int) { emit(0x1380_0000 | UInt32(rn) << 16 | UInt32(amount & 31) << 10 | UInt32(rn) << 5 | UInt32(rd)) } // extr
    mutating func lsr(x rd: Int, _ rn: Int, _ amount: Int) { bitfield64(2, rd, rn, immr: amount, imms: 63) }
    mutating func lsl(x rd: Int, _ rn: Int, _ amount: Int) { bitfield64(2, rd, rn, immr: (64 - amount) & 63, imms: 63 - amount) }
    mutating func ubfx(w rd: Int, _ rn: Int, lsb: Int, width: Int) { bitfield(2, rd, rn, immr: lsb, imms: lsb + width - 1) }
    mutating func sbfx(w rd: Int, _ rn: Int, lsb: Int, width: Int) { bitfield(0, rd, rn, immr: lsb, imms: lsb + width - 1) }
    /// Inserts `width` low bits of `rn` at bit `lsb` of `rd`.
    mutating func bfi(w rd: Int, _ rn: Int, lsb: Int, width: Int) { bitfield(1, rd, rn, immr: (32 - lsb) & 31, imms: width - 1) }
    mutating func uxtb(w rd: Int, _ rn: Int) { bitfield(2, rd, rn, immr: 0, imms: 7) }
    mutating func uxth(w rd: Int, _ rn: Int) { bitfield(2, rd, rn, immr: 0, imms: 15) }
    mutating func sxtb(w rd: Int, _ rn: Int) { bitfield(0, rd, rn, immr: 0, imms: 7) }
    mutating func sxth(w rd: Int, _ rn: Int) { bitfield(0, rd, rn, immr: 0, imms: 15) }
    /// Zero-extends `wn` into `xd` (a plain 32-bit move does).
    mutating func uxtw(x rd: Int, _ rn: Int) { mov(w: rd, w: rn) }
    mutating func sxtw(x rd: Int, _ rn: Int) { bitfield64(0, rd, rn, immr: 0, imms: 31) }

    mutating func clz(w rd: Int, _ rn: Int) { emit(0x5AC0_1000 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func rbit(w rd: Int, _ rn: Int) { emit(0x5AC0_0000 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func rev(w rd: Int, _ rn: Int) { emit(0x5AC0_0800 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func rev16(w rd: Int, _ rn: Int) { emit(0x5AC0_0400 | UInt32(rn) << 5 | UInt32(rd)) }

    // MARK: Multiply and divide

    mutating func madd(w rd: Int, _ rn: Int, _ rm: Int, _ ra: Int) { emit(0x1B00_0000 | UInt32(rm) << 16 | UInt32(ra) << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func msub(w rd: Int, _ rn: Int, _ rm: Int, _ ra: Int) { emit(0x1B00_8000 | UInt32(rm) << 16 | UInt32(ra) << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func mul(w rd: Int, _ rn: Int, _ rm: Int) { madd(w: rd, rn, rm, 31) }
    /// 32x32 -> 64 multiply-add into `xd`: `xd = xa + wn * wm`.
    mutating func umaddl(x rd: Int, _ rn: Int, _ rm: Int, _ ra: Int) { emit(0x9BA0_0000 | UInt32(rm) << 16 | UInt32(ra) << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func smaddl(x rd: Int, _ rn: Int, _ rm: Int, _ ra: Int) { emit(0x9B20_0000 | UInt32(rm) << 16 | UInt32(ra) << 10 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func udiv(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1AC0_0800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func sdiv(w rd: Int, _ rn: Int, _ rm: Int) { emit(0x1AC0_0C00 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

    // MARK: Conditional select

    mutating func csel(w rd: Int, _ rn: Int, _ rm: Int, _ condition: Condition) { emit(0x1A80_0000 | UInt32(rm) << 16 | condition.rawValue << 12 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func csinc(w rd: Int, _ rn: Int, _ rm: Int, _ condition: Condition) { emit(0x1A80_0400 | UInt32(rm) << 16 | condition.rawValue << 12 | UInt32(rn) << 5 | UInt32(rd)) }
    /// `wd = condition ? 1 : 0`.
    mutating func cset(w rd: Int, _ condition: Condition) { csinc(w: rd, 31, 31, condition.inverted) }

    // MARK: Flags

    mutating func mrsNZCV(x rt: Int) { emit(0xD53B_4200 | UInt32(rt)) }
    mutating func msrNZCV(x rt: Int) { emit(0xD51B_4200 | UInt32(rt)) }

    // MARK: Loads and stores (unsigned scaled offsets)

    /// `size` 0 byte, 1 half, 2 word, 3 double; `opc` 0 store, 1 load, 2
    /// load signed into X, 3 load signed into W.
    private mutating func loadStore(size: UInt32, opc: UInt32, _ rt: Int, _ rn: Int, offset: Int) {
        let scaled = offset >> Int(size)
        precondition(offset >= 0 && scaled << Int(size) == offset && scaled < 4096, "offset \(offset) not encodable")
        emit(0x3900_0000 | size << 30 | opc << 22 | UInt32(scaled) << 10 | UInt32(rn) << 5 | UInt32(rt))
    }

    mutating func ldr(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 2, opc: 1, rt, rn, offset: offset) }
    mutating func str(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 2, opc: 0, rt, rn, offset: offset) }
    mutating func ldr(x rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 3, opc: 1, rt, rn, offset: offset) }
    mutating func str(x rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 3, opc: 0, rt, rn, offset: offset) }
    mutating func ldrh(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 1, opc: 1, rt, rn, offset: offset) }
    mutating func strh(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 1, opc: 0, rt, rn, offset: offset) }
    mutating func ldrb(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 0, opc: 1, rt, rn, offset: offset) }
    mutating func strb(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 0, opc: 0, rt, rn, offset: offset) }
    mutating func ldrsh(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 1, opc: 3, rt, rn, offset: offset) }
    mutating func ldrsb(w rt: Int, _ rn: Int, offset: Int = 0) { loadStore(size: 0, opc: 3, rt, rn, offset: offset) }

    /// Register-offset forms: address `xn + xm` (`xm` already 64-bit).
    private mutating func loadStoreRegister(size: UInt32, opc: UInt32, _ rt: Int, _ rn: Int, _ rm: Int, shifted: Bool = false) {
        emit(0x3820_6800 | size << 30 | opc << 22 | UInt32(rm) << 16 | (shifted ? 1 << 12 : 0) | UInt32(rn) << 5 | UInt32(rt))
    }

    mutating func ldr(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 2, opc: 1, rt, rn, rm) }
    mutating func str(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 2, opc: 0, rt, rn, rm) }
    mutating func ldrh(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 1, opc: 1, rt, rn, rm) }
    mutating func strh(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 1, opc: 0, rt, rn, rm) }
    mutating func ldrb(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 0, opc: 1, rt, rn, rm) }
    mutating func strb(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 0, opc: 0, rt, rn, rm) }
    mutating func ldrsh(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 1, opc: 3, rt, rn, rm) }
    mutating func ldrsb(w rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 0, opc: 3, rt, rn, rm) }
    /// Pair store/load of X registers, pre-indexed store and post-indexed
    /// load, for prologues and epilogues.
    mutating func stpPreIndex(x rt: Int, _ rt2: Int, sp offset: Int) {
        emit(0xA980_0000 | UInt32((offset / 8) & 0x7F) << 15 | UInt32(rt2) << 10 | 31 << 5 | UInt32(rt))
    }
    mutating func ldpPostIndex(x rt: Int, _ rt2: Int, sp offset: Int) {
        emit(0xA8C0_0000 | UInt32((offset / 8) & 0x7F) << 15 | UInt32(rt2) << 10 | 31 << 5 | UInt32(rt))
    }

    mutating func nop() { emit(0xD503_201F) }

    // MARK: Logical (immediate)

    /// The `(immr, imms)` of `value` as an AArch64 32-bit bitmask
    /// immediate (a rotated run of ones repeating in a 2- to 32-bit
    /// element), or nil if it isn't one.
    static func logicalImmediate32(_ value: UInt32) -> (immr: UInt32, imms: UInt32)? {
        guard value != 0, value != 0xFFFF_FFFF else { return nil }
        var size: UInt32 = 32
        while size > 2 {
            let half = size / 2
            let mask: UInt32 = (1 << half) - 1
            guard value & mask == (value >> half) & mask else { break }
            size = half
        }
        let mask: UInt64 = size == 32 ? 0xFFFF_FFFF : (1 << UInt64(size)) - 1
        let element = UInt64(value) & mask
        let ones = element.nonzeroBitCount
        let pattern: UInt64 = (1 << UInt64(ones)) - 1
        for rotation in 0..<UInt64(size) {
            let rotated = rotation == 0 ? pattern : ((pattern >> rotation) | (pattern << (UInt64(size) - rotation))) & mask
            if rotated == element {
                let imms = (~(2 * size - 1) & 0x3F) | UInt32(ones - 1)
                return (UInt32(rotation), imms)
            }
        }
        return nil
    }

    /// `opc` 0 AND, 1 ORR, 2 EOR, 3 ANDS with a bitmask immediate; false
    /// (nothing emitted) if `value` isn't encodable.
    @discardableResult
    private mutating func logicalImmediate(_ opc: UInt32, _ rd: Int, _ rn: Int, _ value: UInt32) -> Bool {
        guard let (immr, imms) = Self.logicalImmediate32(value) else { return false }
        emit(0x1200_0000 | opc << 29 | immr << 16 | imms << 10 | UInt32(rn) << 5 | UInt32(rd))
        return true
    }

    /// `wd = wn & value`, through `scratch` when `value` isn't a bitmask
    /// immediate. The same for `orr`/`eor`/`ands` below.
    mutating func and(w rd: Int, _ rn: Int, imm value: UInt32, scratch: Int) {
        if value == 0xFFFF_FFFF { if rd != rn { mov(w: rd, w: rn) }; return }
        if value == 0 { mov(w: rd, w: 31); return }
        if !logicalImmediate(0, rd, rn, value) { mov(w: scratch, value); and(w: rd, rn, scratch) }
    }
    mutating func orr(w rd: Int, _ rn: Int, imm value: UInt32, scratch: Int) {
        if value == 0 { if rd != rn { mov(w: rd, w: rn) }; return }
        if !logicalImmediate(1, rd, rn, value) { mov(w: scratch, value); orr(w: rd, rn, scratch) }
    }
    mutating func eor(w rd: Int, _ rn: Int, imm value: UInt32, scratch: Int) {
        if value == 0 { if rd != rn { mov(w: rd, w: rn) }; return }
        if !logicalImmediate(2, rd, rn, value) { mov(w: scratch, value); eor(w: rd, rn, scratch) }
    }
    mutating func ands(w rd: Int, _ rn: Int, imm value: UInt32, scratch: Int) {
        if !logicalImmediate(3, rd, rn, value) { mov(w: scratch, value); ands(w: rd, rn, scratch) }
    }

    // MARK: Arithmetic with any immediate

    /// `wd = wn + value` (wrapping), through `scratch` when needed; never
    /// touches the flags.
    mutating func add(w rd: Int, _ rn: Int, anyImm value: UInt32, scratch: Int) {
        if value < 4096 {
            if value != 0 || rd != rn { add(w: rd, rn, imm: value) }
        } else if (0 &- value) < 4096 {
            sub(w: rd, rn, imm: 0 &- value)
        } else if value & 0xFFF == 0, value >> 12 < 4096 {
            emit(0x1140_0000 | (value >> 12) << 10 | UInt32(rn) << 5 | UInt32(rd)) // add wd, wn, #imm, lsl #12
        } else {
            mov(w: scratch, value)
            add(w: rd, rn, scratch)
        }
    }

    mutating func neg(w rd: Int, _ rm: Int) { sub(w: rd, 31, rm) }

    /// `add xd, xn, xm, lsl #amount`.
    mutating func add(x rd: Int, _ rn: Int, _ rm: Int, lsl amount: Int) {
        emit(0x8B00_0000 | UInt32(rm) << 16 | UInt32(amount & 63) << 10 | UInt32(rn) << 5 | UInt32(rd))
    }

    mutating func sub(x rd: Int, _ rn: Int, _ rm: Int) { emit(0xCB00_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

    /// 64-bit `asrv`, and immediate `asr` on X registers.
    mutating func asrv(x rd: Int, _ rn: Int, _ rm: Int) { emit(0x9AC0_2800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func asr(x rd: Int, _ rn: Int, _ amount: Int) { bitfield64Public(0, rd, rn, immr: amount, imms: 63) }
    mutating func ubfx(x rd: Int, _ rn: Int, lsb: Int, width: Int) { bitfield64Public(2, rd, rn, immr: lsb, imms: lsb + width - 1) }
    private mutating func bitfield64Public(_ op: UInt32, _ rd: Int, _ rn: Int, immr: Int, imms: Int) {
        emit(0x9340_0000 | op << 29 | UInt32(immr & 63) << 16 | UInt32(imms & 63) << 10 | UInt32(rn) << 5 | UInt32(rd))
    }

    // MARK: Indexed loads and stores

    /// `ldr wt, [xn, xm, lsl #2]` and `ldr xt, [xn, xm, lsl #3]`: an
    /// element of a table of words or pointers.
    mutating func ldr(w rt: Int, _ rn: Int, index rm: Int) { loadStoreRegister(size: 2, opc: 1, rt, rn, rm, shifted: true) }
    mutating func ldr(x rt: Int, _ rn: Int, index rm: Int) { loadStoreRegister(size: 3, opc: 1, rt, rn, rm, shifted: true) }
    mutating func ldr(x rt: Int, _ rn: Int, _ rm: Int) { loadStoreRegister(size: 3, opc: 1, rt, rn, rm) }

    /// `ldp`/`stp` of X registers at a signed, 8-byte-scaled offset.
    mutating func ldp(x rt: Int, _ rt2: Int, _ rn: Int, offset: Int) {
        emit(0xA940_0000 | UInt32((offset / 8) & 0x7F) << 15 | UInt32(rt2) << 10 | UInt32(rn) << 5 | UInt32(rt))
    }
    mutating func stp(x rt: Int, _ rt2: Int, _ rn: Int, offset: Int) {
        emit(0xA900_0000 | UInt32((offset / 8) & 0x7F) << 15 | UInt32(rt2) << 10 | UInt32(rn) << 5 | UInt32(rt))
    }

    // MARK: Branches out of the code being assembled

    /// `b` to a word `delta` away from this instruction.
    mutating func b(wordDelta delta: Int) {
        precondition(delta >= -(1 << 25) && delta < (1 << 25), "branch out of range")
        emit(0x1400_0000 | UInt32(truncatingIfNeeded: delta) & 0x03FF_FFFF)
    }
    mutating func br(x rn: Int) { emit(0xD61F_0000 | UInt32(rn) << 5) }
    mutating func brk(_ imm: UInt16) { emit(0xD420_0000 | UInt32(imm) << 5) }

    /// Finalizes and returns the instructions.
    mutating func finalizedWords() -> [UInt32] {
        finalize()
        return words
    }

    /// The index the next instruction will have.
    var position: Int { words.count }

    /// Where `label` was bound, as an instruction index.
    func offset(of label: Label) -> Int? { labelOffsets[label.id] }
}
