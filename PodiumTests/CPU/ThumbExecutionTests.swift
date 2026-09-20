import XCTest
@testable import Podium

/// Runs real Thumb instruction sequences (words verified the same way
/// `ThumbDecoderTests` verifies decode — see its doc comment) through
/// the full fetch/decode/execute pipeline against a real
/// `FlatPhysicalMemory`.
final class ThumbExecutionTests: XCTestCase {
    private func makeThumbCPU(program: [UInt16], memorySize: Int = 256) -> ARMv7CPU {
        let memory = FlatPhysicalMemory(length: memorySize)
        for (index, halfword) in program.enumerated() {
            try! memory.writeWord16(halfword, at: UInt32(index * 2))
        }
        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        cpu.cpsr.thumbState = true
        return cpu
    }

    func testBxFromArmSwitchesToThumbAndExecutesRealInstruction() {
        // Entered the only way real guest code would: an ARM-state BX
        // whose target has bit 0 set. Confirms the interworking switch
        // itself, not just Thumb execution in isolation.
        let memory = FlatPhysicalMemory(length: 256)
        try! memory.writeWord32(0xE12F_FF10, at: 0) // BX r0
        try! memory.writeWord16(0x2105, at: 8) // movs r1, #5 (Thumb, at address 8)

        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        cpu.loadInitialRegisters([9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) // r0 = 9: target 8, bit0 set.

        cpu.step() // BX r0
        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.thumbState)
        XCTAssertEqual(cpu.registers.pc, 8)

        cpu.step() // movs r1, #5, now genuinely fetched/decoded/executed as Thumb.
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 5)
    }

    func testItBlockExecutesInstructionWhenConditionHolds() {
        let cpu = makeThumbCPU(program: [
            0x2000, // movs r0, #0   (sets Z)
            0xbf08, // it eq
            0x2107, // moveq r1, #7
        ])
        for _ in 0..<3 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 7)
    }

    func testItBlockSkipsInstructionWhenConditionFails() {
        let cpu = makeThumbCPU(program: [
            0x2001, // movs r0, #1   (clears Z)
            0xbf08, // it eq
            0x2107, // moveq r1, #7 -- must NOT execute
        ])
        for _ in 0..<3 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0)
    }

    func testPushThenPopRoundTripsRegisters() {
        let cpu = makeThumbCPU(program: [
            0x2404, // movs r4, #4
            0x2505, // movs r5, #5
            0xb430, // push {r4, r5}
            0x2400, // movs r4, #0   -- clobber before reloading
            0x2500, // movs r5, #0   -- clobber before reloading
            0xbc30, // pop {r4, r5}
        ], memorySize: 256)
        cpu.registers.sp = 128
        for _ in 0..<6 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 4)
        XCTAssertEqual(cpu.registers[5], 5)
        XCTAssertEqual(cpu.registers.sp, 128)
    }

    func testBlBranchesAndSetsLRWithThumbBit() {
        let cpu = makeThumbCPU(program: [
            0xf000, 0xf802, // bl +4 (from address 0 to address 8)
            0x0000, 0x0000, // padding at addresses 4 and 6 (never executed)
            0x2209, // movs r2, #9 (at address 8, the bl target)
        ], memorySize: 256)
        cpu.step() // bl
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 8)
        XCTAssertEqual(cpu.registers.lr, 5) // instruction-after-bl address (4), with the Thumb bit set

        cpu.step() // movs r2, #9 at the bl target
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 9)
    }

    func testMovwThenMovtBuildsFullConstant() {
        let cpu = makeThumbCPU(program: [
            0xf649, 0x6464, // movw r4, #0x9e64, real word from the actual kernel
            0xf2c0, 0x0404, // movt r4, #4, real word from the actual kernel
        ])
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 0x0004_9E64)
    }

    func testBicModifiedImmediateClearsBit() {
        let cpu = makeThumbCPU(program: [
            0x21FF, // movs r1, #0xFF
            0xf021, 0x0101, // bic r1, r1, #1, real word from the actual kernel
        ])
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xFE)
    }

    func testAddWModifiedImmediateComputesRealKernelConstant() {
        // add.w r0, r4, #0x120 — real word from the actual kernel,
        // independently confirming the ThumbExpandImm rotate-case math
        // at the CPU level, not just via the decoder unit test.
        let cpu = makeThumbCPU(program: [
            0xf504, 0x7090,
        ])
        cpu.registers[4] = 0x8000_0000
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x8000_0120)
    }

    func testLsrByImmediateRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0x0A00, // lsr r0, r0, #8, real word from the actual kernel
        ])
        cpu.registers[0] = 0xABCD_1234
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x00AB_CD12)
    }

    func testAsrByZeroImmediateMeansShiftByThirtyTwo() {
        let cpu = makeThumbCPU(program: [
            0x1023, // asr r3, r4, #0 (encoded 0 means #32, same convention as ARM state)
        ])
        cpu.registers[4] = 0x8000_0000 // negative
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[3], 0xFFFF_FFFF) // sign-filled
        XCTAssertTrue(cpu.cpsr.carry) // bit 31 shifted out last
    }

    func testStrhThenLdrhRoundTripsOnlyTheLowHalfword() {
        let cpu = makeThumbCPU(program: [
            0x8091, // strh r1, [r2, #4]
            0x8890, // ldrh r0, [r2, #4]
        ])
        cpu.registers[1] = 0xAABB_CCDD
        cpu.registers[2] = 0
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xCCDD)
    }

    func testLdrhRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0x8D60, // ldrh r0, [r4, #42], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[4] = 0
        try! (cpu.memory as! FlatPhysicalMemory).writeWord16(0xBEEF, at: 42)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xBEEF)
    }

    func testStrbThenLdrbRoundTripsOnlyTheLowByte() {
        let cpu = makeThumbCPU(program: [
            0xF886, 0x0064, // strb r0, [r6, #0x64], real word from the actual kernel
            0xF896, 0x1064, // ldrb r1, [r6, #0x64]
        ])
        cpu.registers[0] = 0xAABB_CCDD
        cpu.registers[6] = 0
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xDD)
    }

    func testMrcRoundTripsThroughCP15RealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xee1d, 0x0f90, // mrc p15, #0, r0, c13, c0, #4, real word from the actual kernel
        ])
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0) // never-written CP15 register reads as 0
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 13, crm: 0, opc2: 4), 0)
    }

    func testBeqWBranchesWhenZeroFlagSet() {
        let cpu = makeThumbCPU(program: [
            0x2000, // movs r0, #0   (sets Z)
            0xf000, 0x8001, // beq.w +2 (real word shape from the actual kernel, retargeted for this small test buffer)
            0x2101, // movs r1, #1 -- must NOT execute
        ])
        cpu.step() // movs r0, #0
        cpu.step() // beq.w -- branches since Z is set

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 8) // instrAddr(2) + 4 + offset(2) == 8, landing past the "must not execute" word
    }

    func testBeqWSkippedWhenZeroFlagClear() {
        let cpu = makeThumbCPU(program: [
            0x2001, // movs r0, #1   (clears Z)
            0xf000, 0x8001, // beq.w +2
            0x2101, // movs r1, #1 -- must execute since the branch is not taken
        ])
        for _ in 0..<3 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 1)
    }

    func testPushWDbDirectionStoresBelowOriginalSP() {
        let cpu = makeThumbCPU(program: [
            0xe92d, 0x0d00, // push.w {r8, sl, fp}, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers.sp = 100
        cpu.registers[8] = 0x8888_8888
        cpu.registers[10] = 0xAAAA_AAAA
        cpu.registers[11] = 0xBBBB_BBBB
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.sp, 88) // 100 - 3*4
        XCTAssertEqual(try! cpu.memory.readWord32(at: 88), 0x8888_8888) // r8, lowest register, lowest address
        XCTAssertEqual(try! cpu.memory.readWord32(at: 92), 0xAAAA_AAAA) // r10
        XCTAssertEqual(try! cpu.memory.readWord32(at: 96), 0xBBBB_BBBB) // r11
    }

    func testStmWStoresRegistersRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xe881, 0x0009, // stm.w r1, {r0, r3}, real word from the actual kernel
            0xF8D1, 0x2000, // ldr.w r2, [r1]       -- readback of the first stored word
            0xF8D1, 0x4004, // ldr.w r4, [r1, #4]   -- readback of the second stored word
        ], memorySize: 256)
        cpu.registers[0] = 0x1111_1111
        cpu.registers[3] = 0x3333_3333
        cpu.registers[1] = 64
        for _ in 0..<3 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 3 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[2], 0x1111_1111) // r0, the lowest-numbered register, at the lowest address
        XCTAssertEqual(cpu.registers[4], 0x3333_3333) // r3 immediately after
        XCTAssertEqual(cpu.registers[1], 64, "stm.w without '!' must not write back the base")
    }

    func testUxtbZeroExtendsLowByte() {
        let cpu = makeThumbCPU(program: [
            0xb2c0, // uxtb r0, r0, real word from the actual kernel
        ])
        cpu.registers[0] = 0xAABB_CCDD
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xDD)
    }

    func testSxtbSignExtendsNegativeByte() {
        let cpu = makeThumbCPU(program: [
            0xb241, // sxtb r1, r0
        ])
        cpu.registers[0] = 0x0000_00FF // low byte 0xFF: negative as a signed byte
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xFFFF_FFFF)
    }

    func testCbzBranchesWhenRegisterIsZero() {
        let cpu = makeThumbCPU(program: [
            0x2000, // movs r0, #0
            0xb130, // cbz r0, <offset> (real word from the actual kernel)
            0x2107, // movs r1, #7 -- must NOT execute
        ])
        cpu.step() // movs r0, #0
        cpu.step() // cbz -- branches

        XCTAssertNil(cpu.lastError)
        // cbz is at byte address 2; target = 2 + 4 + 12 (this word's
        // encoded offset) = 0x12.
        XCTAssertEqual(cpu.registers.pc, 0x12)
    }

    func testRealKernelPrologueInstructionsRunWithoutHalting() {
        // The actual opening instruction sequence of the real kernel's
        // struct-initializer function at 0x802b8268 (see
        // `ThumbDecoder`'s doc comment) — confirms the pieces work
        // together, not just each in isolation. Only the pure
        // register/memory-independent prefix is included (the tail
        // reads/writes through pointers this small test buffer doesn't
        // back).
        let cpu = makeThumbCPU(program: [
            0xb5f0, // push {r4,r5,r6,r7,lr}
            0xf649, 0x6464, // movw r4, #0x9e64
            0x2600, // movs r6, #0
            0xf2c0, 0x0404, // movt r4, #4
        ], memorySize: 4096)
        cpu.registers.sp = 256

        for _ in 0..<4 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 4 real kernel instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[4], 0x0004_9E64)
        XCTAssertEqual(cpu.registers[6], 0)
        XCTAssertEqual(cpu.registers.sp, 256 - 20) // 5 registers pushed
    }

    func testLdrWRegisterOffsetRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf855, 0x3030, // ldr.w r3, [r5, r0, lsl #3], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[5] = 0
        cpu.registers[0] = 2 // offset = r0 << 3 = 16
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0xC0FF_EE00, at: 16)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[3], 0xC0FF_EE00)
    }

    func testSubWShiftedRegisterRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xeba3, 0x0109, // sub.w r1, r3, sb (r9), real word from the actual kernel
        ])
        cpu.registers[3] = 100
        cpu.registers[9] = 30
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 70)
    }
}
