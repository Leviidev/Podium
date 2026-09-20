import XCTest
@testable import Podium

final class ShifterOperandTests: XCTestCase {
    private var registers = Registers()

    override func setUp() {
        registers = Registers()
    }

    func testLSLByZeroPassesThroughCarryUnchanged() {
        registers[0] = 0x1234
        let op = ShifterOperand.shiftedRegister(rm: 0, shiftType: .lsl, shiftAmount: 0)
        let resolved = op.resolve(registers: registers, currentCarry: true)
        XCTAssertEqual(resolved.value, 0x1234)
        XCTAssertTrue(resolved.carryOut)
    }

    func testLSLByOneShiftsOutBit31AsCarry() {
        registers[0] = 0x8000_0000
        let op = ShifterOperand.shiftedRegister(rm: 0, shiftType: .lsl, shiftAmount: 1)
        let resolved = op.resolve(registers: registers, currentCarry: false)
        XCTAssertEqual(resolved.value, 0)
        XCTAssertTrue(resolved.carryOut)
    }

    func testLSRByThirtyTwoEncodedAsZeroShiftsOutEverything() {
        registers[0] = 0x8000_0001
        // shift_imm == 0 with LSR means "LSR #32", not "no shift".
        let op = ShifterOperand.shiftedRegister(rm: 0, shiftType: .lsr, shiftAmount: 0)
        let resolved = op.resolve(registers: registers, currentCarry: false)
        XCTAssertEqual(resolved.value, 0)
        XCTAssertTrue(resolved.carryOut) // bit 31 of the original value.
    }

    func testASRSignExtendsNegativeValues() {
        registers[0] = 0x8000_0000 // INT32_MIN
        let op = ShifterOperand.shiftedRegister(rm: 0, shiftType: .asr, shiftAmount: 4)
        let resolved = op.resolve(registers: registers, currentCarry: false)
        XCTAssertEqual(resolved.value, 0xF800_0000)
    }

    func testRotateRightByEight() {
        XCTAssertEqual(ShifterOperand.rotateRight(0x1234_5678, by: 8), 0x7812_3456)
    }

    func testRRXRotatesThroughCarry() {
        registers[0] = 0x0000_0001
        let op = ShifterOperand.shiftedRegister(rm: 0, shiftType: .ror, shiftAmount: 0)
        let resolved = op.resolve(registers: registers, currentCarry: true)
        XCTAssertEqual(resolved.value, 0x8000_0000)
        XCTAssertTrue(resolved.carryOut) // bit 0 of the original value.
    }

    func testImmediateOperandPassesThroughUnchangedCarryWhenRotateIsZero() {
        let op = ShifterOperand.immediate(value: 0xFF, forcedCarryOut: nil)
        let resolved = op.resolve(registers: registers, currentCarry: true)
        XCTAssertEqual(resolved.value, 0xFF)
        XCTAssertTrue(resolved.carryOut)
    }

    func testImmediateOperandWithRotationForcesCarryFromBit31() {
        // #0xFF000000 — imm8 0xFF rotated right by 8.
        let rotated = ShifterOperand.rotateRight(0xFF, by: 8)
        let op = ShifterOperand.immediate(value: rotated, forcedCarryOut: rotated & 0x8000_0000 != 0)
        let resolved = op.resolve(registers: registers, currentCarry: false)
        XCTAssertEqual(resolved.value, 0xFF00_0000)
        XCTAssertTrue(resolved.carryOut)
    }

    func testPCReadAsShiftedRegisterOperandIsInstructionAddressPlusEight() {
        // `registers.pc` holds the address of the *next* instruction to
        // fetch (see `Registers.pcForOperandRead`'s doc comment) — by the
        // time an instruction at address 100 is executing, `step()` has
        // already advanced `pc` to 104. An operand read of r15 should
        // then see 100 + 8 = 108.
        registers.pc = 104
        let op = ShifterOperand.shiftedRegister(rm: Registers.pcIndex, shiftType: .lsl, shiftAmount: 0)
        let resolved = op.resolve(registers: registers, currentCarry: false)
        XCTAssertEqual(resolved.value, 108)
    }
}
