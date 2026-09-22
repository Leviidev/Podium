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

    func testLdmiaLoadsRegistersAndSkipsWritebackWhenBaseInListRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xce4c, // ldm r6, {r2, r3, r6}, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[6] = 100
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0x1111_1111, at: 100)
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0x2222_2222, at: 104)
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0x3333_3333, at: 108)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 0x1111_1111)
        XCTAssertEqual(cpu.registers[3], 0x2222_2222)
        // r6 (the base) is both loaded from the list and used as the
        // base -- no separate writeback, so it ends up with the
        // loaded value, not the incremented base address.
        XCTAssertEqual(cpu.registers[6], 0x3333_3333)
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

    /// Traced back from a real mid-boot halt (`unsupportedInstruction` at
    /// 0x80033a44, an emulated kernel that by then had already correctly
    /// run 18M+ instructions past the `TBB` fix above): the register-offset
    /// halfword form of `STRH`/`LDRH` shares this same instruction family
    /// as `testLdrWRegisterOffsetRealKernelWord` above but wasn't decoded
    /// yet, since no real word had confirmed it before this one did.
    /// Traced back from a real early-boot kernel panic: a genuine null
    /// pointer store, caused by the 4th instruction of a real `itttt ne`
    /// block (`addne.w r0, r1, r0, lsl #2`) being wrongly skipped. Root
    /// cause was the 3rd instruction, `andne r0, r6` — a 16-bit Thumb
    /// `AND` — unconditionally overwriting the `Z` flag `cmp r1, #0` had
    /// set for `NE`, even though 16-bit Thumb ALU ops must leave flags
    /// alone when they're themselves the conditional target of an active
    /// `IT` block. All 5 real words are from the actual kernel at
    /// 0x80033336.
    func testAndInsideItBlockDoesNotClobberFlagsRealKernelWords() {
        let cpu = makeThumbCPU(program: [
            0x2900, // cmp r1, #0
            0xbf1f, // itttt ne
            0xf8db, 0x0000, // ldrne.w r0, [fp]  (fp == r11)
            0x3801, // subne r0, #1
            0x4030, // andne r0, r6
            0xeb01, 0x0080, // addne.w r0, r1, r0, lsl #2
        ], memorySize: 256)
        cpu.registers[1] = 0xC058_C000 // non-zero: NE holds throughout
        cpu.registers[6] = 0
        cpu.registers[11] = 64 // fp
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0x200, at: 64)

        for _ in 0..<6 {
            cpu.step()
            XCTAssertNil(cpu.lastError)
        }

        // ldrne: r0 = 0x200; subne: r0 = 0x1ff; andne: r0 = 0x1ff & r6(0) = 0,
        // and must NOT touch Z (still true from `cmp r1,#0` seeing r1 != 0
        // is false... concretely: Z stays clear, so NE keeps holding);
        // addne.w: r0 = r1 + (r0 << 2) = 0xC058C000 + 0 = 0xC058C000.
        XCTAssertEqual(cpu.registers[0], 0xC058_C000)
    }

    func testVmovI32QRegisterImmediateZeroRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xefc0, 0x0050, // vmov.i32 q8, #0, real word from the actual kernel
        ], memorySize: 256)
        cpu.neon[16] = 0xFFFF_FFFF_FFFF_FFFF
        cpu.neon[17] = 0xFFFF_FFFF_FFFF_FFFF
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0) // D16 (low half of Q8)
        XCTAssertEqual(cpu.neon[17], 0) // D17 (high half of Q8)
    }

    func testVmovI32QRegisterImmediateNonzeroReplicatesAcrossLanes() {
        let cpu = makeThumbCPU(program: [
            0xefc0, 0x0051, // vmov.i32 q8, #1 (hw1 bit0 flipped from the real word)
        ], memorySize: 256)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0x0000_0001_0000_0001)
        XCTAssertEqual(cpu.neon[17], 0x0000_0001_0000_0001)
    }

    func testVstmiaDoubleRegisterListRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xecc2, 0x0b04, // vstmia r2, {d16, d17}, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[2] = 32
        cpu.neon[16] = 0x1111_1111_2222_2222
        cpu.neon[17] = 0x3333_3333_4444_4444
        cpu.step()

        XCTAssertNil(cpu.lastError)
        let memory = cpu.memory as! FlatPhysicalMemory
        XCTAssertEqual(try memory.readWord32(at: 32), 0x2222_2222) // D16 low word
        XCTAssertEqual(try memory.readWord32(at: 36), 0x1111_1111) // D16 high word
        XCTAssertEqual(try memory.readWord32(at: 40), 0x4444_4444) // D17 low word
        XCTAssertEqual(try memory.readWord32(at: 44), 0x3333_3333) // D17 high word
        XCTAssertEqual(cpu.registers[2], 32) // no writeback in this real word
    }

    func testSmmulRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfb50, 0xf001, // smmul r0, r0, r1, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[0] = 0x8000_0000 // -2^31
        cpu.registers[1] = 2
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // (-2^31 * 2) = -2^32; top 32 bits of the 64-bit result = -1.
        XCTAssertEqual(cpu.registers[0], 0xFFFF_FFFF)
    }

    func testPkhbtRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xeac1, 0x0000, // pkhbt r0, r1, r0, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 0x1111_2222
        cpu.registers[0] = 0x3333_4444
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Rd[31:16] = Rm[31:16] (no shift), Rd[15:0] = Rn[15:0].
        XCTAssertEqual(cpu.registers[0], 0x3333_2222)
    }

    func testRbitRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfa91, 0xf0a1, // rbit r0, r1, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 0x0000_0001
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x8000_0000)
    }

    func testMlsRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfb01, 0x3010, // mls r0, r1, r0, r3, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 5
        cpu.registers[0] = 3
        cpu.registers[3] = 100
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // r0 = ra(100) - rn(5)*rm(3, the OLD r0) = 100 - 15 = 85.
        XCTAssertEqual(cpu.registers[0], 85)
    }

    func testRevRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xba00, // rev r0, r0, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[0] = 0x1122_3344
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x4433_2211)
    }

    func testRev16() {
        let cpu = makeThumbCPU(program: [
            0xba40, // rev16 r0, r0 (base word with bit6 set)
        ], memorySize: 256)
        cpu.registers[0] = 0x1122_3344
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x2211_4433)
    }

    /// Traced back from a real, otherwise-inexplicable kernel data abort
    /// during IOKit startup (a kernel that had, by then, already run
    /// correctly for 18M+ instructions past every other fix this
    /// session): `ldr.w r8, [pc, #0x158]` sitting at a 2-byte-aligned
    /// (not 4-byte-aligned) address read 2 bytes into its literal pool
    /// instead of at the start, loading the wrong 32-bit constant, which
    /// then flowed into a PC-relative address computation and produced a
    /// garbage pointer that crashed `strncmp`. The other `loadStoreWide`
    /// tests in this file don't catch this because they all place the
    /// instruction at address 0 (4-byte aligned already, where the buggy
    /// and correct formulas happen to agree) — same class of gap
    /// `testTbbAtUnalignedAddressReadsTableRightAfterInstructionRealKernelWord`
    /// already covers for `TBB`.
    func testLdrPcRelativeWideAtUnalignedAddressRealKernelWord() {
        let memory = FlatPhysicalMemory(length: 0x200)
        try! memory.writeWord16(0xf8df, at: 2) // ldr.w r8, [pc, #0x158] — real word from the actual kernel, at 0x8023083e
        try! memory.writeWord16(0x8158, at: 4) // second halfword of the same instruction
        // Correct literal address: Align(2+4,4) + 0x158 == 4 + 0x158 == 0x15c.
        // The pre-fix bug would instead read from the unaligned (2+4) +
        // 0x158 == 0x15e, landing 2 bytes into this word plus 2 bytes of
        // whatever follows it — never equal to the correct value below.
        try! memory.writeWord32(0xC0FF_EE00, at: 0x15c)

        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        cpu.cpsr.thumbState = true
        cpu.registers.pc = 2

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[8], 0xC0FF_EE00)
    }

    func testStrhWRegisterOffsetRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf821, 0x2023, // strh.w r2, [r1, r3, lsl #2], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 0
        cpu.registers[3] = 2 // offset = r3 << 2 = 8
        cpu.registers[2] = 0xC0FF_EE55
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(try (cpu.memory as! FlatPhysicalMemory).readWord16(at: 8), 0xEE55)
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

    func testLdrsbSignExtendsNegativeByteRealKernelWordAndWritesBack() {
        let cpu = makeThumbCPU(program: [
            0xf915, 0x0f01, // ldrsb r0, [r5, #1]!, real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[5] = 10
        try! (cpu.memory as! FlatPhysicalMemory).writeByte(0xFF, at: 11) // -1 as a signed byte.
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xFFFF_FFFF)
        XCTAssertEqual(cpu.registers[5], 11) // pre-indexed with writeback.
    }

    func testLdrsbWRegisterOffsetSignExtendsRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf911, 0x8000, // ldrsb.w r8, [r1, r0], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 10
        cpu.registers[0] = 5
        try! (cpu.memory as! FlatPhysicalMemory).writeByte(0xFF, at: 15) // -1 as a signed byte.
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[8], 0xFFFF_FFFF)
    }

    func testLdrshWideSignExtendsNegativeHalfwordRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf9b6, 0x2000, // ldrsh.w r2, [r6], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[6] = 10
        try! (cpu.memory as! FlatPhysicalMemory).writeWord16(0xFFFE, at: 10) // -2 as a signed halfword.
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 0xFFFF_FFFE)
    }

    func testLdrhWideLoadsHalfwordRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf8b8, 0x1000, // ldrh.w r1, [r8], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[8] = 10
        try! (cpu.memory as! FlatPhysicalMemory).writeWord16(0xBEEF, at: 10)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xBEEF)
    }

    func testSubsImmediate3RealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0x1f3c, // subs r4, r7, #4, real word from the actual kernel
        ])
        cpu.registers[7] = 10
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 6)
        XCTAssertFalse(cpu.cpsr.zero)
        XCTAssertTrue(cpu.cpsr.carry) // No borrow.
    }

    func testAddsRegisterFormat2() {
        let cpu = makeThumbCPU(program: [
            0x1888, // adds r0, r1, r2 (format 2, register)
        ])
        cpu.registers[1] = 5
        cpu.registers[2] = 3
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 8)
    }

    func testLdrbRegisterOffsetRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0x5c08, // ldrb r0, [r1, r0], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 10
        cpu.registers[0] = 5
        try! (cpu.memory as! FlatPhysicalMemory).writeByte(0xAB, at: 15)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xAB)
    }

    func testLdrshRegisterOffsetSignExtends() {
        let cpu = makeThumbCPU(program: [
            0x5f1a, // ldrsh r2, [r3, r4]
        ], memorySize: 256)
        cpu.registers[3] = 10
        cpu.registers[4] = 4
        try! (cpu.memory as! FlatPhysicalMemory).writeWord16(0x8000, at: 14) // -32768 as a signed halfword.
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 0xFFFF_8000)
    }

    func testTbhRealKernelWordBranchesThroughJumpTable() {
        let cpu = makeThumbCPU(program: [
            0xe8df, 0xf011, // tbh [pc, r1, lsl #1], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[1] = 2 // index 2 into the halfword table.
        // Table follows the instruction at Align(instructionAddress+4, 4) == 4;
        // entry 2 is at 4 + 2*2 == 8.
        try! (cpu.memory as! FlatPhysicalMemory).writeWord16(5, at: 8)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 14) // (0 + 4) + 5*2
    }

    /// Traced back from a real early-boot kernel panic: unlike the usual
    /// Thumb "read PC as an operand" rule, `TBB`'s base when `Rn==PC` is
    /// *not* additionally word-aligned — it's simply the address right
    /// after the (always 4-byte) instruction. The other `TBB`/`TBH` tests
    /// in this file all place the instruction at a word-aligned address
    /// (0), where the wrong, word-aligning formula and the correct one
    /// happen to agree and can't tell them apart. This one starts the
    /// instruction at address 2 (2-byte aligned, not 4-byte aligned) —
    /// exactly the real kernel's own alignment (0x80090232, ≡ 2 mod 4) —
    /// where the buggy formula used to round the read address down by 2
    /// bytes, into the TBB instruction's own second halfword, and jump
    /// into garbage instead of the real case handler.
    func testTbbAtUnalignedAddressReadsTableRightAfterInstructionRealKernelWord() {
        let memory = FlatPhysicalMemory(length: 256)
        try! memory.writeWord16(0xe8df, at: 2) // tbb [pc, r1] — real word from the actual kernel, at 0x80090232
        try! memory.writeWord16(0xf001, at: 4) // second halfword of the same instruction
        try! memory.writeWord16(0xCC03, at: 6) // table[0] = 3 (low byte) right after the instruction; high byte (0xCC) is unused filler

        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        cpu.cpsr.thumbState = true
        cpu.registers.pc = 2
        cpu.registers[1] = 0 // index 0

        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Correct: base = instructionAddress(2) + 4 == 6 (no extra
        // word-alignment), table[0] == 3, target = 6 + 2*3 == 12.
        // The pre-fix bug would round the base down to 4 — the
        // instruction's own second halfword — read 0x01 from it, and
        // land on 8 instead.
        XCTAssertEqual(cpu.registers.pc, 12)
    }

    func testUmullRealKernelWordComputes64BitProduct() {
        let cpu = makeThumbCPU(program: [
            0xfba0, 0x5203, // umull r5, r2, r0, r3, real word from the actual kernel
        ])
        cpu.registers[0] = 0xFFFF_FFFF
        cpu.registers[3] = 2
        cpu.step()

        // 0xFFFFFFFF * 2 = 0x1_FFFFFFFE
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[5], 0xFFFF_FFFE) // RdLo
        XCTAssertEqual(cpu.registers[2], 1) // RdHi
    }

    func testSmullRealKernelWordComputesSigned64BitProduct() {
        let cpu = makeThumbCPU(program: [
            0xfb80, 0x100b, // smull r1, r0, r0, fp, real word from the actual kernel
        ])
        cpu.registers[0] = UInt32(bitPattern: -5) // 0xFFFFFFFB
        cpu.registers[11] = 3
        cpu.step()

        // -5 * 3 = -15 = 0xFFFFFFFF_FFFFFFF1
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xFFFF_FFF1) // RdLo
        XCTAssertEqual(cpu.registers[0], 0xFFFF_FFFF) // RdHi
    }

    func testMulWideRealKernelWordComputesProduct() {
        let cpu = makeThumbCPU(program: [
            0xfb00, 0xf102, // mul r1, r0, r2, real word from the actual kernel
        ])
        cpu.registers[0] = 6
        cpu.registers[2] = 7
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 42)
    }

    func testMlaRealKernelWordMultipliesAndAccumulates() {
        let cpu = makeThumbCPU(program: [
            0xfb01, 0x2403, // mla r4, r1, r3, r2, real word from the actual kernel
        ])
        cpu.registers[1] = 6
        cpu.registers[3] = 7
        cpu.registers[2] = 100
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 142) // 6*7 + 100
    }

    func testStrdRealKernelWordStoresConsecutiveWords() {
        let cpu = makeThumbCPU(program: [
            0xe9c8, 0x0100, // strd r0, r1, [r8], real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[8] = 16
        cpu.registers[0] = 0x1111_1111
        cpu.registers[1] = 0x2222_2222
        cpu.step()

        XCTAssertNil(cpu.lastError)
        let memory = cpu.memory as! FlatPhysicalMemory
        XCTAssertEqual(try! memory.readWord32(at: 16), 0x1111_1111)
        XCTAssertEqual(try! memory.readWord32(at: 20), 0x2222_2222)
        XCTAssertEqual(cpu.registers[8], 16) // No writeback.
    }

    func testUbfxExtractsBitFieldRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf3c0, 0x0040, // ubfx r0, r0, #1, #1, real word from the actual kernel
        ])
        cpu.registers[0] = 0b110 // bit 1 set
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 1)
    }

    func testLdrPcRelativeLoadsFromAlignedLiteralPool() {
        // ldr r0, [pc, #0x24] — real word from the actual kernel, the
        // instruction that halted execution before format 6 was decoded
        // at all. At address 0: base = Align(0+4,4) = 4, so the literal
        // lives at 4 + 0x24 = 0x28.
        let cpu = makeThumbCPU(program: [0x4809])
        try! cpu.memory.writeWord32(0xDEAD_BEEF, at: 0x28)

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xDEAD_BEEF)
    }

    func testSbfxSignExtendsBitFieldRealKernelWord() {
        // sbfx r5, r5, #0, #1 — real word from the actual kernel, the
        // instruction that halted execution before SBFX was decoded at
        // all. Extracting a single set bit sign-extends it to all 1s,
        // not just 1 — the whole point of `S` vs `U`BFX.
        let cpu = makeThumbCPU(program: [
            0xf345, 0x0500, // sbfx r5, r5, #0, #1, real word from the actual kernel
        ])
        cpu.registers[5] = 0b1 // bit 0 set
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[5], 0xFFFF_FFFF)
    }

    func testSbfxExtractsZeroBitAsZero() {
        let cpu = makeThumbCPU(program: [
            0xf345, 0x0500, // sbfx r5, r5, #0, #1, real word from the actual kernel
        ])
        cpu.registers[5] = 0b10 // bit 0 clear, bit 1 set (outside the extracted field)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[5], 0)
    }

    func testBfcClearsBitFieldRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf36f, 0x000b, // bfc r0, #0, #0xc, real word from the actual kernel
        ])
        cpu.registers[0] = 0xFFFF_FFFF
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Low 12 bits cleared to zero, rest of r0 untouched.
        XCTAssertEqual(cpu.registers[0], 0xFFFF_F000)
    }

    func testClzWideCountsLeadingZerosRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfab5, 0xf185, // clz r1, r5, real word from the actual kernel
        ])
        cpu.registers[5] = 0x0000_0010 // bit 4 set: 27 leading zeros
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 27)
    }

    func testLslRegisterWideShiftsByRegisterAmountRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfa05, 0xf202, // lsl.w r2, r5, r2, real word from the actual kernel
        ])
        cpu.registers[5] = 1
        cpu.registers[2] = 4
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 16) // 1 << 4
    }

    /// Traced back from a real early-boot kernel halt: this real word
    /// disambiguates `ShiftType`'s field position from `lsl.w`'s own
    /// test above, whose bits happen to be all-zero either way — see
    /// `decode32ExtendOrShift`'s doc comment.
    func testRorRegisterWideRotatesByRegisterAmountRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfa62, 0xf101, // ror.w r1, r2, r1, real word from the actual kernel
        ])
        cpu.registers[2] = 0x0000_0001
        cpu.registers[1] = 4
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0x1000_0000) // ROR(1, #4)
    }

    func testUxtbWideZeroExtendsHighRegisterRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfa5f, 0xf18a, // uxtb.w r1, r10, real word from the actual kernel
        ])
        cpu.registers[10] = 0xAABB_CCDD
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xDD)
    }

    func testUxtb16ExtractsAndZeroExtendsTwoBytesRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfa3f, 0xf383, // uxtb16 r3, r3, real word from the actual kernel
        ])
        cpu.registers[3] = 0xAABB_CCDD
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // byte0 (0xDD) -> low halfword, byte2 (0xBB) -> high halfword.
        XCTAssertEqual(cpu.registers[3], 0x00BB_00DD)
    }

    func testUxthWideZeroExtendsHighRegisterRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xfa1f, 0xf88b, // uxth.w r8, fp, real word from the actual kernel
        ])
        cpu.registers[11] = 0xAABB_CCDD
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[8], 0xCCDD)
    }

    func testDsbIsANoOpRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf3bf, 0x8f4f, // dsb sy, real word from the actual kernel
        ])
        cpu.registers[0] = 42
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 42) // Nothing should change.
    }

    func testMvnImmediateNegatesModifiedImmediateRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf06f, 0x4570, // mvn r5, #0xf0000000, real word from the actual kernel
        ])
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[5], 0x0FFF_FFFF)
    }

    func testMovPcFromHiRegisterStaysInThumbEvenWithTargetBit0Clear() {
        // mov pc, r5 -- real word from the actual kernel at 0x80020110,
        // part of an ordinary compiled switch-statement jump table
        // (adr.w r2,#table / add.w r5,r2,r6,lsl#2 / mov pc,r5, indexing
        // into a table of b.w slots). Confirms the real-architecture
        // fix: a hi-register MOV/ADD into PC, unlike BX, does NOT
        // interwork -- it must stay in Thumb even though the jump
        // table's own address (and so every slot address) isn't
        // 4-byte aligned and has bit 0 clear.
        let cpu = makeThumbCPU(program: [
            0x46af, // mov pc, r5
        ])
        cpu.registers[5] = 0x80020112 // even address, bit 0 clear
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.thumbState, "A hi-register MOV/ADD to PC must not interwork -- it stays in whatever state it was already in")
        XCTAssertEqual(cpu.registers.pc, 0x80020112)
    }

    func testAdrComputesPcRelativeAddressRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf20f, 0x0216, // addw r2, pc, #0x16 (ADR), real word from the actual kernel, at address 0
        ])
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Align(PC, 4) + imm12 = Align(0 + 4, 4) + 0x16 = 4 + 22 = 26.
        XCTAssertEqual(cpu.registers[2], 26)
    }

    func testAddwAddsPlainImmediateRealKernelWord() {
        let cpu = makeThumbCPU(program: [
            0xf204, 0x40d4, // addw r0, r4, #0x4d4, real word from the actual kernel
        ])
        cpu.registers[4] = 100
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 100 + 0x4D4)
    }

    /// `uxtab r1, r5, r1` — the real kernel word at 0x800940F6 that halted
    /// boot before the accumulating extend forms were decoded.
    func testUxtabAddsZeroExtendedByteToRn() {
        let cpu = makeThumbCPU(program: [0xFA55, 0xF181])
        cpu.registers[1] = 0xDEAD_BEF0
        cpu.registers[5] = 0x1000
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0x1000 + 0xF0)
    }

    /// `uxtb.w r0, r1, ror #8` — a nonzero rotation, which the decoder
    /// used to reject by requiring hw1 bits[7:4] == 1000 exactly.
    func testUxtbWideHonorsRotation() {
        let cpu = makeThumbCPU(program: [0xFA5F, 0xF091])
        cpu.registers[1] = 0x1234_5678
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x56)
    }

    /// `sxtah r1, r4, r2, ror #16`: sign-extends the rotated low halfword.
    func testSxtahSignExtendsRotatedHalfwordAndAdds() {
        let cpu = makeThumbCPU(program: [0xFA04, 0xF1A2])
        cpu.registers[2] = 0xFFFE_0000 // after ror #16: low halfword 0xFFFE (-2)
        cpu.registers[4] = 10
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 8)
    }

    /// `uxtab16`/`sxtab16 r3, r2, r4`: bytes 0 and 2 extended to 16 bits
    /// and added to each halfword of Rn separately, wrapping per lane.
    func testDualLaneExtendAndAdd() {
        let unsignedCPU = makeThumbCPU(program: [0xFA32, 0xF384])
        unsignedCPU.registers[2] = 0x0001_FFFF
        unsignedCPU.registers[4] = 0x0080_0002
        unsignedCPU.step()
        XCTAssertNil(unsignedCPU.lastError)
        XCTAssertEqual(unsignedCPU.registers[3], 0x0081_0001)

        let signedCPU = makeThumbCPU(program: [0xFA22, 0xF384])
        signedCPU.registers[2] = 0x0001_FFFF
        signedCPU.registers[4] = 0x0080_0002
        signedCPU.step()
        XCTAssertNil(signedCPU.lastError)
        XCTAssertEqual(signedCPU.registers[3], 0xFF81_0001)
    }

    /// `vmov.i32 d16, #0` — the real kernel word in `IOService::addPowerChild`
    /// that halted boot, decoded through the shared ARM-form NEON path.
    func testThumbNEONMoveImmediateDRegister() {
        let cpu = makeThumbCPU(program: [0xEFC0, 0x0010])
        cpu.neon[16] = 0xDEAD_BEEF_DEAD_BEEF
        cpu.neon[17] = 0x1234
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0)
        XCTAssertEqual(cpu.neon[17], 0x1234, "D form must not touch the next register")
    }

    /// `vmov.i32 q8, #0` (the Q form the old Thumb-only path handled) and
    /// `vmov.i8 d0, #0xff` with U=1 — the `0xFF` prefix used to alias onto
    /// `0xFB` (long multiply).
    func testThumbNEONQFormAndUEqualsOnePrefix() {
        let q = makeThumbCPU(program: [0xEFC0, 0x0050])
        q.neon[16] = 1
        q.neon[17] = 2
        q.step()
        XCTAssertNil(q.lastError)
        XCTAssertEqual(q.neon[16], 0)
        XCTAssertEqual(q.neon[17], 0)

        let u = makeThumbCPU(program: [0xFF87, 0x0E1F])
        u.step()
        XCTAssertNil(u.lastError)
        XCTAssertEqual(u.neon[0], 0xFFFF_FFFF_FFFF_FFFF)
    }

    /// `vstr d16, [sp, #8]` — the real kernel word in
    /// `IOService::addPowerChild` that halted boot next.
    func testThumbVstrStoresDoubleAtOffset() {
        let cpu = makeThumbCPU(program: [0xEDCD, 0x0B02])
        cpu.registers.sp = 0x80
        cpu.neon[16] = 0x1122_3344_5566_7788
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x88), 0x5566_7788)
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x8C), 0x1122_3344)
        XCTAssertEqual(cpu.registers.sp, 0x80, "VSTR never writes back")
    }

    /// `vldr d0, [pc, #8]` in Thumb: the base is Align(instruction + 4, 4),
    /// not ARM's instruction + 8, even though it decodes via its ARM form.
    func testThumbVldrLiteralUsesThumbPC() {
        let cpu = makeThumbCPU(program: [0x0000, 0xED9F, 0x0B02])
        cpu.registers.pc = 2 // the VLDR sits at 2: base = Align(6, 4) = 4, address = 12
        try! cpu.memory.writeWord32(0xAAAA_0001, at: 12)
        try! cpu.memory.writeWord32(0xBBBB_0002, at: 16)
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[0], 0xBBBB_0002_AAAA_0001)
    }

    /// An IRQ taken right after `IT` (inside the block) must save ITSTATE
    /// in SPSR and restore it on `SUBS PC, LR, #4`, so the rest of the
    /// block still runs under its conditions — here Z is clear, so only
    /// the `movne` may write r0.
    func testInterruptInsideITBlockPreservesITState() {
        let memory = FlatPhysicalMemory(length: 0x200)
        try! memory.writeWord32(0xE25E_F004, at: 0x18) // IRQ vector: subs pc, lr, #4 (ARM)
        try! memory.writeWord16(0xBF0C, at: 0x100)    // ite eq
        try! memory.writeWord16(0x2001, at: 0x102)    // moveq r0, #1
        try! memory.writeWord16(0x2002, at: 0x104)    // movne r0, #2
        let cpu = ARMv7CPU(memory: memory)
        cpu.reset()
        cpu.cpsr.thumbState = true
        cpu.cpsr.irqDisabled = false
        cpu.cpsr.zero = false
        cpu.registers.pc = 0x100
        cpu.registers[0] = 0xFF

        cpu.run(maxUnits: 1) // ite eq
        XCTAssertNotEqual(cpu.itState, 0)
        cpu.irqAsserted = true
        cpu.run(maxUnits: 1) // IRQ taken, then the handler's subs pc, lr, #4 runs
        cpu.irqAsserted = false
        XCTAssertEqual(cpu.registers.pc, 0x102, "should return to the interrupted IT block")
        XCTAssertTrue(cpu.cpsr.thumbState)
        XCTAssertNotEqual(cpu.itState, 0, "ITSTATE must come back from SPSR")

        cpu.run(maxUnits: 2)
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 2)
        XCTAssertEqual(cpu.itState, 0)
    }

    /// The real `ipc_kobject_destroy` dispatch at 0x8001a6c2: `cmp r1, #0x1c;
    /// it eq; beq.w mach_destroy_memory_entry`. The T4 `B.W` must obey the IT
    /// condition — ignoring it sent every destroyed port down the named-
    /// memory-entry path and panicked the kernel (kotype 1 != 0x1c).
    func testWideBranchInsideITBlockObeysITCondition() {
        func run(r1: UInt32) -> UInt32 {
            let base: UInt32 = 0x8001_a6c2
            let memory = FlatPhysicalMemory(length: 0x10_0000, baseAddress: 0x8000_0000)
            for (offset, halfword) in [UInt16(0x291C), 0xBF08, 0xF054, 0xBEC9].enumerated() {
                try! memory.writeWord16(halfword, at: base + UInt32(offset * 2))
            }
            let cpu = ARMv7CPU(memory: memory)
            cpu.reset()
            cpu.cpsr.thumbState = true
            cpu.registers.pc = base
            cpu.registers[1] = r1
            cpu.run(maxUnits: 3)
            XCTAssertNil(cpu.lastError)
            return cpu.registers.pc
        }
        XCTAssertEqual(run(r1: 1), 0x8001_a6ca, "kotype 1: must fall through")
        XCTAssertEqual(run(r1: 0x1C), 0x8006_f45c, "kotype 0x1c: must branch")
    }

    /// `tst.w r3, #0xf00` (real kernel word): a rotated modified immediate,
    /// so C becomes bit 31 of the constant (0) — not left unchanged.
    func testThumb2LogicalRotatedImmediateSetsCarryFromConstant() {
        let cpu = makeThumbCPU(program: [0xF413, 0x6F70])
        cpu.cpsr.carry = true
        cpu.registers[3] = 0
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.zero)
        XCTAssertFalse(cpu.cpsr.carry)

        // `tst.w r0, #0xff` is unrotated: C must stay as it was.
        let unrotated = makeThumbCPU(program: [0xF010, 0x0FFF])
        unrotated.cpsr.carry = true
        unrotated.step()
        XCTAssertNil(unrotated.lastError)
        XCTAssertTrue(unrotated.cpsr.carry)
    }

    /// Thumb-2 literal loads: with Rn == PC, hw0 bit[7] is U and the offset
    /// is always imm12 from Align(PC, 4). `ldr.w r2, [pc, #-0x178]` is the
    /// real kext word that halted boot; `#-0x978` has imm12 bit 11 set,
    /// which the old T3/T4 split misread as a T4 load.
    func testThumb2LiteralLoadsWithNegativeOffsets() {
        func load(_ hw0: UInt16, _ hw1: UInt16, literalAt address: UInt32, value: UInt32) -> ARMv7CPU {
            let memory = FlatPhysicalMemory(length: 0x4000)
            try! memory.writeWord16(hw0, at: 0x2000)
            try! memory.writeWord16(hw1, at: 0x2002)
            try! memory.writeWord32(value, at: address)
            let cpu = ARMv7CPU(memory: memory)
            cpu.reset()
            cpu.cpsr.thumbState = true
            cpu.registers.pc = 0x2000
            cpu.step()
            return cpu
        }
        let near = load(0xF85F, 0x2178, literalAt: 0x2004 - 0x178, value: 0xCAFE_F00D)
        XCTAssertNil(near.lastError)
        XCTAssertEqual(near.registers[2], 0xCAFE_F00D)

        let far = load(0xF85F, 0x2978, literalAt: 0x2004 - 0x978, value: 0x1234_5678)
        XCTAssertNil(far.lastError)
        XCTAssertEqual(far.registers[2], 0x1234_5678)
        XCTAssertEqual(far.registers.pc, 0x2004)

        let signed = load(0xF93F, 0x1008, literalAt: 0x2004 - 8, value: 0x0000_8001) // ldrsh.w r1, [pc, #-8]
        XCTAssertNil(signed.lastError)
        XCTAssertEqual(signed.registers[1], 0xFFFF_8001)
    }

    func testThumb2PreloadHintDoesNotLoadIntoPC() {
        let cpu = makeThumbCPU(program: [0xF81F, 0xF001]) // pld [pc, #-1]
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 4)
    }
}
