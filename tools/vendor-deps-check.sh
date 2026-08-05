#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Report DT_NEEDED entries that nothing on the device can resolve for a vendor
# process. Run against a BUILT vendor image (out/target/product/S666LN/vendor).
#
# WHY THIS EXISTS
#   The 2026-08-05 build compiled, linked, packaged, release-signed and flashed
#   cleanly, and then stalled at 46 seconds with
#
#     HidlServiceManagement: Waited one second for
#       android.hardware.boot@1.0::IBootControl/default
#
#   android.hardware.boot@{1.0,1.1,1.2}.so were missing from /vendor, so
#   android.hardware.boot@1.2-service died in the linker before registering
#   IBootControl. Nothing that runs at build time noticed: the audit that found
#   it reported 10,675 unresolved references across 221 libraries.
#
#   Two things that had made it look fine, and are NOT evidence a file reaches
#   /vendor:
#     - an install rule in out/soong/installs-*.mk. Rules exist for modules that
#       nothing requests, so they are never built into the image.
#     - the library existing under /system. A vendor process cannot link it.
#
#   The KMI gate catches the kernel version of exactly this class of defect --
#   valid artifacts that cannot work at runtime. This is its userspace
#   counterpart, and its absence is why a broken vendor partition shipped.
#
# WHAT COUNTS AS RESOLVABLE
#   /vendor/lib{,64} and every subdirectory (this device puts most libraries in
#   an mt6789/ subdir with symlinks beside them), plus the VNDK snapshot for the
#   vendor's VNDK version, plus whatever public.libraries.txt exposes from
#   /system. Anything else is unreachable from a vendor process no matter where
#   it exists on the device.
#
# USAGE
#   tools/vendor-deps-check.sh [OUT_VENDOR_DIR] [SYSTEM_DIR]
#   tools/vendor-deps-check.sh $OUT/vendor $OUT/system
#
# Exit status is 1 when anything is unresolved, so it can gate a release.

set -u

VENDOR_DIR="${1:-${OUT:-}/vendor}"
SYSTEM_DIR="${2:-${OUT:-}/system}"

if [ ! -d "${VENDOR_DIR}" ]; then
    echo "usage: $0 <vendor_dir> [system_dir]" >&2
    echo "  e.g. $0 \$OUT/vendor \$OUT/system" >&2
    exit 2
fi

READELF="${READELF:-readelf}"
command -v "${READELF}" >/dev/null 2>&1 || { echo "!! readelf not found" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- dangling symlinks ----------------------------------------------------
# Run this FIRST: a broken link is not a missing file, so every other check
# here will happily report it as present.
#
# The 2026-08-05 build shipped 635 dangling links out of 641, because
# symlinks.mk deferred its link target to recipe-execution time through a
# variable name that build/make/core/definitions.mk also uses. Every link
# pointed at lineage.x509.pem. The image contained gralloc.common.so,
# libGLES_mali.so, vulkan.mali.so and arm.graphics-V1-ndk_platform.so by name
# and none of them could be opened, so surfaceflinger never started and the
# device sat at the boot logo without ever bootlooping.
# Absolute targets are excluded: they are resolved against / on the device, not
# against $OUT, so they always look dangling here. vendor/lib/modules ->
# /vendor_dlkm/lib/modules is the legitimate case. Relative links must resolve.
find "${VENDOR_DIR}" -type l ! -lname '/*' ! -exec test -e {} \; -printf '%p -> %l\n' \
    2>/dev/null > "${TMP}/dangling"
DANGLING="$(wc -l < "${TMP}/dangling")"
if [ "${DANGLING}" -gt 0 ]; then
    echo "DANGLING SYMLINKS: ${DANGLING}"
    sed 's/^/  /' "${TMP}/dangling" | head -20
    [ "${DANGLING}" -gt 20 ] && echo "  ... $((DANGLING - 20)) more"
fi

# --- what a vendor process can actually load ------------------------------
# -xtype f, not -name alone: a dangling symlink still matches '*.so' and would
# otherwise be counted as a library that resolves.
find "${VENDOR_DIR}/lib" "${VENDOR_DIR}/lib64" -name '*.so' -xtype f 2>/dev/null \
    | xargs -r -n1 basename | sort -u > "${TMP}/resolvable"

# VNDK. On this platform it is delivered as an APEX (com.android.vndk.current),
# NOT as system/lib{,64}/vndk-<ver>/ -- those directories do not exist here, and
# looking only for them reports every VNDK library (libc++, libutils, libcutils,
# libhidlbase ...) as missing, which buries the real findings in ~4000 false
# positives. Check both layouts.
VNDK_VER="$(grep -h '^ro.vndk.version=' "${VENDOR_DIR}/build.prop" \
    "${VENDOR_DIR}/etc/build.prop" 2>/dev/null | head -1 | cut -d= -f2)"
if [ -d "${SYSTEM_DIR}" ]; then
    for d in "${SYSTEM_DIR}/apex/com.android.vndk.current/lib" \
             "${SYSTEM_DIR}/apex/com.android.vndk.current/lib64" \
             "${SYSTEM_DIR}/apex/com.android.vndk.v${VNDK_VER}/lib" \
             "${SYSTEM_DIR}/apex/com.android.vndk.v${VNDK_VER}/lib64" \
             "${SYSTEM_DIR}/lib/vndk-${VNDK_VER}" "${SYSTEM_DIR}/lib64/vndk-${VNDK_VER}" \
             "${SYSTEM_DIR}/lib/vndk-sp-${VNDK_VER}" "${SYSTEM_DIR}/lib64/vndk-sp-${VNDK_VER}"; do
        [ -d "$d" ] && find "$d" -name '*.so' 2>/dev/null | xargs -r -n1 basename \
            >> "${TMP}/resolvable"
    done
fi

# LLNDK: libraries /system exposes to vendor by contract (libEGL, libnativewindow,
# libsync, libbinder_ndk, libmediandk, libselinux ...). They live in system/lib{,64}
# and are NOT in the VNDK APEX's lib dirs, so they must be picked up from the
# LLNDK manifest or ~200 legitimate references are reported as broken. On this
# platform the list ships INSIDE the VNDK apex, not in system/etc.
for f in "${SYSTEM_DIR}/apex/com.android.vndk.current/etc/llndk.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/apex/com.android.vndk.v${VNDK_VER}/etc/llndk.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/etc/llndk.libraries.${VNDK_VER}.txt"; do
    [ -f "$f" ] && grep -oE '^[A-Za-z0-9_.+-]+\.so' "$f" >> "${TMP}/resolvable" 2>/dev/null
done

# Libraries /system explicitly exposes to vendor.
if [ -f "${VENDOR_DIR}/etc/public.libraries.txt" ]; then
    grep -oE '^[A-Za-z0-9_.+-]+\.so' "${VENDOR_DIR}/etc/public.libraries.txt" \
        >> "${TMP}/resolvable" 2>/dev/null
fi
# The linker always provides these.
printf '%s\n' ld-android.so libdl.so libc.so libm.so libstdc++.so liblog.so \
    >> "${TMP}/resolvable"

sort -u "${TMP}/resolvable" -o "${TMP}/resolvable"

# --- every vendor ELF's dependencies --------------------------------------
: > "${TMP}/unresolved"
COUNT=0
while IFS= read -r f; do
    head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
    COUNT=$((COUNT + 1))
    "${READELF}" -d "$f" 2>/dev/null \
        | grep -oE 'Shared library: \[[^]]+\]' | sed 's/.*\[//; s/\]//' \
        | while IFS= read -r need; do
            grep -qxF "${need}" "${TMP}/resolvable" \
                || printf '%s\t%s\n' "${need}" "${f#"${VENDOR_DIR}"/}" >> "${TMP}/unresolved"
          done
done < <(find "${VENDOR_DIR}/bin" "${VENDOR_DIR}/lib" "${VENDOR_DIR}/lib64" -type f 2>/dev/null)

echo "vendor ELFs scanned : ${COUNT}"
echo "resolvable libraries: $(wc -l < "${TMP}/resolvable")"

# --- passthrough HAL implementations ------------------------------------
# DT_NEEDED cannot see these. A passthrough impl is dlopen'd by name at runtime,
# so it is not a link dependency of anything and a clean dependency report says
# nothing about whether it exists. The 2026-08-05 build passed this check with
# zero unresolved and still would not boot, because
# android.hardware.boot@1.0-impl-1.2-mtkimpl.so was absent and IBootControl
# therefore never registered.
#
# Compare against a stock vendor reference when one is available: anything in
# stock's lib{,64}/hw that we do not ship is a HAL that will fail to load.
IMPL_MISSING=0
# Reference can be a stock vendor DIRECTORY or, more portably, a manifest listing
# stock's impl paths one per line (lib64/hw/foo.so). The manifest is a few KB and
# can live in the tree; the directory is a multi-GB extraction that usually only
# exists on the machine that did the dump.
IMPL_LIST="${STOCK_IMPL_LIST:-$(dirname "$0")/stock-impls.txt}"
if [ -n "${STOCK_VENDOR:-}" ] && [ -d "${STOCK_VENDOR}" ]; then
    for abi in lib lib64; do
        [ -d "${STOCK_VENDOR}/${abi}/hw" ] || continue
        while IFS= read -r impl; do
            base="$(basename "${impl}")"
            if [ ! -e "${VENDOR_DIR}/${abi}/hw/${base}" ]; then
                echo "MISSING IMPL: ${abi}/hw/${base}"
                IMPL_MISSING=$((IMPL_MISSING + 1))
            fi
        done < <(find "${STOCK_VENDOR}/${abi}/hw" -maxdepth 1 -name '*-impl*.so' 2>/dev/null)
    done
    echo "passthrough impls missing vs stock: ${IMPL_MISSING}"
elif [ -f "${IMPL_LIST}" ]; then
    while IFS= read -r rel; do
        [ -z "${rel}" ] && continue
        case "${rel}" in \#*) continue ;; esac
        if [ ! -e "${VENDOR_DIR}/${rel}" ]; then
            echo "MISSING IMPL: ${rel}"
            IMPL_MISSING=$((IMPL_MISSING + 1))
        fi
    done < "${IMPL_LIST}"
    echo "passthrough impls missing vs stock: ${IMPL_MISSING}"
else
    echo "NOTE: set STOCK_VENDOR=<stock vendor dir> to also check passthrough HAL impls."
    echo "      DT_NEEDED alone cannot detect a missing dlopen'd implementation."
fi

if [ ! -s "${TMP}/unresolved" ] && [ "${IMPL_MISSING}" -eq 0 ] && [ "${DANGLING}" -eq 0 ]; then
    echo "OK: every DT_NEEDED resolves, no passthrough impl is missing vs stock,"
    echo "    and no symlink dangles"
    exit 0
fi
if [ "${DANGLING}" -gt 0 ]; then
    echo
    echo "Fix the dangling symlinks first -- they make every other result here"
    echo "unreliable, and a library behind a broken link is unloadable."
fi
if [ ! -s "${TMP}/unresolved" ]; then
    echo "Link dependencies are clean, but passthrough implementations are missing."
    exit 1
fi

echo
echo "UNRESOLVED (missing library <- consumer), by number of consumers:"
cut -f1 "${TMP}/unresolved" | sort | uniq -c | sort -rn | head -60
echo
echo "distinct missing libraries : $(cut -f1 "${TMP}/unresolved" | sort -u | wc -l)"
echo "total unresolved references: $(wc -l < "${TMP}/unresolved")"
echo
echo "For each one, decide deliberately:"
echo "  * platform builds it  -> add <module>.vendor to PRODUCT_PACKAGES in device.mk"
echo "  * only stock has it   -> add the path to proprietary-files.txt"
echo "Do NOT conclude it is fine because a rule exists in installs-*.mk, or"
echo "because the file is present under /system. Neither reaches /vendor."
exit 1
