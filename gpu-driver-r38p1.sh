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
#   The Mali UMD binds to the MediaTek *BSP generation*, not to the SoC. This
#   file is an Android-12-generation build, the same generation as our vendor
#   partition, so its dependency set is a strict SUBSET of what our stock r32p1
#   already needs, and every symbol it imports from MediaTek's libraries
#   (libgpud, libged, libgpu_aux, libgralloc_extra, libladder,
#   libgralloctypes_mtk) is present in ours. Verified: 0 missing symbols.
#
#   An Android-13-generation build does NOT work, even from a closer SoC. It
#   needs gpudMaliSyncEventLog from an A13 libgpud, which our A12 vendor lacks;
#   supplying that library was not sufficient either (SurfaceFlinger then aborts
#   with "no suitable EGLConfig found"). Generation is the constraint. Do not
#   substitute a newer revision without re-running the symbol check.
#
# VERIFIED ON HARDWARE (2026-08-04, itel RS4, reversible bind mount)
#   GLES: ARM, Mali-G57 MC2, OpenGL ES 3.2 v1.r38p1
#   SurfaceFlinger stable, no EGL/linker errors, no new tombstones.
#
# PROVENANCE
#   Public firmware dump of a MediaTek ALPS reference build. Stock firmware
#   content, which this tree's licensing policy permits. Redistribution of the
#   blob itself is not performed here: the file is fetched at your request and
#   checksum-verified, never committed to this repository.
set -eu

URL="https://raw.githubusercontent.com/Jiovanni-dump/alps_brax3_dump/HEAD/vendor"
SRC64="$URL/lib64/egl/mt6835/libGLES_mali.so"
SRC32="$URL/lib/egl/mt6835/libGLES_mali.so"
SHA64="dce51517d88ae3ef15effd0012e2076103bd155aa58555ab66fbef13a058e195"
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
[ "$(stat -c%s "${tmp}/32.so")" = "${SIZE32}" ] || { echo "error: 32-bit size mismatch" >&2; exit 1; }

# Sanity-check the revision rather than trusting the URL to still point at it.
if ! strings "${tmp}/64.so" | grep -q 'r38p1-'; then
    echo "error: fetched file is not r38p1" >&2
    exit 1
fi

install -m644 "${tmp}/64.so" "${VENDOR_DIR}/vendor/lib64/egl/mt6789/libGLES_mali.so"
install -m644 "${tmp}/32.so" "${VENDOR_DIR}/vendor/lib/egl/mt6789/libGLES_mali.so"

echo "Installed Mali r38p1:"
echo "  vendor/lib64/egl/mt6789/libGLES_mali.so  (${SIZE64} bytes)"
echo "  vendor/lib/egl/mt6789/libGLES_mali.so    (${SIZE32} bytes)"
echo
echo "Wipe the shader caches on first boot after switching drivers:"
echo "  rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache"
