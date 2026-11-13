/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * One HIDL Bn-constructor map for the whole process, reachable both ways:
 *  - as the data symbol details::gBnConstructorMap, which pre-A12 hidl-gen output
 *    (the goodix fingerprint interface library) inlines ConcurrentMap::set() into;
 *  - through details::getBnConstructorMap(), which this library exports too. Loaded
 *    ahead of libhidlbase (patchelf --add-needed prepends), it interposes
 *    libhidlbase's own calls, which go through the PLT in A16's libhidlbase.
 * ConcurrentMap's class body is identical in the A12 (v31) and A16 headers, so
 * the inlined code and libhidlbase agree on the layout.
 *
 * The storage is constructed on first use, from whichever comes first: this
 * library's constructor (run before any library that NEEDs it, e.g. the goodix
 * library), or an earlier getBnConstructorMap() call. It is never destroyed, like
 * libhidlbase's own maps.
 */

#include <new>

#include <hidl/Static.h>

namespace android::hardware::details {

alignas(BnConstructorMap) unsigned char gBnConstructorMapStorage[sizeof(BnConstructorMap)]
        asm("_ZN7android8hardware7details17gBnConstructorMapE");

BnConstructorMap& getBnConstructorMap() {
    static BnConstructorMap* map = new (gBnConstructorMapStorage) BnConstructorMap();
    return *map;
}

}  // namespace android::hardware::details

__attribute__((constructor(101))) static void s666ln_construct_bn_map() {
    android::hardware::details::getBnConstructorMap();
}
