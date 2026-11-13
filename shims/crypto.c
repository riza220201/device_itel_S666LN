/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * BoringSSL names the Android 12 hostapd/wpa_supplicant import that Android 16's
 * libcrypto no longer exports. Neither BoringSSL header is included: stack.h
 * defines sk_* as macros and bytestring.h defines CBS_init inline, and both would
 * collide with the exported functions below.
 */

#include <stddef.h>
#include <stdint.h>

/* OPENSSL_STACK is opaque to callers; only the pointer passes through. */
void *OPENSSL_sk_dup(const void *sk);

void *sk_dup(const void *sk) {
    return OPENSSL_sk_dup(sk);
}

/* struct cbs_st is { const uint8_t *data; size_t len; } in both generations
 * (bytestring.h:40), and CBS_init has always been exactly these two stores. */
struct cbs_st {
    const uint8_t *data;
    size_t len;
};

void CBS_init(struct cbs_st *cbs, const uint8_t *data, size_t len) {
    cbs->data = data;
    cbs->len = len;
}
