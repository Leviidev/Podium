import XCTest
@testable import Podium

/// The Thumb-state sibling of `JITExecutionTests` — see that file's doc
/// comment on why these skip (rather than fail) when the process doesn't
/// hold the dynamic-codesigning right `mprotect(PROT_EXEC)` needs.
final class ThumbJITExecutionTests: XCTestCase {
    func testCompiledSubWShiftedRegisterMatchesRealKernelWord() throws {
        // sub.w r1, r3, sb (r9) — from the real kernel at 0x80018042 (see
        // ThumbDecoderTests.testDecodesSubWShiftedRegisterFromRealKernel).
        guard case .dataProcessingShiftedRegister(let instr) = ThumbDecoder.decode(0xeba3, 0x0109) else {
            return XCTFail("Expected dataProcessingShiftedRegister")
        }
        guard let block = ThumbJITTranslator.translate([(.dataProcessingShiftedRegister(instr), 4)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(block.totalByteLength, 4, "dataProcessingShiftedRegister is a Thumb-2 wide (32-bit) encoding")

        var registers = [UInt32](repeating: 0, count: 16)
        registers[3] = 10
        registers[9] = 3
        var cpsr: UInt32 = 0
        registers.withUnsafeMutableBufferPointer { block.run(registers: $0.baseAddress!, cpsr: &cpsr) }

        XCTAssertEqual(registers[1], 7) // r1 = r3 - r9 = 10 - 3
    }

    func testCompiledHiRegisterMovCopiesRegister() throws {
        let instr = ThumbHiRegisterInstruction(op: .mov, rdn: 5, rm: 3)
        guard let block = ThumbJITTranslator.translate([(.hiRegister(instr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(block.totalByteLength, 2, "hiRegister is a Thumb16 (16-bit) encoding")

        var registers = [UInt32](repeating: 0, count: 16)
        registers[3] = 0xABCD
        var cpsr: UInt32 = 0
        registers.withUnsafeMutableBufferPointer { block.run(registers: $0.baseAddress!, cpsr: &cpsr) }

        XCTAssertEqual(registers[5], 0xABCD)
    }

    func testCompiledHiRegisterAddSumsRegisters() throws {
        let instr = ThumbHiRegisterInstruction(op: .add, rdn: 8, rm: 2)
        guard let block = ThumbJITTranslator.translate([(.hiRegister(instr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        var registers = [UInt32](repeating: 0, count: 16)
        registers[8] = 100
        registers[2] = 23
        var cpsr: UInt32 = 0
        registers.withUnsafeMutableBufferPointer { block.run(registers: $0.baseAddress!, cpsr: &cpsr) }

        XCTAssertEqual(registers[8], 123)
    }

    /// `rm == pc` for a hi-register `ADD`/`MOV` reads the *aligned
    /// instruction address + 4* (see `thumbOperandValue`), not the raw
    /// register file value this translator's calling convention has
    /// access to — must stay interpreted. Verified against a real `add
    /// r4, pc` word from the actual kernel (confirms this combination is
    /// real code the JIT will actually be asked about, not just a
    /// theoretical edge case).
    func testHiRegisterWithPCSourceIsNotJITEligible() {
        guard case .hiRegister(let instr) = ThumbDecoder.decode(0x447c, 0) else {
            return XCTFail("Expected hiRegister")
        }
        XCTAssertEqual(instr.rm, Registers.pcIndex)
        XCTAssertFalse(ThumbJITTranslator.isSupported(.hiRegister(instr)))
    }

    /// The real bug this session found the hard way: `ThumbJITTranslator`
    /// has no representation of Thumb `IT`-block conditional execution —
    /// its compiled code always runs unconditionally — but
    /// `stepThumb()`'s interpreter path conditionally *skips* a
    /// predicated instruction's effect entirely (advancing `pc` but never
    /// calling `executeThumb`) whenever `currentThumbCondition()` fails
    /// against the current flags. Compiling and running a `sub.w r1, r3,
    /// sb`-shaped instruction while `itState` is active would silently
    /// perform the write even on an iteration where a real ARM CPU (and
    /// this interpreter) would skip it — traced back from a real,
    /// reproducible false kernel panic (`sleh_abort at interrupt
    /// context`) that only happened with the JIT enabled, never with the
    /// interpreter alone. `runOneUnit()` now refuses the JIT outright
    /// whenever `itState != 0`, regardless of whether the specific
    /// instruction at `pc` happens to be predicated true or false this
    /// time — this test locks that gate in place.
    func testJITNeverAttemptedInsideActiveITBlock() throws {
        let bytes: [UInt8] = [0xa3, 0xeb, 0x09, 0x01] // sub.w r1, r3, sb, little-endian

        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeByte(bytes[0], at: 0)
        try memory.writeByte(bytes[1], at: 1)
        try memory.writeByte(bytes[2], at: 2)
        try memory.writeByte(bytes[3], at: 3)

        let jitEngine = JITEngine()
        let cpu = ARMv7CPU(memory: memory, jit: jitEngine)
        cpu.reset()
        cpu.cpsr.thumbState = true
        cpu.itState = 0xA8 // any nonzero value simulates an active IT block
        _ = cpu.run(maxUnits: 1)

        XCTAssertEqual(jitEngine.stats, JITEngine.Stats())
    }

    /// Runs the same real kernel word (`sub.w r1, r3, sb`) through a
    /// pure-interpreter CPU and a JIT-enabled CPU via `ARMv7CPU.run()`,
    /// and requires them to agree exactly — the same cross-check
    /// `JITExecutionTests.testJITEnabledCPUMatchesInterpreterOverAFullRun`
    /// does for ARM state, but exercising the real Thumb-state path
    /// through `ARMv7CPU.runOneUnit()` (its `thumbState`-aware cache key
    /// and `block.totalByteLength`-based `pc` advance), not just the
    /// translator in isolation.
    func testJITEnabledCPUMatchesInterpreterOverAFullThumbRun() throws {
        let bytes: [UInt8] = [0xa3, 0xeb, 0x09, 0x01] // sub.w r1, r3, sb (0xeba3, 0x0109), little-endian

        let interpreterMemory = FlatPhysicalMemory(length: 16)
        for (index, byte) in bytes.enumerated() {
            try interpreterMemory.writeByte(byte, at: UInt32(index))
        }
        let interpreterCPU = ARMv7CPU(memory: interpreterMemory)
        interpreterCPU.reset()
        interpreterCPU.cpsr.thumbState = true
        interpreterCPU.registers[3] = 10
        interpreterCPU.registers[9] = 3
        interpreterCPU.step()

        let jitMemory = FlatPhysicalMemory(length: 16)
        for (index, byte) in bytes.enumerated() {
            try jitMemory.writeByte(byte, at: UInt32(index))
        }
        let jitEngine = JITEngine()
        let jitCPU = ARMv7CPU(memory: jitMemory, jit: jitEngine)
        jitCPU.reset()
        jitCPU.cpsr.thumbState = true
        jitCPU.registers[3] = 10
        jitCPU.registers[9] = 3
        _ = jitCPU.run(maxUnits: 1)

        guard jitEngine.stats.compiledBlockCount > 0 else {
            throw XCTSkip("JIT produced no compiled blocks in this environment (mprotect PROT_EXEC unavailable).")
        }

        XCTAssertNil(jitCPU.lastError)
        for register in [1, 3, 9] {
            XCTAssertEqual(jitCPU.registers[register], interpreterCPU.registers[register], "register \(register) diverged between JIT and interpreter")
        }
        XCTAssertEqual(jitCPU.registers.pc, interpreterCPU.registers.pc)
    }

    /// Runs `bytes` as Thumb code on a JIT-enabled CPU and on a plain
    /// interpreter, for exactly `instructionCount` retired instructions
    /// each, and requires identical registers and CPSR.
    private func assertJITMatchesInterpreter(thumbBytes bytes: [UInt8], instructionCount: Int, setUp: (ARMv7CPU) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        func makeCPU(jit: JITEngine?) throws -> ARMv7CPU {
            let memory = FlatPhysicalMemory(length: 64)
            for (offset, byte) in bytes.enumerated() {
                try memory.writeByte(byte, at: UInt32(offset))
            }
            let cpu = ARMv7CPU(memory: memory, jit: jit)
            cpu.reset()
            cpu.cpsr.thumbState = true
            setUp(cpu)
            return cpu
        }

        let jitEngine = JITEngine()
        let jitCPU = try makeCPU(jit: jitEngine)
        let interpreterCPU = try makeCPU(jit: nil)
        while jitCPU.retiredInstructionCount < UInt64(instructionCount) && jitCPU.lastError == nil {
            jitCPU.run(maxUnits: 1)
        }
        interpreterCPU.run(maxUnits: instructionCount)

        guard jitEngine.stats.compiledBlockCount > 0 else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(jitCPU.retiredInstructionCount, UInt64(instructionCount), file: file, line: line)
        for register in 0..<16 {
            XCTAssertEqual(jitCPU.registers[register], interpreterCPU.registers[register], "r\(register)", file: file, line: line)
        }
        XCTAssertEqual(jitCPU.cpsr.rawValue, interpreterCPU.cpsr.rawValue, "cpsr", file: file, line: line)
    }

    /// Real kernel bytes at 0x802B827A: `movs r2, #2` (16-bit) then
    /// `mov.w r1, #-1` (32-bit, `f04f 31ff`). Discovery once advanced past
    /// the 16-bit `MOVS` by 4 bytes (a stale per-case width table), landing
    /// on `31ff` — the second halfword of the `MOV.W` — and compiling it as
    /// an unrelated `ADDS r1, #0xFF`.
    func testDiscoveryUsesRealInstructionWidthNotAPerCaseGuess() throws {
        try assertJITMatchesInterpreter(
            thumbBytes: [0x02, 0x22, 0x4f, 0xf0, 0xff, 0x31, 0x00, 0x28],
            instructionCount: 3,
            setUp: { $0.registers[1] = 0x802D_B000 }
        )
    }

    /// Real kernel bytes at 0x8027AD62: `cmp r0, #0` with r0 = 0x80000000.
    /// The JIT (host `SUBS`) was right here and the interpreter wrong — see
    /// `ALUTests.testSubtractionWhoseTrueResultIsIntMinDoesNotOverflow`.
    func testCompareOfIntMinAgainstZeroMatchesInterpreter() throws {
        try assertJITMatchesInterpreter(
            thumbBytes: [0x00, 0x28, 0x00, 0x28],
            instructionCount: 2,
            setUp: { $0.registers[0] = 0x8000_0000 }
        )
    }

    /// Flag-setting Thumb16 forms the JIT compiles — `MOVS`/`ADDS`/`SUBS`/
    /// `CMP`/`CMN` — in one block, followed by a flag-*reading* check via
    /// the final CPSR: every exit path must merge host NZCV back correctly,
    /// and `MOVS` must leave C/V exactly as the previous instruction set them.
    func testFlagSettingThumb16BlockMatchesInterpreter() throws {
        let bytes: [UInt8] = [
            0xff, 0x30, // adds r0, #0xff
            0x05, 0x38, // subs r0, #5
            0x00, 0x21, // movs r1, #0     (Z=1, C/V unchanged)
            0x88, 0x42, // cmp r0, r1
            0xc8, 0x42, // cmn r0, r1
            0x02, 0x22, // movs r2, #2
        ]
        try assertJITMatchesInterpreter(thumbBytes: bytes, instructionCount: 6, setUp: { $0.registers[0] = 0xFFFF_FF10 })
    }
}
