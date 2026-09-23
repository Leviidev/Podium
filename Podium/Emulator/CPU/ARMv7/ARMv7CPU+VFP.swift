import Foundation

/// VFPv3 (the A4's Cortex-A8 floating-point unit): the system registers,
/// core <-> extension register transfers, data processing, and the
/// disabled-unit trap XNU's lazy context switching is built on.
///
/// XNU saves and restores VFP state lazily: switching threads clears
/// FPEXC.EN (unless the incoming thread already owns the unit), so that
/// thread's first VFP/Advanced SIMD instruction is UNDEFINED, and the
/// Undefined Instruction handler saves the previous owner's registers,
/// loads the current thread's, sets EN and returns to retry it. Executing
/// those instructions with EN clear would silently let every thread share
/// one register file.
extension ARMv7CPU {
    static let fpexcEnableBit: UInt32 = 1 << 30

    /// Cortex-A8 (r3p2) identification, as the TRM gives it: VFPv3 with
    /// 32 double registers, no short vectors or FP16 conversion; Advanced
    /// SIMD with integer and single-precision support.
    static let fpsidValue: UInt32 = 0x4103_30C3
    static let mvfr0Value: UInt32 = 0x1111_0222
    static let mvfr1Value: UInt32 = 0x0001_1100

    var floatingPointUnitEnabled: Bool { fpexc & Self.fpexcEnableBit != 0 }

    // MARK: - Register transfers (ARM DDI 0406C A7.8)

    /// Coprocessor 10/11 `MCR`/`MRC` encodings: `VMOV` between a core and
    /// an `S` register, `VMRS`/`VMSR`, and `VMOV`/`VDUP` to or from a
    /// `D`-register scalar. Returns `false` for any other coprocessor.
    func executeVFPRegisterTransfer(_ instr: CoprocessorRegisterTransferInstruction) -> Bool {
        guard instr.coprocessor == 10 || instr.coprocessor == 11 else { return false }
        let privileged = cpsr.rawValue & Self.modeBitsMask != Self.userModeBits

        if instr.coprocessor == 10, instr.opc1 == 0b111 {
            // VMRS/VMSR. FPSID, MVFR0/1 and FPEXC stay accessible to
            // privileged code while the unit is disabled — that's how the
            // kernel turns it back on.
            let register = instr.crn
            let isFPSCR = register == 0b0001
            guard isFPSCR || privileged, isFPSCR ? floatingPointUnitEnabled : true else {
                raiseUndefinedInstruction()
                return true
            }
            if instr.isLoad {
                let value: UInt32
                switch register {
                case 0b0000: value = Self.fpsidValue
                case 0b0001: value = fpscr
                case 0b0110: value = Self.mvfr1Value
                case 0b0111: value = Self.mvfr0Value
                case 0b1000: value = fpexc
                default:
                    raiseUndefinedInstruction()
                    return true
                }
                if instr.rt == Registers.pcIndex {
                    // VMRS APSR_nzcv, FPSCR: the comparison result.
                    guard isFPSCR else { raiseUndefinedInstruction(); return true }
                    cpsr.rawValue = (cpsr.rawValue & 0x0FFF_FFFF) | (fpscr & 0xF000_0000)
                } else {
                    registers[instr.rt] = value
                }
            } else {
                let value = registers[instr.rt]
                switch register {
                case 0b0001: fpscr = value
                case 0b1000: fpexc = value & Self.fpexcEnableBit
                case 0b0000, 0b0110, 0b0111: break // read-only
                default: raiseUndefinedInstruction()
                }
            }
            return true
        }

        guard floatingPointUnitEnabled else {
            raiseUndefinedInstruction()
            return true
        }

        let nBit = instr.opc2 >> 2 & 1
        if instr.coprocessor == 10 {
            // VMOV Rt <-> Sn: opc1 000, opc2 bits[1:0] and CRm zero.
            guard instr.opc1 == 0, instr.opc2 & 0b11 == 0, instr.crm == 0 else {
                raiseUndefinedInstruction()
                return true
            }
            let s = instr.crn << 1 | nBit
            if instr.isLoad {
                registers[instr.rt] = neon.single(s)
            } else {
                neon.setSingle(s, registers[instr.rt])
            }
            return true
        }

        // Coprocessor 11: scalars. D register = N:Vn.
        let dIndex = nBit << 4 | instr.crn
        let selector = (instr.opc1 & 0b11) << 2 | (instr.opc2 & 0b11)
        if !instr.isLoad, instr.opc1 & 0b100 != 0 {
            executeVDUPFromCore(dIndex: dIndex, opc1: instr.opc1, opc2: instr.opc2, rt: instr.rt)
            return true
        }
        let size: Int, lane: Int
        if selector & 0b1000 != 0 {
            size = 8; lane = selector & 0b111
        } else if selector & 0b0001 != 0 {
            size = 16; lane = selector >> 1 & 0b11
        } else if selector & 0b0011 == 0 {
            size = 32; lane = selector >> 2 & 1
        } else {
            raiseUndefinedInstruction()
            return true
        }
        let shift = UInt64(size * lane)
        let mask: UInt64 = size == 32 ? 0xFFFF_FFFF : (1 << UInt64(size)) - 1
        if instr.isLoad {
            let unsigned = instr.opc1 & 0b100 != 0
            guard !(unsigned && size == 32) else { raiseUndefinedInstruction(); return true }
            let raw = (neon[dIndex] >> shift) & mask
            if unsigned || size == 32 {
                registers[instr.rt] = UInt32(raw)
            } else {
                let signBit: UInt64 = 1 << UInt64(size - 1)
                registers[instr.rt] = UInt32(truncatingIfNeeded: Int64(bitPattern: (raw ^ signBit) &- signBit))
            }
        } else {
            neon[dIndex] = (neon[dIndex] & ~(mask << shift)) | ((UInt64(registers[instr.rt]) & mask) << shift)
        }
        return true
    }

    /// `VDUP.<size> Dd/Qd, Rt` (A8.8.320): B:E (bit22, bit5) pick the size.
    private func executeVDUPFromCore(dIndex: Int, opc1: Int, opc2: Int, rt: Int) {
        let b = opc1 >> 1 & 1, e = opc2 & 1, isQuad = opc1 & 1 != 0
        let value = UInt64(registers[rt])
        let pattern: UInt64
        switch (b, e) {
        case (0, 0): pattern = value | value << 32
        case (0, 1): pattern = (value & 0xFFFF) &* 0x0001_0001_0001_0001
        case (1, 0): pattern = (value & 0xFF) &* 0x0101_0101_0101_0101
        default:
            raiseUndefinedInstruction()
            return
        }
        guard !isQuad || dIndex & 1 == 0 else { raiseUndefinedInstruction(); return }
        neon[dIndex] = pattern
        if isQuad { neon[dIndex + 1] = pattern }
    }

    // MARK: - Data processing (ARM DDI 0406C A7.5)

    private static let fpscrFlushToZeroBit: UInt32 = 1 << 24
    private static let fpscrDefaultNaNBit: UInt32 = 1 << 25

    private var flushToZero: Bool { fpscr & Self.fpscrFlushToZeroBit != 0 }
    private var defaultNaN: Bool { fpscr & Self.fpscrDefaultNaNBit != 0 }

    /// FPSCR.RMode as a Swift rounding rule (00 nearest, 01 toward +inf,
    /// 10 toward -inf, 11 toward zero).
    private var fpscrRoundingRule: FloatingPointRoundingRule {
        switch fpscr >> 22 & 0b11 {
        case 0b01: return .up
        case 0b10: return .down
        case 0b11: return .towardZero
        default: return .toNearestOrEven
        }
    }

    private func readDouble(_ index: Int) -> Double { flushInput(Double(bitPattern: neon[index])) }
    private func readSingle(_ index: Int) -> Float { flushInput(Float(bitPattern: neon.single(index))) }

    /// Results are already rounded, flushed and NaN-processed by `result`,
    /// so writes store the bits as they are — `VNMUL` negates *after* NaN
    /// processing, and a second default-NaN substitution would undo it.
    private func writeDouble(_ index: Int, _ value: Double) { neon[index] = value.bitPattern }
    private func writeSingle(_ index: Int, _ value: Float) { neon.setSingle(index, value.bitPattern) }

    /// FZ: denormal inputs count as a zero of the same sign.
    private func flushInput<T: BinaryFloatingPoint>(_ value: T) -> T {
        flushToZero && value.isSubnormal ? (value.sign == .minus ? -0.0 : 0.0) : value
    }

    /// FZ flushes denormal results to zero; DN replaces any NaN result
    /// with the default NaN (positive, quiet, zero payload).
    private func flushOutput<T: BinaryFloatingPoint>(_ value: T) -> T {
        if value.isNaN, defaultNaN { return T.nan }
        return flushInput(value)
    }

    /// `FPProcessNaNs` (ARM DDI 0406C A2.7.8): the first signaling NaN
    /// operand, quieted, else the first quiet NaN — or the default NaN
    /// under DN. Done explicitly: which NaN plain Swift arithmetic returns
    /// depends on operand order the optimizer is free to commute.
    private func processNaNs<T: VFPValue>(_ a: T, _ b: T) -> T? {
        let nan: T? = a.isSignalingNaN ? a : b.isSignalingNaN ? b : a.isNaN ? a : b.isNaN ? b : nil
        guard let nan else { return nil }
        return defaultNaN ? T.nan : nan.quietedNaN
    }

    /// One arithmetic step: NaN operands per `processNaNs`, otherwise the
    /// host's IEEE result (an invalid operation gives the default NaN on
    /// both), then FZ/DN on the result.
    private func result<T: VFPValue>(_ a: T, _ b: T, _ operation: (T, T) -> T) -> T {
        if let nan = processNaNs(a, b) { return nan }
        return flushOutput(operation(a, b))
    }

    func executeVFPDataProcessing(_ instr: VFPDataProcessingInstruction) {
        if instr.isDouble {
            executeVFPArithmetic(instr, read: readDouble, write: writeDouble)
        } else {
            executeVFPArithmetic(instr, read: readSingle, write: writeSingle)
        }
    }

    /// The operations that read and write registers of the instruction's
    /// own precision go through here, generic over `Float`/`Double`; the
    /// conversions handle their mixed widths themselves.
    private func executeVFPArithmetic<T: VFPValue>(
        _ instr: VFPDataProcessingInstruction, read: (Int) -> T, write: (Int, T) -> Void
    ) {
        switch instr.operation {
        case .multiplyAccumulate(let negateProduct, let negateAccumulator):
            // Two roundings, as VMLA's pseudocode has: the product is
            // rounded (and NaN-processed) before the add; the negations
            // are sign flips, NaNs included (FPNeg).
            var product = result(read(instr.n), read(instr.m), *)
            if negateProduct { product = -product }
            var accumulator = read(instr.d)
            if negateAccumulator { accumulator = -accumulator }
            write(instr.d, result(accumulator, product, +))
        case .multiply:
            write(instr.d, result(read(instr.n), read(instr.m), *))
        case .negatedMultiply:
            write(instr.d, -result(read(instr.n), read(instr.m), *))
        case .add:
            write(instr.d, result(read(instr.n), read(instr.m), +))
        case .subtract:
            write(instr.d, result(read(instr.n), read(instr.m), -))
        case .divide:
            write(instr.d, result(read(instr.n), read(instr.m), /))
        case .moveImmediate(let bits):
            if instr.isDouble { neon[instr.d] = bits } else { neon.setSingle(instr.d, UInt32(truncatingIfNeeded: bits)) }
        case .move:
            // A bit copy, like the hardware's: no flushing, no NaN rules.
            if instr.isDouble { neon[instr.d] = neon[instr.m] } else { neon.setSingle(instr.d, neon.single(instr.m)) }
        case .absolute:
            if instr.isDouble {
                neon[instr.d] = neon[instr.m] & ~(1 << 63)
            } else {
                neon.setSingle(instr.d, neon.single(instr.m) & ~(1 << 31))
            }
        case .negate:
            if instr.isDouble {
                neon[instr.d] = neon[instr.m] ^ (1 << 63)
            } else {
                neon.setSingle(instr.d, neon.single(instr.m) ^ (1 << 31))
            }
        case .squareRoot:
            let x = read(instr.m)
            write(instr.d, x.isNaN ? (processNaNs(x, x) ?? x) : flushOutput(x.squareRoot()))
        case .compare(let withZero):
            let a = read(instr.d)
            let b = withZero ? 0 : read(instr.m)
            let nzcv: UInt32
            if a.isNaN || b.isNaN {
                nzcv = 0b0011
            } else if a == b {
                nzcv = 0b0110
            } else if a < b {
                nzcv = 0b1000
            } else {
                nzcv = 0b0010
            }
            fpscr = (fpscr & 0x0FFF_FFFF) | nzcv << 28
        case .convertPrecision:
            // The host's conversion quiets a signaling NaN and keeps the
            // payload, as FPConvert does.
            if instr.isDouble {
                writeSingle(instr.d, flushOutput(Float(readDouble(instr.m))))
            } else {
                writeDouble(instr.d, flushOutput(Double(readSingle(instr.m))))
            }
        case .convertFromInteger(let signed):
            let raw = neon.single(instr.m)
            let rule = fpscrRoundingRule
            if instr.isDouble {
                // Every 32-bit integer is exact in a double.
                writeDouble(instr.d, flushOutput(signed ? Double(Int32(bitPattern: raw)) : Double(raw)))
            } else {
                let exact = signed ? Double(Int32(bitPattern: raw)) : Double(raw)
                writeSingle(instr.d, flushOutput(Self.roundToSingle(exact, rule)))
            }
        case .convertToInteger(let signed, let roundTowardZero):
            let value = instr.isDouble ? readDouble(instr.m) : Double(readSingle(instr.m))
            let rounded = value.rounded(roundTowardZero ? .towardZero : fpscrRoundingRule)
            let result: UInt32
            if value.isNaN {
                result = 0
            } else if signed {
                result = UInt32(bitPattern: rounded >= 2_147_483_647 ? .max : rounded <= -2_147_483_648 ? .min : Int32(rounded))
            } else {
                result = rounded >= 4_294_967_295 ? .max : rounded <= 0 ? 0 : UInt32(rounded)
            }
            neon.setSingle(instr.d, result)
        }
    }

    /// Rounds an exactly-representable double to single precision under
    /// `rule` (Swift's `Float(_:)` always rounds to nearest).
    private static func roundToSingle(_ value: Double, _ rule: FloatingPointRoundingRule) -> Float {
        let nearest = Float(value)
        guard rule != .toNearestOrEven, Double(nearest) != value else { return nearest }
        let above = Double(nearest) > value
        switch rule {
        case .up: return above ? nearest : nearest.nextUp
        case .down: return above ? nearest.nextDown : nearest
        default: return (value > 0) == above ? (above ? nearest.nextDown : nearest.nextUp) : nearest
        }
    }
}

extension ARMInstruction {
    /// The condition of an instruction that uses the VFP/Advanced SIMD
    /// unit — UNDEFINED while FPEXC.EN is clear — or nil for any other
    /// instruction. Unconditional Advanced SIMD instructions report AL.
    /// The coprocessor register transfers aren't here: some of them stay
    /// usable with the unit disabled, so `executeVFPRegisterTransfer`
    /// makes that call itself.
    var floatingPointUnitCondition: ARMCondition? {
        switch self {
        case .vfpDataProcessing(let instr): return instr.condition
        case .extensionRegisterLoadStore(let instr): return instr.condition
        case .vfpTwoRegisterTransfer(let instr): return instr.condition
        case .bitwiseExclusiveOr, .neonModifiedImmediate, .bitwiseOr, .integerAdd,
             .vectorExtract, .vectorShiftImmediate, .elementLoadStore, .reverseElements, .neon, .neonStructureLoadStore:
            return .always
        default:
            return nil
        }
    }
}

/// A VFP operand type: `Float` or `Double`, with the bit-level quieting
/// `FPProcessNaNs` needs.
protocol VFPValue: BinaryFloatingPoint {
    var quietedNaN: Self { get }
}

extension Float: VFPValue {
    var quietedNaN: Float { Float(bitPattern: bitPattern | 0x0040_0000) }
}

extension Double: VFPValue {
    var quietedNaN: Double { Double(bitPattern: bitPattern | 0x0008_0000_0000_0000) }
}
