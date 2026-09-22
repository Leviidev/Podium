import XCTest
@testable import Podium

/// `ThumbJITTranslator`'s load/store support — see its own doc comment
/// for the bounds-check and partial-completion scheme these tests
/// exercise directly (bypassing `ARMv7CPU`/`JITEngine` discovery, so a
/// bug here can't be masked by anything upstream). Skips (rather than
/// fails) when the process doesn't hold the dynamic-codesigning right
/// `mprotect(PROT_EXEC)` needs, same as `JITExecutionTests`.
final class ThumbJITLoadStoreTests: XCTestCase {
    private let ramGuestBase: UInt32 = 0x1000
    private let ramSize = 4096

    private func withRAM<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T {
        var buffer = [UInt8](repeating: 0, count: ramSize)
        return buffer.withUnsafeMutableBytes { body($0.baseAddress!) }
    }

    /// `ldrh r0, [r4, #42]` — from the real kernel at 0x8027b9f8 (see
    /// `ThumbDecoderTests.testDecodesLdrhFromRealKernel`).
    func testCompiledHalfwordLoadMatchesRealKernelWord() throws {
        guard case .loadStoreImmediate(let instr) = ThumbDecoder.decode(0x8D60, 0) else {
            return XCTFail("Expected loadStoreImmediate")
        }
        guard let block = ThumbJITTranslator.translate([(.loadStoreImmediate(instr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        withRAM { ram in
            ram.storeBytes(of: UInt16(0xBEEF).littleEndian, toByteOffset: 42, as: UInt16.self)
            var registers = [UInt32](repeating: 0xFFFF_FFFF, count: 16)
            registers[4] = ramGuestBase
            var cpsr: UInt32 = 0
            let completed = registers.withUnsafeMutableBufferPointer { regPtr in
                block.run(registers: regPtr.baseAddress!, ramHostPointer: ram, ramGuestBase: ramGuestBase, ramGuestLength: UInt32(ramSize), cpsr: &cpsr)
            }
            XCTAssertEqual(completed, 1)
            XCTAssertEqual(registers[0], 0xBEEF, "halfword load must zero-extend, not sign-extend")
        }
    }

    func testCompiledWordLoadAndStoreRoundTrip() throws {
        let store = ThumbLoadStoreImmediateInstruction(isLoad: false, size: .word, rn: 1, rt: 2, offset: 16)
        let load = ThumbLoadStoreImmediateInstruction(isLoad: true, size: .word, rn: 1, rt: 3, offset: 16)
        guard let block = ThumbJITTranslator.translate([(.loadStoreImmediate(store), 2), (.loadStoreImmediate(load), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        withRAM { ram in
            var registers = [UInt32](repeating: 0, count: 16)
            registers[1] = ramGuestBase + 0x40
            registers[2] = 0xC0FFEE42
            var cpsr: UInt32 = 0
            let completed = registers.withUnsafeMutableBufferPointer { regPtr in
                block.run(registers: regPtr.baseAddress!, ramHostPointer: ram, ramGuestBase: ramGuestBase, ramGuestLength: UInt32(ramSize), cpsr: &cpsr)
            }
            XCTAssertEqual(completed, 2)
            XCTAssertEqual(registers[3], 0xC0FFEE42, "value stored then reloaded through the fast path must round-trip exactly")
        }
    }

    func testCompiledByteLoadZeroExtends() throws {
        let instr = ThumbLoadStoreImmediateInstruction(isLoad: true, size: .byte, rn: 1, rt: 2, offset: 5)
        guard let block = ThumbJITTranslator.translate([(.loadStoreImmediate(instr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        withRAM { ram in
            ram.storeBytes(of: UInt8(0xFE), toByteOffset: 5, as: UInt8.self)
            var registers = [UInt32](repeating: 0xFFFF_FFFF, count: 16)
            registers[1] = ramGuestBase
            var cpsr: UInt32 = 0
            _ = registers.withUnsafeMutableBufferPointer { regPtr in
                block.run(registers: regPtr.baseAddress!, ramHostPointer: ram, ramGuestBase: ramGuestBase, ramGuestLength: UInt32(ramSize), cpsr: &cpsr)
            }
            XCTAssertEqual(registers[2], 0xFE)
        }
    }

    /// An out-of-bounds guest address must stop the block *before* the
    /// failing instruction's effect happens at all (not perform a wild
    /// host memory access) and report zero completed instructions, so
    /// `ARMv7CPU.runOneUnit()` knows to fall back to the interpreter —
    /// see its own doc comment on why `completed == 0` specifically
    /// triggers an immediate single interpreted step.
    func testOutOfBoundsAddressBailsWithoutTouchingMemoryOrRegisters() throws {
        let instr = ThumbLoadStoreImmediateInstruction(isLoad: true, size: .word, rn: 1, rt: 2, offset: 0)
        guard let block = ThumbJITTranslator.translate([(.loadStoreImmediate(instr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        withRAM { ram in
            var registers = [UInt32](repeating: 0, count: 16)
            registers[1] = ramGuestBase + UInt32(ramSize) // exactly one past the end
            registers[2] = 0xDEAD_BEEF
            var cpsr: UInt32 = 0
            let completed = registers.withUnsafeMutableBufferPointer { regPtr in
                block.run(registers: regPtr.baseAddress!, ramHostPointer: ram, ramGuestBase: ramGuestBase, ramGuestLength: UInt32(ramSize), cpsr: &cpsr)
            }
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(registers[2], 0xDEAD_BEEF, "register array must be untouched when the block bails immediately")
        }
    }

    /// No fast-path region offered at all (`ramGuestLength == 0`, as
    /// `ARMv7CPU.runOneUnit()` passes when `MemoryBus.fastPathRegion`
    /// returns `nil`) must behave exactly like an out-of-bounds address —
    /// confirms the "no separate null check needed" claim in this file's
    /// own doc comment.
    func testNoFastPathRegionBailsImmediately() throws {
        let instr = ThumbLoadStoreImmediateInstruction(isLoad: true, size: .word, rn: 1, rt: 2, offset: 0)
        guard let block = ThumbJITTranslator.translate([(.loadStoreImmediate(instr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        var registers = [UInt32](repeating: 0, count: 16)
        registers[1] = 0x1000
        var cpsr: UInt32 = 0
        let completed = registers.withUnsafeMutableBufferPointer { regPtr in
            block.run(registers: regPtr.baseAddress!, ramHostPointer: nil, ramGuestBase: 0, ramGuestLength: 0, cpsr: &cpsr)
        }
        XCTAssertEqual(completed, 0)
    }

    /// A register-only instruction (`sub.w`) followed by a load in the
    /// *same* compiled block: proves `w2`/`w3` (the fast-path region's
    /// base/length, reserved for the whole block) survive an instruction
    /// that isn't itself a load/store — see this file's own doc comment
    /// on why `Scratch.a`/`Scratch.b` had to move off `w1`/`w2`.
    func testMixedRegisterAndLoadBlockPreservesRegionBounds() throws {
        // sub.w r1, r3, sb (r9) — from the real kernel at 0x80018042.
        guard case .dataProcessingShiftedRegister(let subInstr) = ThumbDecoder.decode(0xeba3, 0x0109) else {
            return XCTFail("Expected dataProcessingShiftedRegister")
        }
        let loadInstr = ThumbLoadStoreImmediateInstruction(isLoad: true, size: .word, rn: 1, rt: 5, offset: 0)
        guard let block = ThumbJITTranslator.translate([(.dataProcessingShiftedRegister(subInstr), 4), (.loadStoreImmediate(loadInstr), 2)]) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        withRAM { ram in
            ram.storeBytes(of: UInt32(0x99887766).littleEndian, toByteOffset: 0x70, as: UInt32.self)
            var registers = [UInt32](repeating: 0, count: 16)
            registers[3] = ramGuestBase + 0x70 + 3
            registers[9] = 3
            var cpsr: UInt32 = 0
            let completed = registers.withUnsafeMutableBufferPointer { regPtr in
                block.run(registers: regPtr.baseAddress!, ramHostPointer: ram, ramGuestBase: ramGuestBase, ramGuestLength: UInt32(ramSize), cpsr: &cpsr)
            }
            XCTAssertEqual(completed, 2)
            XCTAssertEqual(registers[1], ramGuestBase + 0x70)
            XCTAssertEqual(registers[5], 0x99887766)
        }
    }

    /// Full CPU integration: a JIT-enabled `ARMv7CPU` running the real
    /// `ldrh r0, [r4, #42]` word through `run()` must match a
    /// pure-interpreter CPU exactly, including `pc` and the fast-path
    /// memory region actually being consulted (not just the isolated
    /// translator).
    func testJITEnabledCPUMatchesInterpreterForRealLoadWord() throws {
        let bytes: [UInt8] = [0x60, 0x8D] // ldrh r0, [r4, #42], little-endian

        let interpMemory = FlatPhysicalMemory(length: 128, baseAddress: 0)
        try interpMemory.writeByte(bytes[0], at: 0)
        try interpMemory.writeByte(bytes[1], at: 1)
        try interpMemory.writeWord16(0xBEEF, at: 42)
        let interpCPU = ARMv7CPU(memory: interpMemory)
        interpCPU.reset()
        interpCPU.cpsr.thumbState = true
        interpCPU.registers[4] = 0
        interpCPU.step()

        let jitMemory = FlatPhysicalMemory(length: 128, baseAddress: 0)
        try jitMemory.writeByte(bytes[0], at: 0)
        try jitMemory.writeByte(bytes[1], at: 1)
        try jitMemory.writeWord16(0xBEEF, at: 42)
        let jitEngine = JITEngine()
        let jitCPU = ARMv7CPU(memory: jitMemory, jit: jitEngine)
        jitCPU.reset()
        jitCPU.cpsr.thumbState = true
        jitCPU.registers[4] = 0
        _ = jitCPU.run(maxUnits: 1)

        guard jitEngine.stats.compiledBlockCount > 0 else {
            throw XCTSkip("JIT produced no compiled blocks in this environment (mprotect PROT_EXEC unavailable).")
        }

        XCTAssertNil(jitCPU.lastError)
        XCTAssertEqual(jitCPU.registers[0], interpCPU.registers[0])
        XCTAssertEqual(jitCPU.registers.pc, interpCPU.registers.pc)
    }
}
