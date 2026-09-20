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
        XCTAssertEqual(instr.offset, .immediate(4))
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
        XCTAssertEqual(instr.offset, .immediate(8))
    }

    func testDecodesRegisterOffsetLoad() {
        // LDR r0, [r1, r2] — verified against the real iPod4,1 6.1.6
        // kernel's "ldr lr, [pc, lr]" at 0x80086090 (raw 0xE79FE00E),
        // using r0/r1/r2 here just to keep the fixture simple.
        guard case .loadStore(let instr) = ARMDecoder.decode(0xE791_0002) else {
            return XCTFail("Expected loadStore")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.offset, .register(rm: 2, shiftType: .lsl, shiftAmount: 0))
    }

    func testDecodesRealKernelRegisterOffsetLoad() {
        // The actual instruction from the real kernel this was verified against.
        guard case .loadStore(let instr) = ARMDecoder.decode(0xE79F_E00E) else {
            return XCTFail("Expected loadStore")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.rn, Registers.pcIndex)
        XCTAssertEqual(instr.rd, Registers.lrIndex)
        XCTAssertEqual(instr.offset, .register(rm: Registers.lrIndex, shiftType: .lsl, shiftAmount: 0))
    }

    func testMultiplyEncodingSpaceIsUnsupportedNotDataProcessing() {
        let word: UInt32 = 0xE000_0090
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for multiply-space encoding")
        }
    }

    func testUnrecognizedUnconditionalSpaceEncodingIsUnsupportedNotUndefined() {
        // cond bits 1111 ("NV") no longer means "never execute" from
        // ARMv6 on — it's the unconditional-instruction-extension space
        // (CPS, barriers, ...). An encoding within that space this
        // decoder doesn't recognize is honestly "not decoded yet"
        // (.unsupported), not "genuinely invalid" (.undefined).
        let word: UInt32 = 0xF3A0_0005
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for an unrecognized unconditional-space encoding")
        }
    }

    func testDecodesMovwFromRealKernel() {
        // movw lr, #0xc42c — the actual instruction that first halted
        // execution of the real iPod4,1 6.1.6 kernel, at 0x80086088.
        guard case .movWide(let instr) = ARMDecoder.decode(0xE30C_E42C) else {
            return XCTFail("Expected movWide")
        }
        XCTAssertFalse(instr.isTop)
        XCTAssertEqual(instr.rd, Registers.lrIndex)
        XCTAssertEqual(instr.imm16, 0xC42C)
    }

    func testDecodesMovtFromRealKernel() {
        // movt lr, #0x24 — the very next instruction in the same kernel.
        guard case .movWide(let instr) = ARMDecoder.decode(0xE340_E024) else {
            return XCTFail("Expected movWide")
        }
        XCTAssertTrue(instr.isTop)
        XCTAssertEqual(instr.rd, Registers.lrIndex)
        XCTAssertEqual(instr.imm16, 0x0024)
    }

    func testDecodesCpsidFromRealKernel() {
        // cpsid if — disables IRQ and FIQ, from the real kernel at 0x80086094.
        guard case .changeProcessorState(let instr) = ARMDecoder.decode(0xF10C_00C0) else {
            return XCTFail("Expected changeProcessorState")
        }
        XCTAssertFalse(instr.enable)
        XCTAssertFalse(instr.affectsAbort)
        XCTAssertTrue(instr.affectsIRQ)
        XCTAssertTrue(instr.affectsFIQ)
    }

    func testDecodesIsbFromRealKernel() {
        // isb sy, from the real kernel at 0x8008609c.
        guard case .memoryBarrier = ARMDecoder.decode(0xF57F_F06F) else {
            return XCTFail("Expected memoryBarrier")
        }
    }

    func testDecodesMcrFromRealKernel() {
        // mcr p15, #0, r11, c7, c5, #0 (instruction-cache invalidate),
        // from the real kernel at 0x80086098.
        guard case .coprocessorRegisterTransfer(let instr) = ARMDecoder.decode(0xEE07_BF15) else {
            return XCTFail("Expected coprocessorRegisterTransfer")
        }
        XCTAssertFalse(instr.isLoad) // MCR: ARM register -> coprocessor
        XCTAssertEqual(instr.coprocessor, 15)
        XCTAssertEqual(instr.opc1, 0)
        XCTAssertEqual(instr.rt, 11)
        XCTAssertEqual(instr.crn, 7)
        XCTAssertEqual(instr.crm, 5)
        XCTAssertEqual(instr.opc2, 0)
    }
}
