// Guest-side helper for capturing iOS's first-boot state. Installed only
// in a capture build of the root filesystem, as a launchd job: waits for
// first boot's one-time work to finish, stores the stand-in activation
// identity, then syncs and halts, so the RAM disk the host dumps
// afterwards is a cleanly unmounted volume.
//
// The activation identity is the keypair lockdownd uses for activation,
// kept in the keychain (access group `lockdown-identities`, labelled
// `com.apple.lockdown.identity.activation`) together with the device
// certificate activation issues. Until one is there, lockdownd generates
// a fresh 1024-bit RSA keypair at every start — billions of emulated
// instructions each boot. A device can't be activated here, so this
// stores what activation would have: the key, with a self-signed
// certificate standing in for Apple's, built into the helper by build.sh
// (identity.h). It's added the way lockdownd adds one itself: an identity
// from SecIdentityCreate, passed to SecItemAdd as its value reference.
#include <stdlib.h>
#include <syslog.h>
#include <unistd.h>

#include "identity.h"

#define RB_HALT 0x08

int reboot(int howto);

typedef const void *CFTypeRef;
typedef const void *CFAllocatorRef;
typedef const void *CFDictionaryRef;
typedef const void *CFDataRef;
typedef const void *CFStringRef;
typedef long CFIndex;
typedef int OSStatus;
typedef struct { CFIndex version; const void *retain, *release, *copyDescription, *equal, *hash; } CFDictionaryKeyCallBacks;
typedef struct { CFIndex version; const void *retain, *release, *copyDescription, *equal; } CFDictionaryValueCallBacks;

extern const CFAllocatorRef kCFAllocatorDefault;
extern const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
CFDataRef CFDataCreate(CFAllocatorRef, const unsigned char *, CFIndex);
CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, unsigned encoding);
CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void **, const void **, CFIndex, const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *);
void CFRelease(CFTypeRef);

extern const CFStringRef kSecClass, kSecClassIdentity, kSecValueRef, kSecAttrAccessGroup, kSecAttrLabel;
CFTypeRef SecCertificateCreateWithData(CFAllocatorRef, CFDataRef);
CFTypeRef SecKeyCreateRSAPrivateKey(CFAllocatorRef, const unsigned char *, CFIndex, int encoding);
CFTypeRef SecIdentityCreate(CFAllocatorRef, CFTypeRef certificate, CFTypeRef privateKey);
OSStatus SecItemAdd(CFDictionaryRef, CFTypeRef *);
OSStatus SecItemDelete(CFDictionaryRef);

#define kCFStringEncodingUTF8 0x08000100
#define kSecKeyEncodingPkcs1 1
#define errSecDuplicateItem (-25299)

static OSStatus store_activation_identity(void) {
    CFDataRef certificateData = CFDataCreate(kCFAllocatorDefault, activation_certificate_der, sizeof activation_certificate_der);
    CFTypeRef certificate = SecCertificateCreateWithData(kCFAllocatorDefault, certificateData);
    CFTypeRef key = SecKeyCreateRSAPrivateKey(kCFAllocatorDefault, activation_key_der, sizeof activation_key_der, kSecKeyEncodingPkcs1);
    if (!certificate || !key) {
        syslog(LOG_ERR, "podium_first_boot_capture: bad identity (certificate %p, key %p)", certificate, key);
        return -1;
    }
    CFTypeRef identity = SecIdentityCreate(kCFAllocatorDefault, certificate, key);
    CFStringRef group = CFStringCreateWithCString(kCFAllocatorDefault, "lockdown-identities", kCFStringEncodingUTF8);
    CFStringRef label = CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.lockdown.identity.activation", kCFStringEncodingUTF8);

    const void *queryKeys[] = { kSecClass, kSecAttrAccessGroup, kSecAttrLabel };
    const void *queryValues[] = { kSecClassIdentity, group, label };
    CFDictionaryRef query = CFDictionaryCreate(kCFAllocatorDefault, queryKeys, queryValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecItemDelete(query);

    const void *keys[] = { kSecValueRef, kSecAttrAccessGroup, kSecAttrLabel };
    const void *values[] = { identity, group, label };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = SecItemAdd(attributes, NULL);
    CFRelease(attributes);
    CFRelease(query);
    CFRelease(label);
    CFRelease(group);
    CFRelease(identity);
    CFRelease(key);
    CFRelease(certificate);
    CFRelease(certificateData);
    return status;
}

int main(int argc, char **argv) {
    unsigned seconds = argc > 1 ? (unsigned)atoi(argv[1]) : 150;
    sleep(seconds);
    // securityd and the system keybag may still be coming up: retry.
    OSStatus status = -1;
    for (int attempt = 0; attempt < 30; attempt++) {
        status = store_activation_identity();
        syslog(LOG_ERR, "podium_first_boot_capture: storing activation identity: %d", (int)status);
        if (status == 0 || status == errSecDuplicateItem) break;
        sleep(5);
    }
    sync();
    sleep(2);
    sync();
    syslog(LOG_ERR, "podium_first_boot_capture: halting");
    reboot(RB_HALT);
    return 0;
}
