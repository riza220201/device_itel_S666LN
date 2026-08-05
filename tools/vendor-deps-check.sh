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

# --- what a vendor process can actually load ------------------------------
find "${VENDOR_DIR}/lib" "${VENDOR_DIR}/lib64" -name '*.so' 2>/dev/null \
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

if [ ! -s "${TMP}/unresolved" ]; then
    echo "OK: every DT_NEEDED resolves from /vendor, the VNDK snapshot or public.libraries.txt"
    exit 0
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
