import XCTest
@testable import Podium

/// Every expected value here is a real, independently-known AArch64
/// encoding (the same bytes a real assembler would produce) — `RET`
/// (0xD65F03C0) and `MOV X0, X0` (0xAA0003E0, whose 32-bit form is
/// 0x2A0003E0) in particular are about as well-attested as ARM64
/// encodings get.
final class ARM64AssemblerTests: XCTestCase {
    func testMovzImmediate() {
        XCTAssertEqual(ARM64Assembler.movz32(rd: 0, imm16: 5), 0x5280_00A0)
        XCTAssertEqual(ARM64Assembler.movz32(rd: 3, imm16: 100), 0x5280_0C83)
    }

    func testMovRegisterAlias() {
        XCTAssertEqual(ARM64Assembler.movRegister32(rd: 0, rm: 0), 0x2A00_03E0)
        XCTAssertEqual(ARM64Assembler.movRegister32(rd: 0, rm: 1), 0x2A01_03E0)
    }

    func testAddRegister() {
        XCTAssertEqual(ARM64Assembler.add32(rd: 0, rn: 1, rm: 2), 0x0B02_0020)
    }

    func testSubRegister() {
        XCTAssertEqual(ARM64Assembler.sub32(rd: 0, rn: 1, rm: 2), 0x4B02_0020)
    }

    func testLoadUnsignedOffset() {
        XCTAssertEqual(ARM64Assembler.ldrWordUnsignedOffset(rt: 1, rn: 0, byteOffset: 0), 0xB940_0001)
        XCTAssertEqual(ARM64Assembler.ldrWordUnsignedOffset(rt: 1, rn: 0, byteOffset: 4), 0xB940_0401)
    }

    func testStoreUnsignedOffset() {
        XCTAssertEqual(ARM64Assembler.strWordUnsignedOffset(rt: 2, rn: 0, byteOffset: 8), 0xB900_0802)
    }

    func testRet() {
        XCTAssertEqual(ARM64Assembler.ret, 0xD65F_03C0)
    }
}
