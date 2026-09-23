import XCTest
@testable import Podium

/// Exercises `ARMv7MMU.translate` directly against a real
/// `FlatPhysicalMemory` holding hand-built (but Python-verified — see the
/// comment on each test) short-descriptor translation tables, the same
/// format the real iPod4,1 6.1.6 kernel's own boot code builds (confirmed
/// via `llvm-objdump` around 0x80086184–0x800861f4, which zero-fills a
/// 16KB first-level table and then fills it with 1MB identity-mapped
/// section descriptors before ever setting SCTLR.M).
final class ARMv7MMUTests: XCTestCase {
    private static let tableBase: UInt32 = 0x4000
    private static let memorySize = 0x30000

    private func makeMemoryAndCP15(ttbr0: UInt32 = tableBase, dacr: UInt32 = 0b01) -> (FlatPhysicalMemory, CP15State) {
        let memory = FlatPhysicalMemory(length: Self.memorySize)
        var cp15 = CP15State()
        cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: ttbr0) // TTBR0
        cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 2, value: 0) // TTBCR, N=0
        cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: dacr) // DACR
        return (memory, cp15)
    }

    func testTranslatesIdentityMappedSection() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        // VA 0x00100004, index 1: full-RW section descriptor mapping
        // 0x00100000 -> 0x00100000 (identity).
        try memory.writeWord32(0x0010_0C02, at: 0x4004)

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0010_0004, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x0010_0004)
    }

    func testTranslatesNonIdentitySectionToADifferentPhysicalBase() throws {
        // Proves this is a real table walk, not an accidental VA
        // passthrough: VA 0x00200048 (index 2) maps to physical base
        // 0x00500000, a different region entirely.
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0050_0C02, at: 0x4008)

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0020_0048, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x0050_0048)
    }

    func testMissingFirstLevelDescriptorThrowsTranslationFault() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        // Index 7's slot (0x401c) is never written, so it's zero: type
        // bits [1:0] == 0b00, the fault encoding.
        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0070_0000, access: .read, cp15: cp15, memory: memory)) { error in
            guard case MemoryAccessError.translationFault = error else {
                return XCTFail("Expected .translationFault, got \(error)")
            }
        }
    }

    func testDomainNoAccessThrowsFault() throws {
        // Domain 1's section (index 3) is client-accessible with full AP,
        // but DACR only grants domain 0 — domain 1 defaults to "no
        // access" (0b00), so this must fault regardless of the AP bits.
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0030_0C22, at: 0x400c)

        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0030_0000, access: .read, cp15: cp15, memory: memory)) { error in
            guard case MemoryAccessError.translationFault = error else {
                return XCTFail("Expected .translationFault, got \(error)")
            }
        }
    }

    func testManagerDomainBypassesAPCheckEvenWithNoAccessBits() throws {
        // Domain 2's section has AP == 0b000 (no access under the normal
        // client check), but DACR sets domain 2 to "manager" (0b11),
        // which real hardware defines as bypassing the AP check entirely.
        let (memory, cp15) = makeMemoryAndCP15(dacr: 0b01 | (0b11 << 4))
        try memory.writeWord32(0x0040_0042, at: 0x4010)

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0040_0000, access: .write, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x0040_0000)
    }

    func testWriteToReadOnlySectionThrowsPermissionFaultButReadSucceeds() throws {
        // APX=1, AP=01: privileged read-only.
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0050_8402, at: 0x4014)

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0050_0000, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x0050_0000)

        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0050_0000, access: .write, cp15: cp15, memory: memory)) { error in
            guard case MemoryAccessError.translationFault = error else {
                return XCTFail("Expected .translationFault, got \(error)")
            }
        }
    }

    func testExecuteFromXNSectionThrowsPermissionFaultButReadSucceeds() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0060_0C12, at: 0x4018) // full RW, XN set (bit4)

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0060_0000, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x0060_0000)

        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0060_0000, access: .execute, cp15: cp15, memory: memory)) { error in
            guard case MemoryAccessError.translationFault = error else {
                return XCTFail("Expected .translationFault, got \(error)")
            }
        }
    }

    func testSmallPageTranslation() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0000_8001, at: 0x4020) // first-level: page table at 0x8000, domain 0
        try memory.writeWord32(0x0090_0032, at: 0x8000) // second-level: small page, base 0x00900000, full RW

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0080_0abc, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x0090_0abc)
    }

    func testLargePageTranslation() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0000_8401, at: 0x4024) // first-level: page table at 0x8400
        try memory.writeWord32(0x00A1_0031, at: 0x8400) // second-level: large (64KB) page, base 0x00A10000

        let pa = try ARMv7MMU.translate(virtualAddress: 0x0090_0abc, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(pa, 0x00A1_0abc)
    }

    func testPageNotPresentThrowsTranslationFault() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0000_8001, at: 0x4020) // first-level: page table at 0x8000
        // Second-level entry at 0x8000 is never written (stays 0 = fault).

        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0080_0000, access: .read, cp15: cp15, memory: memory)) { error in
            guard case MemoryAccessError.translationFault = error else {
                return XCTFail("Expected .translationFault, got \(error)")
            }
        }
    }

    func testTTBR0AndTTBR1AreSelectedByTTBCRSplit() throws {
        // N=2: VAs with their top 2 bits clear use TTBR0 (a smaller,
        // 4KB-aligned 1024-entry table); everything else uses TTBR1 (the
        // full 16KB, 4096-entry table).
        let memory = FlatPhysicalMemory(length: 0x30000)
        var cp15 = CP15State()
        cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 0, value: 0x1_0000) // TTBR0
        cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 1, value: 0x2_0000) // TTBR1
        cp15.write(coprocessor: 15, opc1: 0, crn: 2, crm: 0, opc2: 2, value: 2) // TTBCR, N=2
        cp15.write(coprocessor: 15, opc1: 0, crn: 3, crm: 0, opc2: 0, value: 0b01) // DACR domain 0 = client

        try memory.writeWord32(0x0000_0C02, at: 0x1_0000) // TTBR0 table, index 0: identity-map 0x00000000
        try memory.writeWord32(0xC000_0C02, at: 0x2_3000) // TTBR1 table, index 0xC00: identity-map 0xC0000000

        let lowPA = try ARMv7MMU.translate(virtualAddress: 0x0000_0004, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(lowPA, 0x0000_0004)

        let highPA = try ARMv7MMU.translate(virtualAddress: 0xC000_0004, access: .read, cp15: cp15, memory: memory)
        XCTAssertEqual(highPA, 0xC000_0004)
    }

    private func fault(_ body: () throws -> UInt32) -> (reason: TranslationFaultReason, isWrite: Bool)? {
        do {
            _ = try body()
            return nil
        } catch MemoryAccessError.translationFault(_, let reason, let isWrite) {
            return (reason, isWrite)
        } catch {
            return nil
        }
    }

    func testSectionPermissionFaultReportsSectionLevelAndWrite() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0050_8402, at: 0x4014) // APX=1, AP=01: privileged read-only section
        let result = fault { try ARMv7MMU.translate(virtualAddress: 0x0050_0000, access: .write, cp15: cp15, memory: memory) }
        XCTAssertEqual(result?.reason, .permissionFault(isPage: false))
        XCTAssertEqual(result?.isWrite, true)
    }

    func testSmallPagePermissionFaultReportsPageLevel() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0000_8001, at: 0x4020) // first-level: page table at 0x8000
        try memory.writeWord32(0x0090_0212, at: 0x8000) // small page, APX=1 AP=01: read-only
        XCTAssertNoThrow(try ARMv7MMU.translate(virtualAddress: 0x0080_0000, access: .read, cp15: cp15, memory: memory))
        let result = fault { try ARMv7MMU.translate(virtualAddress: 0x0080_0000, access: .write, cp15: cp15, memory: memory) }
        XCTAssertEqual(result?.reason, .permissionFault(isPage: true))
        XCTAssertEqual(result?.isWrite, true)
    }

    /// A missing second-level entry under a no-access domain is a page
    /// *translation* fault: translation faults outrank domain faults.
    func testMissingPageUnderNoAccessDomainIsTranslationNotDomainFault() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0000_8021, at: 0x4020) // page table at 0x8000, domain 1 (no access in DACR)
        let result = fault { try ARMv7MMU.translate(virtualAddress: 0x0080_0000, access: .read, cp15: cp15, memory: memory) }
        XCTAssertEqual(result?.reason, .pageTranslation)
        XCTAssertEqual(result?.isWrite, false)
    }

    func testPresentPageUnderNoAccessDomainIsPageDomainFault() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0000_8021, at: 0x4020) // page table at 0x8000, domain 1 (no access in DACR)
        try memory.writeWord32(0x0090_0032, at: 0x8000) // valid small page
        let result = fault { try ARMv7MMU.translate(virtualAddress: 0x0080_0000, access: .read, cp15: cp15, memory: memory) }
        XCTAssertEqual(result?.reason, .domainFault(isPage: true))
    }

    /// User-mode accesses get the user half of Table B3-8: AP 001 is
    /// privileged-only, AP 010 is read-only for user code (how read-only
    /// and copy-on-write user pages fault on write).
    func testUserPermissionsFollowTableB38() throws {
        let (memory, cp15) = makeMemoryAndCP15()
        try memory.writeWord32(0x0010_0402, at: 0x4004) // AP 001: privileged RW, user none
        try memory.writeWord32(0x0020_0802, at: 0x4008) // AP 010: privileged RW, user RO

        XCTAssertEqual(try ARMv7MMU.translate(virtualAddress: 0x0010_0000, access: .read, cp15: cp15, memory: memory), 0x0010_0000)
        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0010_0000, access: .read, cp15: cp15, memory: memory, privileged: false))

        XCTAssertEqual(try ARMv7MMU.translate(virtualAddress: 0x0020_0000, access: .read, cp15: cp15, memory: memory, privileged: false), 0x0020_0000)
        XCTAssertEqual(try ARMv7MMU.translate(virtualAddress: 0x0020_0000, access: .write, cp15: cp15, memory: memory), 0x0020_0000)
        XCTAssertThrowsError(try ARMv7MMU.translate(virtualAddress: 0x0020_0000, access: .write, cp15: cp15, memory: memory, privileged: false)) { error in
            guard case MemoryAccessError.translationFault(_, .permissionFault, true) = error else {
                return XCTFail("Expected a write permission fault, got \(error)")
            }
        }
    }
}
