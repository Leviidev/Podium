// Guest-side first-boot helper for the reference rootfs. A restored
// device gets /private/var/keybags/systembag.kb from the restore
// ramdisk; this rootfs comes straight from the IPSW without one, and
// keybagd treats a missing system keybag as fatal ("tears in rain") and
// reboots into recovery. Installed as keybagd's launchd program: creates
// the system keybag through MobileKeyBag (the same call a restore makes)
// when there is none, then execs keybagd itself so it keeps keybagd's
// launchd job and Mach service check-in.
#include <dlfcn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*MKBKeyBagCreateSystemFunction)(void *passcode, const char *volume);

int main(int argc, char **argv) {
    struct stat info;
    if (stat("/private/var/keybags/systembag.kb", &info) != 0) {
        mkdir("/private/var/keybags", 0700);
        void *framework = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_NOW);
        MKBKeyBagCreateSystemFunction create = framework ? (MKBKeyBagCreateSystemFunction)dlsym(framework, "MKBKeyBagCreateSystem") : 0;
        int result = create ? create(0, "/private/var") : -1000;
        fprintf(stderr, "keybag_bootstrap: MKBKeyBagCreateSystem -> %d\n", result);
    }
    if (argc > 1) execv(argv[1], argv + 1);
    return 1;
}
