import XCTest
import Darwin
@testable import Podium

final class FileBackedStorageTests: XCTestCase {
    private func withDisk(_ body: (URL, FileBackedStorage) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("disk.hfs")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: FileBackedStorage.capacity)
        try handle.close()
        try body(url, FileBackedStorage(url: url, persistent: true))
    }

    func testHighOffsetsPersistenceBoundsAndPrivateBoot() throws {
        try withDisk { url, disk in
            let last = disk.blockCount - 1
            let high = Int((UInt64(5) << 30) / 512)
            let payload = Data(repeating: 0xA7, count: 512)
            try disk.writeBlocks(payload, at: high)
            try disk.writeBlocks(Data(repeating: 0xCC, count: 512), at: last)
            try disk.synchronize()
            let reopened = try FileBackedStorage(url: url, persistent: true)
            XCTAssertEqual(try reopened.readBlocks(at: high, count: 1), payload)
            XCTAssertEqual(try reopened.readBlocks(at: last, count: 1), Data(repeating: 0xCC, count: 512))
            XCTAssertEqual(try disk.readBlocks(at: 0, count: 1), Data(repeating: 0, count: 512))
            XCTAssertThrowsError(try disk.readBlocks(at: last, count: 2))
            XCTAssertThrowsError(try disk.writeBlocks(payload, at: disk.blockCount))
            XCTAssertThrowsError(try disk.writeBlocks(Data([1]), at: 0))
            let privateDisk = try FileBackedStorage(url: url, persistent: false)
            try privateDisk.writeBlocks(Data(repeating: 0x55, count: 512), at: high)
            XCTAssertEqual(try disk.readBlocks(at: high, count: 1), payload)
            var info = stat()
            XCTAssertEqual(stat(url.path, &info), 0)
            XCTAssertLessThan(UInt64(info.st_blocks) * 512, 16 << 20, "Empty capacity must remain sparse")
        }
    }

    func testGuestBridgeCrossesPagesAboveFourGiBAndReportsEOF() throws {
        try withDisk { _, disk in
            // MMU off: an artificial contiguous physical range covers md0's
            // ABI table, a stack and an intentionally unaligned I/O buffer.
            let ram = FlatPhysicalMemory(length: 4 << 20, baseAddress: 0x8000_0000)
            let cpu = ARMv7CPU(memory: ram, jit: nil)
            cpu.linearMap = (0x8000_0000, 0x8000_0000, 4 << 20)
            cpu.registers.sp = 0x8000_1000
            try cpu.writeData(512, GuestDiskBridge.md0 + 16, width: 4)
            try cpu.writeData(0, cpu.registers.sp + 4, width: 4)
            let buffer: UInt32 = 0x8000_3F80
            let payload = Data(repeating: 0x7B, count: 1024)
            try ram.writeBytes(payload, at: buffer)
            func transfer(block: UInt64, read: Bool, count: UInt32 = 1024) throws {
                try cpu.writeData(read ? 1 : 0, cpu.registers.sp, width: 4)
                cpu.registers[0] = buffer
                cpu.registers[1] = count
                cpu.registers[2] = UInt32(truncatingIfNeeded: block)
                cpu.registers[3] = UInt32(block >> 32)
                GuestDiskBridge.transfer(cpu, disk: disk)
            }
            let high = (UInt64(5) << 30) / 512
            try transfer(block: high, read: false)
            XCTAssertEqual(cpu.registers[0], 0)
            XCTAssertEqual(cpu.registers[1], 1024)
            try ram.writeBytes(Data(repeating: 0, count: 1024), at: buffer)
            try transfer(block: high, read: true)
            XCTAssertEqual(try ram.readBytes(1024, at: buffer), payload)
            try transfer(block: UInt64(disk.blockCount - 1), read: true)
            XCTAssertEqual(cpu.registers[1], 512)
            try transfer(block: UInt64(disk.blockCount), read: true)
            XCTAssertEqual(cpu.registers[0], 0)
            XCTAssertEqual(cpu.registers[1], 0)
            try transfer(block: UInt64(disk.blockCount + 1), read: true)
            XCTAssertEqual(cpu.registers[0], UInt32(EINVAL))
            try transfer(block: UInt64.max, read: true)
            XCTAssertEqual(cpu.registers[0], UInt32(EINVAL))
        }
    }

    func testDiskDMAReadsIntoAReadOnlyCPUMapping() throws {
        try withDisk { _, disk in
            let ram = FlatPhysicalMemory(length: 4 << 20, baseAddress: 0x8000_0000)
            let cpu = ARMv7CPU(memory: ram, jit: nil)
            cpu.linearMap = (0x8000_0000, 0x8000_0000, 4 << 20)
            let table: UInt32 = 0x8000_4000
            for section in 0..<4 {
                let base = UInt32(0x8000_0000) + UInt32(section << 20)
                let permissions: UInt32 = section == 1 ? 0x8402 : 0xC02
                try ram.writeWord32(base | permissions, at: table + ((base >> 20) * 4))
            }
            try ram.writeWord32(512, at: GuestDiskBridge.md0 + 16)
            let stack: UInt32 = 0x8000_1000
            try ram.writeWord32(1, at: stack)
            try ram.writeWord32(0, at: stack + 4)
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: table)
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: 1)
            cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0, value: 1)
            let buffer: UInt32 = 0x8010_3F80
            XCTAssertThrowsError(try cpu.translatedAddress(buffer, access: .write))
            let payload = Data(repeating: 0xDB, count: 1024)
            let offset = UInt64(5) << 30
            try disk.write(payload, at: offset)
            cpu.registers.sp = stack
            cpu.registers[0] = buffer
            cpu.registers[1] = 1024
            cpu.registers[2] = UInt32(offset / 512)
            cpu.registers[3] = 0
            GuestDiskBridge.transfer(cpu, disk: disk)
            XCTAssertEqual(cpu.registers[0], 0)
            XCTAssertEqual(cpu.registers[1], 1024)
            XCTAssertEqual(try ram.readBytes(1024, at: buffer), payload)
            XCTAssertThrowsError(try cpu.translatedAddress(buffer, access: .write), "DMA must not alter CPU page permissions")
        }
    }

    func testCapacityIoctlsAndUnknownKernelRejection() throws {
        try withDisk { _, disk in
            let ram = FlatPhysicalMemory(length: 4 << 20, baseAddress: 0x8000_0000)
            let cpu = ARMv7CPU(memory: ram, jit: nil)
            cpu.linearMap = (0x8000_0000, 0x8000_0000, 4 << 20)
            try cpu.writeData(512, GuestDiskBridge.md0 + 16, width: 4)
            GuestDiskBridge.install(on: cpu, disk: disk)
            let ioctl = try XCTUnwrap(cpu.nativeFunctions[GuestDiskBridge.ioctlAddress])
            let output: UInt32 = 0x8000_1000
            cpu.registers[0] = 0
            cpu.registers[1] = 0x4008_6419
            cpu.registers[2] = output
            XCTAssertTrue(ioctl(cpu))
            XCTAssertEqual(cpu.registers[0], 0)
            XCTAssertEqual(try cpu.readData(output, width: 4), UInt32(disk.blockCount))
            XCTAssertEqual(try cpu.readData(output + 4, width: 4), 0)
            XCTAssertThrowsError(try GuestDiskBridge.patch(Data(repeating: 0, count: 64)))
        }
    }

    func testDMAUsesKernelPmapIncludingPendingSoftwareMappings() throws {
        let ram = FlatPhysicalMemory(length: 4 << 20, baseAddress: 0x4000_0000)
        let cpu = ARMv7CPU(memory: ram, jit: nil)
        cpu.linearMap = (0x8000_0000, 0x4000_0000, 4 << 20)
        let activeTable: UInt32 = 0x4002_0000
        for section in 0..<4 {
            let virtual = UInt32(0x8000_0000) + UInt32(section << 20)
            let physical = UInt32(0x4000_0000) + UInt32(section << 20)
            try ram.writeWord32(physical | 0xC02, at: activeTable + (virtual >> 20) * 4)
        }
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: 0x4001_0000)
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 1, value: activeTable)
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 2, value: 1)
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: 1)
        cpu.cp15.write(coprocessor: 15, opc1: 0, crn: 1, crm: 0, opc2: 0, value: 1)
        func write(_ value: UInt32, _ virtual: UInt32) throws {
            try ram.writeWord32(value, at: GuestMemoryLayout.physical(fromKernelVirtual: virtual))
        }
        let pmap: UInt32 = 0x8002_8000
        let kernelTable: UInt32 = 0x8003_0000
        try write(pmap, 0x802D_47E8)
        try write(kernelTable, pmap)
        try write(4096, pmap + 0x54)
        let buffer: UInt32 = 0x000D_3000
        XCTAssertThrowsError(try cpu.translatedAddress(buffer, access: .read))
        try write(0x4000_0C02, kernelTable)
        XCTAssertEqual(try GuestDiskBridge.kernelPhysicalAddress(buffer, cpu: cpu), 0x400D_3000)
        try write(0x4003_8001, kernelTable)
        let pte: UInt32 = 0x8003_8000 + ((buffer >> 10) & 0x3FC)
        let software = ((pte & 0xFFFF_F000) | 0x400) + ((pte >> 2) & 0x3FF) * 12 + 8
        try write(0x4000_0000, software)
        XCTAssertEqual(try GuestDiskBridge.kernelPhysicalAddress(buffer, cpu: cpu), 0x400D_3000)
        XCTAssertThrowsError(try cpu.translatedAddress(buffer, access: .read), "DMA must not replace the task's page tables")
    }

    func testRawBouncePageUsesUnalignedByteOffsetsAboveFourGiB() throws {
        try withDisk { _, disk in
            let ram = FlatPhysicalMemory(length: 4 << 20, baseAddress: 0x4000_0000)
            let cpu = ARMv7CPU(memory: ram, jit: nil)
            cpu.linearMap = (0x8000_0000, 0x4000_0000, 4 << 20)
            cpu.registers.sp = 0x4000_1000
            try ram.writeWord32(1, at: cpu.registers.sp)
            try ram.writeWord32(0, at: cpu.registers.sp + 4)
            let offset = (UInt64(5) << 30) + 17
            let payload = Data(repeating: 0xED, count: 1024)
            try disk.write(payload, at: offset)
            func request(_ byteOffset: UInt64) {
                cpu.registers[0] = 0x8000_4000
                cpu.registers[1] = 1024
                cpu.registers[2] = UInt32(truncatingIfNeeded: byteOffset)
                cpu.registers[3] = UInt32(byteOffset >> 32)
                GuestDiskBridge.transferRawPage(cpu, disk: disk)
            }
            request(offset)
            XCTAssertEqual(cpu.registers[0], 0)
            XCTAssertEqual(cpu.registers[1], 1024)
            XCTAssertEqual(try ram.readBytes(1024, at: 0x4000_4000), payload)
            try ram.writeWord32(0, at: cpu.registers.sp)
            request(offset + 123)
            XCTAssertEqual(try disk.read(at: offset + 123, count: 1024), payload)
            request(disk.byteCount)
            XCTAssertEqual(cpu.registers[0], 0)
            XCTAssertEqual(cpu.registers[1], 0)
        }
    }
}
