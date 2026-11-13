/*
 * libr54shim - the three symbols Mali r54p1's userspace driver needs that this
 * device's stock (A12) vendor libraries do not export.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (C) 2026 The LineageOS Project
 *
 * WHY THIS EXISTS
 *   The vendor tree ships Mali r54p1 from Samsung SM-A175F firmware
 *   A175FXXS5CZF1 (mt6789, the same SoC): libGLES_mali sha256 0a68d23d...,
 *   Build ID 5f2913fd. Measured 2026-11-13 against stock rev 28's libged,
 *   libgpu_aux, libgralloc_extra, libgralloc_metadata, libgralloctypes_mtk and
 *   A16's libc++ (clang-r563880c), its undefined symbols leave exactly three:
 *
 *     libged      ged_fr_swd_mark_frame / ged_fr_swd_frame_destroy
 *     libgpu_aux  GpuAuxBlitAHardwareBuffer
 *
 *   (positive control: the donor's own libged + libgpu_aux define all three.)
 *
 * 🔁 ANDROID 16 (lineage-23.2): THE THREE libc++ STUBS ARE GONE.
 *   On the A13 tree this file also defined std::__1::bad_function_call's vtable
 *   and destructor and std::__1::__libcpp_verbose_abort, because no libc++ on
 *   that device exported them. A16's does (all three, 2333 exports), and it is
 *   the libc++ /vendor gets now (no VNDK, route L). This library is a DT_NEEDED
 *   of libGLES_mali, so keeping the stubs would SHADOW the real definitions --
 *   exactly what the old header warned: "if a future platform bump adds them to
 *   the system libc++, this library must be re-measured and probably deleted."
 *   Re-measured; deleted. Same reason libgpud no longer needs libc++_r54.so:
 *   its 57 libc++ imports all resolve against A16's libc++. (The Infinix X678B
 *   graft, LineageOS 23 on the same driver, landed on the same three exports.)
 *
 * WHY STUBS RATHER THAN THE REAL LIBRARIES
 *   Taking A16's libgpu_aux cascades into libdpframework and MediaTek's whole
 *   picture-quality stack at AIDL V7 -- for ONE symbol, because our A12
 *   libgpu_aux already provides 9 of the 10 GpuAux* symbols r54p1 wants. A16's
 *   libged: see the ged section below.
 *
 * 🔴 EVERY STUB LOGS. If one is ever reached in a way that matters, the log
 *   says so instead of the path silently doing nothing. Grep `r54shim`.
 */

#include <log/log.h>

#define EXPORT __attribute__((visibility("default"), used))

/*
 * ged_fr_swd_mark_frame / ged_fr_swd_frame_destroy -- MediaTek libged, A14+.
 *
 * r54p1's libGLES_mali imports both; this device's A13 libged exports neither
 * (it has only the older ged_swd_create/destroy/push_fence -- measured, 0
 * ged_fr_swd exports). Unresolved, the driver cannot be dlopen'd at all and
 * SurfaceFlinger crash-loops.
 *
 * 🔴 THIS SECTION HAS BEEN WRITTEN THREE TIMES, and each version was right
 * about something. The history is the documentation.
 *
 *   v3build2 (28/08)  stubbed these two, arguing no stub had ever been called.
 *                     False: SystemUI hit mark_frame 80 times during boot.
 *   27/08 rewrite     replaced them with atrace_async_for_track_* stubs, on a
 *                     plan to ship A16's libged instead -- which exports BOTH
 *                     ged APIs, so nothing is stubbed away, and needs only those
 *                     two atrace symbols that A13's libcutils lacks.
 *   01/09 (this)      back to stubbing the ged pair, because THE A16 libged WAS
 *                     NEVER SHIPPED. The vendor tree carries the A13 one, so the
 *                     atrace version left r54p1 with two unresolved symbols: a
 *                     build that could not boot. The plan was sound, half-landed,
 *                     and invisible because this file lived only in the build
 *                     tree and never in this repo.
 *
 * ⏭ THE A16 libged PATH (A13-era note below). On lineage-23.2 its libc++
 * blocker is gone -- /vendor's libc++ IS A16's -- but libged is also the
 * userspace half of our kernel's ged.ko ioctl ABI, and an A16 libged against
 * the 5.10 ged module is unmeasured. Not taken; the stubs stay. Was blocked on
 * exactly one thing: A16's libged needs four std::__1::basic_filebuf<char> symbols
 * (open, close, ctor, dtor) that NO libc++ on this device exports -- measured,
 * zero hits across the v31 pin, the v33 apex and /system, while libc++_r54.so
 * has 23. The precedent for fixing that already ships in this tree: libgpud.so
 * has its DT_NEEDED libc++.so rewritten to libc++_r54.so. Do the same to A16's
 * libged, restore the atrace stubs, and this whole section retires. It was not
 * done for v3 because it is a second unproven change stacked on a driver swap.
 * Its DT_NEEDED list is otherwise IDENTICAL to our A13 libged's, so it is a
 * drop-in in every other respect.
 *
 * WHAT STUBBING COSTS, measured rather than assumed:
 *   ged_fr_swd_mark_frame     A16's implementation is 28 bytes: read a debug
 *                             flag, and only if it is 1 tail-call
 *                             ged_fr_swd_thread_debug; otherwise return. With
 *                             the flag off -- the normal case -- a do-nothing
 *                             stub is BEHAVIOURALLY IDENTICAL to the real one.
 *   ged_fr_swd_frame_destroy  232 bytes, does real work, and has been called
 *                             ZERO times here (against 7,049 mark_frame hits).
 *                             Free today, but not a no-op in the real library,
 *                             so it stays LOUD.
 *
 * ⚠ mark_frame is called PER FRAME. Logging every hit cost 7,049 lines -- 47%
 * of the entire logcat buffer on the validation device -- which is why it logs
 * once. Silent afterwards is also exactly what the real implementation does.
 */
static void r54shim_log_once(volatile char *seen, const char *what)
{
    if (*seen)
        return;
    *seen = 1;
    ALOGW("r54shim: %s STUB (logged once; this one is called per frame)", what);
}

EXPORT void ged_fr_swd_mark_frame(void *a, void *b, void *c, void *d)
{
    static volatile char seen;
    (void)a; (void)b; (void)c; (void)d;
    r54shim_log_once(&seen, "ged_fr_swd_mark_frame");
}

EXPORT void ged_fr_swd_frame_destroy(void *a, void *b, void *c, void *d)
{
    (void)a; (void)b; (void)c; (void)d;
    ALOGW("r54shim: ged_fr_swd_frame_destroy STUB HIT -- this one is NOT a no-op "
          "in the real libged; re-measure before trusting it");
}

/*
 * GpuAuxBlitAHardwareBuffer. The tenth GpuAux* entry point; our A12
 * libgpu_aux provides the other nine. Returning non-zero reports failure, which
 * is the honest answer -- the blit did not happen.
 */
EXPORT int GpuAuxBlitAHardwareBuffer(void *a, void *b, void *c, void *d)
{
    (void)a; (void)b; (void)c; (void)d;
    ALOGE("r54shim: GpuAuxBlitAHardwareBuffer STUB HIT -- this path is dead, "
          "and if you are seeing this the stub is no longer safe");
    return -1;
}
