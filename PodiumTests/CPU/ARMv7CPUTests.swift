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

    func testEnablingMMUWithARealIdentityMapTranslatesSubsequentFetchesCorrectly() {
        // Sets up a genuine (if minimal) identity-mapped first-level
        // table — the same shape of table the real kernel's own boot
        // code builds (see `ARMv7MMUTests`'s doc comment) — then enables
        // the MMU and confirms the *next* instruction fetch, translated
        // through that table, still executes normally rather than
        // halting: SCTLR.M no longer halts unconditionally now that
        // `ARMv7MMU` does the real translation work.
        let cpu = makeCPU(program: [
            0xEE02_0F10, // MCR p15, #0, r0, c2, c0, #0  (TTBR0 = r0)
            0xEE03_2F10, // MCR p15, #0, r2, c3, c0, #0  (DACR = r2)
            0xE580_1000, // STR r1, [r0]                 (table[0] = r1: identity section, full RW)
            0xEE01_3F10, // MCR p15, #0, r3, c1, c0, #0  (SCTLR = r3, enables the MMU)
            0xE3A0_4063, // MOV r4, #99                  -- fetched via a real MMU translation
        ], memorySize: 0x8000)
        cpu.loadInitialRegisters([
            0x0000_4000, 0xC02, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])

        for _ in 0..<5 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 5 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[4], 99)
    }

    func testFetchingFromAnUnmappedRegionAfterEnablingTheMMUFaultsHonestly() {
        // Same setup as above, but the program then branches to a VA
        // whose first-level slot was never written — a real translation
        // fault, not a silent continuation past untranslated memory.
        let cpu = makeCPU(program: [
            0xEE02_0F10, // MCR p15, #0, r0, c2, c0, #0  (TTBR0 = r0)
            0xEE03_2F10, // MCR p15, #0, r2, c3, c0, #0  (DACR = r2)
            0xE580_1000, // STR r1, [r0]                 (table[0] = r1: identity section for this code's own VA range)
            0xEE01_3F10, // MCR p15, #0, r3, c1, c0, #0  (SCTLR = r3, enables the MMU)
            0xEA1B_FFFA, // B 0x00700000                 -- an address with no first-level entry at all
        ], memorySize: 0x8000)
        cpu.loadInitialRegisters([
            0x0000_4000, 0xC02, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])

        for _ in 0..<6 { cpu.step() } // 5 real instructions + the faulting fetch at the branch target

        guard case .memoryFault(let underlying, let address) = cpu.lastError else {
            return XCTFail("Expected .memoryFault, got \(String(describing: cpu.lastError))")
        }
        guard case .translationFault = underlying else {
            return XCTFail("Expected .translationFault, got \(underlying)")
        }
        XCTAssertEqual(address, 0x0070_0000)
    }

    func testEnablingSCTLRAccessFlagEnableHaltsHonestlyRatherThanMisreadingAPBits() {
        let cpu = makeCPU(program: [
            0xEE01_0F10, // MCR p15, #0, r0, c1, c0, #0  (SCTLR = r0)
        ])
        cpu.loadInitialRegisters([1 << 29, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

        cpu.step()

        guard case .unimplementedHardwareFeature(let description, _) = cpu.lastError else {
            return XCTFail("Expected .unimplementedHardwareFeature, got \(String(describing: cpu.lastError))")
        }
        XCTAssertTrue(description.contains("AFE"))
    }

    func testWritingSCTLRWithoutMMUBitSetDoesNotHalt() {
        // Same register, but writing a value with bit 0 clear (e.g. just
        // enabling caches) is exactly what the real kernel does before
        // it ever touches the MMU bit, and must keep executing normally.
        let cpu = makeCPU(program: [
            0xE3A0_0C18, // MOV r0, #0x1800 (bits 11/12 — icache + branch prediction, no MMU bit)
            0xEE01_0F10, // MCR p15, #0, r0, c1, c0, #0
        ])
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0), 0x1800)
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

    func testMrsReadsCpsrIntoRegister() {
        let cpu = makeCPU(program: [
            0xE3B0_0001, // MOVS r0, #1  -- sets Z=0, and leaves N/C/V clear
            0xE10F_B000, // mrs r11, apsr -- real word from the actual kernel
        ])
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[11], cpu.cpsr.rawValue)
    }

    func testMsrWritesOnlySelectedByteOfCpsr() {
        let cpu = makeCPU(program: [
            0xE3E0_B000, // MVN r11, #0  -- r11 = 0xFFFFFFFF
            0xE122_F00B, // msr CPSR_x, r11 -- real word from the actual kernel (byte 1 only)
        ])
        let before = cpu.cpsr.rawValue
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        // Only bits [15:8] (the 'x' field) should have changed; everything
        // else in CPSR must be untouched, per the fieldMask.
        XCTAssertEqual(cpu.cpsr.rawValue, before | 0x0000_FF00)
    }

    func testMsrImmediateWritesFlagsByteOnly() {
        // msr CPSR_f, #0xF0000000 -- N,Z,C,V all set via the immediate form.
        let cpu = makeCPU(program: [0xE328_F20F])
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.negative)
        XCTAssertTrue(cpu.cpsr.zero)
        XCTAssertTrue(cpu.cpsr.carry)
        XCTAssertTrue(cpu.cpsr.overflow)
    }

    func testBxBranchesToRegisterValue() {
        let cpu = makeCPU(program: [
            0xE3A0_E00C, // MOV lr, #12      (word-aligned target)
            0xE12F_FF1E, // bx lr, real word from the actual kernel
            0xE3A0_00FF, // must NOT execute (address 8)
            0xE3A0_0063, // MOV r0, #99      -- bx target at address 12
        ])
        cpu.step() // MOV lr, #12
        cpu.step() // bx lr
        cpu.step() // MOV r0, #99 at address 12

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 99)
        XCTAssertEqual(cpu.registers.pc, 16)
    }

    func testBxToThumbInterworkingAddressHaltsHonestly() {
        let cpu = makeCPU(program: [
            0xE3A0_E011, // MOV lr, #17     (bit0 set: real hardware would switch to Thumb)
            0xE12F_FF1E, // bx lr
        ])
        cpu.step() // MOV
        cpu.step() // bx lr -- should halt here

        guard case .unimplementedHardwareFeature(let description, let address) = cpu.lastError else {
            return XCTFail("Expected .unimplementedHardwareFeature, got \(String(describing: cpu.lastError))")
        }
        XCTAssertTrue(description.contains("Thumb"))
        XCTAssertEqual(address, 4) // the bx instruction's own address
    }

    func testPushThenPopRoundTripsRegistersThroughTheStack() {
        let cpu = makeCPU(program: [
            0xE3A0_D080, // MOV sp, #128
            0xE3A0_4004, // MOV r4, #4
            0xE3A0_5005, // MOV r5, #5
            0xE92D_0030, // STMDB sp!, {r4, r5}   (push {r4,r5})
            0xE3A0_4000, // MOV r4, #0            -- clobber r4 before reloading it
            0xE3A0_5000, // MOV r5, #0            -- clobber r5 before reloading it
            0xE8BD_0030, // LDMIA sp!, {r4, r5}   (pop {r4,r5})
        ], memorySize: 256)
        for _ in 0..<7 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 7 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[4], 4)
        XCTAssertEqual(cpu.registers[5], 5)
        XCTAssertEqual(cpu.registers.sp, 128, "Writeback should return sp to its original value after a matched push/pop")
    }

    func testPushRealKernelWordStoresRegistersInAscendingOrderBelowSP() {
        // push {r4, r5, r6, r7, lr} — the real word from the actual
        // kernel at 0x802b9768. Verifies the real addressing-mode math
        // (STMDB: pre-decrement, so all 5 words land *below* the
        // original sp, lowest register at the lowest address) by
        // reading each slot back with a plain LDR rather than just
        // round-tripping through a matching pop.
        let cpu = makeCPU(program: [
            0xE3A0_D064, // MOV sp, #100
            0xE3A0_4004, // MOV r4, #4
            0xE3A0_5005, // MOV r5, #5
            0xE3A0_6006, // MOV r6, #6
            0xE3A0_7007, // MOV r7, #7
            0xE3A0_E00E, // MOV lr, #14
            0xE92D_40F0, // push {r4, r5, r6, r7, lr}
            0xE59D_0000, // LDR r0, [sp, #0]   -> should be 4
            0xE59D_1004, // LDR r1, [sp, #4]   -> should be 5
            0xE59D_2008, // LDR r2, [sp, #8]   -> should be 6
            0xE59D_300C, // LDR r3, [sp, #12]  -> should be 7
            0xE59D_8010, // LDR r8, [sp, #16]  -> should be 14 (lr, at the highest address)
        ], memorySize: 256)
        for _ in 0..<12 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 12 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers.sp, 80) // 100 - 5*4
        XCTAssertEqual(cpu.registers[0], 4)
        XCTAssertEqual(cpu.registers[1], 5)
        XCTAssertEqual(cpu.registers[2], 6)
        XCTAssertEqual(cpu.registers[3], 7)
        XCTAssertEqual(cpu.registers[8], 14)
    }

    func testPopIntoPCBranchesToTheLoadedAddress() {
        let cpu = makeCPU(program: [
            0xE3A0_D064, // MOV sp, #100
            0xE3A0_0055, // MOV r0, #0x55  -- value that will become r4's saved slot
            0xE3A0_102C, // MOV r1, #44    -- return address that will become the saved pc
            0xE58D_0000, // STR r0, [sp]
            0xE58D_1004, // STR r1, [sp, #4]
            0xE8BD_8010, // pop {r4, pc}   -- real word shape (LDMIA sp!, {r4, pc})
        ], memorySize: 256)
        for _ in 0..<6 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected pop {r4,pc} to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[4], 0x55)
        XCTAssertEqual(cpu.registers.pc, 44)
        XCTAssertEqual(cpu.registers.sp, 108) // writeback: 100 + 2*4
    }

    func testPopIntoPCWithThumbBitSetHaltsHonestly() {
        let cpu = makeCPU(program: [
            0xE3A0_D064, // MOV sp, #100
            0xE3A0_102D, // MOV r1, #45   -- bit0 set: requests Thumb interworking
            0xE58D_1004, // STR r1, [sp, #4]
            0xE8BD_8010, // pop {r4, pc}  -- should halt on the Thumb-bit check
        ], memorySize: 256)
        for _ in 0..<4 { cpu.step() }

        guard case .unimplementedHardwareFeature(let description, let address) = cpu.lastError else {
            return XCTFail("Expected .unimplementedHardwareFeature, got \(String(describing: cpu.lastError))")
        }
        XCTAssertTrue(description.contains("Thumb"))
        XCTAssertEqual(address, 12) // the pop instruction's own address
    }

    func testStrhThenLdrhRoundTripsUnsignedAndZeroExtends() {
        let cpu = makeCPU(program: [
            0xE3A0_0040, // MOV r0, #64
            0xE30B_1EEF, // MOVW r1, #0xBEEF
            0xE1C0_10B0, // strh r1, [r0]  -- real word shape from the actual kernel
            0xE1D0_20B0, // ldrh r2, [r0]
        ], memorySize: 256)
        for _ in 0..<4 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 4 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[2], 0xBEEF, "ldrh must zero-extend, not sign-extend")
    }

    func testLdrsbSignExtendsANegativeByte() {
        let cpu = makeCPU(program: [
            0xE3A0_0040, // MOV r0, #64
            0xE300_30C3, // MOVW r3, #0xC3  -- high bit of the low byte is set
            0xE5C0_3000, // strb r3, [r0]
            0xE1D0_40D0, // ldrsb r4, [r0]
        ], memorySize: 256)
        for _ in 0..<4 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 4 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[4], 0xFFFF_FFC3)
    }

    func testLdrshSignExtendsANegativeHalfword() {
        let cpu = makeCPU(program: [
            0xE3A0_0040, // MOV r0, #64
            0xE308_1001, // MOVW r1, #0x8001  -- high bit of the halfword is set
            0xE1C0_10B0, // strh r1, [r0]
            0xE1D0_50F0, // ldrsh r5, [r0]
        ], memorySize: 256)
        for _ in 0..<4 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 4 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[5], 0xFFFF_8001)
    }

    func testStrhPostIndexedWritesBackBase() {
        let cpu = makeCPU(program: [
            0xE3A0_0040, // MOV r0, #64
            0xE30B_1EEF, // MOVW r1, #0xBEEF
            0xE0C0_10B4, // strh r1, [r0], #4  -- post-indexed: store at 64, then r0 += 4
        ], memorySize: 256)
        for _ in 0..<3 { cpu.step() }

        XCTAssertNil(cpu.lastError, "Expected all 3 instructions to run; halted with \(String(describing: cpu.lastError))")
        XCTAssertEqual(cpu.registers[0], 68)
    }

    func testBlxImmediateHaltsHonestlyRequestingThumb() {
        let cpu = makeCPU(program: [
            0xFAFF_FA81, // blx 0x802b8268, real word from the actual kernel (offset relative to address 0 here)
        ])
        cpu.step()

        guard case .unimplementedHardwareFeature(let description, let address) = cpu.lastError else {
            return XCTFail("Expected .unimplementedHardwareFeature, got \(String(describing: cpu.lastError))")
        }
        XCTAssertTrue(description.contains("Thumb"))
        XCTAssertTrue(description.contains("BLX"))
        XCTAssertEqual(address, 0) // the blx instruction's own address
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
