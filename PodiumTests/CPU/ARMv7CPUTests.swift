import XCTest
@testable import Podium

/// Runs real, hand-assembled ARM instruction sequences (the same words
/// an assembler would produce — see `ARMDecoderTests` for how each was
/// derived) through the full fetch/decode/execute pipeline against a
/// real `FlatPhysicalMemory`, rather than only exercising decode or
/// execute in isolation.
final class ARMv7CPUTests: XCTestCase {
    private func makeCPU(program: [UInt32], memorySize: Int = 256) -> ARMv7CPU {
        let memory = FlatPhysicalMemory(length: memorySize)
        for (index, word) in program.enumerated() {
            try! memory.writeWord32(word, at: UInt32(index * 4))
        }
        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        return cpu
    }

    func testArithmeticPipelineEndToEnd() {
        let cpu = makeCPU(program: [
            0xE3A0_0005, // MOV r0, #5
            0xE3A0_1003, // MOV r1, #3
            0xE080_2001, // ADD r2, r0, r1
        ])
        cpu.step(); cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 5)
        XCTAssertEqual(cpu.registers[1], 3)
        XCTAssertEqual(cpu.registers[2], 8)
        XCTAssertEqual(cpu.registers.pc, 12)
    }

    func testSubsEqualOperandsSetsZeroAndCarryNoBorrow() {
        let cpu = makeCPU(program: [
            0xE3A0_0005, // MOV r0, #5
            0xE3A0_1005, // MOV r1, #5
            0xE050_2001, // SUBS r2, r0, r1
        ])
        cpu.step(); cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 0)
        XCTAssertTrue(cpu.cpsr.zero)
        XCTAssertTrue(cpu.cpsr.carry)
        XCTAssertFalse(cpu.cpsr.negative)
        XCTAssertFalse(cpu.cpsr.overflow)
    }

    func testUnconditionalBranchSkipsInstruction() {
        let cpu = makeCPU(program: [
            0xEA00_0000, // B #8  (skip the next instruction)
            0xE3A0_0007, // MOV r0, #7  -- must NOT execute
            0xE3A0_000A, // MOV r0, #10 -- branch target
        ])
        cpu.step() // B
        cpu.step() // MOV r0, #10 at address 8

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 10)
        XCTAssertEqual(cpu.registers.pc, 12)
    }

    func testBranchWithLinkSetsReturnAddress() {
        let cpu = makeCPU(program: [
            0xEB00_0000, // BL #8
        ])
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 8)
        XCTAssertEqual(cpu.registers.lr, 4) // address of the instruction after the BL
    }

    func testStoreThenLoadRoundTrip() {
        let cpu = makeCPU(program: [
            0xE3A0_1080, // MOV r1, #128
            0xE3A0_002A, // MOV r0, #42
            0xE581_0000, // STR r0, [r1]
            0xE591_2000, // LDR r2, [r1]
        ])
        for _ in 0..<4 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 42)
        XCTAssertEqual(cpu.registers[2], 42)
    }

    func testUnsupportedInstructionHaltsRunHonestly() {
        let cpu = makeCPU(program: [
            0xE3A0_0005, // MOV r0, #5 -- executes fine
            0xE000_0090, // multiply-space encoding -- not implemented
            0xE3A0_00FF, // would set r0 to 0xFF if ever reached
        ])
        cpu.run()

        XCTAssertEqual(cpu.registers[0], 5, "The instruction before the unsupported one should still have run")
        guard case .unsupportedInstruction(let rawWord, let address) = cpu.lastError else {
            return XCTFail("Expected .unsupportedInstruction, got \(String(describing: cpu.lastError))")
        }
        XCTAssertEqual(rawWord, 0xE000_0090)
        XCTAssertEqual(address, 4)
    }

    func testConditionalInstructionSkippedWhenConditionFails() {
        let cpu = makeCPU(program: [
            0xE3A0_0000, // MOV r0, #0  (also clears Z, since S==0 here it does NOT touch flags —
                         //              flags start at their CPSR.reset() value, Z == false)
            0x03A0_0009, // MOVEQ r0, #9 -- condition EQ, but Z is false, so this must not execute
        ])
        cpu.step()
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0, "MOVEQ should have been skipped since Z was clear")
        XCTAssertEqual(cpu.registers.pc, 8, "PC still advances past a skipped instruction")
    }
}
