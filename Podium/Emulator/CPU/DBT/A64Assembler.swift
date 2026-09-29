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

    mutating func bic(x rd: Int, _ rn: Int, _ rm: Int) { emit(0x8A20_0000 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func lsr(x rd: Int, _ rn: Int, imm amount: Int) { bitfield64Public(2, rd, rn, immr: amount, imms: 63) }

    // MARK: Floating-point and SIMD registers

    /// Loads and stores of the low 32, 64 or all 128 bits of `v` registers,
    /// at unsigned scaled offsets.
    private mutating func loadStoreVector(_ base: UInt32, scale: Int, _ rt: Int, _ rn: Int, offset: Int) {
        let scaled = offset >> scale
        precondition(offset >= 0 && scaled << scale == offset && scaled < 4096, "offset \(offset) not encodable")
        emit(base | UInt32(scaled) << 10 | UInt32(rn) << 5 | UInt32(rt))
    }
    mutating func ldr(s rt: Int, _ rn: Int, offset: Int) { loadStoreVector(0xBD40_0000, scale: 2, rt, rn, offset: offset) }
    mutating func str(s rt: Int, _ rn: Int, offset: Int) { loadStoreVector(0xBD00_0000, scale: 2, rt, rn, offset: offset) }
    mutating func ldr(d rt: Int, _ rn: Int, offset: Int) { loadStoreVector(0xFD40_0000, scale: 3, rt, rn, offset: offset) }
    mutating func str(d rt: Int, _ rn: Int, offset: Int) { loadStoreVector(0xFD00_0000, scale: 3, rt, rn, offset: offset) }
    mutating func ldr(q rt: Int, _ rn: Int, offset: Int) { loadStoreVector(0x3DC0_0000, scale: 4, rt, rn, offset: offset) }
    mutating func str(q rt: Int, _ rn: Int, offset: Int) { loadStoreVector(0x3D80_0000, scale: 4, rt, rn, offset: offset) }

    /// Register-offset forms: address `xn + xm`.
    mutating func ldr(d rt: Int, _ rn: Int, _ rm: Int) { emit(0xFC60_6800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rt)) }
    mutating func str(d rt: Int, _ rn: Int, _ rm: Int) { emit(0xFC20_6800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rt)) }
    mutating func ldr(q rt: Int, _ rn: Int, _ rm: Int) { emit(0x3CE0_6800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rt)) }
    mutating func str(q rt: Int, _ rn: Int, _ rm: Int) { emit(0x3CA0_6800 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rt)) }
    mutating func ldr(x rt: Int, _ rn: Int, register rm: Int) { loadStoreRegister(size: 3, opc: 1, rt, rn, rm) }
    mutating func str(x rt: Int, _ rn: Int, register rm: Int) { loadStoreRegister(size: 3, opc: 0, rt, rn, rm) }

    /// Scalar floating point, `double` choosing D over S registers. The
    /// bases are the encodings with every register field 0.
    enum FloatOperation: UInt32 {
        case mul = 0x1E20_0800, div = 0x1E20_1800, add = 0x1E20_2800, sub = 0x1E20_3800
        case max = 0x1E20_4800, min = 0x1E20_5800, nmul = 0x1E20_8800
        // One source.
        case mov = 0x1E20_4000, abs = 0x1E20_C000, neg = 0x1E21_4000, sqrt = 0x1E21_C000
    }
    mutating func float(_ op: FloatOperation, double: Bool, _ rd: Int, _ rn: Int, _ rm: Int = 0) {
        emit(op.rawValue | (double ? 1 << 22 : 0) | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd))
    }
    /// `fcmp` against `rm`, or against +0.0 when nil.
    mutating func fcmp(double: Bool, _ rn: Int, _ rm: Int?) {
        emit(0x1E20_2000 | (double ? 1 << 22 : 0) | UInt32(rm ?? 0) << 16 | UInt32(rn) << 5 | (rm == nil ? 8 : 0))
    }
    /// `fcvt`: single to double, or double to single.
    mutating func fcvt(toDouble: Bool, _ rd: Int, _ rn: Int) {
        emit((toDouble ? 0x1E22_C000 : 0x1E62_4000) | UInt32(rn) << 5 | UInt32(rd))
    }

    /// Conversions and moves between W/X and S/D registers.
    enum Conversion: UInt32 {
        /// Float to 32-bit integer, rounding toward zero (`fcvtz`) or to
        /// nearest (`fcvtn`); saturating, NaN giving 0.
        case fcvtzs = 0x1E38_0000, fcvtzu = 0x1E39_0000, fcvtns = 0x1E20_0000, fcvtnu = 0x1E21_0000
        /// 32-bit integer to float.
        case scvtf = 0x1E22_0000, ucvtf = 0x1E23_0000
        /// `fmov wd, sn` and `fmov sd, wn`.
        case fmovToW = 0x1E26_0000, fmovFromW = 0x1E27_0000
    }
    mutating func convert(_ op: Conversion, double: Bool, _ rd: Int, _ rn: Int) {
        emit(op.rawValue | (double ? 1 << 22 : 0) | UInt32(rn) << 5 | UInt32(rd))
    }
    mutating func fmov(d rd: Int, x rn: Int) { emit(0x9E67_0000 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func fmov(x rd: Int, d rn: Int) { emit(0x9E66_0000 | UInt32(rn) << 5 | UInt32(rd)) }

    mutating func mrsFPCR(x rt: Int) { emit(0xD53B_4400 | UInt32(rt)) }
    mutating func msrFPCR(x rt: Int) { emit(0xD51B_4400 | UInt32(rt)) }
    mutating func mrsFPSR(x rt: Int) { emit(0xD53B_4420 | UInt32(rt)) }
    mutating func msrFPSR(x rt: Int) { emit(0xD51B_4420 | UInt32(rt)) }

    // MARK: Advanced SIMD

    /// Vector operations by their encoding with Q, size and the registers
    /// 0: `q` picks the 128-bit arrangement over the 64-bit one, `size`
    /// the element size (0 bytes ... 3 doublewords) where the operation
    /// has one. The logical and floating-point ones fix that field
    /// themselves (it's part of the base).
    enum VectorOperation: UInt32 {
        // Three registers of the same type.
        case add = 0x0E20_8400, sub = 0x2E20_8400, mul = 0x0E20_9C00, pmul = 0x2E20_9C00
        case mla = 0x0E20_9400, mls = 0x2E20_9400
        case shadd = 0x0E20_0400, uhadd = 0x2E20_0400, srhadd = 0x0E20_1400, urhadd = 0x2E20_1400
        case shsub = 0x0E20_2400, uhsub = 0x2E20_2400
        case cmgt = 0x0E20_3400, cmhi = 0x2E20_3400, cmge = 0x0E20_3C00, cmhs = 0x2E20_3C00
        case sshl = 0x0E20_4400, ushl = 0x2E20_4400, srshl = 0x0E20_5400, urshl = 0x2E20_5400
        case smax = 0x0E20_6400, umax = 0x2E20_6400, smin = 0x0E20_6C00, umin = 0x2E20_6C00
        case sabd = 0x0E20_7400, uabd = 0x2E20_7400, saba = 0x0E20_7C00, uaba = 0x2E20_7C00
        case cmtst = 0x0E20_8C00, cmeq = 0x2E20_8C00
        case smaxp = 0x0E20_A400, umaxp = 0x2E20_A400, sminp = 0x0E20_AC00, uminp = 0x2E20_AC00
        case addp = 0x0E20_BC00
        case and = 0x0E20_1C00, bic = 0x0E60_1C00, orr = 0x0EA0_1C00, orn = 0x0EE0_1C00
        case eor = 0x2E20_1C00, bsl = 0x2E60_1C00, bit = 0x2EA0_1C00, bif = 0x2EE0_1C00
        case fadd = 0x0E20_D400, fsub = 0x0EA0_D400, fmul = 0x2E20_DC00, fabd = 0x2EA0_D400, faddp = 0x2E20_D400
        case fmax = 0x0E20_F400, fmin = 0x0EA0_F400, fmaxp = 0x2E20_F400, fminp = 0x2EA0_F400
        case fcmeq = 0x0E20_E400, fcmge = 0x2E20_E400, fcmgt = 0x2EA0_E400, facge = 0x2E20_EC00, facgt = 0x2EA0_EC00
        // Three registers of different types (long, wide, narrow).
        case saddl = 0x0E20_0000, uaddl = 0x2E20_0000, saddw = 0x0E20_1000, uaddw = 0x2E20_1000
        case ssubl = 0x0E20_2000, usubl = 0x2E20_2000, ssubw = 0x0E20_3000, usubw = 0x2E20_3000
        case addhn = 0x0E20_4000, raddhn = 0x2E20_4000, subhn = 0x0E20_6000, rsubhn = 0x2E20_6000
        case sabal = 0x0E20_5000, uabal = 0x2E20_5000, sabdl = 0x0E20_7000, uabdl = 0x2E20_7000
        case smlal = 0x0E20_8000, umlal = 0x2E20_8000, smlsl = 0x0E20_A000, umlsl = 0x2E20_A000
        case smull = 0x0E20_C000, umull = 0x2E20_C000, pmull = 0x0E20_E000
        // Permutes.
        case zip1 = 0x0E00_3800, zip2 = 0x0E00_7800, uzp1 = 0x0E00_1800, uzp2 = 0x0E00_5800
        case trn1 = 0x0E00_2800, trn2 = 0x0E00_6800
    }
    mutating func vector(_ op: VectorOperation, q: Bool, size: Int = 0, _ rd: Int, _ rn: Int, _ rm: Int) {
        emit(op.rawValue | (q ? 1 << 30 : 0) | UInt32(size) << 22 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd))
    }

    /// Two-register operations, like `VectorOperation`.
    enum VectorUnaryOperation: UInt32 {
        case rev64 = 0x0E20_0800, rev32 = 0x2E20_0800, rev16 = 0x0E20_1800
        case saddlp = 0x0E20_2800, uaddlp = 0x2E20_2800, sadalp = 0x0E20_6800, uadalp = 0x2E20_6800
        case cls = 0x0E20_4800, clz = 0x2E20_4800, cnt = 0x0E20_5800, not = 0x2E20_5800
        case cmgt0 = 0x0E20_8800, cmge0 = 0x2E20_8800, cmeq0 = 0x0E20_9800, cmle0 = 0x2E20_9800, cmlt0 = 0x0E20_A800
        case abs = 0x0E20_B800, neg = 0x2E20_B800, xtn = 0x0E21_2800, shll = 0x2E21_3800
        case fcmgt0 = 0x0EA0_C800, fcmeq0 = 0x0EA0_D800, fcmlt0 = 0x0EA0_E800, fcmge0 = 0x2EA0_C800, fcmle0 = 0x2EA0_D800
        case fabs = 0x0EA0_F800, fneg = 0x2EA0_F800
        case fcvtzs = 0x0EA1_B800, fcvtzu = 0x2EA1_B800, scvtf = 0x0E21_D800, ucvtf = 0x2E21_D800
    }
    mutating func vector(_ op: VectorUnaryOperation, q: Bool, size: Int = 0, _ rd: Int, _ rn: Int) {
        emit(op.rawValue | (q ? 1 << 30 : 0) | UInt32(size) << 22 | UInt32(rn) << 5 | UInt32(rd))
    }

    /// Shifts by an immediate: `esize` the element size in bits (for the
    /// narrowing and widening ones, the narrow size), `amount` the shift.
    enum VectorShift: UInt32 {
        case sshr = 0x0F00_0400, ushr = 0x2F00_0400, ssra = 0x0F00_1400, usra = 0x2F00_1400
        case srshr = 0x0F00_2400, urshr = 0x2F00_2400, srsra = 0x0F00_3400, ursra = 0x2F00_3400
        case sri = 0x2F00_4400, shl = 0x0F00_5400, sli = 0x2F00_5400
        case shrn = 0x0F00_8400, rshrn = 0x0F00_8C00, sshll = 0x0F00_A400, ushll = 0x2F00_A400

        var isLeft: Bool { self == .shl || self == .sli || self == .sshll || self == .ushll }
    }
    mutating func vector(_ op: VectorShift, q: Bool, esize: Int, amount: Int, _ rd: Int, _ rn: Int) {
        let immhb = op.isLeft ? esize + amount : 2 * esize - amount
        precondition(immhb >= esize && immhb < 2 * esize, "shift not encodable")
        emit(op.rawValue | (q ? 1 << 30 : 0) | UInt32(immhb) << 16 | UInt32(rn) << 5 | UInt32(rd))
    }

    /// Operations by an element of `rm`: 16-bit elements (`size` 1) take
    /// `rm` 0...15 and `index` 0...7, 32-bit ones (`size` 2) any `rm` and
    /// `index` 0...3. `fmul` is the single-precision form.
    enum VectorByElement: UInt32 {
        case mla = 0x2F00_0000, mls = 0x2F00_4000, mul = 0x0F00_8000
        case smlal = 0x0F00_2000, umlal = 0x2F00_2000, smlsl = 0x0F00_6000, umlsl = 0x2F00_6000
        case smull = 0x0F00_A000, umull = 0x2F00_A000, fmul = 0x0F80_9000
    }
    mutating func vector(_ op: VectorByElement, q: Bool, size: Int, _ rd: Int, _ rn: Int, _ rm: Int, index: Int) {
        let h: UInt32, l: UInt32, m: UInt32
        if size == 1 {
            precondition(rm < 16 && index < 8)
            h = UInt32(index >> 2 & 1); l = UInt32(index >> 1 & 1); m = UInt32(index & 1)
        } else {
            precondition(index < 4)
            h = UInt32(index >> 1 & 1); l = UInt32(index & 1); m = UInt32(rm >> 4)
        }
        let sizeBits: UInt32 = op == .fmul ? 0 : UInt32(size) << 22
        emit(op.rawValue | (q ? 1 << 30 : 0) | sizeBits | l << 21 | m << 20 | UInt32(rm & 15) << 16 | h << 11 | UInt32(rn) << 5 | UInt32(rd))
    }

    /// `ext vd, vn, vm, #index` (bytes).
    mutating func ext(q: Bool, _ rd: Int, _ rn: Int, _ rm: Int, index: Int) {
        emit(0x2E00_0000 | (q ? 1 << 30 : 0) | UInt32(rm) << 16 | UInt32(index) << 11 | UInt32(rn) << 5 | UInt32(rd))
    }
    /// `tbl`/`tbx vd, {vn...vn+length-1}.16b, vm`.
    mutating func tbl(q: Bool, extends: Bool, _ rd: Int, _ rn: Int, length: Int, _ rm: Int) {
        emit(0x0E00_0000 | (q ? 1 << 30 : 0) | UInt32(rm) << 16 | UInt32(length - 1) << 13 | (extends ? 1 << 12 : 0) | UInt32(rn) << 5 | UInt32(rd))
    }
    /// `imm5` encodes the element size and index: `index << 1 | 1` for
    /// bytes, `index << 2 | 2` halfwords, `index << 3 | 4` words, `index << 4 | 8` doublewords.
    mutating func dup(q: Bool, _ rd: Int, element rn: Int, imm5: Int) {
        emit(0x0E00_0400 | (q ? 1 << 30 : 0) | UInt32(imm5) << 16 | UInt32(rn) << 5 | UInt32(rd))
    }
    mutating func dup(q: Bool, _ rd: Int, general rn: Int, imm5: Int) {
        emit(0x0E00_0C00 | (q ? 1 << 30 : 0) | UInt32(imm5) << 16 | UInt32(rn) << 5 | UInt32(rd))
    }
    /// `add`/`sub dd, dn, dm`: the 64-bit scalar forms.
    mutating func addScalar(d rd: Int, _ rn: Int, _ rm: Int) { emit(0x5EE0_8400 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }
    mutating func subScalar(d rd: Int, _ rn: Int, _ rm: Int) { emit(0x7EE0_8400 | UInt32(rm) << 16 | UInt32(rn) << 5 | UInt32(rd)) }

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
