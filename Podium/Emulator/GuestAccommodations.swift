import Foundation

/// Where the emulated iPod can't be what iOS expects of its storage, the
/// few system calls that would fail because of it are answered here.
enum GuestAccommodations {
    private static let fcntlSyscall: UInt32 = 92
    private static let setProtectionClass: UInt32 = 64 // F_SETPROTECTIONCLASS

    /// iOS gives every file it creates a data-protection class —
    /// `fcntl(fd, F_SETPROTECTIONCLASS, class)` — starting with the system
    /// keybag at first boot and every app container installd sets up. A
    /// device's data volume is mounted with HFS content protection; the
    /// RAM disk here isn't (mounting it with `protect` stalls launchd right
    /// after the remount), so each such call would fail — and the keybag
    /// is never created, keybagd, securityd and lockdownd stall behind it,
    /// and so does everything that waits on the device's lock state,
    /// SpringBoard's first frame included. Nothing on the RAM disk is
    /// encrypted either way, so the calls succeed as no-ops.
    static func install(on cpu: ARMv7CPU) {
        cpu.userSupervisorCallFilter = { cpu in
            guard cpu.registers[12] == fcntlSyscall, cpu.registers[1] == setProtectionClass else { return nil }
            return 0
        }
    }
}
