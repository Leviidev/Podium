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
        guard let block = ThumbJITTranslator.translate([.dataProcessingShiftedRegister(instr)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(block.totalByteLength, 4, "dataProcessingShiftedRegister is a Thumb-2 wide (32-bit) encoding")

        var registers = [UInt32](repeating: 0, count: 16)
        registers[3] = 10
        registers[9] = 3
        registers.withUnsafeMutableBufferPointer { block.run(registers: $0.baseAddress!) }

        XCTAssertEqual(registers[1], 7) // r1 = r3 - r9 = 10 - 3
    }

    func testCompiledHiRegisterMovCopiesRegister() throws {
        let instr = ThumbHiRegisterInstruction(op: .mov, rdn: 5, rm: 3)
        guard let block = ThumbJITTranslator.translate([.hiRegister(instr)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(block.totalByteLength, 2, "hiRegister is a Thumb16 (16-bit) encoding")

        var registers = [UInt32](repeating: 0, count: 16)
        registers[3] = 0xABCD
        registers.withUnsafeMutableBufferPointer { block.run(registers: $0.baseAddress!) }

        XCTAssertEqual(registers[5], 0xABCD)
    }

    func testCompiledHiRegisterAddSumsRegisters() throws {
        let instr = ThumbHiRegisterInstruction(op: .add, rdn: 8, rm: 2)
        guard let block = ThumbJITTranslator.translate([.hiRegister(instr)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        var registers = [UInt32](repeating: 0, count: 16)
        registers[8] = 100
        registers[2] = 23
        registers.withUnsafeMutableBufferPointer { block.run(registers: $0.baseAddress!) }

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
}
