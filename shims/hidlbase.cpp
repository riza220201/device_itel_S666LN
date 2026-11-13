/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pre-A12 hidl-gen output (the goodix fingerprint interface library) registers its
 * Bn constructors through details::getBnConstructorMap() -- which Android 16 still
 * has -- but its inlined toBinder<> helpers read the map through the old DATA
 * symbol details::gBnConstructorMap, which Android 16's libhidlbase no longer
 * exports. Without the symbol the library does not load.
 *
 * The symbol must name the SAME map libhidlbase uses, not a second one. A first
 * version of this shim owned a map and interposed getBnConstructorMap(); on the
 * device that split in two: libhidlbase, loaded with the service, bound to the
 * shim, while the dlopen'ed goodix library (whose own load group reaches
 * libhidlbase first; bionic's global group is the executable alone) registered
 * into libhidlbase's map, and registerAsService aborted with "getBnConstructorMap
 * returned null" (first A16 boot, 2026-11-13).
 *
 * So the old name is exported as a GNU IFUNC whose resolver returns the address
 * of libhidlbase's real map. bionic resolves EVERY relocation against an IFUNC by
 * calling its resolver (linker_soinfo.h resolve_symbol_address, used for symbol
 * relocations in linker_relocate.cpp), so the goodix library's GLOB_DAT entry
 * receives that address. No interposition: one map in the process.
 *
 * The resolver runs while the REFERENCING library is relocated and calls into
 * libhidlbase, so this shim must already be loaded and relocated by then: it is
 * NEEDED by the fingerprint service executable (extract-files.py), i.e. linked at
 * process start, long before the HAL module is dlopen'ed. ConcurrentMap's class
 * body is identical in the A12 (v31) and A16 headers, so the inlined readers agree
 * with libhidlbase on its layout.
 */

#include <hidl/Static.h>

using s666ln_any_fn = void (*)();

extern "C" s666ln_any_fn s666ln_gbn_constructor_map_resolver() {
    return reinterpret_cast<s666ln_any_fn>(&android::hardware::details::getBnConstructorMap());
}

extern "C" void s666ln_gbn_constructor_map() __attribute__((ifunc("s666ln_gbn_constructor_map_resolver")))
        asm("_ZN7android8hardware7details17gBnConstructorMapE");
