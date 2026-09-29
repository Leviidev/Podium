// Guest-side: flushes the file system cache to the root disk every few
// seconds. Podium keeps the guest's root file system in a file on the host
// that the guest writes straight into, and the app's Power Off stops the
// machine at once, like pulling a battery — what the kernel still held in
// its buffer cache would be lost, and an unjournaled volume left
// inconsistent. Run by launchd (com.podium.syncd).
#include <unistd.h>

int main(void) {
    for (;;) {
        sleep(3);
        sync();
    }
    return 0;
}
