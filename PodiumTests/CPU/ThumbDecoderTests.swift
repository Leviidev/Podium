import XCTest
@testable import Podium

/// Every case here uses a real halfword pair captured from the actual
/// iPod4,1 6.1.6 kernel's Thumb-compiled code (confirmed genuine via
/// Capstone disassembly of the real, decrypted kernel binary — see
/// `ThumbDecoder`'s doc comment), the same discipline `ARMDecoderTests`
/// established for ARM-state instructions.
final class ThumbDecoderTests: XCTestCase {
    func testDecodesPushFromRealKernel() {
        // push {r4, r5, r6, r7, lr} — from the real kernel at 0x802b8268.
        guard case .pushPop(let instr) = ThumbDecoder.decode(0xb5f0, 0) else {
            return XCTFail("Expected pushPop")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertEqual(instr.registerList, 0x40F0) // r4-r7 + LR (bit 14)
    }

    func testDecodesMovsImmediateFromRealKernel() {
        // movs r6, #0 — from the real kernel at 0x802b826e.
        guard case .immediate(let instr) = ThumbDecoder.decode(0x2600, 0) else {
            return XCTFail("Expected immediate")
        }
        XCTAssertEqual(instr.op, .mov)
        XCTAssertEqual(instr.rdn, 6)
        XCTAssertEqual(instr.imm8, 0)
    }

    func testDecodesHiRegisterAddFromRealKernel() {
        // add r4, pc — from the real kernel at 0x802b8278.
        guard case .hiRegister(let instr) = ThumbDecoder.decode(0x447c, 0) else {
            return XCTFail("Expected hiRegister")
        }
        XCTAssertEqual(instr.op, .add)
        XCTAssertEqual(instr.rdn, 4)
        XCTAssertEqual(instr.rm, Registers.pcIndex)
    }

    func testDecodesAddSpImmediateFromRealKernel() {
        // add r7, sp, #0xc — from the real kernel at 0x802b828c.
        guard case .address(let instr) = ThumbDecoder.decode(0xaf03, 0) else {
            return XCTFail("Expected address")
        }
        XCTAssertTrue(instr.usesSP)
        XCTAssertEqual(instr.rd, 7)
        XCTAssertEqual(instr.imm8, 3) // ×4 applied at execute time
    }

    func testDecodesMulsFromRealKernel() {
        // muls r1, r0, r1 — from the real kernel at 0x802b8436.
        guard case .alu(let instr) = ThumbDecoder.decode(0x4341, 0) else {
            return XCTFail("Expected alu")
        }
        XCTAssertEqual(instr.op, .mul)
        XCTAssertEqual(instr.rdn, 1)
        XCTAssertEqual(instr.rm, 0)
    }

    func testDecodesSubSpImmediateFromRealKernel() {
        // sub sp, #0x44 — from the real kernel at 0x802b8494.
        guard case .adjustStack(let instr) = ThumbDecoder.decode(0xb091, 0) else {
            return XCTFail("Expected adjustStack")
        }
        XCTAssertTrue(instr.subtract)
        XCTAssertEqual(instr.imm7, 0x11) // ×4 applied at execute time
    }

    func testDecodesCbzFromRealKernel() {
        // cbz r0, #0x802b84cc — from the real kernel at 0x802b84bc.
        guard case .compareBranch(let instr) = ThumbDecoder.decode(0xb130, 0) else {
            return XCTFail("Expected compareBranch")
        }
        XCTAssertFalse(instr.branchIfNonZero)
        XCTAssertEqual(instr.rn, 0)
        // Real instruction address 0x802b84bc + 4 + 12 == 0x802b84cc.
        XCTAssertEqual(instr.offset, 12)
    }

    func testDecodesItFromRealKernel() {
        // itt ne — from the real kernel at 0x802b8514.
        guard case .it(let instr) = ThumbDecoder.decode(0xbf1c, 0) else {
            return XCTFail("Expected it")
        }
        XCTAssertEqual(instr.firstCondition, 1) // NE
        XCTAssertEqual(instr.mask, 0xC)
    }

    func testDecodesMovwFromRealKernel() {
        // movw r4, #0x9e64 — from the real kernel at 0x802b826a.
        guard case .movWide(let instr) = ThumbDecoder.decode(0xf649, 0x6464) else {
            return XCTFail("Expected movWide")
        }
        XCTAssertFalse(instr.isTop)
        XCTAssertEqual(instr.rd, 4)
        XCTAssertEqual(instr.imm16, 0x9E64)
    }

    func testDecodesMovtFromRealKernel() {
        // movt r4, #4 — from the real kernel at 0x802b8270.
        guard case .movWide(let instr) = ThumbDecoder.decode(0xf2c0, 0x0404) else {
            return XCTFail("Expected movWide")
        }
        XCTAssertTrue(instr.isTop)
        XCTAssertEqual(instr.rd, 4)
        XCTAssertEqual(instr.imm16, 4)
    }

    func testDecodesUbfxFromRealKernel() {
        // ubfx r0, r0, #1, #1 — from the real kernel at 0x802b797c.
        guard case .bitFieldExtract(let instr) = ThumbDecoder.decode(0xf3c0, 0x0040) else {
            return XCTFail("Expected bitFieldExtract")
        }
        XCTAssertFalse(instr.signed)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.lsb, 1)
        XCTAssertEqual(instr.width, 1)
    }

    func testDecodesSbfxFromRealKernel() {
        // sbfx r5, r5, #0, #1 — from the real kernel, the instruction
        // that halted execution before this op value was decoded at all.
        guard case .bitFieldExtract(let instr) = ThumbDecoder.decode(0xf345, 0x0500) else {
            return XCTFail("Expected bitFieldExtract")
        }
        XCTAssertTrue(instr.signed)
        XCTAssertEqual(instr.rd, 5)
        XCTAssertEqual(instr.rn, 5)
        XCTAssertEqual(instr.lsb, 0)
        XCTAssertEqual(instr.width, 1)
    }

    func testDecodesLdrPcRelativeFromRealKernel() {
        // ldr r0, [pc, #0x24] — from the real kernel, the instruction
        // that halted execution before format 6 was decoded at all.
        guard case .loadPCRelative(let instr) = ThumbDecoder.decode(0x4809, 0) else {
            return XCTFail("Expected loadPCRelative")
        }
        XCTAssertEqual(instr.rt, 0)
        XCTAssertEqual(instr.offset, 0x24)
    }

    func testDecodesAddwFromRealKernel() {
        // addw r0, r4, #0x4d4 — from the real kernel at 0x80021b34.
        guard case .addWide(let instr) = ThumbDecoder.decode(0xf204, 0x40d4) else {
            return XCTFail("Expected addWide")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rn, 4)
        XCTAssertEqual(instr.imm12, 0x4D4)
    }

    func testDecodesBfcFromRealKernel() {
        // bfc r0, #0, #0xc — from the real kernel at 0x8007eefa.
        guard case .bitFieldInsert(let instr) = ThumbDecoder.decode(0xf36f, 0x000b) else {
            return XCTFail("Expected bitFieldInsert")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertNil(instr.sourceRegister)
        XCTAssertEqual(instr.lsb, 0)
        XCTAssertEqual(instr.width, 12)
    }

    func testDecodesAdrFromRealKernel() {
        // addw r2, pc, #0x16 — from the real kernel at 0x800200f8.
        // ADDW with Rn==1111 is architecturally ADR.
        guard case .adr(let instr) = ThumbDecoder.decode(0xf20f, 0x0216) else {
            return XCTFail("Expected adr")
        }
        XCTAssertEqual(instr.rd, 2)
        XCTAssertEqual(instr.imm12, 0x16)
    }

    func testDecodesUxtbWideFromRealKernel() {
        // uxtb.w r1, r10 — from the real kernel at 0x8007b056.
        guard case .extendWide(let instr) = ThumbDecoder.decode(0xfa5f, 0xf18a) else {
            return XCTFail("Expected extendWide")
        }
        XCTAssertEqual(instr.kind, .unsignedByte)
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.rm, 10)
        XCTAssertEqual(instr.rotate, 0)
    }

    func testDecodesDsbFromRealKernel() {
        // dsb sy — from the real kernel at 0x8007b106.
        guard case .memoryBarrier = ThumbDecoder.decode(0xf3bf, 0x8f4f) else {
            return XCTFail("Expected memoryBarrier")
        }
    }

    func testDecodesLslRegisterWideFromRealKernel() {
        // lsl.w r2, r5, r2 — from the real kernel at 0x802b94ec.
        guard case .shiftRegister(let instr) = ThumbDecoder.decode(0xfa05, 0xf202) else {
            return XCTFail("Expected shiftRegister")
        }
        XCTAssertEqual(instr.shiftType, .lsl)
        XCTAssertEqual(instr.rd, 2)
        XCTAssertEqual(instr.rn, 5)
        XCTAssertEqual(instr.rm, 2)
    }

    func testDecodesLdmiaFromRealKernel() {
        // ldm r6, {r2, r3, r6} — from the real kernel at 0x80067e56.
        // Rn (r6) is itself in the register list, so no writeback.
        guard case .blockDataTransfer(let instr) = ThumbDecoder.decode(0xce4c, 0) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertTrue(instr.isIncrement)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.rn, 6)
        XCTAssertEqual(instr.registerList, 0b0100_1100) // r2, r3, r6
    }

    func testDecodesLdmiaWithWritebackWhenBaseNotInList() {
        // ldm r0!, {r2, r3} — synthetic (same shape as the real
        // ldm r6, {r2,r3,r6} word, but with r0 as base, not in the
        // list): writeback applies since Rn isn't overwritten by the load.
        guard case .blockDataTransfer(let instr) = ThumbDecoder.decode(0xc80c, 0) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.registerList, 0b0000_1100) // r2, r3
    }

    func testDecodesClzWideFromRealKernel() {
        // clz r1, r5 — from the real kernel at 0x80287cf2.
        guard case .clz(let instr) = ThumbDecoder.decode(0xfab5, 0xf185) else {
            return XCTFail("Expected clz")
        }
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.rm, 5)
    }

    func testDecodesBicImmediateFromRealKernel() {
        // bic r1, r1, #1 — from the real kernel at 0x802b8578.
        guard case .dataProcessingImmediate(let instr) = ThumbDecoder.decode(0xf021, 0x0101) else {
            return XCTFail("Expected dataProcessingImmediate")
        }
        XCTAssertEqual(instr.op, .bic)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.imm32, 1)
        XCTAssertFalse(instr.setFlags)
    }

    func testDecodesMvnImmediateFromRealKernel() {
        // mvn r5, #0xf0000000 — from the real kernel at 0x8007ed2e.
        // ORN with Rn==1111 (the MVN alias).
        guard case .dataProcessingImmediate(let instr) = ThumbDecoder.decode(0xf06f, 0x4570) else {
            return XCTFail("Expected dataProcessingImmediate")
        }
        XCTAssertEqual(instr.op, .orn)
        XCTAssertEqual(instr.rn, 15)
        XCTAssertEqual(instr.rd, 5)
        XCTAssertEqual(instr.imm32, 0xF000_0000)
        XCTAssertFalse(instr.setFlags)
    }

    func testDecodesOrrImmediateFromRealKernel() {
        // orr r3, r3, #1 — from the real kernel at 0x802b8584.
        guard case .dataProcessingImmediate(let instr) = ThumbDecoder.decode(0xf043, 0x0301) else {
            return XCTFail("Expected dataProcessingImmediate")
        }
        XCTAssertEqual(instr.op, .orr)
        XCTAssertEqual(instr.rn, 3)
        XCTAssertEqual(instr.imm32, 1)
    }

    func testDecodesMovWImmediateFromRealKernel() {
        // mov.w r1, #-1 — from the real kernel at 0x802b827c.
        guard case .dataProcessingImmediate(let instr) = ThumbDecoder.decode(0xf04f, 0x31ff) else {
            return XCTFail("Expected dataProcessingImmediate")
        }
        XCTAssertEqual(instr.op, .orr)
        XCTAssertEqual(instr.rn, Registers.pcIndex) // Rn == 1111 selects the MOV alias.
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.imm32, 0xFFFF_FFFF)
    }

    func testDecodesCmpWImmediateFromRealKernel() {
        // cmp.w r0, #0x1f40 — from the real kernel at 0x802b85da.
        guard case .dataProcessingImmediate(let instr) = ThumbDecoder.decode(0xf5b0, 0x5ffa) else {
            return XCTFail("Expected dataProcessingImmediate")
        }
        XCTAssertEqual(instr.op, .sub)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rd, Registers.pcIndex) // Rd == 1111, S == 1 selects the CMP alias.
        XCTAssertTrue(instr.setFlags)
        XCTAssertEqual(instr.imm32, 0x1F40)
    }

    func testDecodesAddWImmediateFromRealKernel() {
        // add.w r0, r4, #0x120 — from the real kernel at 0x802b8328.
        guard case .dataProcessingImmediate(let instr) = ThumbDecoder.decode(0xf504, 0x7090) else {
            return XCTFail("Expected dataProcessingImmediate")
        }
        XCTAssertEqual(instr.op, .add)
        XCTAssertEqual(instr.rn, 4)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.imm32, 0x120)
    }

    func testDecodesBlFromRealKernel() {
        // bl #0x80030938 — from the real kernel at 0x802b832c.
        guard case .branchLink(let instr) = ThumbDecoder.decode(0xf578, 0xfb04) else {
            return XCTFail("Expected branchLink")
        }
        XCTAssertFalse(instr.switchesToARM)
        XCTAssertEqual(0x802B_832C &+ 4 &+ UInt32(bitPattern: instr.signedOffset), 0x8003_0938)
    }

    func testDecodesBlxImmediateFromRealKernel() {
        // blx #0x80089744 — from the real kernel at 0x802b8406 (target
        // must additionally be Align(pc,4)'d at execute time — see
        // ARMv7CPU+Thumb.swift's executeThumbBranchLink).
        guard case .branchLink(let instr) = ThumbDecoder.decode(0xf5d1, 0xe99e) else {
            return XCTFail("Expected branchLink")
        }
        XCTAssertTrue(instr.switchesToARM)
    }

    func testDecodesBWUnconditionalFromRealKernel() {
        // b.w #0x802bd23c — from the real kernel at 0x802b8410.
        guard case .branchWide(let instr) = ThumbDecoder.decode(0xf004, 0xbf14) else {
            return XCTFail("Expected branchWide")
        }
        XCTAssertEqual(0x802B_8410 &+ 4 &+ UInt32(bitPattern: instr.signedOffset), 0x802B_D23C)
    }

    func testDecodesLdmWFromRealKernel() {
        // pop.w {r4, r5, r6, r7, lr} == ldmia.w sp!, {r4,r5,r6,r7,lr} —
        // from the real kernel at 0x802b840c.
        guard case .blockDataTransfer(let instr) = ThumbDecoder.decode(0xe8bd, 0x40f0) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertTrue(instr.isIncrement)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.rn, Registers.spIndex)
        XCTAssertEqual(instr.registerList, 0x40F0)
    }

    func testDecodesStrWImmediateFromRealKernel() {
        // str.w r2, [r4, #0x224] — from the real kernel at 0x802b8288.
        guard case .loadStoreWide(let instr) = ThumbDecoder.decode(0xf8c4, 0x2224) else {
            return XCTFail("Expected loadStoreWide")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertEqual(instr.rn, 4)
        XCTAssertEqual(instr.rt, 2)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.offset, 0x224)
    }

    func testDecodesStrPreIndexedWritebackFromRealKernel() {
        // str r8, [sp, #-4]! — from the real kernel at 0x802b8490.
        guard case .loadStoreWide(let instr) = ThumbDecoder.decode(0xf84d, 0x8d04) else {
            return XCTFail("Expected loadStoreWide")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertEqual(instr.rn, Registers.spIndex)
        XCTAssertEqual(instr.rt, 8)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertFalse(instr.addOffset)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.offset, 4)
    }

    func testDecodesLsrFromRealKernel() {
        // lsr r0, r0, #8 — from the real kernel at 0x8027b9f2.
        guard case .shiftImmediate(let instr) = ThumbDecoder.decode(0x0A00, 0) else {
            return XCTFail("Expected shiftImmediate")
        }
        XCTAssertEqual(instr.shiftType, .lsr)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rm, 0)
        XCTAssertEqual(instr.imm5, 8)
    }

    func testDecodesLdrhFromRealKernel() {
        // ldrh r0, [r4, #42] — from the real kernel at 0x8027b9f8.
        guard case .loadStoreImmediate(let instr) = ThumbDecoder.decode(0x8D60, 0) else {
            return XCTFail("Expected loadStoreImmediate")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.size, .halfword)
        XCTAssertEqual(instr.rn, 4)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertEqual(instr.offset, 42)
    }

    func testDecodesStmWFromRealKernel() {
        // stm.w r1, {r0, r3} — from the real kernel at 0x8027a462.
        guard case .blockDataTransfer(let instr) = ThumbDecoder.decode(0xe881, 0x0009) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertTrue(instr.isIncrement)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.registerList, 0x0009) // r0, r3
    }

    func testDecodesMrcFromRealKernel() {
        // mrc p15, #0, r0, c13, c0, #4 — from the real kernel at
        // 0x8008e11c, reusing ARM state's exact field layout.
        guard case .coprocessorRegisterTransfer(let instr) = ThumbDecoder.decode(0xee1d, 0x0f90) else {
            return XCTFail("Expected coprocessorRegisterTransfer")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertEqual(instr.coprocessor, 15)
        XCTAssertEqual(instr.opc1, 0)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertEqual(instr.crn, 13)
        XCTAssertEqual(instr.crm, 0)
        XCTAssertEqual(instr.opc2, 4)
    }

    func testDecodesBeqWConditionalFromRealKernel() {
        // beq.w #0x80020924 — from the real kernel at 0x8001ff66.
        guard case .branchWide(let instr) = ThumbDecoder.decode(0xf000, 0x84dd) else {
            return XCTFail("Expected branchWide")
        }
        XCTAssertEqual(instr.condition, .equal)
        XCTAssertEqual(0x8001_FF66 &+ 4 &+ UInt32(bitPattern: instr.signedOffset), 0x8002_0924)
    }

    func testDecodesPushWDbDirectionFromRealKernel() {
        // push.w {r8, sl, fp} — from the real kernel at 0x8027ad44,
        // the DB-direction form (16-bit PUSH can't reach r8-r11).
        guard case .blockDataTransfer(let instr) = ThumbDecoder.decode(0xe92d, 0x0d00) else {
            return XCTFail("Expected blockDataTransfer")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertFalse(instr.isIncrement)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.rn, Registers.spIndex)
        XCTAssertEqual(instr.registerList, 0x0D00) // r8, r10, r11
    }

    func testDecodesStrbFromRealKernel() {
        // strb r0, [r6, #0x64] — from the real kernel at 0x8027b9f2.
        guard case .loadStoreWide(let instr) = ThumbDecoder.decode(0xF886, 0x0064) else {
            return XCTFail("Expected loadStoreWide")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertTrue(instr.isByte)
        XCTAssertEqual(instr.rn, 6)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertEqual(instr.offset, 0x64)
    }

    func testDecodesLdrhWideFromRealKernel() {
        // ldrh.w r1, [r8] — from the real kernel at 0x8007ef7e.
        guard case .loadStoreWide(let instr) = ThumbDecoder.decode(0xf8b8, 0x1000) else {
            return XCTFail("Expected loadStoreWide")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertFalse(instr.isByte)
        XCTAssertTrue(instr.isHalfword)
        XCTAssertFalse(instr.isSigned)
        XCTAssertEqual(instr.rn, 8)
        XCTAssertEqual(instr.rt, 1)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertEqual(instr.offset, 0)
    }

    func testDecodesUxtbFromRealKernel() {
        // uxtb r0, r0 — from the real kernel at 0x8027b9ec.
        guard case .extend(let instr) = ThumbDecoder.decode(0xb2c0, 0) else {
            return XCTFail("Expected extend")
        }
        XCTAssertEqual(instr.kind, .unsignedByte)
        XCTAssertEqual(instr.rm, 0)
        XCTAssertEqual(instr.rd, 0)
    }

    func testDecodesLdrPostIndexedWritebackFromRealKernel() {
        // ldr r8, [sp], #4 — from the real kernel at 0x802b8716.
        guard case .loadStoreWide(let instr) = ThumbDecoder.decode(0xf85d, 0x8b04) else {
            return XCTFail("Expected loadStoreWide")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertFalse(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.offset, 4)
    }

    func testDecodesLdrWRegisterOffsetFromRealKernel() {
        // ldr.w r3, [r5, r0, lsl #3] — from the real kernel at 0x8008e0c8.
        guard case .loadStoreRegister(let instr) = ThumbDecoder.decode(0xf855, 0x3030) else {
            return XCTFail("Expected loadStoreRegister")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertFalse(instr.isByte)
        XCTAssertEqual(instr.rn, 5)
        XCTAssertEqual(instr.rt, 3)
        XCTAssertEqual(instr.rm, 0)
        XCTAssertEqual(instr.shiftAmount, 3)
    }

    func testDecodesVmovI32QRegisterImmediateFromRealKernel() {
        // vmov.i32 q8, #0 — from the real kernel at 0x802b7c4e.
        guard case .vectorMoveImmediate(let instr) = ThumbDecoder.decode(0xefc0, 0x0050) else {
            return XCTFail("Expected vectorMoveImmediate")
        }
        XCTAssertEqual(instr.qd, 8)
        XCTAssertEqual(instr.imm8, 0)
    }

    func testDecodesVmovI32QRegisterImmediateNonzeroFromRealKernel() {
        // Same real word with hw1 bit0 flipped (0x0051): vmov.i32 q8, #1 —
        // confirms the imm8/Qd field extraction beyond the all-zero case.
        guard case .vectorMoveImmediate(let instr) = ThumbDecoder.decode(0xefc0, 0x0051) else {
            return XCTFail("Expected vectorMoveImmediate")
        }
        XCTAssertEqual(instr.qd, 8)
        XCTAssertEqual(instr.imm8, 1)
    }

    func testDecodesVstmiaDoubleRegisterListFromRealKernel() {
        // vstmia r2, {d16, d17} — from the real kernel at 0x802b7c6e.
        guard case .vectorLoadStoreMultiple(let instr) = ThumbDecoder.decode(0xecc2, 0x0b04) else {
            return XCTFail("Expected vectorLoadStoreMultiple")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.rn, 2)
        XCTAssertEqual(instr.vd, 16)
        XCTAssertEqual(instr.registerCount, 2)
    }

    func testDecodesSmmulFromRealKernel() {
        // smmul r0, r0, r1 — from the real kernel at 0x800311fc.
        guard case .smmul(let instr) = ThumbDecoder.decode(0xfb50, 0xf001) else {
            return XCTFail("Expected smmul")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rm, 1)
    }

    func testDecodesPkhbtFromRealKernel() {
        // pkhbt r0, r1, r0 — from the real kernel at 0x8006a392.
        guard case .packHalfword(let instr) = ThumbDecoder.decode(0xeac1, 0x0000) else {
            return XCTFail("Expected packHalfword")
        }
        XCTAssertFalse(instr.useTopBottom)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rm, 0)
        XCTAssertEqual(instr.shiftAmount, 0)
    }

    func testDecodesRbitFromRealKernel() {
        // rbit r0, r1 — from the real kernel at 0x8007faa0.
        guard case .rbit(let instr) = ThumbDecoder.decode(0xfa91, 0xf0a1) else {
            return XCTFail("Expected rbit")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rm, 1)
    }

    func testDecodesMlsFromRealKernel() {
        // mls r0, r1, r0, r3 — from the real kernel at 0x80033b44.
        guard case .mls(let instr) = ThumbDecoder.decode(0xfb01, 0x3010) else {
            return XCTFail("Expected mls")
        }
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rm, 0)
        XCTAssertEqual(instr.ra, 3)
    }

    func testDecodesRevFromRealKernel() {
        // rev r0, r0 — from the real kernel at 0x8000a8f8.
        guard case .reverseBytes(let instr) = ThumbDecoder.decode(0xba00, 0) else {
            return XCTFail("Expected reverseBytes")
        }
        XCTAssertFalse(instr.isHalfwordWise)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rm, 0)
    }

    func testDecodesStrhWRegisterOffsetFromRealKernel() {
        // strh.w r2, [r1, r3, lsl #2] — from the real kernel at 0x80033a44.
        guard case .loadStoreRegister(let instr) = ThumbDecoder.decode(0xf821, 0x2023) else {
            return XCTFail("Expected loadStoreRegister")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertFalse(instr.isByte)
        XCTAssertTrue(instr.isHalfword)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rt, 2)
        XCTAssertEqual(instr.rm, 3)
        XCTAssertEqual(instr.shiftAmount, 2)
    }

    func testDecodesSubWShiftedRegisterFromRealKernel() {
        // sub.w r1, r3, sb (r9) — from the real kernel at 0x80018042.
        guard case .dataProcessingShiftedRegister(let instr) = ThumbDecoder.decode(0xeba3, 0x0109) else {
            return XCTFail("Expected dataProcessingShiftedRegister")
        }
        XCTAssertEqual(instr.op, .sub)
        XCTAssertFalse(instr.setFlags)
        XCTAssertEqual(instr.rn, 3)
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.rm, 9)
        XCTAssertEqual(instr.shiftType, .lsl)
        XCTAssertEqual(instr.shiftAmount, 0)
    }

    func testDecodesLdrsbFromRealKernel() {
        // ldrsb r0, [r5, #1]! — from the real kernel at 0x8001ff9a.
        guard case .loadStoreWide(let instr) = ThumbDecoder.decode(0xf915, 0x0f01) else {
            return XCTFail("Expected loadStoreWide")
        }
        XCTAssertTrue(instr.isLoad)
        XCTAssertTrue(instr.isByte)
        XCTAssertTrue(instr.isSigned)
        XCTAssertEqual(instr.rn, 5)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertTrue(instr.writeback)
        XCTAssertEqual(instr.offset, 1)
    }

    func testDecodesSubsImmediate3FromRealKernel() {
        // subs r4, r7, #4 — from the real kernel at 0x80287ed0.
        guard case .addSub(let instr) = ThumbDecoder.decode(0x1f3c, 0) else {
            return XCTFail("Expected addSub")
        }
        XCTAssertTrue(instr.isSub)
        XCTAssertEqual(instr.rd, 4)
        XCTAssertEqual(instr.rn, 7)
        XCTAssertEqual(instr.operand2, .immediate(4))
    }

    func testDecodesLdrbRegisterOffsetFromRealKernel() {
        // ldrb r0, [r1, r0] — from the real kernel at 0x800207ce.
        guard case .loadStoreRegisterOffset(let instr) = ThumbDecoder.decode(0x5c08, 0) else {
            return XCTFail("Expected loadStoreRegisterOffset")
        }
        XCTAssertEqual(instr.op, .ldrb)
        XCTAssertEqual(instr.rd, 0)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rm, 0)
    }

    func testDecodesTbhFromRealKernel() {
        // tbh [pc, r1, lsl #1] — from the real kernel at 0x80020176.
        guard case .tableBranch(let instr) = ThumbDecoder.decode(0xe8df, 0xf011) else {
            return XCTFail("Expected tableBranch")
        }
        XCTAssertEqual(instr.rn, Registers.pcIndex)
        XCTAssertEqual(instr.rm, 1)
        XCTAssertTrue(instr.isHalfword)
    }

    func testDecodesUmullFromRealKernel() {
        // umull r5, r2, r0, r3 — from the real kernel at 0x8008b8f8.
        guard case .umull(let instr) = ThumbDecoder.decode(0xfba0, 0x5203) else {
            return XCTFail("Expected umull")
        }
        XCTAssertEqual(instr.rdLo, 5)
        XCTAssertEqual(instr.rdHi, 2)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rm, 3)
    }

    func testDecodesMlaFromRealKernel() {
        // mla r4, r1, r3, r2 — from the real kernel at 0x8008b8fc.
        guard case .mla(let instr) = ThumbDecoder.decode(0xfb01, 0x2403) else {
            return XCTFail("Expected mla")
        }
        XCTAssertEqual(instr.rd, 4)
        XCTAssertEqual(instr.rn, 1)
        XCTAssertEqual(instr.rm, 3)
        XCTAssertEqual(instr.ra, 2)
    }

    func testDecodesMulWideFromRealKernel() {
        // mul r1, r0, r2 — from the real kernel at 0x802b783e.
        guard case .mul(let instr) = ThumbDecoder.decode(0xfb00, 0xf102) else {
            return XCTFail("Expected mul")
        }
        XCTAssertEqual(instr.rd, 1)
        XCTAssertEqual(instr.rn, 0)
        XCTAssertEqual(instr.rm, 2)
    }

    func testDecodesStrdFromRealKernel() {
        // strd r0, r1, [r8] — from the real kernel at 0x8008b92c.
        guard case .loadStoreDual(let instr) = ThumbDecoder.decode(0xe9c8, 0x0100) else {
            return XCTFail("Expected loadStoreDual")
        }
        XCTAssertFalse(instr.isLoad)
        XCTAssertEqual(instr.rn, 8)
        XCTAssertEqual(instr.rt, 0)
        XCTAssertEqual(instr.rt2, 1)
        XCTAssertTrue(instr.preIndexed)
        XCTAssertTrue(instr.addOffset)
        XCTAssertFalse(instr.writeback)
        XCTAssertEqual(instr.offset, 0)
    }
}
