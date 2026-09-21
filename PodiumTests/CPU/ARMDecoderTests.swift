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

    func testRegisterSpecifiedShiftDecodesRsNotAsAnImmediateShiftAmount() {
        // ADD r0, r1, r2, LSL r3 — bit4==1 (register-specified shift
        // amount) with bit7==0. Regression test for a bug where this
        // fell through and had Rs (bits 11:8) misread as a 5-bit
        // shift-immediate instead of being decoded as the real Rs form.
        guard case .dataProcessing(let instr) = ARMDecoder.decode(0xE081_0312) else {
            return XCTFail("Expected dataProcessing")
        }
        XCTAssertEqual(instr.op, .add)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 0)
        guard case .shiftedRegisterByRegister(let rm, let shiftType, let rs) = instr.operand2 else {
            return XCTFail("Expected shiftedRegisterByRegister, not a misread immediate shift")
        }
        XCTAssertEqual(rm, 2)
        XCTAssertEqual(shiftType, .lsl)
        XCTAssertEqual(rs, 3)
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

    func testDecodesBlockDataTransfer() {
        // Same 27:26 block as branch, but bit 25 == 0 -> LDM/STM
        // (LDMIA sp!, {r0}). See `testDecodesPushFromRealKernel` and
        // `testDecodesPopWithPCFromRealKernel` for real-kernel-verified
        // words exercising the full field set.
        guard case .blockDataTransfer(let instr) = ARMDecoder.decode(0xE8BD_0001) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.registerList, 0x0001)
    }

    func testDecodesOrrRegisterShiftedByRegisterFromRealKernel() {
        // orr r1, r1, r3, lsr r2 — from the real kernel at 0x80089bbc.
        guard case .dataProcessing(let instr) = ARMDecoder.decode(0xE181_1233) else {
            return XCTFail("Expected dataProcessing")
        }
        XCTAssertEqual(instr.op, .orr)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 1)
        guard case .shiftedRegisterByRegister(let rm, let shiftType, let rs) = instr.operand2 else {
            return XCTFail("Expected shiftedRegisterByRegister")
        }
        XCTAssertEqual(rm, 3)
        XCTAssertEqual(shiftType, .lsr)
        XCTAssertEqual(rs, 2)
    }

    func testDecodesUqsub8FromRealKernel() {
        // uqsub8 r2, r3, r1 — from the real kernel at 0x80089bc4,
        // confirmed via Capstone (independent of this decoder).
        guard case .uqsub8(let instr) = ARMDecoder.decode(0xE663_2FF1) else {
            return XCTFail("Expected uqsub8")
        }
        XCTAssertEqual(instr.rd, 2)
        XCTAssertEqual(instr.rn, 3)
        XCTAssertEqual(instr.rm, 1)
    }

    func testDecodesRevFromRealKernel() {
        // rev r2, r2 — from the real kernel at 0x80089be4, confirmed
        // via Capstone.
        guard case .rev(let instr) = ARMDecoder.decode(0xE6BF_2F32) else {
            return XCTFail("Expected rev")
        }
        XCTAssertEqual(instr.rd, 2)
        XCTAssertEqual(instr.rm, 2)
    }

    func testDecodesBfiFromRealKernel() {
        // bfi r0, r2, #0x10, #4 — from the real kernel at 0x8007dca4,
        // confirmed via Capstone.
        guard case .bitFieldInsert(let instr) = ARMDecoder.decode(0xE7D3_0812) else {
            return XCTFail("Expected bitFieldInsert")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.sourceRegister, 2)
        XCTAssertEqual(instr.lsb, 16)
        XCTAssertEqual(instr.width, 4)
    }

    func testDecodesBfcAsBitFieldInsertWithNoSourceRegister() {
        // Synthetic word with Rn == 1111 (BFC): same shape as the real
        // BFI word above but with bits[3:0] set to 0b1111.
        guard case .bitFieldInsert(let instr) = ARMDecoder.decode(0xE7D3_081F) else {
            return XCTFail("Expected bitFieldInsert")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertNil(instr.sourceRegister)
        XCTAssertEqual(instr.lsb, 16)
        XCTAssertEqual(instr.width, 4)
    }

    func testDecodesUbfxArmStateFromRealKernel() {
        // ubfx r3, r0, #3, #0xa — from the real kernel at 0x8007dd80,
        // confirmed via Capstone. A different encoding from Thumb's
        // UBFX (see BitFieldExtractInstruction's doc comment).
        guard case .bitFieldExtract(let instr) = ARMDecoder.decode(0xE7E9_31D0) else {
            return XCTFail("Expected bitFieldExtract")
        }
        XCTAssertEqual(instr.rd, 3)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.lsb, 3)
        XCTAssertEqual(instr.width, 10)
    }

    func testDecodesMulFromRealKernel() {
        // mul r0, r3, r4 — from the real kernel at 0x8007dd9c,
        // confirmed via Capstone.
        guard case .multiply(let instr) = ARMDecoder.decode(0xE000_0493) else {
            return XCTFail("Expected multiply")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rm, 3)
        XCTAssertEqual(instr.rs, 4)
    }

    func testDecodesClzFromRealKernel() {
        // clz r2, r2 — from the real kernel at 0x80089be8, confirmed
        // via Capstone.
        guard case .clz(let instr) = ARMDecoder.decode(0xE16F_2F12) else {
            return XCTFail("Expected clz")
        }
        XCTAssertEqual(instr.rd, 2)
        XCTAssertEqual(instr.rm, 2)
    }

    func testDecodesLdrexFromRealKernel() {
        // ldrex r0, [ip] — from the real kernel at 0x80080fa4.
        guard case .loadExclusive(let instr) = ARMDecoder.decode(0xE19C_0F9F) else {
            return XCTFail("Expected loadExclusive")
        }
        XCTAssertEqual(instr.rt, 0)
        XCTAssertEqual(instr.rn, 12)
    }

    func testDecodesStrexFromRealKernel() {
        // strex r3, r0, [ip] — from the real kernel at 0x80080fac.
        guard case .storeExclusive(let instr) = ARMDecoder.decode(0xE18C_3F90) else {
            return XCTFail("Expected storeExclusive")
        }
        XCTAssertEqual(instr.rd, 3)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertEqual(instr.rn, 12)
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

    func testMlaEncodingSpaceIsUnsupportedNotDataProcessing() {
        // Same multiply-space shape as MUL (bits[27:22]==0, SH==00,
        // bit7==1, bit4==1) but with the A (accumulate) bit set,
        // selecting MLA — not decoded, unlike plain MUL (see
        // testDecodesMulFromRealKernel), so this stays the boundary
        // check that the multiply-space gate doesn't silently
        // misdecode instructions of that space it hasn't confirmed.
        let word: UInt32 = 0xE020_0090
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for MLA (multiply-accumulate) encoding")
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

    func testDecodesPldFromRealKernel() {
        // pld [r1, #32] — from the real kernel at 0x80089798, reached
        // via a genuine Thumb-to-ARM `blx` this CPU can now follow.
        guard case .memoryBarrier = ARMDecoder.decode(0xF5D1_F020) else {
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

    func testDecodesMrsFromRealKernel() {
        // mrs r11, apsr — from the real kernel at 0x8008637c, the
        // instruction that halted execution before MRS/MSR were decoded.
        guard case .moveFromStatusRegister(let instr) = ARMDecoder.decode(0xE10F_B000) else {
            return XCTFail("Expected moveFromStatusRegister")
        }
        XCTAssertEqual(instr.rd, 11)
    }

    func testDecodesMsrFromRealKernel() {
        // msr CPSR_x, r11 — from the real kernel, the instruction right
        // after the mrs above.
        guard case .moveToStatusRegister(let instr) = ARMDecoder.decode(0xE122_F00B) else {
            return XCTFail("Expected moveToStatusRegister")
        }
        XCTAssertEqual(instr.fieldMask, 0b0010) // 'x' (extension) field only
        guard case .register(let rm) = instr.source else {
            return XCTFail("Expected register source")
        }
        XCTAssertEqual(rm, 11)
    }

    func testDecodesBxFromRealKernel() {
        // bx lr — from the real kernel at 0x80086424, a plain function
        // return that used to misdecode as an attempted (and rejected)
        // MSR before BX got its own explicit check.
        guard case .branchExchange(let instr) = ARMDecoder.decode(0xE12F_FF1E) else {
            return XCTFail("Expected branchExchange")
        }
        XCTAssertEqual(instr.rm, Registers.lrIndex)
    }

    func testDecodesPushFromRealKernel() {
        // push {r4, r5, r6, r7, lr} — from the real kernel at 0x802b9768,
        // a standard function prologue (STMDB sp!, {r4-r7,lr}).
        guard case .blockDataTransfer(let instr) = ARMDecoder.decode(0xE92D_40F0) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertFalse(instr.addOffset)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.rn, Registers.spIndex)
        XCTAssertEqual(instr.registerList, 0x40F0)
    }

    func testDecodesPopWithPCFromRealKernel() {
        // pop {r4, r5, r6, r7, pc} — a real function epilogue (LDMIA
        // sp!, {r4-r7,pc}), confirmed via llvm-objdump against the
        // actual kernel binary (address varies by build; word verified
        // directly).
        guard case .blockDataTransfer(let instr) = ARMDecoder.decode(0xE8BD_80F0) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertFalse(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.rn, Registers.spIndex)
        XCTAssertEqual(instr.registerList, 0x80F0)
    }

    func testBlockDataTransferWithSBitIsUnsupported() {
        // Same shape as the real push above, but with bit22 (S) set —
        // user-bank/exception-return semantics, not modeled.
        let word: UInt32 = 0xE92D_40F0 | (1 << 22)
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for the S-bit block transfer form")
        }
    }

    func testDecodesStrhFromRealKernel() {
        // strh r1, [r0, #2] — the real word that halted execution of the
        // actual iPod4,1 6.1.6 kernel at 0x8007d3e4 before this family
        // was decoded.
        guard case .halfwordDataTransfer(let instr) = ARMDecoder.decode(0xE1C0_10B2) else {
            return XCTFail("Expected halfwordDataTransfer")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertEqual(instr.kind, .unsignedHalfword)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.offset, .immediate(2))
    }

    func testDecodesLdrhImmediate() {
        guard case .halfwordDataTransfer(let instr) = ARMDecoder.decode(0xE1D2_30B4) else {
            return XCTFail("Expected halfwordDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.kind, .unsignedHalfword)
        XCTAssertEqual(instr.offset, .immediate(4))
    }

    func testDecodesLdrsbRegisterOffset() {
        guard case .halfwordDataTransfer(let instr) = ARMDecoder.decode(0xE192_30D5) else {
            return XCTFail("Expected halfwordDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.kind, .signedByte)
        XCTAssertEqual(instr.offset, .register(5))
    }

    func testDecodesLdrshNegativeImmediate() {
        guard case .halfwordDataTransfer(let instr) = ARMDecoder.decode(0xE152_30F2) else {
            return XCTFail("Expected halfwordDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.kind, .signedHalfword)
        XCTAssertFalse(instr.addOffset)
        XCTAssertEqual(instr.offset, .immediate(2))
    }

    func testStoreWithSignedKindIsUnsupported() {
        // STRSB/STRSH don't exist — SH==10 (signedByte) with L==0
        // (store) is a reserved encoding, not an ordinary halfword store.
        let word: UInt32 = 0xE1C0_10D2 // same shape as the real strh, but SH=10 instead of 01
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for a store with a signed SH field")
        }
    }

    func testDecodesBlxImmediateFromRealKernel() {
        // blx 0x802b8268 — from the real kernel at 0x802b985c. The
        // target disassembles as garbage under ARM decoding, confirming
        // it's genuine Thumb code (see ARMv7CPUTests for the execute-
        // level halt this produces).
        guard case .branchLinkExchangeImmediate(let instr) = ARMDecoder.decode(0xFAFF_FA81) else {
            return XCTFail("Expected branchLinkExchangeImmediate")
        }
        // Target = (instruction address + 8) + signedOffset = 0x802b985c + 8 - 0x15fc = 0x802b8268.
        XCTAssertEqual(instr.signedOffset, -0x15FC)
    }

    func testMrsWithSpsrBitSetIsUnsupported() {
        // Same shape as the real mrs above but with bit22 (R) set,
        // selecting SPSR — not modeled since there's no exception
        // entry/exit yet for a saved SPSR to matter to.
        let word: UInt32 = 0xE10F_B000 | (1 << 22)
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for SPSR access")
        }
    }
}
