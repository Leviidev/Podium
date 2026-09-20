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
enum BootArgsBuilder {
    /// sizeof(boot_args) on 32-bit ARM: 2+2+4+4+4+4 (header fields) +
    /// 24 (Boot_Video, six uint32_t) + 4 (machineType) + 4
    /// (deviceTreeP) + 4 (deviceTreeLength) + 256 (CommandLine) + 4
    /// (bootFlags) + 4 (memSizeActual) = 320.
    static let structSize = 320

    private static let revision: UInt16 = 1 // kBootArgsRevision
    private static let version: UInt16 = 2 // kBootArgsVersion2 (adds bootFlags)
    private static let bootLineLength = 256 // BOOT_LINE_LENGTH

    static func build(
        virtBase: UInt32,
        physBase: UInt32,
        memSize: UInt32,
        topOfKernelData: UInt32,
        deviceTreeP: UInt32,
        deviceTreeLength: UInt32,
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
        // Boot_Video at offset 20 (24 bytes) is left zeroed: no
        // framebuffer to describe yet (Milestone 5 territory).
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
