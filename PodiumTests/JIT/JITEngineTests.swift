import XCTest
@testable import Podium

final class JITEngineTests: XCTestCase {
    func testDiscoversEligibleRunAndCachesIt() throws {
        let memory = FlatPhysicalMemory(length: 64)
        try memory.writeWord32(0xE3A0_0005, at: 0) // MOV r0, #5 -- eligible
        try memory.writeWord32(0xE3A0_1003, at: 4) // MOV r1, #3 -- eligible
        try memory.writeWord32(0xEA00_0000, at: 8) // B -- not eligible, ends the run

        let engine = JITEngine()
        guard let block = engine.block(at: 0, thumbState: false, memory: memory) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        XCTAssertEqual(block.instructionCount, 2)
        XCTAssertEqual(engine.stats.compiledBlockCount, 1)

        // Same address again should be a cache hit, not a recompile.
        XCTAssertNotNil(engine.block(at: 0, thumbState: false, memory: memory))
        XCTAssertEqual(engine.stats.cacheHitCount, 1)
        XCTAssertEqual(engine.stats.compiledBlockCount, 1)
    }

    func testIneligibleFirstInstructionFallsBackWithoutCompiling() throws {
        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeWord32(0xEA00_0000, at: 0) // B -- not JIT-eligible at all

        let engine = JITEngine()
        XCTAssertNil(engine.block(at: 0, thumbState: false, memory: memory))
        XCTAssertEqual(engine.stats.interpreterFallbackCount, 1)
        XCTAssertEqual(engine.stats.compiledBlockCount, 0)
    }

    /// The same address is, in principle, reachable in either ARM or
    /// Thumb state via interworking — a block compiled from one state's
    /// interpretation of the bytes at that address must never be handed
    /// back for the other state's call there. Uses a real ARM-state `MOV
    /// r0, #5` word (0xE3A00005), whose first two bytes, read instead as
    /// a little-endian Thumb halfword (`0x0005` = `LSLS r5, r0, #0`, the
    /// `MOVS r5, r0` alias), decode to a real but *not* JIT-eligible
    /// Thumb instruction (a plain shift-immediate, not
    /// `dataProcessingShiftedRegister`/`hiRegister`) — so a `thumbState:
    /// true` request at the same address must correctly fall back to
    /// `nil` rather than wrongly reusing the cached ARM block. If the
    /// cache were keyed on address alone (not address *and* state), this
    /// second call would incorrectly return the ARM-compiled block
    /// instead.
    func testSameAddressDoesNotShareCacheBetweenARMAndThumbState() throws {
        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeWord32(0xE3A0_0005, at: 0)

        let engine = JITEngine()
        guard let armBlock = engine.block(at: 0, thumbState: false, memory: memory) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(engine.stats.compiledBlockCount, 1)

        XCTAssertNil(engine.block(at: 0, thumbState: true, memory: memory))
        XCTAssertEqual(engine.stats.interpreterFallbackCount, 1)
        XCTAssertEqual(engine.stats.compiledBlockCount, 1, "the Thumb-state miss must not be satisfied by the cached ARM block")

        var armRegisters = [UInt32](repeating: 0, count: 16)
        armRegisters.withUnsafeMutableBufferPointer { armBlock.run(registers: $0.baseAddress!) }
        XCTAssertEqual(armRegisters[0], 5, "ARM-state block should still be MOV r0, #5")
    }

    func testRunStopsAtFirstIneligibleInstructionNotJustAtABranch() throws {
        let memory = FlatPhysicalMemory(length: 64)
        try memory.writeWord32(0xE3A0_0005, at: 0) // MOV r0, #5 -- eligible
        try memory.writeWord32(0xE050_2001, at: 4) // SUBS r2, r0, r1 -- flag-setting, not JIT-eligible

        let engine = JITEngine()
        guard let block = engine.block(at: 0, thumbState: false, memory: memory) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(block.instructionCount, 1, "The flag-setting SUBS must not be swept into the compiled block")
    }
}
