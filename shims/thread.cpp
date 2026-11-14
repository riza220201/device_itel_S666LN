/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Android 12's Thread::run() kept the thread object alive with `mHoldSelf = this;`
 * -- an sp<T>(T*) construction, which is also how an object that NOTHING owns yet
 * receives its first strong reference. Android 16's does
 * `mHoldSelf = sp<Thread>::fromExisting(this);`, and fromExisting aborts
 * ("incStrongRequireStrong() called on ... which isn't already owned") unless an
 * sp<> already holds the object.
 *
 * MediaTek's camera stack calls run() from inside its own constructors
 * (NSCam::v3::AppStreamMgr::CallbackHandler::CallbackHelper): legal on A12, a
 * SIGABRT in camerahalserver on EVERY camera open on A16 (measured 2026-11-14,
 * "error while setting up the session" in the camera app).
 *
 * The stock blobs' import of android::Thread::run(char const*, int, unsigned long)
 * (_ZN7android6Thread3runEPKcim, 28 bytes) is renamed to this symbol (28 bytes) by
 * extract-files.py, so only they get the A12 contract; every other caller in the
 * process keeps libutils' own. The rename, not interposition: the camera libraries
 * are dlopen'ed, and bionic resolves a dlopen'ed library through its own load group
 * (see hidlbase.cpp), where libutils comes first.
 *
 * For an object that is already owned this IS Thread::run. For one that is not, it
 * takes the first strong reference itself -- what A12's `mHoldSelf = this` did --
 * runs the real A16 Thread::run (which now finds the object owned), and drops its
 * own reference again, leaving mHoldSelf the only owner, exactly as on A12. On a
 * failed start A16 clears mHoldSelf and the object is released, as A12 did too.
 */

#include <utils/Thread.h>

namespace {
// libutils/RefBase.cpp INITIAL_STRONG_VALUE: the strong count of an object that no
// sp<> has ever held. Not in any header.
constexpr int32_t kInitialStrongValue = 1 << 28;
}  // namespace

extern "C" android::status_t s666ln_a12_thread_run_compat(android::Thread* self, const char* name,
                                                          int32_t priority, size_t stack) {
    const bool adopt = self->getStrongCount() == kInitialStrongValue;
    if (adopt) self->incStrong(self);
    const android::status_t ret = self->Thread::run(name, priority, stack);
    if (adopt) self->decStrong(self);
    return ret;
}
