import XCTest
@testable import Podium

/// VFPv3: every word here was checked against Capstone, and most are the
/// real kernelcache's own (`vadd.f64 d16, d17, d16`, `vcmpe.f64 d16, d17`,
/// `vcvt.f64.s32 d16, s0`, ... from the kexts).
final class VFPTests: XCTestCase {
    private func makeCPU(program: [UInt32], fpuEnabled: Bool = true) -> ARMv7CPU {
        let memory = FlatPhysicalMemory(length: 256)
        for (index, word) in program.enumerated() {
            try! memory.writeWord32(word, at: UInt32(index * 4))
        }
        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        if fpuEnabled { cpu.fpexc = ARMv7CPU.fpexcEnableBit }
        return cpu
    }

    private func setDouble(_ cpu: ARMv7CPU, _ index: Int, _ value: Double) { cpu.neon[index] = value.bitPattern }
    private func double(_ cpu: ARMv7CPU, _ index: Int) -> Double { Double(bitPattern: cpu.neon[index]) }

    func testDecodesVaddF64() {
        guard case .vfpDataProcessing(let instr) = ARMDecoder.decode(0xEE71_0BA0) else {
            return XCTFail("Expected vfpDataProcessing")
        }
        XCTAssertEqual(instr, VFPDataProcessingInstruction(condition: .always, operation: .add, isDouble: true, d: 16, n: 17, m: 16))
    }

    func testDoubleArithmetic() {
        let cpu = makeCPU(program: [
            0xEE71_0BA0, // vadd.f64 d16, d17, d16
            0xEE60_0BA1, // vmul.f64 d16, d16, d17
            0xEE70_0BE1, // vsub.f64 d16, d16, d17
            0xEEC0_0BA1, // vdiv.f64 d16, d16, d17
        ])
        setDouble(cpu, 16, 2.25)
        setDouble(cpu, 17, 1.5)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 3.75)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 5.625)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 4.125)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 2.75)
        XCTAssertNil(cpu.lastError)
    }

    func testMultiplyAccumulateForms() {
        let cpu = makeCPU(program: [
            0xEE41_0BA2, // vmla.f64 d16, d17, d18: d16 = d16 + d17*d18
            0xEE51_0BE2, // vnmla.f64 d16, d17, d18: d16 = -d16 - d17*d18
        ])
        setDouble(cpu, 16, 1)
        setDouble(cpu, 17, 2)
        setDouble(cpu, 18, 3)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 7)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), -13)
    }

    /// `vcmpe` sets FPSCR's NZCV; `vmrs APSR_nzcv, fpscr` copies it to the
    /// CPSR for the following conditional code.
    func testCompareAndTransferFlags() {
        let cpu = makeCPU(program: [
            0xEEF4_0BE1, // vcmpe.f64 d16, d17
            0xEEF1_FA10, // vmrs APSR_nzcv, fpscr
        ])
        setDouble(cpu, 16, 1)
        setDouble(cpu, 17, 2)
        cpu.step(); cpu.step()
        XCTAssertTrue(cpu.cpsr.negative, "less than")
        XCTAssertFalse(cpu.cpsr.zero)
        XCTAssertFalse(cpu.cpsr.carry)

        cpu.registers.pc = 0
        setDouble(cpu, 16, .nan)
        cpu.step(); cpu.step()
        XCTAssertEqual(cpu.cpsr.rawValue >> 28, 0b0011, "unordered")

        cpu.registers.pc = 0
        setDouble(cpu, 16, 2)
        cpu.step(); cpu.step()
        XCTAssertEqual(cpu.cpsr.rawValue >> 28, 0b0110, "equal")
    }

    func testCompareWithZero() {
        let cpu = makeCPU(program: [0xEEF5_0BC0, 0xEEF1_FA10]) // vcmpe.f64 d16, #0; vmrs
        setDouble(cpu, 16, 0.5)
        cpu.step(); cpu.step()
        XCTAssertEqual(cpu.cpsr.rawValue >> 28, 0b0010, "greater than")
    }

    func testIntegerConversions() {
        let cpu = makeCPU(program: [
            0xEEF8_0BC0, // vcvt.f64.s32 d16, s0
            0xEEBD_0BE0, // vcvt.s32.f64 s0, d16  (round toward zero)
            0xEEF8_0B40, // vcvt.f64.u32 d16, s0
        ])
        cpu.neon.setSingle(0, UInt32(bitPattern: -7))
        cpu.step()
        XCTAssertEqual(double(cpu, 16), -7)

        setDouble(cpu, 16, -2.9)
        cpu.step()
        XCTAssertEqual(Int32(bitPattern: cpu.neon.single(0)), -2)

        cpu.neon.setSingle(0, 0xFFFF_FFFF)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 4_294_967_295)
    }

    func testConversionToIntegerSaturatesAndMapsNaNToZero() {
        let cpu = makeCPU(program: [0xEEBD_0BE0, 0xEEBD_0BE0, 0xEEBC_0BE0]) // s32, s32, u32
        setDouble(cpu, 16, 1e20)
        cpu.step()
        XCTAssertEqual(cpu.neon.single(0), 0x7FFF_FFFF)
        setDouble(cpu, 16, .nan)
        cpu.step()
        XCTAssertEqual(cpu.neon.single(0), 0)
        setDouble(cpu, 16, -5)
        cpu.step()
        XCTAssertEqual(cpu.neon.single(0), 0, "unsigned conversion clamps negatives to 0")
    }

    func testPrecisionConversions() {
        let cpu = makeCPU(program: [
            0xEEF7_0AC0, // vcvt.f64.f32 d16, s0
            0xEEB7_0BE0, // vcvt.f32.f64 s0, d16
        ])
        cpu.neon.setSingle(0, Float(1.25).bitPattern)
        cpu.step()
        XCTAssertEqual(double(cpu, 16), 1.25)
        setDouble(cpu, 16, 0.1)
        cpu.step()
        XCTAssertEqual(Float(bitPattern: cpu.neon.single(0)), Float(0.1))
    }

    func testMoveImmediateAndSquareRoot() {
        let cpu = makeCPU(program: [
            0xEEF7_0B00, // vmov.f64 d16, #1.0
            0xEEB0_0A00, // vmov.f32 s0, #2.0
            0xEEB1_0BE0, // vsqrt.f64 d0, d16
        ])
        cpu.step()
        XCTAssertEqual(cpu.neon[16], 0x3FF0_0000_0000_0000)
        cpu.step()
        XCTAssertEqual(cpu.neon.single(0), Float(2).bitPattern)
        setDouble(cpu, 16, 6.25)
        cpu.step()
        XCTAssertEqual(double(cpu, 0), 2.5)
    }

    func testSinglePrecisionDivide() {
        let cpu = makeCPU(program: [0xEE88_0A00]) // vdiv.f32 s0, s16, s0
        cpu.neon.setSingle(16, Float(1).bitPattern)
        cpu.neon.setSingle(0, Float(3).bitPattern)
        cpu.step()
        XCTAssertEqual(Float(bitPattern: cpu.neon.single(0)), Float(1) / Float(3))
    }

    /// Core <-> S register and scalar transfers go to the real register
    /// file (they used to land in a generic coprocessor store instead).
    func testCoreTransfersReachTheRegisterFile() {
        let cpu = makeCPU(program: [
            0xEE00_0A10, // vmov s0, r0
            0xEE10_1A10, // vmov r1, s0
            0xEE20_2B90, // vmov.32 d16[1], r2
            0xEE30_0B90, // vmov.32 r0, d16[1]
        ])
        cpu.registers[0] = 0x1234_5678
        cpu.registers[2] = 0xCAFE_F00D
        cpu.step()
        XCTAssertEqual(cpu.neon.single(0), 0x1234_5678)
        cpu.step()
        XCTAssertEqual(cpu.registers[1], 0x1234_5678)
        cpu.step()
        XCTAssertEqual(cpu.neon[16] >> 32, 0xCAFE_F00D)
        cpu.step()
        XCTAssertEqual(cpu.registers[0], 0xCAFE_F00D)
    }

    /// FPEXC.EN clear (XNU's lazy switching): a VFP instruction is
    /// UNDEFINED and enters the Undefined Instruction exception, while
    /// VMRS/VMSR FPEXC stay usable so the handler can turn the unit on.
    func testDisabledUnitTrapsButFPEXCStaysAccessible() {
        let cpu = makeCPU(program: [
            0xEEF8_0A10, // vmrs r0, fpexc
            0xEE71_0BA0, // vadd.f64 d16, d17, d16 — traps
        ], fpuEnabled: false)
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~0x1F) | ARMv7CPU.svcModeBits
        setDouble(cpu, 16, 1)
        setDouble(cpu, 17, 1)
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0)
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.undefinedModeBits)
        XCTAssertEqual(cpu.registers.pc, 0x04)
        XCTAssertEqual(cpu.registers.lr, 8, "LR_und = the instruction's address + 4 in ARM state")
        XCTAssertEqual(double(cpu, 16), 1, "the add didn't happen")
        XCTAssertEqual(cpu.savedProgramStatus(forModeBits: ARMv7CPU.undefinedModeBits).map { $0 & 0x1F }, ARMv7CPU.svcModeBits)
    }

    func testEnablingTheUnitThroughFPEXC() {
        let cpu = makeCPU(program: [0xEEE8_0A10, 0xEE71_0BA0], fpuEnabled: false) // vmsr fpexc, r0; vadd.f64
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~0x1F) | ARMv7CPU.svcModeBits
        cpu.registers[0] = ARMv7CPU.fpexcEnableBit
        setDouble(cpu, 16, 1)
        setDouble(cpu, 17, 2)
        cpu.step(); cpu.step()
        XCTAssertEqual(double(cpu, 16), 3)
    }

    /// In Thumb state LR_und is the address + 2 even for a 32-bit
    /// instruction — the handler reads the halfword at LR-2.
    func testThumbTrapLinkRegisterPointsAtSecondHalfword() {
        let memory = FlatPhysicalMemory(length: 256)
        try! memory.writeWord16(0xEE71, at: 0x20)
        try! memory.writeWord16(0x0BA0, at: 0x22) // vadd.f64 d16, d17, d16
        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        cpu.cpsr.thumbState = true
        cpu.registers.pc = 0x20
        cpu.step()
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.undefinedModeBits)
        XCTAssertEqual(cpu.registers.lr, 0x22)
        XCTAssertFalse(cpu.cpsr.thumbState)
    }

    func testFlushToZeroAndDefaultNaN() {
        let cpu = makeCPU(program: [0xEE60_0BA1, 0xEEC0_0BA1]) // vmul.f64 d16, d16, d17; vdiv.f64 d16, d16, d17
        cpu.fpscr = 1 << 24 | 1 << 25 // FZ | DN, the kernel's own setting
        setDouble(cpu, 16, Double.leastNormalMagnitude)
        setDouble(cpu, 17, 0.5)
        cpu.step()
        XCTAssertEqual(cpu.neon[16], 0, "a denormal result is flushed to +0")
        setDouble(cpu, 16, 0)
        setDouble(cpu, 17, 0)
        cpu.step()
        XCTAssertEqual(cpu.neon[16], 0x7FF8_0000_0000_0000, "0/0 gives the default NaN")
    }

    func testThumbRoutesVFPDataProcessingThroughTheARMDecoder() {
        guard case .advancedSIMD(let wrapped) = ThumbDecoder.decode(0xEE71, 0x0BA0),
              case .vfpDataProcessing(let instr) = wrapped.instruction else {
            return XCTFail("Expected vfpDataProcessing")
        }
        XCTAssertEqual(instr.operation, .add)
    }
}
