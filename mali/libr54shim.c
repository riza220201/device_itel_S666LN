/*
 * libr54shim - the six symbols Mali r54p1's userspace driver needs that this
 * device's Android 13 stack does not export.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (C) 2026 The LineageOS Project
 *
 * WHY THIS EXISTS
 *   The vendor tree ships Mali r54p1, lifted from Samsung SM-A175F firmware
 *   (mt6789 -- the same SoC). Its userspace driver resolves cleanly against our
 *   A12 vendor stack except for six symbols, measured 2026-08-27:
 *
 *     libc++      std::__1::bad_function_call::~bad_function_call()
 *                 vtable for std::__1::bad_function_call
 *                 std::__1::__libcpp_verbose_abort(char const*, ...)
 *     libgpu_aux  GpuAuxBlitAHardwareBuffer
 *     libged      ged_fr_swd_mark_frame / ged_fr_swd_frame_destroy
 *
 *   Every one of them is absent from EVERY libc++ on this device -- the v31
 *   pin, the v33 apex and /system all export 2162 symbols and none of these;
 *   the A16 libc++ exports 2344 and has them. They are Android 14+ additions.
 *
 * WHY STUBS RATHER THAN THE REAL LIBRARIES
 *   Taking A16's libged costs a newer libcutils (it needs
 *   atrace_async_for_track_begin_body, absent before A14). Taking A16's
 *   libgpu_aux cascades into libdpframework and MediaTek's whole picture-quality
 *   stack at AIDL V7 -- for ONE symbol, because our A12 libgpu_aux already
 *   provides 9 of the 10 GpuAux* symbols r54p1 wants. Stubbing avoids both.
 *
 *   The libc++ symbols are handled DIFFERENTLY and deliberately: libgpud gets a
 *   private A16 libc++ (libc++_r54.so) instead, because ITS libc++ needs are
 *   iostreams -- real constructed objects whose vtables cannot be faked. Only
 *   bad_function_call is stubbed here, and it is an error-path type: reaching it
 *   means std::function was invoked while empty, which is a bug either way.
 *
 * 🔴 EVERY STUB LOGS. On the validation boot, zero of them were ever called --
 *   which is the only reason stubbing is defensible. If that ever changes, the
 *   log says so instead of the path silently doing nothing. Grep `r54shim`.
 *
 * ⚠ This library exports libc++ symbol NAMES. That is safe only because nothing
 *   else on this device defines them -- it shadows no real implementation. If a
 *   future platform bump adds them to the system libc++, this library must be
 *   re-measured and probably deleted.
 */

#include <log/log.h>

#define EXPORT __attribute__((visibility("default"), used))

/* std::__1::bad_function_call -- vtable + destructor. Error-path type. */
EXPORT void *_ZTVNSt3__117bad_function_callE[4] = { 0, 0, 0, 0 };
EXPORT void _ZNSt3__117bad_function_callD1Ev(void *self)
{
    (void)self;
    ALOGW("r54shim: bad_function_call dtor STUB");
}

/*
 * std::__1::__libcpp_verbose_abort(char const*, ...). libc++ calls this on a
 * hardened-mode contract violation, so reaching it is a real defect. Make it
 * loud and stop, rather than returning into undefined behaviour.
 */
EXPORT void _ZNSt3__122__libcpp_verbose_abortEPKcz(const char *fmt, ...)
{
    ALOGE("r54shim: __libcpp_verbose_abort: %s", fmt ? fmt : "(null)");
    __builtin_trap();
}

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
 * ⏭ THE A16 libged PATH IS STILL THE RIGHT ONE, and it is blocked on exactly
 * one thing: A16's libged needs four std::__1::basic_filebuf<char> symbols
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
