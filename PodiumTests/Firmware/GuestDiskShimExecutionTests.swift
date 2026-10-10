import XCTest
import Darwin
@testable import Podium

/// Executes the production Thumb shim with Podium's own decoder and CPU.
/// Mock only XNU buffer accessors; the host disk handler is real.
final class GuestDiskShimExecutionTests: XCTestCase {
    func testStrategyReadsHighOffsetsAndPreservesXNUCallingConvention() throws {
        try runStrategy(translated: false)
    }

    func testTranslatedStrategyPreservesXNUCallingConvention() throws {
        try runStrategy(translated: true)
    }

    private func runStrategy(translated: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("disk.hfs")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: FileBackedStorage.capacity)
        try handle.close()
        let disk = try FileBackedStorage(url: url, persistent: true)
        let offset = UInt64(5) << 30
        let payload = Data(repeating: 0xA5, count: 1024)
        try disk.write(payload, at: offset)
        let ram = FlatPhysicalMemory(length: 4 << 20, baseAddress: 0x8000_0000)
        let cpu = ARMv7CPU(memory: ram, jit: nil)
            cpu.linearMap = (0x8000_0000, 0x8000_0000, 4 << 20)
        try ram.writeBytes(Data(hex: GuestDiskBridge.strategyCode), at: GuestDiskBridge.strategyAddress)
        try cpu.writeData(512, GuestDiskBridge.md0 + 16, width: 4)
        GuestDiskBridge.install(on: cpu, disk: disk)
        let buffer: UInt32 = 0x8000_8F80
        let bufferObject: UInt32 = 0x8000_6000
        var residual: UInt32 = 999
        var error: UInt32 = 999
        var mapped = false
        var completed = false
        cpu.nativeFunctions[0x8009_CDF8] = { c in c.registers[0] = 1024; return true }
        cpu.nativeFunctions[0x8009_CE0C] = { c in residual = c.registers[1]; return true }
        cpu.nativeFunctions[0x8009_D1E8] = { c in
            XCTAssertEqual(c.registers[0], bufferObject)
            try! c.writeData(buffer, c.registers[1], width: 4)
            mapped = true
            c.registers[0] = 0
            return true
        }
        cpu.nativeFunctions[0x8009_D1A0] = { c in c.registers[0] = 0; return true }
        cpu.nativeFunctions[0x8009_CDCC] = { c in c.registers[0] = 1; return true }
        cpu.nativeFunctions[0x8009_D178] = { c in
            c.registers[0] = UInt32(offset / 512)
            c.registers[1] = 0
            return true
        }
        cpu.nativeFunctions[0x8009_D230] = { _ in XCTAssertTrue(mapped); mapped = false; return true }
        cpu.nativeFunctions[0x8009_CD90] = { c in error = c.registers[1]; return true }
        cpu.nativeFunctions[0x8009_D5D4] = { c in
            XCTAssertEqual(c.registers[0], bufferObject)
            XCTAssertFalse(mapped)
            completed = true
            return true
        }
        cpu.registers[0] = bufferObject
        for r in 4...7 { cpu.registers[r] = UInt32(0x12340000 + r) }
        cpu.registers.sp = 0x8001_0000
        cpu.registers.lr = 0x8000_5001
        cpu.registers.pc = GuestDiskBridge.strategyAddress
        cpu.cpsr.thumbState = true
        cpu.breakpoints = [0x8000_5000]
        if translated {
            // A real guest callee with its own frame, like XNU's buf_map.
            // A native mock alone cannot catch JIT stack/frame mistakes.
            // push {r4,r5,r7,lr}; add r7,sp,#8; sub sp,#4;
            // mov r5,r0; mov r4,r1; ldr r0,[r5,#60]; str r0,[r4];
            // movs r0,#0; add sp,#4; pop {r4,r5,r7,pc}.
            try ram.writeBytes(Data(hex: "b0b502af81b005460c46e86b2060002001b0b0bd"), at: 0x8009_D1E8)
            try ram.writeWord32(buffer, at: bufferObject + 60)
            cpu.nativeFunctions.removeValue(forKey: 0x8009_D1E8)
            mapped = true
            let table: UInt32 = 0x8002_0000
            for section in 0..<4 {
                let base = UInt32(0x8000_0000) + UInt32(section << 20)
                try ram.writeWord32(base | 0xC02, at: table + ((base >> 20) * 4))
            }
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: table)
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: 1)
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0, value: 1)
            cpu.linearMap = (0x8000_0000, 0x8000_0000, 4 << 20)
            guard let dbt = DBTEngine(cpu: cpu) else { throw XCTSkip("JIT unavailable") }
            cpu.dbt = dbt
        }
        cpu.run(maxUnits: 1000)
        XCTAssertNil(cpu.lastError)
        XCTAssertEqual(cpu.hitBreakpoint, 0x8000_5000)
        XCTAssertTrue(completed)
        XCTAssertEqual(residual, 0)
        XCTAssertEqual(error, 999, "No buf_seterror call on a successful transfer")
        XCTAssertEqual(cpu.registers.sp, 0x8001_0000)
        for r in 4...7 { XCTAssertEqual(cpu.registers[r], UInt32(0x12340000 + r)) }
        XCTAssertEqual(try ram.readBytes(1024, at: buffer), payload)
    }
}
