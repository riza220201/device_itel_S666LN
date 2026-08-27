#!/bin/bash
#
# mali-r54p1-prepare.sh <samsung-vendor-dir> <vendor-tree-proprietary-dir>
#
# Regenerate the Mali r54p1 blob set from Samsung SM-A175F firmware.
#
# WHY THIS SCRIPT EXISTS RATHER THAN JUST COMMITTING THE BINARIES
#   Three of these files are patchelf-edited. A hand-edited binary in a repo is
#   unreproducible by anyone else, which is the exact defect BLUEPRINT §1 exists
#   to end. This script is the recipe: given the same firmware it produces the
#   same bytes, and it prints hashes so that can be checked.
#
# SOURCE, and why this firmware
#   Samsung Galaxy A17 4G, SM-A175F, ro.board.platform=mt6789 -- the SAME SoC as
#   the itel RS4, so the MediaTek-side integration (libgpud, libmtk_mali_user)
#   is the one built for this silicon rather than a near relative.
#   Downloaded by the operator from samfw.com and extracted locally; not a
#   third-party re-upload. Same provenance class as the r38p1 driver this
#   replaces (Samsung XCover7, documented in .build/malibuild/*/SOURCE.txt).
#
# WHAT EACH EDIT IS FOR  (all measured 2026-08-27, see notes/JOURNAL.md)
#   libGLES_mali    --add-needed libr54shim.so
#                   pulls in the six symbols A13 does not export. The shim is
#                   built from source in device/itel/S666LN/mali.
#   libgpud         --replace-needed libc++.so libc++_r54.so
#                   libgpud needs SIX libc++ symbols we lack, five of them
#                   iostreams (filebuf, istringstream) -- real constructed
#                   objects whose vtables cannot be stubbed. So it gets a
#                   private A16 libc++ instead.
#   libc++_r54      --set-soname libc++_r54.so
#                   the A16 libc++ under a name that cannot collide with the
#                   platform's. Two C++ runtimes end up in one process, which is
#                   safe here for a MEASURED reason: the libGLES_mali -> libgpud
#                   boundary is 231 symbols and ZERO are C++-mangled. It is pure
#                   C, so no C++ ABI ever crosses between the runtimes.
#
# 🔴 If a future driver revision makes that boundary C++, this whole approach is
#    void. Re-measure before assuming it still holds:
#      readelf --dyn-syms -W libGLES_mali.so | grep ' UND ' | grep '^_Z.*gpud'
set -uo pipefail

SRC="${1:-}"
DST="${2:-}"
PATCHELF="${PATCHELF:-patchelf}"

[ -d "${SRC}" ] || { echo "usage: $0 <samsung-vendor-dir> <vendor-proprietary-dir>" >&2; exit 2; }
[ -d "${DST}" ] || { echo "!! no destination: ${DST}" >&2; exit 2; }
command -v "${PATCHELF}" >/dev/null 2>&1 || {
    echo "!! patchelf not found. Set PATCHELF=/path/to/patchelf" >&2
    echo "   (no root needed: python3 -m venv v && v/bin/pip install patchelf)" >&2
    exit 2; }

# Positive control: refuse to run against a directory that is not this firmware.
rev="$(strings "${SRC}/lib64/egl/mt6789/libGLES_mali.so" 2>/dev/null | grep -oE 'r54p1-[0-9a-f]+' | head -1)"
[ "${rev}" = "r54p1-12eac0" ] || {
    echo "!! ${SRC} does not contain Mali r54p1-12eac0 (found: '${rev:-nothing}')" >&2
    exit 2; }
echo "source firmware carries ${rev}"

emit() { printf '  %-52s %12s  %s\n' "$1" "$2" "$3"; }

for abi in lib64 lib; do
    out="${DST}/vendor/${abi}"
    mkdir -p "${out}/egl/mt6789"

    # --- the driver -------------------------------------------------------
    cp "${SRC}/${abi}/egl/mt6789/libGLES_mali.so" "${out}/egl/mt6789/libGLES_mali.so"
    "${PATCHELF}" --add-needed libr54shim.so "${out}/egl/mt6789/libGLES_mali.so" || exit 3

    # --- libgpud, on a private libc++ --------------------------------------
    cp "${SRC}/${abi}/libgpud.so" "${out}/libgpud.so"
    "${PATCHELF}" --replace-needed libc++.so libc++_r54.so "${out}/libgpud.so" || exit 3

    # --- that private libc++ ------------------------------------------------
    cp "${SRC}/${abi}/libc++.so" "${out}/libc++_r54.so"
    "${PATCHELF}" --set-soname libc++_r54.so "${out}/libc++_r54.so" || exit 3

    # --- carried unmodified --------------------------------------------------
    cp "${SRC}/${abi}/mt6789/libmtk_mali_user.so" "${out}/libmtk_mali_user.so"
    # 🔴 android.hardware.graphics.allocator-V2-ndk.so is DELIBERATELY NOT copied.
    # soong already generates FOUR modules of that exact name on this branch (the
    # unfrozen `current` AIDL becomes V2), so a prebuilt would be a duplicate
    # module name -- and that fires even when neither side is requested. The
    # platform's own .vendor variant is used instead, via device.mk. That also
    # 🔴 common-V6-ndk IS still required, and dropping it cost a build: libgpud
    # DT_NEEDEDs it DIRECTLY, not only through Samsung's allocator. The symbols
    # resolved without it (from the platform's V4), so a symbol-level closure
    # check passed -- but the LINKER needs the named file to exist regardless of
    # where the symbols come from. tools/vendor-deps-check.sh caught it:
    #   2 android.hardware.graphics.common-V6-ndk.so
    # Its module name is free (soong generates V1..V4 here, never V6).
    for l in android.hardware.graphics.common-V6-ndk.so \
             vendor.mediatek.hardware.graphics-V1-ndk.so; do
        cp "${SRC}/${abi}/${l}" "${out}/${l}"
    done

    echo "== ${abi}"
    for f in egl/mt6789/libGLES_mali.so libgpud.so libc++_r54.so libmtk_mali_user.so \
             android.hardware.graphics.common-V6-ndk.so \
             vendor.mediatek.hardware.graphics-V1-ndk.so; do
        emit "${f}" "$(stat -c %s "${out}/${f}")" "$(sha256sum "${out}/${f}" | cut -c1-16)"
    done

    # Verify the edits actually took, rather than trusting patchelf's exit code.
    n=$(readelf -d "${out}/egl/mt6789/libGLES_mali.so" | grep -c 'libr54shim\.so')
    m=$(readelf -d "${out}/libgpud.so" | grep -c 'libc++_r54\.so')
    o=$(readelf -d "${out}/libgpud.so" | grep -cE 'Shared library: \[libc\+\+\.so\]')
    s=$(readelf -d "${out}/libc++_r54.so" | grep -c 'soname: \[libc++_r54.so\]')
    echo "   checks: driver->shim=${n} gpud->privatelibc++=${m} gpud->plain libc++=${o} (must be 0) soname=${s}"
    [ "${n}" = 1 ] && [ "${m}" = 1 ] && [ "${o}" = 0 ] && [ "${s}" = 1 ] || {
        echo "!! ${abi}: patchelf edits did not verify" >&2; exit 4; }
done

echo
echo "OK. Now rebuild libr54shim from source (device/itel/S666LN/mali) -- the"
echo "driver will not load without it."
