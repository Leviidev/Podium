import Foundation

/// Builds the `boot_args` structure XNU's ARM entry code reads out of
/// `r0` — normally filled in and passed by iBoot, which Podium doesn't
/// run, so there's nothing else to put it there.
///
/// Field layout (offsets, sizes, order) is not assumed — it's copied
/// directly from Apple's own open-source XNU
/// (`pexpert/pexpert/arm/boot.h`, `struct boot_args` / `struct
/// Boot_Video`), fetched from
/// https://github.com/apple-oss-distributions/xnu at the time this was
/// written. This is independently corroborated by the real iPod4,1
/// 6.1.6 kernel's own first instructions after its entry point:
/// `ldr r9, [r0, #4]` then `ldr r8, [r0, #8]` then `ldr r10, [r0, #0xc]`
/// read exactly `virtBase`, `physBase`, then `memSize` at this struct's
/// offsets 4, 8, and 12.
/// `Boot_Video` (`pexpert/pexpert/arm/boot.h`): the framebuffer descriptor
/// iBoot normally hands the kernel — six `uint32_t` fields, in this exact
/// order, at `boot_args` offset 20. `depth` packs bits-per-pixel in its
/// low byte (`kBootVideoDepthMask`) with an optional rotate encoding above
/// it (`kBootVideoDepthRotateMask`, unused here — 0 means no rotation).
struct BootVideoInfo {
    let baseAddress: UInt32
    let display: UInt32
    let rowBytes: UInt32
    let width: UInt32
    let height: UInt32
    let depth: UInt32
}

enum BootArgsBuilder {
    /// sizeof(boot_args) on 32-bit ARM: 2+2+4+4+4+4 (header fields) +
    /// 24 (Boot_Video, six uint32_t) + 4 (machineType) + 4
    /// (deviceTreeP) + 4 (deviceTreeLength) + 256 (CommandLine) + 4
    /// (bootFlags) + 4 (memSizeActual) = 320.
    static let structSize = 320

    private static let revision: UInt16 = 1 // kBootArgsRevision
    /// The real iPod4,1 6.1.6 kernel enforces this exactly — confirmed
    /// directly by tracing a real panic this CPU hit ("pe_identify_machine:
    /// Epoch Mismatch") back to its cause: `ldrh r0, [r0, #2]; cmp r0, #3`
    /// reading `boot_args->Version` from the very struct this builder
    /// writes (verified byte-for-byte against a live run — every other
    /// field this function checked, `virtBase`/`physBase`/`memSize`/
    /// `topOfKernelData`/`deviceTreeP`/`deviceTreeLength`, matched exactly
    /// what was written, at their expected offsets) and panicking because
    /// this was previously `2`. `kBootArgsVersion2` is real and used by
    /// plenty of other iOS builds, but this specific kernel's own entry
    /// path demands `3`, not a value this codebase gets to pick freely.
    private static let version: UInt16 = 3
    private static let bootLineLength = 256 // BOOT_LINE_LENGTH

    static func build(
        virtBase: UInt32,
        physBase: UInt32,
        memSize: UInt32,
        topOfKernelData: UInt32,
        deviceTreeP: UInt32,
        deviceTreeLength: UInt32,
        video: BootVideoInfo? = nil,
        commandLine: String = ""
    ) -> Data {
        var data = Data(count: structSize)

        func writeU16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func writeU32(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        writeU16(revision, at: 0)
        writeU16(version, at: 2)
        writeU32(virtBase, at: 4)
        writeU32(physBase, at: 8)
        writeU32(memSize, at: 12)
        writeU32(topOfKernelData, at: 16)
        // Boot_Video at offset 20 (24 bytes). Left zeroed when no video
        // is described — an honest "no display" rather than a guessed
        // address the kernel would fault trying to draw through.
        if let video {
            writeU32(video.baseAddress, at: 20)
            writeU32(video.display, at: 24)
            writeU32(video.rowBytes, at: 28)
            writeU32(video.width, at: 32)
            writeU32(video.height, at: 36)
            writeU32(video.depth, at: 40)
        }
        writeU32(0, at: 44) // machineType — not modeled; 0 is "unknown", not a wrong guess dressed up as a real value.
        writeU32(deviceTreeP, at: 48)
        writeU32(deviceTreeLength, at: 52)
        if !commandLine.isEmpty {
            for (index, byte) in commandLine.utf8.prefix(bootLineLength - 1).enumerated() {
                data[56 + index] = byte
            }
        }
        writeU32(0, at: 312) // bootFlags
        writeU32(memSize, at: 316) // memSizeActual

        return data
    }
}
