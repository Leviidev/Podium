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

    func testDecodesLdrexdFromRealKernel() {
        // ldrexd r4, r5, [r2] — from the real kernel at 0x80080f74.
        guard case .loadExclusiveDouble(let instr) = ARMDecoder.decode(0xE1B2_4F9F) else {
            return XCTFail("Expected loadExclusiveDouble")
        }
        XCTAssertEqual(instr.rt, 4)
        XCTAssertEqual(instr.rn, 2)
    }

    func testDecodesStrexdFromRealKernel() {
        // strexd r3, r8, sb, [r2] — from the real kernel at 0x80080f84.
        guard case .storeExclusiveDouble(let instr) = ARMDecoder.decode(0xE1A2_3F98) else {
            return XCTFail("Expected storeExclusiveDouble")
        }
        XCTAssertEqual(instr.rd, 3)
        XCTAssertEqual(instr.rt, 8)
        XCTAssertEqual(instr.rn, 2)
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

    func testDecodesLdrdFromRealKernel() {
        // ldrd r0, r1, [r0] — from the real kernel at 0x8027c224.
        guard case .loadStoreDual(let instr) = ARMDecoder.decode(0xE1C0_00D0) else {
            return XCTFail("Expected loadStoreDual")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertEqual(instr.offset, .immediate(0))
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

    func testMlaDecodesAsMultiplyAccumulate() {
        // mla r0, r0, r0, r0 — same multiply-space shape as MUL with the
        // A (accumulate) bit set.
        guard case .multiply(let instr) = ARMDecoder.decode(0xE020_0090) else {
            return XCTFail("Expected multiply")
        }
        XCTAssertEqual(instr.kind, .mla)
        XCTAssertFalse(instr.setFlags)
    }

    func testSwpInSynchronizationSpaceIsUnsupportedNotDataProcessing() {
        // swp r1, r1, [r0] — the deprecated swap shares the
        // multiply/synchronization gate (SH==00, bit7==1, bit4==1) and
        // isn't decoded, so it must stay unsupported rather than be
        // misread as a multiply or data-processing instruction.
        let word: UInt32 = 0xE100_1091
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for SWP")
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
        XCTAssertFalse(instr.changesMode)
    }

    func testDecodesCpsWithModeChangeFromRealKernel() {
        // cpsid i, #0x13 — from the real kernel's Data Abort handler at
        // 0x80084808 and again at 0x80084874, switching into SVC mode to
        // reach a real (larger) stack for the handler's actual work —
        // the mode-only/combined form this CPU didn't decode at all
        // before (bit17 mmod + bits[4:0] mode, independent of imod).
        guard case .changeProcessorState(let instr) = ARMDecoder.decode(0xF10E_0093) else {
            return XCTFail("Expected changeProcessorState")
        }
        XCTAssertTrue(instr.changesMode)
        XCTAssertEqual(instr.mode, 0x13)
        XCTAssertTrue(instr.affectsIRQ)
        XCTAssertFalse(instr.affectsFIQ)
    }

    func testDecodesCpsWithModeChangeToAbortFromRealKernel() {
        // cpsid i, #0x17 — from the real kernel at 0x80084864, switching
        // back into Abort mode from within the handler's SVC-mode work.
        guard case .changeProcessorState(let instr) = ARMDecoder.decode(0xF10E_0097) else {
            return XCTFail("Expected changeProcessorState")
        }
        XCTAssertTrue(instr.changesMode)
        XCTAssertEqual(instr.mode, 0x17)
    }

    func testDecodesVrshlFromRealKernel() {
        // vrshl.u8 d16, d0, d5 — from the real kernel, the instruction
        // that halted execution before any NEON encoding was decoded at
        // all. Field-to-operand mapping empirically confirmed via
        // Capstone (see ARMDecoder's decode-site comment), not read off a
        // manual table from memory.
        guard case .vectorRoundingShiftLeft(let instr) = ARMDecoder.decode(0xF345_0500) else {
            return XCTFail("Expected vectorRoundingShiftLeft")
        }
        XCTAssertTrue(instr.unsigned)
        XCTAssertEqual(instr.size, .bits8)
        XCTAssertEqual(instr.vd, 16)
        XCTAssertEqual(instr.vm, 0)
        XCTAssertEqual(instr.vn, 5)
    }

    func testDecodesVpushFromRealKernel() {
        // vpush {d16-d31} — from the real kernel, hit right after the
        // first-ever ARM-state (non-Thumb) unsupported-instruction halt
        // this session (a VFP/NEON context-save prologue). P=1,U=0,D=1,
        // W=1,L=0,Rn=13(SP),Vd=0,imm8=0x20.
        guard case .extensionRegisterLoadStoreMultiple(let instr) = ARMDecoder.decode(0xED6D_0B20) else {
            return XCTFail("Expected extensionRegisterLoadStoreMultiple")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertFalse(instr.addOffset)
        XCTAssertEqual(instr.rn, 13)
        XCTAssertEqual(instr.firstRegister, 16)
        XCTAssertEqual(instr.registerCount, 16)
    }

    func testDecodesVeorFromRealKernel() {
        // veor q14, q14, q14 — from the real kernel, a NEON register-
        // zeroing idiom hit in the same VFP-context-save routine as the
        // preceding vpush {d16-d31}.
        guard case .bitwiseExclusiveOr(let instr) = ARMDecoder.decode(0xF34C_C1FC) else {
            return XCTFail("Expected bitwiseExclusiveOr")
        }
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 14)
        XCTAssertEqual(instr.vn, 14)
        XCTAssertEqual(instr.vm, 14)
    }

    func testDecodesVld1MultipleFromRealKernel() {
        // vld1.32 {d30, d31}, [r3:0x80]! — from the real kernel, part of
        // the same VFP-context routine as the preceding vpush/veor.
        guard case .elementLoadStore(let instr) = ARMDecoder.decode(0xF463_EAAD) else {
            return XCTFail("Expected elementLoadStore")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.rn, 3)
        XCTAssertEqual(instr.firstRegister, 30)
        XCTAssertEqual(instr.registerCount, 2)
        XCTAssertEqual(instr.writeback, .byTransferSize)
    }

    func testDecodesVrev32FromRealKernel() {
        // vrev32.8 q4, q12 — from the real kernel, part of the same
        // VFP-context routine as the preceding vpush/veor/vld1.
        guard case .reverseElements(let instr) = ARMDecoder.decode(0xF3B0_80E8) else {
            return XCTFail("Expected reverseElements")
        }
        XCTAssertEqual(instr.groupSize, .bits32)
        XCTAssertEqual(instr.elementBits, 8)
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 4)
        XCTAssertEqual(instr.vm, 12)
    }

    func testDecodesVaddI32QuadFromRealKernel() {
        // vadd.i32 q12, q4, q15 — from the real kernel, part of the same
        // NEON SHA-1-style round function as vpush/veor/vld1/vrev32.
        guard case .integerAdd(let instr) = ARMDecoder.decode(0xF268_886E) else {
            return XCTFail("Expected integerAdd")
        }
        XCTAssertEqual(instr.size, .bits32)
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 12)
        XCTAssertEqual(instr.vn, 4)
        XCTAssertEqual(instr.vm, 15)
    }

    func testDecodesVorrQuadFromRealKernel() {
        // vorr q8, q12, q12 — from the real kernel, the VMOV-via-VORR
        // idiom, in the same NEON round function.
        guard case .bitwiseOr(let instr) = ARMDecoder.decode(0xF268_01F8) else {
            return XCTFail("Expected bitwiseOr")
        }
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 8)
        XCTAssertEqual(instr.vn, 12)
        XCTAssertEqual(instr.vm, 12)
    }

    func testDecodesVext64FromRealKernel() {
        // vext.64 q8, q4, q11, #1 — from the real kernel, in the same
        // NEON round function; also the word that motivated adding the
        // bit23==0 guard to the "three registers of the same length"
        // decode branches (its imm4==0b1000 would otherwise misdecode as
        // VADD, since imm4 and VADD's opc field share the same bits).
        guard case .vectorExtract(let instr) = ARMDecoder.decode(0xF2F8_0866) else {
            return XCTFail("Expected vectorExtract")
        }
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 8)
        XCTAssertEqual(instr.vn, 4)
        XCTAssertEqual(instr.vm, 11)
        XCTAssertEqual(instr.byteOffset, 8) // ".64 #1" -> 1 element * 8 bytes
    }

    func testDecodesVext32FromRealKernel() {
        // vext.32 q12, q9, q14, #1 — from the real kernel, confirming the
        // byte-offset scales with element size (4 bytes here vs. 8 above)
        // even though both display as "#1" in assembly.
        guard case .vectorExtract(let instr) = ARMDecoder.decode(0xF2F2_84EC) else {
            return XCTFail("Expected vectorExtract")
        }
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 12)
        XCTAssertEqual(instr.vn, 9)
        XCTAssertEqual(instr.vm, 14)
        XCTAssertEqual(instr.byteOffset, 4) // ".32 #1" -> 1 element * 4 bytes
    }

    func testDecodesVshlI32ImmediateFromRealKernel() {
        // vshl.i32 q12, q8, #1 — from the real kernel, in the same NEON
        // round function.
        guard case .vectorShiftImmediate(let instr) = ARMDecoder.decode(0xF2E1_8570) else {
            return XCTFail("Expected vectorShiftImmediate")
        }
        XCTAssertEqual(instr.direction, .left)
        XCTAssertFalse(instr.unsigned)
        XCTAssertEqual(instr.elementBits, 32)
        XCTAssertEqual(instr.shiftAmount, 1)
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 12)
        XCTAssertEqual(instr.vm, 8)
    }

    func testDecodesVshrU32ImmediateFromRealKernel() {
        // vshr.u32 q8, q8, #0x1f — from the real kernel, sharing the same
        // imm6 size-decoding logic as the VSHL test above (imm6=33 in
        // both cases, but the shift-amount formula differs by direction).
        guard case .vectorShiftImmediate(let instr) = ARMDecoder.decode(0xF3E1_0070) else {
            return XCTFail("Expected vectorShiftImmediate")
        }
        XCTAssertEqual(instr.direction, .right)
        XCTAssertTrue(instr.unsigned)
        XCTAssertEqual(instr.elementBits, 32)
        XCTAssertEqual(instr.shiftAmount, 31)
        XCTAssertTrue(instr.isQuad)
        XCTAssertEqual(instr.vd, 8)
        XCTAssertEqual(instr.vm, 8)
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
        XCTAssertFalse(instr.link)
    }

    func testDecodesBlxRegisterFromRealKernel() {
        // blx r0 — from the real kernel at 0x8027c358.
        guard case .branchExchange(let instr) = ARMDecoder.decode(0xE12F_FF30) else {
            return XCTFail("Expected branchExchange")
        }
        XCTAssertEqual(instr.rm, 0)
        XCTAssertTrue(instr.link)
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

    func testRegisterOffsetHalfwordWithNonzeroHighNibbleIsUnsupported() {
        // The register-offset "extra load/store" form (I==0) requires
        // bits[11:8]==0 (those bits only carry meaning for the
        // immediate form's high nibble) — a real STRH shape but with
        // that nibble nonzero is a reserved encoding, not silently
        // treated as an ordinary register-offset store.
        let word: UInt32 = 0xE180_11B2 // same shape as a real register-offset strh, but bits[11:8]=1
        if case .unsupported = ARMDecoder.decode(word) {
            // expected
        } else {
            XCTFail("Expected .unsupported for a register-offset extra-load-store with a nonzero high nibble")
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

    func testDecodesMrsSpsrFromRealKernel() {
        // mrs sp, spsr — from the real kernel's Data Abort handler
        // prologue at 0x80084740, the instruction that halted execution
        // before SPSR access (R==1) was decoded.
        guard case .moveFromStatusRegister(let instr) = ARMDecoder.decode(0xE14F_D000) else {
            return XCTFail("Expected moveFromStatusRegister")
        }
        XCTAssertTrue(instr.isSPSR)
        XCTAssertEqual(instr.rd, Registers.spIndex)
    }

    func testMsrWithSpsrBitSetDecodesAsSpsrAccess() {
        // Same shape as the real msr above but with bit22 (R) set,
        // selecting SPSR.
        let word: UInt32 = 0xE122_F00B | (1 << 22)
        guard case .moveToStatusRegister(let instr) = ARMDecoder.decode(word) else {
            return XCTFail("Expected moveToStatusRegister")
        }
        XCTAssertTrue(instr.isSPSR)
    }
}
