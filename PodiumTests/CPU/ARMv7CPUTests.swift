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

    func testMovwThenMovtBuildsFullConstant() {
        let cpu = makeCPU(program: [
            0xE301_0234, // MOVW r0, #0x1234
            0xE345_0678, // MOVT r0, #0x5678
        ])
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x5678_1234)
    }

    func testRegisterOffsetStoreThenLoadRoundTrip() {
        let cpu = makeCPU(program: [
            0xE3A0_0000, // MOV r0, #0    (base)
            0xE3A0_1014, // MOV r1, #20   (offset)
            0xE3A0_30AB, // MOV r3, #0xAB
            0xE780_3001, // STR r3, [r0, r1]
            0xE790_2001, // LDR r2, [r0, r1]
        ])
        for _ in 0..<5 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 0xAB)
    }

    func testCpsidDisablesIrqAndFiq() {
        let cpu = makeCPU(program: [0xF10C_00C0]) // cpsid if, real word from the actual kernel
        XCTAssertFalse(cpu.cpsr.irqDisabled)
        XCTAssertFalse(cpu.cpsr.fiqDisabled)

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.irqDisabled)
        XCTAssertTrue(cpu.cpsr.fiqDisabled)
    }

    func testMemoryBarriersAreNoOpsThatAdvancePC() {
        let cpu = makeCPU(program: [
            0xF57F_F04F, // dsb sy, real word from the actual kernel
            0xF57F_F06F, // isb sy, real word from the actual kernel
        ])
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 8)
    }

    func testMcrThenMrcRoundTripsThroughCP15() {
        let cpu = makeCPU(program: [
            0xE3A0_302A, // MOV r3, #42
            0xEE01_3F10, // MCR p15, #0, r3, c1, c0, #0
            0xEE11_4F10, // MRC p15, #0, r4, c1, c0, #0
        ])
        cpu.step(); cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 42)
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0), 42)
    }

    func testUnwrittenCP15RegisterReadsAsZero() {
        let cpu = makeCPU(program: [
            0xEE11_4F10, // MRC p15, #0, r4, c1, c0, #0 -- never written
        ])
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 0)
    }

    func testRealKernelInstructionsRunWithoutHalting() {
        // The actual instruction sequence from the real iPod4,1 6.1.6
        // kernel at its entry point (0x80086084 onward) that used to
        // halt on the very first `movw`. Confirms the CPU now gets
        // through it — not a claim about what these specific
        // instructions compute, since several (the `ldr [pc, lr]`-style
        // ones) target addresses far outside this small test buffer and
        // are expected to run against effectively-zeroed memory here.
        let cpu = makeCPU(program: [
            0xE3A0_1000, // mov r1, #0
            0xE30C_E42C, // movw lr, #0xc42c
            0xE340_E024, // movt lr, #0x24
            0xF10C_00C0, // cpsid if
            0xEE07_BF15, // mcr p15, #0, r11, c7, c5, #0
            0xF57F_F06F, // isb sy
            0xEE11_BF10, // mrc p15, #0, r11, c1, c0, #0
            0xE38B_BB06, // orr r11, r11, #6144
            0xEE01_BF10, // mcr p15, #0, r11, c1, c0, #0
            0xF57F_F04F, // dsb sy
            0xF57F_F06F, // isb sy
        ], memorySize: 4096)

        // Exactly 11 steps, not run(maxUnits:) with headroom: memory
        // past the program is zero-filled, and 0x00000000 decodes as a
        // valid (if inert) "ANDEQ r0, r0, r0" rather than anything that
        // would naturally halt execution, so a larger budget would just
        // keep stepping through zeroed memory instead of stopping.
        for _ in 0..<11 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 11 real kernel instructions to execute; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[1], 0)
        XCTAssertTrue(cpu.cpsr.irqDisabled)
        XCTAssertTrue(cpu.cpsr.fiqDisabled)
        // orr r11, r11, #6144 with r11 starting at 0 (never-written CP15
        // register reads as 0) leaves r11 == 6144, which then gets
        // written back to the same CP15 slot.
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0), 6144)
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
