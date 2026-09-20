import XCTest
@testable import Podium

/// Every word here is a real, independently-known ARM encoding (the kind
/// any ARM disassembler would produce), not just whatever this decoder
/// happens to accept — so these tests catch the decoder disagreeing with
/// the actual instruction set, not just with itself.
final class ARMDecoderTests: XCTestCase {
    func testDecodesMovImmediate() {
        // MOV r0, #5
        guard case .dataProcessing(let instr) = ARMDecoder.decode(0xE3A0_0005) else {
            return XCTFail("Expected dataProcessing")
        }
        XCTAssertEqual(instr.condition, .always)
        XCTAssertEqual(instr.op, .mov)
        XCTAssertFalse(instr.setFlags)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.operand2, .immediate(value: 5, forcedCarryOut: nil))
    }

    func testDecodesAddRegisterShiftedByImmediate() {
        // ADD r0, r1, r2
        guard case .dataProcessing(let instr) = ARMDecoder.decode(0xE081_0002) else {
            return XCTFail("Expected dataProcessing")
        }
        XCTAssertEqual(instr.op, .add)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.operand2, .shiftedRegister(rm: 2, shiftType: .lsl, shiftAmount: 0))
    }

    func testRegisterSpecifiedShiftIsUnsupportedNotMisreadAsImmediateShift() {
        // ADD r0, r1, r2, LSL r3 — bit4==1 (register-specified shift
        // amount) with bit7==0, so it's valid data-processing, just a
        // form this decoder doesn't decode. Regression test for a bug
        // where this fell through and had Rs (bits 11:8) misread as a
        // 5-bit shift-immediate instead of being refused.
        let word: UInt32 = 0xE081_0312
        if case .dataProcessing = ARMDecoder.decode(word) {
            XCTFail("Register-specified shift must not be misdecoded as an immediate shift amount")
        }
    }

    func testDecodesSubsSettingFlags() {
        // SUBS r2, r0, r1
        guard case .dataProcessing(let instr) = ARMDecoder.decode(0xE050_2001) else {
            return XCTFail("Expected dataProcessing")
        }
        XCTAssertEqual(instr.op, .sub)
        XCTAssertTrue(instr.setFlags)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rd, 2)
    }

    func testCompareWithFlagsClearIsUnsupportedNotMisdecoded() {
        // CMP's encoding space with S==0 is actually MRS/MSR — must not
        // be decoded as a flag-less CMP.
        let word: UInt32 = 0xE140_0000 // cond=AL, opcode=CMP(1010), S=0
        if case .dataProcessing = ARMDecoder.decode(word) {
            XCTFail("S==0 CMP-space encoding should not decode as dataProcessing")
        }
    }

    func testDecodesUnconditionalBranchForwardOffset() {
        // B with imm24 == 2 -> byte offset +8 from (address + 8).
        guard case .branch(let instr) = ARMDecoder.decode(0xEA00_0002) else {
            return XCTFail("Expected branch")
        }
        XCTAssertEqual(instr.condition, .always)
        XCTAssertFalse(instr.link)
        XCTAssertEqual(instr.signedOffset, 8)
    }

    func testDecodesBranchWithLinkAndNegativeOffset() {
        // BL with imm24 all-ones -> -1 word -> byte offset -4.
        guard case .branch(let instr) = ARMDecoder.decode(0xEBFF_FFFF) else {
            return XCTFail("Expected branch")
        }
        XCTAssertTrue(instr.link)
        XCTAssertEqual(instr.signedOffset, -4)
    }

    func testBlockDataTransferIsUnsupported() {
        // Same 27:26 block as branch, but bit 25 == 0 -> LDM/STM, not decoded.
        let word: UInt32 = 0xE8BD_0001
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for block data transfer encoding")
        }
    }

    func testDecodesLoadWordImmediateOffset() {
        // LDR r0, [r1, #4]
        guard case .loadStore(let instr) = ARMDecoder.decode(0xE591_0004) else {
            return XCTFail("Expected loadStore")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertFalse(instr.isByte)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.immediateOffset, 4)
    }

    func testDecodesStoreWordPostIndexedSubtract() {
        // STR r2, [r3], #-8
        guard case .loadStore(let instr) = ARMDecoder.decode(0xE403_2008) else {
            return XCTFail("Expected loadStore")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertFalse(instr.preIndexed)
        XCTAssertFalse(instr.addOffset)
        XCTAssertEqual(instr.rn, 3)
        XCTAssertEqual(instr.rd, 2)
        XCTAssertEqual(instr.immediateOffset, 8)
    }

    func testRegisterOffsetLoadStoreIsUnsupported() {
        // Same family as LDR/STR but bit 25 == 1 -> register offset, not decoded.
        let word: UInt32 = 0xE791_0002
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for register-offset load/store")
        }
    }

    func testMultiplyEncodingSpaceIsUnsupportedNotDataProcessing() {
        let word: UInt32 = 0xE000_0090
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for multiply-space encoding")
        }
    }

    func testNeverConditionIsUndefined() {
        let word: UInt32 = 0xF3A0_0005 // cond bits 1111
        if case .undefined = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .undefined for the NV condition")
        }
    }
}
