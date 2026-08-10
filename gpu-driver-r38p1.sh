#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# OPTIONAL: upgrade the Mali userspace driver from r32p1 to r38p1.
#
# Run AFTER extract-files.sh. It replaces exactly two files in the generated
# vendor tree and touches nothing else.
#
# WHY THIS IS A SEPARATE STEP, NOT PART OF THE EXTRACTION
# -------------------------------------------------------
# Every other blob in this tree comes from our own device's stock firmware
# (itel RS4 revision 28). This one does not, so it is not silently mixed in with
# them -- it is opted into, from a named source, with a checksum.
#
# WHAT IT IS
#   itel RS4 stock ships Mali r32p1, which caps at Vulkan 1.1. r38p1 supports
#   Vulkan 1.3. MediaTek never shipped an r38p1 for MT6789 in any retail
#   firmware -- 14 firmware images and ~50 vendor trees across 7 OEMs were
#   checked, all r32p1 or r54p1. It does exist for other MediaTek platforms of
#   the same BSP generation, and those are drop-in compatible.
#
# WHY A DIFFERENT PLATFORM'S BUILD WORKS
#   Not because of the SoC, and -- correcting what this comment said until
#   2026-08-10 -- not because of the BSP generation either.
#
#   The old text called this "an Android-12-generation build, the same
#   generation as our vendor partition". It is not. The source dump's own
#   vendor/build.prop says:
#
#       ro.product.vendor.model     = BraX3
#       ro.vendor.build.fingerprint = alps/vext_k6835v1_64/k6835v1_64:14/
#                                     UP1A.231005.007/:user/release-keys
#       ro.vendor.build.version.sdk = 33        <- Android 13 vendor
#       ro.board.platform           = mt6835
#
#   So an sdk-33 vendor's driver runs on our sdk-31 vendor, while zircon's
#   sdk-33 driver did not -- and zircon (mt6886) is a far closer SoC to mt6789
#   than mt6835 is. Neither SoC nor sdk level predicts this. The project spent a
#   day proving that: five predictors proposed, five falsified.
#
#   What is actually true is narrower and is the only thing to check:
#
#     * DT_NEEDED is a strict SUBSET of what our stock r32p1 already needs, and
#     * every symbol it imports from MediaTek's libraries (libgpud, libged,
#       libgpu_aux, libgralloc_extra, libladder, libgralloctypes_mtk) exists in
#       OUR copies -- measured 0 missing, and
#     * it does not reference gpudMaliSyncEventLog, the symbol that killed
#       zircon's build here (supplying zircon's libgpud was not sufficient
#       either: SurfaceFlinger then aborted with "no suitable EGLConfig found").
#
#   Do not substitute another revision, another dump, or another device on the
#   grounds that it is "the same chipset" or "the same generation". Run the
#   symbol check. Reading the binary is the only method that has never misled
#   this project.
#
# VERIFIED ON HARDWARE (2026-08-04, itel RS4, reversible bind mount)
#   GLES: ARM, Mali-G57 MC2, OpenGL ES 3.2 v1.r38p1
#   SurfaceFlinger stable, no EGL/linker errors, no new tombstones.
#
# PROVENANCE
#   Public firmware dump of the BraxTech BraX3 (MediaTek MT6835), an ALPS-based
#   stock build. Stock firmware content, which this tree's licensing policy
#   permits, and unrelated to any third-party device tree. Redistribution of the
#   blob itself is not performed here: the file is fetched at your request and
#   checksum-verified, never committed to this repository.
#
#   The URL pins a COMMIT, not HEAD. It used to pin HEAD, which meant the 32-bit
#   half -- checked only by size -- could have changed under us without the
#   script noticing. Both halves now carry a sha256.
#
#   Stronger provenance is available if BraxTech ever publishes official BraX3
#   firmware: extract it, hash lib64/egl/mt6835/libGLES_mali.so, and if it
#   matches SHA64 below then this dump is proven faithful and the question is
#   closed outright. That check is worth doing; sourcing "some other MT6835
#   device" is not -- it would be a different build needing the full acceptance
#   test again, with no provenance gained.
set -eu

# Jiovanni-dump/alps_brax3_dump @ 0b285d77907517828989415aca878f5a6d1f6e62
URL="https://raw.githubusercontent.com/Jiovanni-dump/alps_brax3_dump/0b285d77907517828989415aca878f5a6d1f6e62/vendor"
SRC64="$URL/lib64/egl/mt6835/libGLES_mali.so"
SRC32="$URL/lib/egl/mt6835/libGLES_mali.so"
SHA64="dce51517d88ae3ef15effd0012e2076103bd155aa58555ab66fbef13a058e195"
SHA32="b522741522ecb5066d48818aa789d0d78d49ee8a6a929c01a20026e61eecbc48"
SIZE64=42397352
SIZE32=29116748

MY_DIR="${BASH_SOURCE%/*}"
[[ ! -d "${MY_DIR}" ]] && MY_DIR="${PWD}"
VENDOR_DIR="${1:-${MY_DIR}/../../../vendor/itel/S666LN/proprietary}"

if [ ! -d "${VENDOR_DIR}/vendor/lib64/egl/mt6789" ]; then
    echo "error: ${VENDOR_DIR} does not look like an extracted vendor tree." >&2
    echo "       run extract-files.sh first, or pass the proprietary/ path." >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

echo "Fetching Mali r38p1 (two ABIs, ~70 MB)..."
curl -fsSL "${SRC64}" -o "${tmp}/64.so"
curl -fsSL "${SRC32}" -o "${tmp}/32.so"

got64=$(sha256sum "${tmp}/64.so" | cut -d' ' -f1)
if [ "${got64}" != "${SHA64}" ]; then
    echo "error: 64-bit checksum mismatch" >&2
    echo "  expected ${SHA64}" >&2
    echo "  got      ${got64}" >&2
    exit 1
fi
got32=$(sha256sum "${tmp}/32.so" | cut -d' ' -f1)
if [ "${got32}" != "${SHA32}" ]; then
    echo "error: 32-bit checksum mismatch" >&2
    echo "  expected ${SHA32}" >&2
    echo "  got      ${got32}" >&2
    exit 1
fi
[ "$(stat -c%s "${tmp}/32.so")" = "${SIZE32}" ] || { echo "error: 32-bit size mismatch" >&2; exit 1; }

# Sanity-check the revision rather than trusting the URL to still point at it.
# Both halves: the 32-bit one has never had field history on this device, and
# BLUEPRINT §8b is explicit that it changes the driver for every 32-bit app.
for abi in 64 32; do
    if ! strings "${tmp}/${abi}.so" | grep -q 'r38p1-'; then
        echo "error: fetched ${abi}-bit file is not r38p1" >&2
        exit 1
    fi
done

install -m644 "${tmp}/64.so" "${VENDOR_DIR}/vendor/lib64/egl/mt6789/libGLES_mali.so"
install -m644 "${tmp}/32.so" "${VENDOR_DIR}/vendor/lib/egl/mt6789/libGLES_mali.so"

echo "Installed Mali r38p1:"
echo "  vendor/lib64/egl/mt6789/libGLES_mali.so  (${SIZE64} bytes)"
echo "  vendor/lib/egl/mt6789/libGLES_mali.so    (${SIZE32} bytes)"
echo
echo "Wipe the shader caches on first boot after switching drivers:"
echo "  rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache"
