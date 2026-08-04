#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Extracts the proprietary blobs this device needs from a stock dump.
# The blobs themselves are itel/MediaTek's; this script only lists and copies
# them. Pin the source to firmware revision 28 (build 251212V1661) — a newer
# dump would ship blobs that no longer match the fingerprint the ROM presents.

set -e

DEVICE=S666LN
VENDOR=itel

MY_DIR="${BASH_SOURCE%/*}"
[[ ! -d "${MY_DIR}" ]] && MY_DIR="${PWD}"

ANDROID_ROOT="${MY_DIR}/../../.."

HELPER="${ANDROID_ROOT}/tools/extract-utils/extract_utils.sh"
if [ ! -f "${HELPER}" ]; then
    echo "Unable to find helper script at ${HELPER}" >&2
    exit 1
fi
source "${HELPER}"

# Default to sanitizing the vendor folder before extraction
CLEAN_VENDOR=true

KANG=
SECTION=

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n | --no-cleanup) CLEAN_VENDOR=false ;;
        -k | --kang)       KANG="--kang" ;;
        -s | --section)    SECTION="${2}"; shift; CLEAN_VENDOR=false ;;
        *)                 SRC="${1}" ;;
    esac
    shift
done

if [ -z "${SRC}" ]; then
    SRC="adb"
fi

# Fix up blobs that name Android-12 sonames.
#
# AOSP dropped the `_platform` suffix from AIDL NDK backend libraries in
# Android 13. A blob built against the A12 vendor still records the old soname,
# which no longer exists on the target, so it fails at load time — a runtime
# dlopen error, not a build failure, which is why it is easy to miss.
#
# Derived mechanically from our own rev 28 dump, not taken from any other tree.
# To re-derive after a firmware bump:
#
#   for f in $(find <vendor> -name '*.so' -o -path '*/bin/*' -type f); do
#       readelf -d "$f" | grep -o '[^[]*_platform\.so'
#   done
#
# On rev 28 that yields exactly two sonames across five real files. Nine paths
# match in total; the other four are the lib*/ -> mt6789/ symlinks, which
# proprietary-files.txt folds with SYMLINK= and which therefore need no fixup of
# their own. Both replacements were confirmed to exist as soong modules on the
# Android 13 branch: `arm.graphics-V1-ndk`, `android.hardware.light-V1-ndk`.
function blob_fixup() {
    case "${1}" in
        vendor/bin/factory)
            "${PATCHELF}" --replace-needed "android.hardware.light-V1-ndk_platform.so" \
                "android.hardware.light-V1-ndk.so" "${2}"
            ;;
        vendor/lib/egl/mt6789/libGLES_mali.so | \
        vendor/lib64/egl/mt6789/libGLES_mali.so | \
        vendor/lib/hw/mt6789/android.hardware.graphics.mapper@4.0-impl-mediatek.so | \
        vendor/lib64/hw/mt6789/android.hardware.graphics.mapper@4.0-impl-mediatek.so)
            "${PATCHELF}" --replace-needed "arm.graphics-V1-ndk_platform.so" \
                "arm.graphics-V1-ndk.so" "${2}"
            ;;
    esac
}

setup_vendor "${DEVICE}" "${VENDOR}" "${ANDROID_ROOT}" false "${CLEAN_VENDOR}"
extract "${MY_DIR}/proprietary-files.txt" "${SRC}" "${KANG}" --section "${SECTION}"

"${MY_DIR}/setup-makefiles.sh"

# CLEAN_VENDOR defaults to true, so the run above WIPED the vendor directory and
# re-extracted everything from stock. That silently reverts the GPU driver to
# stock r32p1 and drops Vulkan from 1.3 back to 1.1 -- no error, no warning.
if [ -x "${MY_DIR}/gpu-driver-r38p1.sh" ]; then
    echo
    echo "NOTE: the Mali driver is now stock r32p1 (Vulkan 1.1)."
    echo "      To restore r38p1 / Vulkan 1.3, run:"
    echo "          ${MY_DIR}/gpu-driver-r38p1.sh"
fi
