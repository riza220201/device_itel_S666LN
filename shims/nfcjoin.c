/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * nfc_nci_nxp.so's pthread_join, bounded for an NFC controller that never answers.
 *
 * The HAL reads the controller from a TML reader thread: select() on /dev/pn553 with a
 * 2 s timeout, then read(). Stock's pn553 driver has no poll() method, so select()
 * reports the fd readable at once, and read() then sleeps in the driver until the
 * controller raises its IRQ -- the only thing that wakes that wait. When the
 * controller is silent, phNxpNciHal_MinOpen() fails, phNxpNciHal_Minclose() calls
 * phTmlNfc_Shutdown(), which clears the thread's run flag and then pthread_join()s a
 * reader that will never return from read(). The HAL's only binder thread is now
 * blocked for good: open_1_1() never returns, NfcService's enable watchdog aborts
 * com.android.nfc, and every later com.android.nfc blocks in JNI_OnLoad (getService ->
 * interfaceChain on that dead thread) until ActivityManager kills it for "failed to
 * complete startup" -- an ANR every ~15 s, forever (measured 2026-11-16: 42 h of it).
 *
 * The import of pthread_join (12 bytes) is renamed to this symbol (12 bytes) by
 * extract-files.py. For a thread that finishes within 2 s this IS pthread_join. For
 * one still running after that, a no-op SIGURG handler is installed WITHOUT
 * SA_RESTART and the thread is signalled until it exits: its interruptible wait in
 * the driver returns EINTR, read() fails, and the reader loop sees the cleared run
 * flag and returns (its error path sleeps 30 ms, posts its semaphores, re-checks the
 * flag). Then the real pthread_join. A controller that answers never takes this path.
 */

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include <android/log.h>

#define LOG_TAG "nfcjoin_shim"

static void s666ln_nfc_noop(int sig) {
    (void)sig;
}

static void s666ln_nfc_install_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = s666ln_nfc_noop; /* no SA_RESTART: the blocked read() returns EINTR */
    sigemptyset(&sa.sa_mask);
    sigaction(SIGURG, &sa, NULL);
}

/* 0 while the thread runs; ESRCH once it has exited (bionic clears the tid on exit). */
static int s666ln_nfc_alive(pthread_t t) {
    return pthread_kill(t, 0) == 0;
}

int s666ln_pjoin(pthread_t t, void** ret);

int s666ln_pjoin(pthread_t t, void** ret) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    int i;

    if (pthread_equal(t, pthread_self())) return pthread_join(t, ret); /* EDEADLK, as before */

    for (i = 0; i < 200 && s666ln_nfc_alive(t); i++) usleep(10 * 1000); /* 2 s grace */

    if (s666ln_nfc_alive(t)) {
        pthread_once(&once, s666ln_nfc_install_handler);
        __android_log_print(ANDROID_LOG_WARN, LOG_TAG,
                            "thread still running 2 s into pthread_join: interrupting it "
                            "(an NFC controller that does not answer)");
        for (i = 0; i < 600 && s666ln_nfc_alive(t); i++) { /* up to 30 s, then as stock */
            pthread_kill(t, SIGURG);
            usleep(50 * 1000);
        }
        __android_log_print(ANDROID_LOG_WARN, LOG_TAG, "thread %s after %d signal(s)",
                            s666ln_nfc_alive(t) ? "STILL running" : "exited", i);
    }
    return pthread_join(t, ret);
}
