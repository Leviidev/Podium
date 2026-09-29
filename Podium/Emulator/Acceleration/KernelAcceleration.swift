import Foundation

/// Stretches of the 10B500 kernel that translated code runs natively (see
/// `DBTEngine.registerSnippet`). The kernel is loaded at the address it
/// was linked for, so these don't move; each is compared with the code
/// it's meant to replace the first time it runs, and a mismatch leaves
/// the kernel's own.
enum KernelAcceleration {
    static func install(on cpu: ARMv7CPU) {
        guard let dbt = cpu.dbt else { return }
        // `mach_absolute_time`'s read of the timebase: high word, low
        // word, high word again until the two highs agree. Called tens of
        // thousands of times a second while the UI animates, and each
        // read is of a device, which translated code leaves to the
        // interpreter one instruction at a time.
        let readLoop: UInt32 = 0x8008_9608
        let expected: [UInt32] = [0xE59C_1004, 0xE59C_0000, 0xE59C_2004, 0xE151_0002, 0x1AFF_FFFA]
        var verified: Bool?
        dbt.registerSnippet(at: readLoop, thumb: false, exit: readLoop &+ UInt32(expected.count * 4)) { cpu in
            if verified == nil {
                guard let host = cpu.hostAddress(ofVirtual: readLoop, for: .execute) else { return false }
                verified = (0..<expected.count).allSatisfy { host.load(fromByteOffset: $0 * 4, as: UInt32.self) == expected[$0] }
            }
            guard verified == true else { return false }
            return readTimebase(cpu)
        }
    }

    /// r12 points at the timer: r1 = high, r0 = low, r2 = high again, and
    /// the flags of `cmp r1, r2` once they agree. No time passes during a
    /// snippet, so they do on the first try.
    static func readTimebase(_ cpu: ARMv7CPU) -> Bool {
        let r = cpu.registers
        let timer = r[12]
        guard let high = try? cpu.readData(timer &+ 4, width: 4), let low = try? cpu.readData(timer, width: 4),
              let again = try? cpu.readData(timer &+ 4, width: 4), again == high else { return false }
        r[1] = high
        r[0] = low
        r[2] = again
        cpu.cpsr.rawValue = (cpu.cpsr.rawValue & 0x0FFF_FFFF) | 0x6000_0000
        return true
    }
}
