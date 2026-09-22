import XCTest
@testable import Podium

final class JITEngineTests: XCTestCase {
    func testDiscoversEligibleRunAndCachesIt() throws {
        let memory = FlatPhysicalMemory(length: 64)
        try memory.writeWord32(0xE3A0_0005, at: 0) // MOV r0, #5 -- eligible
        try memory.writeWord32(0xE3A0_1003, at: 4) // MOV r1, #3 -- eligible
        try memory.writeWord32(0xEA00_0000, at: 8) // B -- not eligible, ends the run

        let engine = JITEngine()
        guard let block = engine.block(at: 0, memory: memory) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }

        XCTAssertEqual(block.instructionCount, 2)
        XCTAssertEqual(engine.stats.compiledBlockCount, 1)

        // Same address again should be a cache hit, not a recompile.
        XCTAssertNotNil(engine.block(at: 0, memory: memory))
        XCTAssertEqual(engine.stats.cacheHitCount, 1)
        XCTAssertEqual(engine.stats.compiledBlockCount, 1)
    }

    func testIneligibleFirstInstructionFallsBackWithoutCompiling() throws {
        let memory = FlatPhysicalMemory(length: 16)
        try memory.writeWord32(0xEA00_0000, at: 0) // B -- not JIT-eligible at all

        let engine = JITEngine()
        XCTAssertNil(engine.block(at: 0, memory: memory))
        XCTAssertEqual(engine.stats.interpreterFallbackCount, 1)
        XCTAssertEqual(engine.stats.compiledBlockCount, 0)
    }

    func testRunStopsAtFirstIneligibleInstructionNotJustAtABranch() throws {
        let memory = FlatPhysicalMemory(length: 64)
        try memory.writeWord32(0xE3A0_0005, at: 0) // MOV r0, #5 -- eligible
        try memory.writeWord32(0xE050_2001, at: 4) // SUBS r2, r0, r1 -- flag-setting, not JIT-eligible

        let engine = JITEngine()
        guard let block = engine.block(at: 0, memory: memory) else {
            throw XCTSkip("Executable memory (mprotect PROT_EXEC) isn't available in this test environment.")
        }
        XCTAssertEqual(block.instructionCount, 1, "The flag-setting SUBS must not be swept into the compiled block")
    }
}
