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
        // The VFP/NEON tests need the unit on (it resets disabled).
        cpu.fpexc = ARMv7CPU.fpexcEnableBit
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
            0xE100_1091, // swp r1, r1, [r0] -- not implemented
            0xE3A0_00FF, // would set r0 to 0xFF if ever reached
        ])
        cpu.run()

        XCTAssertEqual(cpu.registers[0], 5, "The instruction before the unsupported one should still have run")
        guard case .unsupportedInstruction(let rawWord, let address) = cpu.lastError else {
            return XCTFail("Expected .unsupportedInstruction, got \(String(describing: cpu.lastError))")
        }
        XCTAssertEqual(rawWord, 0xE100_1091)
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

    func testResetStartsInSupervisorMode() {
        // Real ARM hardware always resets into SVC mode (ARM DDI 0406C
        // B1.6.15) — never System mode. Getting this wrong meant the
        // kernel's LC_UNIXTHREAD-supplied initial SP was never actually
        // banked into SVC's own slot, so any later `CPS #0x13` "return to
        // SVC" (e.g. from the Data Abort handler) read back an
        // uninitialized SP instead of a real one.
        let cpu = makeCPU(program: [])
        XCTAssertEqual(cpu.cpsr.rawValue & ARMv7CPU.modeBitsMask, ARMv7CPU.svcModeBits)
    }

    func testCpsModeChangeSwitchesModeAndBanksPreviousModesStackPointer() {
        // cpsid i, #0x13 -- real word from the actual kernel's Data Abort
        // handler, switching into SVC mode.
        let cpu = makeCPU(program: [0xF10E_0093])
        cpu.registers.sp = 0x8020_0000 // SVC mode's own real stack
        cpu.switchProcessorMode(from: ARMv7CPU.svcModeBits, to: ARMv7CPU.abortModeBits)
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~ARMv7CPU.modeBitsMask) | ARMv7CPU.abortModeBits
        cpu.registers.sp = 0x8123_4567 // Abort mode's own, distinct live SP

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & ARMv7CPU.modeBitsMask, ARMv7CPU.svcModeBits)
        XCTAssertTrue(cpu.cpsr.irqDisabled)
        // Returns to SVC mode's own real, previously-banked SP — not
        // Abort's SP, and not the uninitialized-bank default of 0.
        XCTAssertEqual(cpu.registers.sp, 0x8020_0000)
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

    func testVrshlLeftShiftsEachByteLaneWithNoRounding() {
        // vrshl.u8 d16, d0, d5 — real word from the actual kernel.
        let cpu = makeCPU(program: [0xF345_0500])
        cpu.neon[0] = 0x0807_0605_0403_0201 // Vm (shifted value): bytes 1...8
        cpu.neon[5] = 0x0101_0101_0101_0101 // Vn (shift amount): +1 in every lane

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0x100E_0C0A_0806_0402) // each byte doubled
    }

    func testVrshlNegativeShiftRoundsRightUnsigned() {
        // vrshl.u8 d16, d0, d5 — real word from the actual kernel.
        let cpu = makeCPU(program: [0xF345_0500])
        cpu.neon[0] = 0xFFFF_FFFF_FFFF_FFFF // Vm: 255 in every lane
        cpu.neon[5] = 0xFFFF_FFFF_FFFF_FFFF // Vn: -1 (0xFF) in every lane

        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Unsigned rounding shift right by 1: (255 + 1) >> 1 == 128.
        XCTAssertEqual(cpu.neon[16], 0x8080_8080_8080_8080)
    }

    func testVrshlZeroShiftLeavesValueUnchanged() {
        // vrshl.u8 d16, d0, d5 — real word from the actual kernel.
        let cpu = makeCPU(program: [0xF345_0500])
        cpu.neon[0] = 0x1122_3344_5566_7788
        cpu.neon[5] = 0 // shift amount 0 in every lane

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0x1122_3344_5566_7788)
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

    func testFetchingFromAnUnmappedRegionRaisesAPrefetchAbort() {
        // Same setup as above, but the program then branches to a VA
        // whose first-level slot was never written — a real translation
        // fault, which the guest's own Prefetch Abort handler gets (demand
        // paging of user code depends on it).
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

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.abortModeBits)
        XCTAssertEqual(cpu.registers.pc, 0x0C, "Prefetch Abort vector (low vectors)")
        XCTAssertEqual(cpu.registers.lr, 0x0070_0004, "LR_abt = faulting address + 4")
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 6, crm: 0, opc2: 2), 0x0070_0000, "IFAR")
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 5, crm: 0, opc2: 1), 0b00101, "IFSR: section translation fault")
        XCTAssertTrue(cpu.cpsr.irqDisabled)
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

    func testMrsSpsrReadsCurrentModesBankedSpsr() {
        // mrs sp, spsr -- real word from the actual kernel's Data Abort
        // handler prologue.
        let cpu = makeCPU(program: [0xE14F_D000])
        cpu.switchProcessorMode(from: ARMv7CPU.userModeBits, to: ARMv7CPU.abortModeBits)
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~ARMv7CPU.modeBitsMask) | ARMv7CPU.abortModeBits
        cpu.setSavedProgramStatus(0xDEAD_BEEF, forModeBits: ARMv7CPU.abortModeBits)

        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[Registers.spIndex], 0xDEAD_BEEF)
    }

    func testMrsSpsrReadsBackZeroInUserModeWhereNoSpsrExists() {
        // Real hardware calls this UNPREDICTABLE (no SPSR in User mode);
        // Podium reads back 0 rather than fabricating a value.
        let cpu = makeCPU(program: [0xE14F_D000]) // mrs sp, spsr
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[Registers.spIndex], 0)
    }

    func testMsrSpsrWritesOnlySelectedByteOfBankedSpsrLeavingCpsrUntouched() {
        let cpu = makeCPU(program: [
            0xE3E0_B000, // MVN r11, #0  -- r11 = 0xFFFFFFFF
            0xE162_F00B, // msr SPSR_x, r11 (bit22/R set on the real msr CPSR_x, r11 word)
        ])
        cpu.switchProcessorMode(from: ARMv7CPU.userModeBits, to: ARMv7CPU.abortModeBits)
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~ARMv7CPU.modeBitsMask) | ARMv7CPU.abortModeBits
        cpu.setSavedProgramStatus(0, forModeBits: ARMv7CPU.abortModeBits)
        let cpsrBefore = cpu.cpsr.rawValue

        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue, cpsrBefore) // CPSR itself untouched
        // Only bits [15:8] (the 'x' field) should have changed in SPSR_abt.
        XCTAssertEqual(cpu.savedProgramStatus(forModeBits: ARMv7CPU.abortModeBits), 0x0000_FF00)
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

    func testBlxRegisterSetsLrAndBranches() {
        let cpu = makeCPU(program: [
            0xE3A0_0010, // MOV r0, #16 (word-aligned target)
            0xE12F_FF30, // blx r0, real word from the actual kernel
        ])
        cpu.step() // MOV r0, #16
        cpu.step() // blx r0

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.lr, 8) // return address: instruction after blx
        XCTAssertEqual(cpu.registers.pc, 16)
    }

    func testBxWithBit0SetSwitchesToThumbState() {
        let cpu = makeCPU(program: [
            0xE3A0_E011, // MOV lr, #17     (bit0 set: requests Thumb)
            0xE12F_FF1E, // bx lr
        ])
        cpu.step() // MOV
        cpu.step() // bx lr -- real interworking now that Thumb decode exists

        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.thumbState)
        XCTAssertEqual(cpu.registers.pc, 16) // bit 0 cleared from the target
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

    func testPopIntoPCWithThumbBitSetSwitchesToThumbState() {
        let cpu = makeCPU(program: [
            0xE3A0_D064, // MOV sp, #100
            0xE3A0_102D, // MOV r1, #45   -- bit0 set: requests Thumb interworking
            0xE58D_1004, // STR r1, [sp, #4]
            0xE8BD_8010, // pop {r4, pc}  -- real interworking now that Thumb decode exists
        ], memorySize: 256)
        for _ in 0..<4 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.thumbState)
        XCTAssertEqual(cpu.registers.pc, 44) // bit 0 cleared from the loaded value
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

    func testBlxImmediateSwitchesToThumbState() {
        let cpu = makeCPU(program: [
            0xFAFF_FA81, // blx 0x802b8268, real word from the actual kernel (offset relative to address 0 here)
        ])
        cpu.step() // real interworking now that Thumb decode exists

        XCTAssertNil(cpu.lastError)
        XCTAssertTrue(cpu.cpsr.thumbState)
        XCTAssertEqual(cpu.registers.lr, 4) // return address: the next ARM instruction, already word-aligned
    }

    func testOrrRegisterShiftedByRegisterRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE181_1233, // orr r1, r1, r3, lsr r2 -- real word from the actual kernel
        ])
        cpu.registers[1] = 0x0000_00F0
        cpu.registers[2] = 4 // shift amount, from a register
        cpu.registers[3] = 0x0000_0F00
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // r3 >> 4 == 0xF0; ORR with r1 (0xF0) == 0xF0.
        XCTAssertEqual(cpu.registers[1], 0x0000_00F0)
    }

    func testRegisterShiftedByRegisterWithZeroAmountLeavesValueAndCarryUnchanged() {
        let cpu = makeCPU(program: [
            0xE3A0_2000, // MOV r2, #0  (shift amount register, S=0: carry unaffected)
            0xE1A0_0231, // MOV r0, r1, lsr r2  (register-shifted-by-register, amount 0)
        ])
        cpu.registers[1] = 0x8000_0001
        cpu.step(); cpu.step()

        XCTAssertNil(cpu.lastError)
        // Amount 0 means "no shift" for the register-specified form,
        // unlike the immediate form's "LSR #0 means #32" convention.
        XCTAssertEqual(cpu.registers[0], 0x8000_0001)
    }

    func testUqsub8SaturatesPerByteRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE663_2FF1, // uqsub8 r2, r3, r1 -- real word from the actual kernel
        ])
        // Rn byte lanes (0..3, LSB first): 0x10, 0x05, 0xFF, 0x00.
        cpu.registers[3] = 0x00FF_0510
        // Rm byte lanes: 0x01, 0x10, 0x01, 0x01.
        cpu.registers[1] = 0x0101_1001
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // byte0: 0x10-0x01=0x0F; byte1: 0x05-0x10 saturates to 0x00;
        // byte2: 0xFF-0x01=0xFE; byte3: 0x00-0x01 saturates to 0x00.
        XCTAssertEqual(cpu.registers[2], 0x00FE_000F)
    }

    func testRevByteSwapsRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE6BF_2F32, // rev r2, r2 -- real word from the actual kernel
        ])
        cpu.registers[2] = 0x1234_5678
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 0x7856_3412)
    }

    func testBfiInsertsBitFieldRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE7D3_0812, // bfi r0, r2, #0x10, #4 -- real word from the actual kernel
        ])
        cpu.registers[0] = 0xFFFF_FFFF
        cpu.registers[2] = 0b1010
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Bits [19:16] replaced with r2's low 4 bits (0b1010); rest of r0 untouched.
        XCTAssertEqual(cpu.registers[0], 0xFFFA_FFFF)
    }

    func testUbfxArmStateExtractsBitFieldRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE7E9_31D0, // ubfx r3, r0, #3, #0xa -- real word from the actual kernel
        ])
        cpu.registers[0] = 0xFFFF_FFFF
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Extract 10 bits starting at bit 3: all-ones source gives an
        // all-ones 10-bit result, zero-extended.
        XCTAssertEqual(cpu.registers[3], 0x3FF)
    }

    func testMulComputesProductRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE000_0493, // mul r0, r3, r4 -- real word from the actual kernel
        ])
        cpu.registers[3] = 6
        cpu.registers[4] = 7
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 42)
    }

    func testLdrdLoadsConsecutiveWordsRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE1C0_00D0, // ldrd r0, r1, [r0] -- real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[0] = 16
        let memory = cpu.memory as! FlatPhysicalMemory
        try! memory.writeWord32(0x1111_1111, at: 16)
        try! memory.writeWord32(0x2222_2222, at: 20)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x1111_1111)
        XCTAssertEqual(cpu.registers[1], 0x2222_2222)
    }

    func testClzCountsLeadingZerosRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE16F_2F12, // clz r2, r2 -- real word from the actual kernel
        ])
        cpu.registers[2] = 0x0000_0010 // bit 4 set: 27 leading zeros
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 27)
    }

    func testClzOfZeroIsThirtyTwo() {
        let cpu = makeCPU(program: [
            0xE16F_2F12, // clz r2, r2
        ])
        cpu.registers[2] = 0
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[2], 32)
    }

    func testLdrexLoadsWordRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE19C_0F9F, // ldrex r0, [ip] -- real word from the actual kernel
        ])
        cpu.registers[12] = 100
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0xC0FF_EE00, at: 100)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0xC0FF_EE00)
    }

    func testLdrexdLoadsDoublewordRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE1B2_4F9F, // ldrexd r4, r5, [r2] -- real word from the actual kernel
        ])
        cpu.registers[2] = 100
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0x1111_1111, at: 100) // low word -> r4
        try! (cpu.memory as! FlatPhysicalMemory).writeWord32(0x2222_2222, at: 104) // high word -> r5
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 0x1111_1111)
        XCTAssertEqual(cpu.registers[5], 0x2222_2222)
    }

    func testStrexdStoresDoublewordAndSignalsSuccessRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE1B2_4F9F, // ldrexd r4, r5, [r2] -- opens the exclusive monitor
            0xE1A2_3F98, // strexd r3, r8, sb, [r2] -- real word from the actual kernel
        ])
        cpu.registers[2] = 100
        cpu.registers[8] = 0x1111_1111
        cpu.registers[9] = 0x2222_2222
        cpu.registers[3] = 0xFFFF_FFFF // Poison, to prove it gets overwritten with 0.
        cpu.step()
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[3], 0)
        XCTAssertEqual(try! (cpu.memory as! FlatPhysicalMemory).readWord32(at: 100), 0x1111_1111)
        XCTAssertEqual(try! (cpu.memory as! FlatPhysicalMemory).readWord32(at: 104), 0x2222_2222)
    }

    func testStrexStoresAndSignalsSuccessRealKernelWord() {
        let cpu = makeCPU(program: [
            0xE19C_1F9F, // ldrex r1, [ip] -- opens the exclusive monitor
            0xE18C_3F90, // strex r3, r0, [ip] -- real word from the actual kernel
        ])
        cpu.registers[12] = 100
        cpu.registers[0] = 0xDEAD_BEEF
        cpu.registers[3] = 0xFFFF_FFFF // Poison, to prove it gets overwritten with 0.
        cpu.step()
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[3], 0)
        XCTAssertEqual(try! (cpu.memory as! FlatPhysicalMemory).readWord32(at: 100), 0xDEAD_BEEF)
    }

    /// With no `LDREX` first, the monitor is closed: `STREX` must report
    /// failure and leave memory alone.
    func testStrexWithoutLdrexFailsAndDoesNotStore() {
        let cpu = makeCPU(program: [
            0xE18C_3F90, // strex r3, r0, [ip]
        ])
        cpu.registers[12] = 100
        cpu.registers[0] = 0xDEAD_BEEF
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[3], 1)
        XCTAssertEqual(try! (cpu.memory as! FlatPhysicalMemory).readWord32(at: 100), 0)
    }

    /// `CLREX` between the pair (what XNU does on exception entry) makes
    /// the interrupted sequence's `STREX` fail, so it retries.
    func testClrexBetweenLdrexAndStrexMakesStrexFail() {
        let cpu = makeCPU(program: [
            0xE19C_1F9F, // ldrex r1, [ip]
            0xF57F_F01F, // clrex -- real word from the actual kernel's abort handler
            0xE18C_3F90, // strex r3, r0, [ip]
        ])
        cpu.registers[12] = 100
        cpu.registers[0] = 0xDEAD_BEEF
        cpu.step()
        cpu.step()
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[3], 1)
        XCTAssertEqual(try! (cpu.memory as! FlatPhysicalMemory).readWord32(at: 100), 0)
    }

    func testVpushRealKernelWord() {
        let cpu = makeCPU(program: [
            0xED6D_0B20, // vpush {d16-d31} -- real word from the actual kernel
        ], memorySize: 512)
        cpu.registers[13] = 256 // SP
        cpu.neon[16] = 0x1111_1111_2222_2222
        cpu.neon[31] = 0x3333_3333_4444_4444
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[13], 128) // 256 - 16 D-registers * 8 bytes
        let memory = cpu.memory as! FlatPhysicalMemory
        // D16 is the first register pushed, at the new (lowest) SP.
        XCTAssertEqual(try! memory.readWord32(at: 128), 0x2222_2222) // low word
        XCTAssertEqual(try! memory.readWord32(at: 132), 0x1111_1111) // high word
        // D31 is the last register pushed, at new SP + 15*8.
        XCTAssertEqual(try! memory.readWord32(at: 248), 0x4444_4444) // low word
        XCTAssertEqual(try! memory.readWord32(at: 252), 0x3333_3333) // high word
    }

    func testVeorQuadRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF34C_C1FC, // veor q14, q14, q14 -- real word from the actual kernel
        ])
        cpu.neon[28] = 0x1111_1111_2222_2222 // D28 (low half of Q14)
        cpu.neon[29] = 0x3333_3333_4444_4444 // D29 (high half of Q14)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[28], 0) // Q14 ^ Q14 == 0, regardless of the operand's prior value.
        XCTAssertEqual(cpu.neon[29], 0)
    }

    func testVld1MultipleWithByTransferSizeWritebackRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF463_EAAD, // vld1.32 {d30,d31}, [r3:0x80]! -- real word from the actual kernel
        ], memorySize: 256)
        cpu.registers[3] = 100
        let memory = cpu.memory as! FlatPhysicalMemory
        try! memory.writeWord32(0x1111_1111, at: 100) // D30 low
        try! memory.writeWord32(0x2222_2222, at: 104) // D30 high
        try! memory.writeWord32(0x3333_3333, at: 108) // D31 low
        try! memory.writeWord32(0x4444_4444, at: 112) // D31 high
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[30], 0x2222_2222_1111_1111)
        XCTAssertEqual(cpu.neon[31], 0x4444_4444_3333_3333)
        XCTAssertEqual(cpu.registers[3], 116) // base + 2 D-registers * 8 bytes
    }

    func testVrev32QuadRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF3B0_80E8, // vrev32.8 q4, q12 -- real word from the actual kernel
        ])
        cpu.neon[24] = 0x8877_6655_4433_2211 // D24 (low half of Q12)
        cpu.neon[25] = 0x8877_6655_4433_2211 // D25 (high half of Q12)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Each 32-bit group's 4 bytes reverse order: 0x44332211 -> 0x11223344, 0x88776655 -> 0x55667788.
        XCTAssertEqual(cpu.neon[8], 0x5566_7788_1122_3344) // D8 (low half of Q4)
        XCTAssertEqual(cpu.neon[9], 0x5566_7788_1122_3344) // D9 (high half of Q4)
    }

    func testVaddI32QuadRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF268_886E, // vadd.i32 q12, q4, q15 -- real word from the actual kernel
        ])
        cpu.neon[8] = 0x0000_0005_0000_0003 // D8 (low half of Q4): lanes 3, 5
        cpu.neon[30] = 0x0000_0002_0000_0001 // D30 (low half of Q15): lanes 1, 2
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[24], 0x0000_0007_0000_0004) // D24 (low half of Q12): 3+1, 5+2
    }

    func testVorrQuadIdentityRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF268_01F8, // vorr q8, q12, q12 -- real word from the actual kernel (VMOV idiom)
        ])
        cpu.neon[24] = 0x1111_1111_2222_2222 // D24 (low half of Q12)
        cpu.neon[25] = 0x3333_3333_4444_4444 // D25 (high half of Q12)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0x1111_1111_2222_2222) // D16 (low half of Q8)
        XCTAssertEqual(cpu.neon[17], 0x3333_3333_4444_4444) // D17 (high half of Q8)
    }

    func testVext64QuadRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF2F8_0866, // vext.64 q8, q4, q11, #1 -- real word from the actual kernel
        ])
        cpu.neon[8] = 0x1111_1111_1111_1111 // D8 (low half of Q4)
        cpu.neon[9] = 0x2222_2222_2222_2222 // D9 (high half of Q4)
        cpu.neon[22] = 0x3333_3333_3333_3333 // D22 (low half of Q11)
        cpu.neon[23] = 0x4444_4444_4444_4444 // D23 (high half of Q11)
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // byteOffset=8 into the 32-byte concatenation [D8,D9,D22,D23] -> [D9, D22].
        XCTAssertEqual(cpu.neon[16], 0x2222_2222_2222_2222) // D16 (low half of Q8)
        XCTAssertEqual(cpu.neon[17], 0x3333_3333_3333_3333) // D17 (high half of Q8)
    }

    func testVshlI32ImmediateQuadRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF2E1_8570, // vshl.i32 q12, q8, #1 -- real word from the actual kernel
        ])
        cpu.neon[16] = 0x0000_0002_0000_0001 // D16 (low half of Q8): lanes 1, 2
        cpu.neon[17] = 0x0000_0003_8000_0000 // D17 (high half of Q8): lanes 0x80000000, 3
        cpu.step()

        XCTAssertNil(cpu.lastError)
        // Non-saturating left shift: 0x80000000 << 1 masked to 32 bits drops the overflow bit.
        XCTAssertEqual(cpu.neon[24], 0x0000_0004_0000_0002) // D24 (low half of Q12)
        XCTAssertEqual(cpu.neon[25], 0x0000_0006_0000_0000) // D25 (high half of Q12)
    }

    func testVshrU32ImmediateQuadRealKernelWord() {
        let cpu = makeCPU(program: [
            0xF3E1_0070, // vshr.u32 q8, q8, #0x1f -- real word from the actual kernel
        ])
        cpu.neon[16] = 0x0000_0002_0000_0001 // D16 (low half of Q8): lanes 1, 2
        cpu.neon[17] = 0x0000_0003_8000_0000 // D17 (high half of Q8): lanes 0x80000000, 3
        cpu.step()

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[16], 0) // 1>>31, 2>>31 both 0
        XCTAssertEqual(cpu.neon[17], 0x0000_0000_0000_0001) // 0x80000000>>31 = 1, 3>>31 = 0
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

    /// `umlal r4, ip, lr, r3` — the real kext word at 0x806EEF08 that
    /// halted boot before the long multiplies were decoded.
    func testUmlalAccumulatesUnsigned64BitProduct() {
        let cpu = makeCPU(program: [0xE0AC_439E])
        cpu.registers[14] = 0xFFFF_FFFF
        cpu.registers[3] = 2
        cpu.registers[12] = 0x0000_0001 // RdHi
        cpu.registers[4] = 0x0000_0003 // RdLo
        cpu.step()
        XCTAssertNil(cpu.lastError)
        // 0xFFFFFFFF * 2 = 0x1_FFFFFFFE; + 0x1_00000003 = 0x3_00000001
        XCTAssertEqual(cpu.registers[12], 3)
        XCTAssertEqual(cpu.registers[4], 1)
    }

    func testSmullProducesSigned64BitProduct() {
        let cpu = makeCPU(program: [0xE0C1_0392]) // smull r0, r1, r2, r3
        cpu.registers[2] = UInt32(bitPattern: -3)
        cpu.registers[3] = 7
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], UInt32(bitPattern: -21))
        XCTAssertEqual(cpu.registers[1], 0xFFFF_FFFF)
    }

    func testMlaAndMls() {
        let mla = makeCPU(program: [0xE023_2190]) // mla r3, r0, r1, r2
        mla.registers[0] = 6
        mla.registers[1] = 7
        mla.registers[2] = 100
        mla.step()
        XCTAssertEqual(mla.registers[3], 142)

        let mls = makeCPU(program: [0xE063_2190]) // mls r3, r0, r1, r2
        mls.registers[0] = 6
        mls.registers[1] = 7
        mls.registers[2] = 100
        mls.step()
        XCTAssertEqual(mls.registers[3], 58)
    }

    func testMulsSetsNZAndLeavesCV() {
        let cpu = makeCPU(program: [0xE010_0291]) // muls r0, r1, r2
        cpu.registers[1] = 0x8000_0000
        cpu.registers[2] = 1
        cpu.cpsr.carry = true
        cpu.cpsr.overflow = true
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[0], 0x8000_0000)
        XCTAssertTrue(cpu.cpsr.negative)
        XCTAssertFalse(cpu.cpsr.zero)
        XCTAssertTrue(cpu.cpsr.carry)
        XCTAssertTrue(cpu.cpsr.overflow)
    }

    func testUmaalAddsBothHalvesToProduct() {
        let cpu = makeCPU(program: [0xE041_0392]) // umaal r0, r1, r2, r3
        cpu.registers[2] = 0xFFFF_FFFF
        cpu.registers[3] = 0xFFFF_FFFF
        cpu.registers[0] = 0xFFFF_FFFF
        cpu.registers[1] = 0xFFFF_FFFF
        cpu.step()
        XCTAssertNil(cpu.lastError)
        // (2^32-1)^2 + 2(2^32-1) = 2^64 - 1: the maximum, with no overflow.
        XCTAssertEqual(cpu.registers[0], 0xFFFF_FFFF)
        XCTAssertEqual(cpu.registers[1], 0xFFFF_FFFF)
    }

    /// A write to an unmapped address must report DFSR.WnR (bit 11), or
    /// the guest's abort handler treats it as a read fault and a
    /// copy-on-write page would be mapped read-only again forever.
    func testDataAbortOnWriteSetsDFSRWriteNotReadBit() {
        let cpu = makeCPU(program: [
            0xEE02_0F10, // MCR p15, #0, r0, c2, c0, #0  (TTBR0 = r0)
            0xEE03_2F10, // MCR p15, #0, r2, c3, c0, #0  (DACR = r2)
            0xE580_1000, // STR r1, [r0]                 (table[0]: identity section for this code)
            0xEE01_3F10, // MCR p15, #0, r3, c1, c0, #0  (SCTLR = r3, enables the MMU)
            0xE585_4000, // STR r4, [r5]                 -- r5 has no first-level entry
        ], memorySize: 0x8000)
        cpu.loadInitialRegisters([
            0x0000_4000, 0xC02, 1, 1, 0, 0x0070_0000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])

        for _ in 0..<5 { cpu.step() }

        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 0x10, "should be at the Data Abort vector")
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 5, crm: 0, opc2: 0), 0b00101 | (1 << 11))
        XCTAssertEqual(cpu.cp15.read(coprocessor: 15, opc1: 0, crn: 6, crm: 0, opc2: 0), 0x0070_0000)
    }

    func testVldmiaSinglePrecisionWithWritebackFillsSRegisterHalves() {
        let cpu = makeCPU(program: [0xECB0_0A04]) // vldmia r0!, {s0-s3}
        cpu.registers[0] = 0x40
        for (i, value) in [UInt32(1), 2, 3, 4].enumerated() {
            try! cpu.memory.writeWord32(value, at: 0x40 + UInt32(i * 4))
        }
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[0], 0x0000_0002_0000_0001, "S0 is D0's low half, S1 its high half")
        XCTAssertEqual(cpu.neon[1], 0x0000_0004_0000_0003)
        XCTAssertEqual(cpu.registers[0], 0x50)
    }

    func testVmovBetweenCoreRegisterPairAndDRegister() {
        let toD = makeCPU(program: [0xEC41_0B30]) // vmov d16, r0, r1
        toD.registers[0] = 0xAAAA_AAAA
        toD.registers[1] = 0xBBBB_BBBB
        toD.step()
        XCTAssertNil(toD.lastError)
        XCTAssertEqual(toD.neon[16], 0xBBBB_BBBB_AAAA_AAAA)

        let toCore = makeCPU(program: [0xEC51_0B30]) // vmov r0, r1, d16
        toCore.neon[16] = 0x1111_2222_3333_4444
        toCore.step()
        XCTAssertNil(toCore.lastError)
        XCTAssertEqual(toCore.registers[0], 0x3333_4444)
        XCTAssertEqual(toCore.registers[1], 0x1111_2222)
    }

    /// ARM-state `WFI` with nothing pending skips virtual time straight to
    /// the next device event, exactly like the Thumb form.
    func testARMWaitForInterruptSkipsToNextDeviceEvent() {
        let cpu = makeCPU(program: [0xE320_F003]) // wfi
        cpu.nextDeviceEventAt = 5_000
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 4)
        XCTAssertEqual(cpu.idleInstructionsSkipped, 5_000)
    }

    /// WFI wakes on the pin even while the interrupt is masked (CPSR.I
    /// set, as in XNU's `cpu_idle`), so a pending IRQ means no skip.
    func testARMWaitForInterruptDoesNotSkipWithMaskedInterruptPending() {
        let cpu = makeCPU(program: [0xE320_F003]) // wfi
        cpu.cpsr.irqDisabled = true
        cpu.irqAsserted = true
        cpu.nextDeviceEventAt = 5_000
        cpu.step()
        XCTAssertEqual(cpu.idleInstructionsSkipped, 0)
    }

    func testConditionalWaitForInterruptNotTakenDoesNotSkip() {
        let cpu = makeCPU(program: [0x0320_F003]) // wfieq
        cpu.cpsr.zero = false
        cpu.nextDeviceEventAt = 5_000
        cpu.step()
        XCTAssertEqual(cpu.idleInstructionsSkipped, 0)
    }

    /// `LDREXD`/`STREXD` obey their condition like every other ARM
    /// instruction: a failed `strexdne` must leave memory, the status
    /// register and the monitor alone.
    func testConditionalExclusiveDoubleNotTakenHasNoEffect() {
        let cpu = makeCPU(program: [
            0x11B2_2F9F, // ldrexdne r2, r3, [r2] — skipped
            0x11A0_1F92, // strexdne r1, r2, r3, [r0] — skipped
        ])
        cpu.cpsr.zero = true
        cpu.registers[0] = 0x80
        cpu.registers[1] = 0xAAAA_AAAA
        cpu.registers[2] = 0x40
        cpu.step(); cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[1], 0xAAAA_AAAA)
        XCTAssertEqual(cpu.registers[2], 0x40)
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x80), 0)
    }

    /// `svc #0x80` from User mode: SVC mode, LR_svc = next instruction,
    /// SPSR_svc = the User CPSR, vector 0x08 — how every syscall enters.
    func testSupervisorCallFromUserMode() {
        let cpu = makeCPU(program: [0xEF00_0080], memorySize: 0x1000)
        cpu.cpsr.rawValue = ARMv7CPU.userModeBits
        cpu.registers.sp = 0x800
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.svcModeBits)
        XCTAssertEqual(cpu.registers.lr, 4)
        XCTAssertEqual(cpu.registers.pc, 0x08)
        XCTAssertTrue(cpu.cpsr.irqDisabled)
        XCTAssertEqual(cpu.savedProgramStatus(forModeBits: ARMv7CPU.svcModeBits).map { $0 & 0x1F }, ARMv7CPU.userModeBits)
    }

    /// `stm r0, {sp, lr}^` in SVC mode stores the *User* SP and LR, and
    /// `ldm sp!, {r0, pc}^` returns to User mode through SPSR.
    func testUserBankTransferAndExceptionReturn() throws {
        let cpu = makeCPU(program: [
            0xEF00_0000, // svc #0 (from User mode)
            0xE8C0_6000, // at 0x08 (the SVC vector): stm r0, {sp, lr}^
            0xE8FD_8001, // ldm sp!, {r0, pc}^
        ], memorySize: 0x1000)
        cpu.cpsr.rawValue = ARMv7CPU.userModeBits
        cpu.registers.sp = 0x1111
        cpu.registers.lr = 0x2222
        cpu.step() // svc: now in SVC mode at 0x08
        // Put the stm/ldm at the vector.
        try cpu.memory.writeWord32(0xE8C0_6000, at: 0x08)
        try cpu.memory.writeWord32(0xE8FD_8001, at: 0x0C)
        cpu.registers[0] = 0x400
        cpu.registers.sp = 0x800
        try cpu.memory.writeWord32(0xAAAA, at: 0x800)
        try cpu.memory.writeWord32(0x0100, at: 0x804)
        cpu.step() // stm ... ^
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x400), 0x1111, "User SP, not SVC SP")
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x404), 0x2222, "User LR, not SVC LR")
        cpu.step() // ldm sp!, {r0, pc}^
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.userModeBits)
        XCTAssertEqual(cpu.registers.pc, 0x100)
        XCTAssertEqual(cpu.registers[0], 0xAAAA)
        XCTAssertEqual(cpu.registers.sp, 0x1111, "back on the User stack")
    }

    /// `srsdb sp!, #0x13` then `rfeia sp!`: the return state goes to the
    /// SVC stack and comes back as PC and CPSR.
    func testStoreReturnStateAndReturnFromException() throws {
        let cpu = makeCPU(program: [0xEF00_0000], memorySize: 0x1000) // svc #0 from User
        cpu.cpsr.rawValue = ARMv7CPU.userModeBits
        cpu.step()
        try cpu.memory.writeWord32(0xF96D_0513, at: 0x08) // srsdb sp!, #0x13
        try cpu.memory.writeWord32(0xF8BD_0A00, at: 0x0C) // rfeia sp!
        cpu.registers.sp = 0x800
        cpu.step()
        XCTAssertEqual(cpu.registers.sp, 0x7F8)
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x7F8), 4, "LR_svc")
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x7FC) & 0x1F, ARMv7CPU.userModeBits, "SPSR_svc")
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers.pc, 4)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.userModeBits)
    }

    /// The TLB caches a translation until the guest invalidates it, as a
    /// real one does: after a section is remapped, TLBIALL makes the next
    /// load see the new mapping.
    func testTLBInvalidationPicksUpARemappedSection() throws {
        let cpu = makeCPU(program: [
            0xEE02_0F10, // MCR p15, #0, r0, c2, c0, #0  (TTBR0 = r0)
            0xEE03_2F10, // MCR p15, #0, r2, c3, c0, #0  (DACR = r2)
            0xE580_1000, // STR r1, [r0]                 (table[0]: identity section for code and data)
            0xEE01_3F10, // MCR p15, #0, r3, c1, c0, #0  (SCTLR.M = 1)
            0xE595_4000, // LDR r4, [r5]                 (VA 0x00100000, section 1)
            0xE580_6004, // STR r6, [r0, #4]             (remap section 1)
            0xEE08_0F17, // MCR p15, #0, r0, c8, c7, #0  (TLBIALL)
            0xE595_4000, // LDR r4, [r5]
        ], memorySize: 0x30_0000)
        try cpu.memory.writeWord32(0x0010_0C02, at: 0x4004)      // section 1 -> 0x00100000
        try cpu.memory.writeWord32(0x1111_1111, at: 0x0010_0000)
        try cpu.memory.writeWord32(0x2222_2222, at: 0x0020_0000)
        cpu.loadInitialRegisters([
            0x0000_4000, 0xC02, 1, 1, 0, 0x0010_0000, 0x0020_0C02, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])
        for _ in 0..<5 { cpu.step() }
        XCTAssertEqual(cpu.registers[4], 0x1111_1111)
        for _ in 0..<3 { cpu.step() }
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.registers[4], 0x2222_2222, "the invalidated TLB re-walked the table")
    }


    /// The TLB tags entries with the ASID (CONTEXTIDR) active when they
    /// were cached, and doesn't need a flush on an ordinary TTBR0/
    /// CONTEXTIDR context switch (see `ARMv7CPU.translatedAddress`'s doc
    /// comment) — this proves that's actually safe: two address spaces
    /// mapping the *same* virtual page to *different* physical pages,
    /// switched between repeatedly with no explicit TLB invalidate, never
    /// cross-contaminate. A version that folded ASID into neither the tag
    /// nor the slot index would return the wrong process's data here.
    func testTLBDistinguishesAddressSpacesByASIDWithoutExplicitInvalidate() throws {
        // Everything here is set up directly via `cpu.cp15`/`cpu.memory`,
        // not by executing guest instructions, so the program is empty.
        let cpu = makeCPU(program: [], memorySize: 0x40_0000)
        // Two independent 16 KB first-level tables, built by hand.
        let tableA: UInt32 = 0x1_0000, tableB: UInt32 = 0x2_0000
        // Both tables identity-map section 0 (VA 0x0-0xFFFFF); table A's
        // section 1 (VA 0x100000) points at physical 0x200000, table B's
        // same slot points at physical 0x300000 — same VA, deliberately
        // different destinations.
        try cpu.memory.writeWord32(0x0000_0C02, at: tableA) // section 0 identity
        try cpu.memory.writeWord32(0x0020_0C02, at: tableA + 4) // section 1 -> 0x200000
        try cpu.memory.writeWord32(0x0000_0C02, at: tableB)
        try cpu.memory.writeWord32(0x0030_0C02, at: tableB + 4) // section 1 -> 0x300000
        try cpu.memory.writeWord32(0xAAAA_AAAA, at: 0x20_0000)
        try cpu.memory.writeWord32(0xBBBB_BBBB, at: 0x30_0000)

        func setUpAddressSpace(_ table: UInt32, asid: UInt32) {
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: table) // TTBR0
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 13, crm: 0, opc2: 1, value: asid) // CONTEXTIDR
        }
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: 1) // DACR: domain 0 client
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0, value: 1) // SCTLR.M = 1

        setUpAddressSpace(tableA, asid: 1)
        XCTAssertEqual(try cpu.translatedAddress(0x10_0000, access: .read), 0x20_0000)
        XCTAssertEqual(try cpu.memory.readWord32(at: try cpu.translatedAddress(0x10_0000, access: .read)), 0xAAAA_AAAA)

        setUpAddressSpace(tableB, asid: 2)
        XCTAssertEqual(try cpu.translatedAddress(0x10_0000, access: .read), 0x30_0000, "different ASID, different mapping for the same VA")
        XCTAssertEqual(try cpu.memory.readWord32(at: try cpu.translatedAddress(0x10_0000, access: .read)), 0xBBBB_BBBB)

        // Switch back to A with no TLBI in between — must still see A's
        // mapping, not a stale/cross-contaminated hit from B.
        setUpAddressSpace(tableA, asid: 1)
        XCTAssertEqual(try cpu.translatedAddress(0x10_0000, access: .read), 0x20_0000, "back on A: A's mapping, not B's")
    }

    /// A VST1/VLD1 word straddling a page boundary must be translated per
    /// page. Two adjacent virtual sections map to non-adjacent physical
    /// memory here, with a sentinel right after the first one's physical
    /// end: a store translated only at its first byte would spill into
    /// that sentinel — the real bug, where a NEON memset two bytes before
    /// a page boundary zeroed another process's page.
    func testVST1AcrossPageBoundaryTranslatesEachPage() throws {
        let cpu = makeCPU(program: [
            0xF401_070F, // vst1.8 {d0}, [r1]
            0xF421_170F, // vld1.8 {d1}, [r1]
        ], memorySize: 0x60_0000)
        let table: UInt32 = 0x1_0000
        try cpu.memory.writeWord32(0x0000_0C02, at: table)       // VA 0x000000 -> PA 0x000000
        try cpu.memory.writeWord32(0x0020_0C02, at: table + 4)   // VA 0x100000 -> PA 0x200000
        try cpu.memory.writeWord32(0x0040_0C02, at: table + 8)   // VA 0x200000 -> PA 0x400000
        try cpu.memory.writeWord32(0xCCCC_CCCC, at: 0x30_0000)   // physically right after VA 0x1FFFFF
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: table)
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: 1)
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0, value: 1)
        cpu.registers[1] = 0x1F_FFFE
        cpu.neon[0] = 0x1122_3344_5566_7788

        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(try cpu.memory.readByte(at: 0x2F_FFFE), 0x88)
        XCTAssertEqual(try cpu.memory.readByte(at: 0x2F_FFFF), 0x77)
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x40_0000), 0x3344_5566, "the rest goes to the second page's own physical memory")
        XCTAssertEqual(try cpu.memory.readWord32(at: 0x30_0000), 0xCCCC_CCCC, "nothing spills into the physically adjacent page")

        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.neon[1], 0x1122_3344_5566_7788, "VLD1 reads back across the same boundary")
    }

    /// A user process running a word this CPU can't execute gets the
    /// Undefined Instruction exception, like real hardware, instead of
    /// halting the whole emulator. 0xF04F2116 is the real case: Thumb
    /// `movs r1,#0x16; mov.w sl,#0` from libsystem_c, run as ARM after a
    /// daemon jumped through a corrupted function pointer — cond=1111 with
    /// op1=0000100 is architecturally UNDEFINED in ARM state.
    func testUserModeUnexecutableInstructionTakesUndefinedException() {
        let cpu = makeCPU(program: [0xF04F_2116])
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~0x1F) | ARMv7CPU.userModeBits
        var reported: (UInt32, UInt32)?
        cpu.userUndefinedInstructionHandler = { reported = ($0, $1) }
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.undefinedModeBits)
        XCTAssertEqual(cpu.registers.pc, 0x04)
        XCTAssertEqual(cpu.registers.lr, 4, "LR_und = the instruction's address + 4 in ARM state")
        XCTAssertEqual(cpu.savedProgramStatus(forModeBits: ARMv7CPU.undefinedModeBits).map { $0 & 0x1F }, ARMv7CPU.userModeBits)
        XCTAssertEqual(reported?.0, 0)
        XCTAssertEqual(reported?.1, 0xF04F_2116)
    }

    /// The same word in a privileged mode still halts: the kernel hitting
    /// it means a gap in this CPU, which must stay loud.
    func testPrivilegedUnexecutableInstructionStillHalts() {
        let cpu = makeCPU(program: [0xF04F_2116])
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~0x1F) | ARMv7CPU.svcModeBits
        cpu.step()
        XCTAssertEqual(cpu.lastError, .unsupportedInstruction(rawWord: 0xF04F_2116, address: 0))
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.svcModeBits)
    }

    /// Thumb state too: LR_und = the address + 2, and SPSR keeps T set so
    /// the guest kernel sees a Thumb fault.
    func testUserModeUndefinedThumbInstructionTakesUndefinedException() {
        let hw: UInt16 = 0xDE00 // udf #0
        switch ThumbDecoder.decode(hw, 0) {
        case .undefined, .unsupported: break
        default: return XCTFail("expected 0xDE00 to be undefined/unsupported in Thumb")
        }
        let cpu = makeCPU(program: [UInt32(hw)])
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & ~0x1F) | ARMv7CPU.userModeBits
        cpu.cpsr.thumbState = true
        cpu.step()
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.cpsr.rawValue & 0x1F, ARMv7CPU.undefinedModeBits)
        XCTAssertFalse(cpu.cpsr.thumbState, "exception entry is in ARM state")
        XCTAssertEqual(cpu.registers.lr, 2)
        XCTAssertEqual(cpu.savedProgramStatus(forModeBits: ARMv7CPU.undefinedModeBits).map { $0 & 0x20 }, 0x20)
    }
}
