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
 *     libged      ged_fr_swd_mark_frame / ged_fr_swd_frame_destroy
 *     libgpu_aux  GpuAuxBlitAHardwareBuffer
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
 * libged frame-swap-detect. FPS/frame tracking telemetry on newer MediaTek
 * kernels; our A12 libged has no such entry points and the ged kernel module is
 * the r32p1-era one, so there is nothing for them to talk to.
 */
EXPORT void ged_fr_swd_mark_frame(void *a, int b, int c)
{
    (void)a; (void)b; (void)c;
    ALOGW("r54shim: ged_fr_swd_mark_frame STUB");
}

EXPORT void ged_fr_swd_frame_destroy(void *a)
{
    (void)a;
    ALOGW("r54shim: ged_fr_swd_frame_destroy STUB");
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
