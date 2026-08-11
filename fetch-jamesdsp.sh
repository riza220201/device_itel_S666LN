#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# OPTIONAL: replace AudioFX with JamesDSP (rootless).
#
# Fetches one APK, verifies its sha256, and writes the soong glue next to it.
# Nothing else in the tree is touched. Safe to re-run; safe to never run.
#
# WHY THIS IS OPT-IN RATHER THAN COMMITTED
#   Same reason as gpu-driver-r38p1.sh: this artifact does not come from our
#   device's own firmware, so it is fetched from a named source with a checksum
#   instead of being silently vendored. It also keeps a ~37 MB binary out of git.
#
# WHY THE Android.bp IS GENERATED AND NOT COMMITTED
#   soong resolves every android_app_import's apk: at parse time. A committed
#   Android.bp pointing at an APK that has not been fetched breaks the whole
#   build for anyone who never ran this script. Generating it here means the
#   tree builds fine without JamesDSP -- AudioFX simply stays.
#
# See prebuilts/JamesDSP/README for what changes on the device and the two
# trade-offs (AudioPlaybackCapture limits, and the DUMP permission).

set -e

PKG="me.timschneeberger.rootlessjamesdsp"
VERSION_NAME="1.6.14"
VERSION_CODE="51"
URL="https://f-droid.org/repo/${PKG}_${VERSION_CODE}.apk"
SHA256="4cdd6cbc57abb00b1ce28668dc29c021640bae8c4521ec592efc58c4239d83a1"

MY_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${MY_DIR}/prebuilts/JamesDSP"
APK="${DEST}/JamesDSP.apk"

mkdir -p "${DEST}"

if [ -f "${APK}" ] && [ "$(sha256sum "${APK}" | cut -d' ' -f1)" = "${SHA256}" ]; then
    echo "JamesDSP ${VERSION_NAME} already present and verified."
else
    echo "Fetching JamesDSP ${VERSION_NAME} (versionCode ${VERSION_CODE})..."
    curl -fL --progress-bar -o "${APK}.tmp" "${URL}"

    GOT="$(sha256sum "${APK}.tmp" | cut -d' ' -f1)"
    if [ "${GOT}" != "${SHA256}" ]; then
        rm -f "${APK}.tmp"
        echo "!! sha256 MISMATCH -- refusing to install." >&2
        echo "!!   expected ${SHA256}" >&2
        echo "!!   got      ${GOT}" >&2
        echo "!! F-Droid republishes a given versionCode only if it was rebuilt." >&2
        echo "!! Do not just update the hash: confirm upstream first." >&2
        exit 1
    fi
    mv "${APK}.tmp" "${APK}"
    echo "Verified sha256 ${SHA256}"
fi

# ---------------------------------------------------------------------------
# 🔴 NOT privileged. This app used to ship with privileged:true plus a
# privapp-permissions allowlist for android.permission.DUMP, and that
# combination BOOT-LOOPED THE DEVICE (measured on hardware, build 51):
#
#   FATAL EXCEPTION IN SYSTEM PROCESS: main
#   java.lang.IllegalStateException: Signature|privileged permissions not in
#     privapp-permissions allowlist: {me.timschneeberger.rootlessjamesdsp
#     (/product/priv-app/JamesDSP): android.permission.DUMP}
#     at PermissionManagerServiceImpl.onSystemReady:4400
#     at PackageManagerService.systemReady:4201
#
# system_server reached ~238 services -- essentially a complete boot -- then
# threw and restarted, forever. Android refuses to boot a privileged app holding
# a signature|privileged permission it considers un-allowlisted.
#
# It had been latent since 2026-08-05: every earlier build was killed by
# Watchdog at the audio HAL before PackageManagerService.systemReady() was ever
# reached. Fixing audio is what exposed it.
#
# 🔴 UNEXPLAINED, and deliberately not guessed at. The allowlist WAS correct and
# WAS being read:
#   * /product/etc/permissions/privapp_whitelist_...xml present, 0644,
#     u:object_r:system_file:s0, well-formed, naming exactly that package and
#     permission
#   * "SystemConfig: Reading permissions from /product/etc/permissions/
#     privapp_whitelist_me.timschneeberger.rootlessjamesdsp.xml" in every boot
#   * no SystemConfig parse warning of any kind
#   * copying it into /system/etc/permissions as well (bind mount, live) did
#     NOT help -- 65 violations and 8 fatals in one minute afterwards
# Whatever the cause, it is not a missing or malformed allowlist file.
#
# Dropping privileged:true removes the requirement entirely: the app installs to
# /product/app, needs no allowlist, and works. The cost is the one the README
# already documented as the opt-out -- the user re-accepts a MediaProjection
# capture dialog after each reboot, because without DUMP the app cannot
# enumerate audio sessions itself.
#
# Restoring privileged mode means first explaining why a correct, parsed
# allowlist was ignored. Do not simply put privileged:true back.
# ---------------------------------------------------------------------------
# Generated soong glue
# ---------------------------------------------------------------------------
#
# overrides: ["AudioFX"] is what actually removes AudioFX. It cannot be removed
# by editing PRODUCT_PACKAGES: AudioFX is added by an INHERITED makefile
# (vendor/lineage/config/common_full.mk), and PRODUCT_PACKAGES cannot be
# subtracted from. The overrides property is the supported mechanism -- the
# build drops the overridden module from the image. AudioFX itself does exactly
# this to MusicFX (packages/apps/AudioFX/Android.bp).
#
# presigned: the F-Droid build is signed with the upstream developer's key; we
# neither have nor want that key, so it is installed as-is.
#
# dex_preopt disabled: the APK is not built here, so there is no source to
# profile-guide against, and preopting a 37 MB multi-ABI APK costs image space
# for no gain.

cat > "${DEST}/Android.bp" <<'BP'
// Generated by fetch-jamesdsp.sh -- do not edit, do not commit.
// Regenerate by re-running that script.

android_app_import {
    name: "JamesDSP",
    apk: "JamesDSP.apk",
    presigned: true,
    product_specific: true,
    overrides: ["AudioFX"],
    dex_preopt: {
        enabled: false,
    },
}
BP


echo
echo "JamesDSP ${VERSION_NAME} staged in ${DEST}"
echo "  - Android.bp was generated (gitignored)"
echo "  - AudioFX will be dropped from the image via overrides:"
echo "  - device.mk picks the module up automatically; no edit needed"
