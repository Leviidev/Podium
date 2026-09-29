#ifndef PODIUM_JIT_H
#define PODIUM_JIT_H

#include <stddef.h>
#include <stdbool.h>

/// How `podium_jit_allocate` got its memory, for the log.
typedef enum {
    PodiumJITModeNone = 0,
    /// One read-write-execute `MAP_JIT` mapping (a debugger attached on
    /// iOS before TXM).
    PodiumJITModeRWX = 1,
    /// An executable region the attached debugger (StikDebug's JIT26
    /// script) prepared, written through a second, read-write mapping of
    /// the same memory (iOS 26 with TXM).
    PodiumJITModeDualMapped = 2,
} PodiumJITMode;

/// Whether a debugger has attached (CS_DEBUGGED), which is what lets iOS
/// hand out memory that can be both written and run.
bool podium_jit_debugger_attached(void);

/// Allocates `size` bytes for translated code, once per process: never
/// call it again after it succeeds (every extra request is another round
/// trip to the debugger). Returns where the code runs from and stores
/// where to write it (the same address in RWX mode) in `writable`; NULL
/// if no mode worked.
void *podium_jit_allocate(size_t size, void **writable, PodiumJITMode *mode);

#endif
