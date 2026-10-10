# iOS 7.1.2 (iPhone 4) Port — Research Notes

Status of the groundwork toward running iOS 7.1.2 on the iPhone 4 (iPhone3,1 /
n90ap) in Podium. The iPhone 4 uses the **same A4 (S5L8930X) SoC** as the
iPod touch 4, so the platform layer, memory layout, and most device emulation
carry over; the kernel, dyld shared cache, and root filesystem are all new.

## Firmware and keys (all verified by direct decryption)

- IPSW: `iPhone3,1_7.1.2_11D257_Restore.ipsw` (1,204,958,925 bytes), from
  Apple's CDN via `https://api.ipsw.me/v4/device/iPhone3,1`.
- Keys from TheAppleWiki "Keys:Sochi 11D257 (iPhone3,1)".
- **kernelcache.release.n90**: AES‑256‑CBC (key/IV from the wiki) →
  `complzss` header → Apple LZSS → **valid Mach-O arm_v7**, embedded
  Adler‑32 matches (`0xbb79d960`). Same `AppleLZSS` format as the 10B500
  kernelcache, so `KernelcacheExtractor`/`AppleLZSS` work unchanged.
- **DeviceTree.n90ap.img3**: key/IV verified — plaintext contains
  `compatible`, `N90AP`, `iPhone3,1`, `AppleARM`.
- **058-4520-010.dmg** (rootfs): `encrcdsa` (36-byte key: 16 AES + 20
  HMAC‑SHA1). Each 512-byte block encrypts with IV = first 16 bytes of
  HMAC‑SHA1(hmacKey, ..., blockNumber) (4-byte big-endian index). Decrypts
  to a UDIF image whose `Apple_HFS` mish table expands to a valid
  **HFSJ volume** (1,605,410,816 bytes; `H+` volume header at +1024).
  Same structure `UDIFDiskImage`/`EncryptedDiskImageDecryptor` already
  handle — only the key differs.

## 11D257 kernel landmarks (symbols retained in the kernelcache)

MACRO: `LC_SYMTAB` with 4139 symbols survives relink. Kernel links at
**0x80001000 in __TEXT**, exactly like 10B500 — `GuestMemoryLayout`,
`MachOLoader`, `KernelBootstrap` need no layout changes for that.

| Landmark | 11D257 address | Notes |
| --- | --- | --- |
| `_panic` | `0x80004A9C` (Thumb) | format in r0 (moved to r5 early; `mov r0, r5` at `0x80004ABE`) |
| `_boot` (shutdown/restart entry, howto in r1, RB_HALT = bit 3) | `0x80056808` (Thumb) | same role as 10B500's `0x801D_F6E8` |
| `_kernel_pmap` | `0x8032E01C` | needed by `GuestDiskBridge.kernelPhysicalAddress` |
| `_mach_absolute_time` read-loop | `0x8002023C` (ARM) | `ldr r2,[r3,#0x5c]` / `ldr r0,[r3,#0x58]` / `cmp r1,r2` / `bne -0x18` / `bx lr` — same instruction pattern as 10B500's snippet; r12→`mrc` … `ldr r3,[r12,#0x4DC]` |

Note: `mach_absolute_time` is a Thumb tail-branch into a branch-island
pool; the reachable body (through `vm_switch` trampoline style islands at
`0x802D704C`) is the ARM loop at `0x8002023C`. The snippet must be
registered at the loop, not at the symbol.

## Entry-point check (resolved — boot path is compatible)

The 11D257 kernel's entry (`0x8001D084`) starts with
`mov r1,#0` + `ldr lr, [pc, lr]` literal-load pairs (kernel caches
`gPhysBase`/`gPhysSize` style globals), then `cpsid if` → `mcr` icache
flush → `mrc/mcr` builds SMP+I-cache bits, and then reads
`boot_args` **exactly like 10B500**:
`ldr r8,[r0,#0x8]` (memSize), `ldr r9,[r0,#4]` (physBase),
`ldr r10,[r0,#0xc]` (memSize again?). No rebasing or entry stub
workaround is needed from the emulator: `KernelBootstrap`'s current
`initialRegisters` (pc=`0x40001000`+base, r0=`boot_args` physical)
work as-is.

## Still to be located in 11D257 (before boot)

1. `shared_region_map_and_slide_np` (mach syscall 438) — `EmulationSession`
   uses its entry to learn the dyld shared-cache slide for
   `QuartzCoreAcceleration`. No retaining symbol; needs sysent structural
   discovery (the 20-byte-record scan so far was too permissive) or code
   signature matching against the xnu-2422 source build.
2. md0 device strategy/raw/ioctl addresses plus kernel SHA‑256 for
   `GuestDiskBridge` (same approach as 10B500: patch verified kernel,
   hash-gate it).
3. Panic-entry register map for a second 11D257 `_panic` tail site
   (10B500 used two breakpoint PCs).
4. `QuartzCoreAcceleration` function addresses + byte signatures in the
   **iOS 7.1.2 dyld shared cache** (iOS 7 moved several compositor loops
   into CoreAnimation) — requires extracting the shared cache from the
   rootfs's dyld cache and re-deriving each span/loop address and code.
5. `RootFilesystemRecipe` differences for iOS 7:
   `backboardd` environment keys still apply; `keybagd` path same;
   `lockdownd` hactivation byte site must be re-derived (different
   binary); `BKDataMigratorLastSystemVersion` should become `11D257`;
   preload/font trim paths need re-validating against the 1.6 GB image.
6. Device-tree/`S5L8930XPlatform` diffs between n81ap and n90ap (font
   panel: iPhone 4 is 640×960 — matches; I²C bus numbering, GPIO lines,
   and the CDMA/DART layout may differ) — diff the two device trees to
   confirm what unchanged base addresses are correct.

## Verified reusable as-is

- Memory map (`0x40000000` DRAM base, kernel linear map at `0x80000000`).
- Boot args v3 structure and string (`rd=md0 ...` — same XNU).
- `IMG3Container` parsing, `AppleLZSS`, `UDIFDiskImage` chunk types
  (type 0x80000005 chunks in this DMG are zlib streams).
- CPU/DBT engine, interpreter, and the general session plumbing.

Recommended order of implementation: (3) panic map → (1) shared-region
entry → md0 bridge (2) → device-tree diff (6) → recipe (5) →
QuartzCoreAcceleration (4), booting with the RAM-disk path first (the
8 GiB md0 path is optional for a first lock screen).
