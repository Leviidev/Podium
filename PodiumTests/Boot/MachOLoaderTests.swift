import XCTest
@testable import Podium

final class MachOLoaderTests: XCTestCase {
    private func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func makeSegmentCommand(vmaddr: UInt32, fileoff: UInt32, fileSize: UInt32) -> Data {
        var cmd = Data()
        appendLE32(0x1, to: &cmd) // LC_SEGMENT
        appendLE32(56, to: &cmd)  // cmdsize, no sections
        cmd.append(Data(repeating: 0, count: 16)) // segname
        appendLE32(vmaddr, to: &cmd)
        appendLE32(fileSize, to: &cmd) // vmsize
        appendLE32(fileoff, to: &cmd)
        appendLE32(fileSize, to: &cmd) // filesize
        appendLE32(7, to: &cmd) // maxprot
        appendLE32(7, to: &cmd) // initprot
        appendLE32(0, to: &cmd) // nsects
        appendLE32(0, to: &cmd) // flags
        return cmd
    }

    private func makeUnixThreadCommand(pc: UInt32) -> Data {
        var cmd = Data()
        appendLE32(0x5, to: &cmd) // LC_UNIXTHREAD
        appendLE32(UInt32(8 + 8 + 17 * 4), to: &cmd)
        appendLE32(1, to: &cmd)  // flavor = ARM_THREAD_STATE
        appendLE32(17, to: &cmd) // count
        for _ in 0..<13 { appendLE32(0, to: &cmd) } // r0-r12
        appendLE32(0, to: &cmd)   // sp
        appendLE32(0, to: &cmd)   // lr
        appendLE32(pc, to: &cmd)  // pc
        appendLE32(0, to: &cmd)   // cpsr
        return cmd
    }

    private func makeHeader(ncmds: Int, sizeofcmds: Int) -> Data {
        var header = Data()
        appendLE32(0xFEED_FACE, to: &header) // MH_MAGIC (32-bit)
        appendLE32(12, to: &header)          // cputype = CPU_TYPE_ARM
        appendLE32(0, to: &header)           // cpusubtype
        appendLE32(2, to: &header)           // filetype = MH_EXECUTE
        appendLE32(UInt32(ncmds), to: &header)
        appendLE32(UInt32(sizeofcmds), to: &header)
        appendLE32(0, to: &header)           // flags
        return header
    }

    func testLoadsSegmentDataAndReadsEntryPoint() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let vmaddr: UInt32 = 0x8000_1000
        let entryPC: UInt32 = 0x8000_1002

        // Two passes: the first just measures how big the load commands
        // are, so the second can declare the segment's true file offset
        // (header size + commands size) without hardcoding either.
        let placeholderCommands = makeSegmentCommand(vmaddr: vmaddr, fileoff: 0, fileSize: UInt32(payload.count))
            + makeUnixThreadCommand(pc: entryPC)
        let header = makeHeader(ncmds: 2, sizeofcmds: placeholderCommands.count)
        let fileoff = UInt32(header.count + placeholderCommands.count)

        let commands = makeSegmentCommand(vmaddr: vmaddr, fileoff: fileoff, fileSize: UInt32(payload.count))
            + makeUnixThreadCommand(pc: entryPC)
        let machO = header + commands + payload

        let memory = FlatPhysicalMemory(length: 0x1_0000, baseAddress: 0x8000_0000)
        let image = try MachOLoader.load(machO, into: memory)

        XCTAssertEqual(image.entryPointPC, entryPC)
        XCTAssertEqual(image.highestAddressUsed, vmaddr &+ UInt32(payload.count))
        XCTAssertEqual(try memory.readByte(at: vmaddr), 0xDE)
        XCTAssertEqual(try memory.readByte(at: vmaddr + 1), 0xAD)
        XCTAssertEqual(try memory.readByte(at: vmaddr + 2), 0xBE)
        XCTAssertEqual(try memory.readByte(at: vmaddr + 3), 0xEF)
    }

    func testRejectsNonMachOMagic() {
        let bogus = Data(repeating: 0, count: 32)
        let memory = FlatPhysicalMemory(length: 4096)
        XCTAssertThrowsError(try MachOLoader.load(bogus, into: memory)) { error in
            guard case MachOLoaderError.notMachO = error else {
                return XCTFail("Expected .notMachO, got \(error)")
            }
        }
    }

    func testRejectsNonARMCPUType() {
        var header = makeHeader(ncmds: 0, sizeofcmds: 0)
        // Overwrite cputype (bytes 4..<8) with something else (x86_64 = 0x01000007).
        header.replaceSubrange(4..<8, with: [0x07, 0x00, 0x00, 0x01])
        let memory = FlatPhysicalMemory(length: 4096)
        XCTAssertThrowsError(try MachOLoader.load(header, into: memory)) { error in
            guard case MachOLoaderError.not32BitARM = error else {
                return XCTFail("Expected .not32BitARM, got \(error)")
            }
        }
    }

    func testMissingUnixThreadThrowsNoEntryPoint() {
        let header = makeHeader(ncmds: 0, sizeofcmds: 0)
        let memory = FlatPhysicalMemory(length: 4096)
        XCTAssertThrowsError(try MachOLoader.load(header, into: memory)) { error in
            guard case MachOLoaderError.noEntryPoint = error else {
                return XCTFail("Expected .noEntryPoint, got \(error)")
            }
        }
    }
}
