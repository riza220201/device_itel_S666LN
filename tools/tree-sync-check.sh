#!/bin/bash
#
# tree-sync-check.sh [<build-tree device dir>]
#
# Report files that differ between THIS repo and the device tree the build
# actually compiles. Run it before any release build.
#
# WHY
#   Two copies of this device tree exist on the build box:
#     ~/itel-rs4-devicetree/device_itel_S666LN   the git repo you edit and commit
#     <crdroid>/device/itel/S666LN               the clone soong reads
#   They are NOT the same checkout, and nothing keeps them in step.
#
#   🔴 2026-08-19: sepolicy/vendor/genfs_contexts (the vibrator label) and
#   rootdir/etc/init/hw/init.modem.rc (the rild fix) were edited, committed,
#   pushed, and validated ON THE DEVICE -- via a KSU overlay, which reads
#   neither tree -- and were still absent from the release build, because they
#   were never copied to the build tree. Stage 1 completed happily and signing
#   had begun before anyone looked. Overlay validation proves the CHANGE is
#   right; it says nothing about whether the BUILD contains it.
#
#   🔴 2026-09-01: the SAME failure in the OTHER DIRECTION, and this script could
#   not see it. device/itel/S666LN/mali/ (libr54shim.c + its Android.bp) and the
#   device.mk entry that installs it existed ONLY in the build tree, left behind
#   when the 28/08 r54p1 revert was applied to this repo but not to the clone.
#   The walk below starts from THIS repo's file list, so a file present only in
#   the build tree is not in the list and cannot be compared -- and the build had
#   been shipping libr54shim.so in v2build5 and v2build6 without it appearing in
#   any published tree. The EXTRA scan added below is the fix.
#
# ⚠ THREE files are EXPECTED to differ, because apply-overlays-v2.sh appends to
#   the build tree's copies things deliberately not committed here:
#     device.mk            PRODUCT_DEFAULT_DEV_CERTIFICATE + the GApps inherit
#     BoardConfig.mk       BUILD_FINGERPRINT + stock ro.build.description
#     lineage_S666LN.mk    the PixelProps-disabling properties
#   They are reported separately rather than as drift. That list is derived from
#   the script itself, not guessed:
#     grep -oE 'device/itel/S666LN/[A-Za-z0-9_./-]+' apply-overlays-v2.sh | sort -u
#   NEVER `cp` this repo's copy of one of those over the build tree's -- doing it
#   to device.mk destroyed the signing certificate and the GApps inherit, and the
#   build then fails its own guard. Patch those in place instead.
set -uo pipefail
MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${MY_DIR}/.." && pwd)"
BUILD="${1:-/mnt/external_nvme/crdroid/device/itel/S666LN}"

[ -d "${BUILD}" ] || { echo "!! no build tree at ${BUILD}" >&2; exit 2; }

# Positive control: the trees must overlap, or a wrong path reports "no drift"
# for the same reason an empty grep reports success.
COMMON=$(cd "${REPO}" && find . -type f -not -path './.git/*' -not -path '*/__pycache__/*' 2>/dev/null | while read -r f; do
    [ -f "${BUILD}/${f}" ] && echo "$f"; done | wc -l)
if [ "${COMMON}" -lt 50 ]; then
    echo "!! REFUSING: only ${COMMON} files exist in both trees (expected hundreds)." >&2
    echo "   ${BUILD} is probably not this device tree. A wrong path would" >&2
    echo "   otherwise report a clean result." >&2
    exit 2
fi

DRIFT=0; MISSING=0
while read -r f; do
    if [ ! -f "${BUILD}/${f}" ]; then
        echo "  MISSING FROM BUILD TREE : ${f}"; MISSING=$((MISSING + 1)); continue
    fi
    cmp -s "${REPO}/${f}" "${BUILD}/${f}" && continue
    case "${f}" in
        ./device.mk|./BoardConfig.mk|./lineage_S666LN.mk)
                     echo "  differs (EXPECTED, apply-overlays owns it): ${f}" ;;
        *)           echo "  DRIFT : ${f}"; DRIFT=$((DRIFT + 1)) ;;
    esac
done < <(cd "${REPO}" && find . -type f -not -path './.git/*' -not -path '*/__pycache__/*' 2>/dev/null | sort)

# The reverse direction. Everything above walks THIS repo's file list, so a file
# that exists only in the build tree is structurally invisible to it -- which is
# how mali/libr54shim.c shipped in two releases while being in no published tree.
# Untracked build-tree files are not automatically wrong (soong writes nothing
# here, but a human experiment might), so they are reported as EXTRA rather than
# as drift, and they do not fail the check on their own.
EXTRA=0
while read -r f; do
    [ -f "${REPO}/${f}" ] && continue
    echo "  EXTRA IN BUILD TREE ONLY : ${f}   <- in no published tree"
    EXTRA=$((EXTRA + 1))
done < <(cd "${BUILD}" && find . -type f -not -path './.git/*' -not -path '*/__pycache__/*' 2>/dev/null | sort)

echo
echo "files compared : ${COMMON}"
echo "extra in build : ${EXTRA}"
echo "drifted        : ${DRIFT}"
echo "missing        : ${MISSING}"
if [ "${DRIFT}" -eq 0 ] && [ "${MISSING}" -eq 0 ] && [ "${EXTRA}" -eq 0 ]; then
    echo "OK: the build tree matches this repo (device.mk aside)."
    exit 0
fi
if [ "${DRIFT}" -eq 0 ] && [ "${MISSING}" -eq 0 ]; then
    echo "No drift, but ${EXTRA} file(s) exist ONLY in the build tree, so they are"
    echo "in no published tree. Most will be strays and backups; the dangerous case"
    echo "is one an Android.bp/mk actually consumes, which then builds here and"
    echo "nowhere else. Check each with:"
    echo "    grep -rn <name> ${BUILD} --include=*.mk --include=*.bp"
    echo "then commit it or delete it."
    exit 1
fi
echo
echo "The build compiles the OTHER tree. Copy each file above into it before"
echo "building -- except device.mk, which must be patched in place."
exit 1
