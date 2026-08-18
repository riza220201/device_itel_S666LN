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

# readelf. 🔴 A build ACTION cannot use the host's readelf: AOSP sanitises PATH
# to prebuilts/build-tools/path/linux-x86 plus out/.path, and readelf is in
# neither, so the interposer refuses it outright:
#
#   Disallowed PATH tool "readelf" used
#   "readelf" is not allowed to be used. See .../Changes.md#PATH_Tools
#
# With no readelf there are no DT_NEEDED entries to resolve, so "0 unresolved"
# is guaranteed -- which is precisely how this gate passed vacuously on its
# first two builds. Prefer the LLVM readelf that ships IN the tree, which is
# reachable by absolute path and needs no PATH at all. Same output for -d.
if [ -z "${READELF:-}" ]; then
    for _c in "${ANDROID_BUILD_TOP:-.}"/prebuilts/clang/host/linux-x86/clang-latest/bin/llvm-readelf \
              ./prebuilts/clang/host/linux-x86/clang-latest/bin/llvm-readelf \
              ../../../prebuilts/clang/host/linux-x86/clang-latest/bin/llvm-readelf; do
        [ -x "${_c}" ] && { READELF="${_c}"; break; }
    done
fi
READELF="${READELF:-readelf}"
command -v "${READELF}" >/dev/null 2>&1 || [ -x "${READELF}" ] || {
    echo "!! readelf not found and no in-tree llvm-readelf located." >&2
    echo "   Set READELF=<path>. Do NOT let this check run without one: with no" >&2
    echo "   readelf every dependency silently 'resolves' and the gate is a lie." >&2
    exit 2
}
# Prove it actually runs before trusting a single result from it.
"${READELF}" --version >/dev/null 2>&1 || {
    echo "!! ${READELF} is present but refuses to run (PATH interposer?)." >&2
    exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- init services whose binary does not exist ----------------------------
# An init .rc naming a path that is not installed is NOT a build error. The
# service simply never starts, and the only symptom is whatever depended on it
# quietly not working.
#
# extract-files.sh makes this easy to hit, because a .rc and the binary it
# starts are two separate lines in proprietary-files.txt and nothing ties them
# together. Found this way:
#   android.hardware.wifi.supplicant-service.rc -> /vendor/bin/hw/wpa_supplicant
#   muxreport.rc                                -> /vendor/bin/muxreport
# both extracted as .rc only, so Wi-Fi could not work at all.
#
# Note the redirect rather than a pipe: running this loop in a pipeline puts it
# in a subshell, and an earlier version of this check reported six false
# positives because of it.
SERVICE_MISSING=0
: > "${TMP}/svc"
for rc in "${VENDOR_DIR}"/etc/init/*.rc; do
    [ -f "${rc}" ] || continue
    # sub(/\r$/...): several stock .rc files use CRLF, and the trailing carriage
    # return becomes part of the path. Without this the check reports
    # "/vendor/bin/dmc_core^M" as missing -- four false positives out of six on
    # the first run.
    awk '/^[[:space:]]*service[[:space:]]/ { p = $3; sub(/\r$/, "", p); if (p != "") print p }' \
        "${rc}" >> "${TMP}/svc" 2>/dev/null
done
sort -u "${TMP}/svc" -o "${TMP}/svc"
while IFS= read -r bin; do
    case "${bin}" in
        /vendor/*) target="${VENDOR_DIR}${bin#/vendor}" ;;
        /system/vendor/*) target="${VENDOR_DIR}${bin#/system/vendor}" ;;
        *) continue ;;   # /system paths are not ours to verify from here
    esac
    if [ ! -e "${target}" ]; then
        echo "MISSING SERVICE BINARY: ${bin}"
        SERVICE_MISSING=$((SERVICE_MISSING + 1))
    fi
done < "${TMP}/svc"
[ "${SERVICE_MISSING}" -gt 0 ] && echo "init services with no binary: ${SERVICE_MISSING}"

# --- vendor properties that must not be empty -----------------------------
# ro.vendor.build.security_patch feeds Tag::VENDOR_PATCHLEVEL in the Trustonic
# KeyMint HAL. Empty leaves the TA unconfigured, generateKey returns -49
# (KEYMINT_NOT_CONFIGURED), vold cannot create the metadata encryption key, and
# init reboots to recovery -- which looks like a bootloop and says nothing about
# keystore. VENDOR_SECURITY_PATCH is referenced by build/make/core/main.mk but
# defined by no default, so this ships blank unless BoardConfig.mk sets it.
PROP_BAD=0
VPROP="${VENDOR_DIR}/build.prop"
if [ -f "${VPROP}" ]; then
    for p in ro.vendor.build.security_patch ro.vendor.build.fingerprint; do
        v="$(grep -m1 "^${p}=" "${VPROP}" 2>/dev/null | cut -d= -f2-)"
        if [ -z "${v}" ]; then
            echo "EMPTY VENDOR PROP: ${p}"
            PROP_BAD=$((PROP_BAD + 1))
        fi
    done
fi

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

# --- kernel module load ORDER ---------------------------------------------
# The module SET is not the module ORDER, and only the set is obvious from the
# build. BOARD_*_KERNEL_MODULES_LOAD is optional to the build system and
# build/make/core/Makefile:447 silently defaults it to the whole _MODULES list,
# so a tree that never sets it ships modules.load as every .ko in $(wildcard)
# order. That is a valid image which cannot boot: build 19 loaded 206 modules in
# glob order instead of MediaTek's 171 in dependency order, hung module init and
# was killed by the watchdog LK arms before it jumps to the kernel --
# [pmic_check_rst] AP Watchdog / wdt_status 0x2 / aee_exp_type:2 -- seven times,
# until the bootloader marked the slot unbootable.
#
# It survived nineteen builds because OrangeFox reflashes its own vendor_boot
# after every install and that ramdisk carries no modules at all, so the broken
# list was never executed on the slot being tested.
#
# Compare against the ordered lists shipping with the kernel package, which are
# the stock ones. Byte-for-byte: a diff of one line is a diff of the order.
MODULES_BAD=0
_out_root="$(dirname "${VENDOR_DIR}")"
_kpkg="$(cd "$(dirname "$0")/../../S666LN-kernel" 2>/dev/null && pwd)"
if [ -n "${_kpkg}" ] && [ -d "${_kpkg}/modules" ]; then
    # built image dir : kernel package dir : list filename
    for spec in \
        "vendor_ramdisk:vendor_boot:modules.load" \
        "vendor_ramdisk:vendor_boot:modules.load.recovery" \
        "vendor_dlkm:vendor_dlkm:modules.load"; do
        _img="${spec%%:*}"; _rest="${spec#*:}"
        _src="${_rest%%:*}"; _name="${_rest#*:}"
        _built="${_out_root}/${_img}/lib/modules/${_name}"
        _want="${_kpkg}/modules/${_src}/${_name}"
        [ -f "${_want}" ] || continue
        if [ ! -f "${_built}" ]; then
            echo "MODULE LOAD LIST MISSING FROM IMAGE: ${_img}/lib/modules/${_name}"
            MODULES_BAD=$((MODULES_BAD + 1))
            continue
        fi
        if ! cmp -s "${_built}" "${_want}"; then
            echo "MODULE LOAD ORDER WRONG: ${_img}/lib/modules/${_name}"
            echo "    built $(wc -l < "${_built}") entries, expected $(wc -l < "${_want}")"
            echo "    first built: $(head -1 "${_built}")   first expected: $(head -1 "${_want}")"
            MODULES_BAD=$((MODULES_BAD + 1))
        fi
    done
fi

# --- what a vendor process can actually load ------------------------------
# Split by ABI. A 64-bit process cannot load a 32-bit library, so merging
# lib/ and lib64/ into one basename set answers the wrong question -- it says
# "does a file by this name exist anywhere", when the question is "can THIS
# consumer load it".
#
# That merge is how android.hardware.media.c2@1.2-mediatek-64b shipped broken
# while this gate reported everything resolved: /vendor/lib had
# libavservices_minijail.so, /vendor/lib64 had only the _vendor-suffixed one,
# and the 64-bit binary died in the linker at every boot --
#
#   CANNOT LINK EXECUTABLE ".../media.c2@1.2-mediatek-64b":
#     library "libavservices_minijail.so" not found
#
# -- so IComponentStore never registered, mediaserver retried forever and the
# boot animation never exited.
#
# A dangling symlink still matches '*.so' and must not count as a library that
# resolves. That used to be `-xtype f`, which is a GNU findutils extension --
# and a build ACTION does not get GNU findutils, it gets toybox:
#
#   $ prebuilts/build-tools/path/linux-x86/find ... -name '*.so' -xtype f
#   find: bad arg 'f'
#
# toybox errored, the pipeline produced nothing, and the resolvable set silently
# collapsed to the ~190 entries that came from grep-based sources -- the second
# half of why this gate passed vacuously in builds 44 and 45. Same toybox-vs-GNU
# family as the `grep 'a\|b'` alternation trap recorded on 2026-08-11.
#
# `[ -f ]` is a bash builtin, follows symlinks, and behaves identically under
# both. `${p##*/}` replaces basename for the same reason. No external tool is
# used here beyond find itself, which both implementations support.
#
# 🔴 vndk/ AND vndk-sp/ ARE EXCLUDED HERE, and added back below only for the
# sonames the VNDK allowlist names. Added 2026-08-18, after this gate printed
# "OK: every DT_NEEDED resolves" for build 68 and build 68 hung in post-fs-data.
#
# vendor/lib*/vndk is NOT a search path of the namespace a vendor process runs
# in. system/linkerconfig/contents/namespace/vendordefault.cc:38 gives the
# vendor `default` namespace exactly four:
#
#     /odm/${LIB}   /vendor/${LIB}   /vendor/${LIB}/hw   /vendor/${LIB}/egl
#
# vndk/ is reached only through an ALLOWLISTED link,
#     ns.GetLink("vndk").AddSharedLib({VNDK_SAMEPROCESS_LIBRARIES_VENDOR,
#                                      VNDK_CORE_LIBRARIES_VENDOR})
# whose contents are vndkcore.libraries.<ver>.txt + vndksp.libraries.<ver>.txt.
# A file sitting in vndk/ whose soname is not in those lists is invisible.
#
# Sweeping vndk/ by basename therefore answers "does a file by this name exist",
# not "can this consumer load it" -- the identical mistake the ABI split above
# was written to fix, one directory deeper. It cost a boot:
# android.hardware.security.keymint-service.trustonic needs the three A12
# android.hardware.security.*-V1-ndk_platform.so, the v31 snapshot put them in
# vndk/, and the v33 allowlist contains no _platform soname at all. keymint
# never linked, keystore2 never registered IKeystoreService, and
# `exec - system system -- /system/bin/vdc keymaster earlyBootEnded`
# (init.rc:710, post-fs-data) blocked init's action queue forever.
_collect_libs() {   # $1 = dir, $2 = output file
    : > "$2"
    [ -d "$1" ] || return 0
    while IFS= read -r p; do
        [ -f "$p" ] && printf '%s\n' "${p##*/}"
    done < <(find "$1" -maxdepth 3 -name '*.so' \
                  ! -path '*/vndk/*' ! -path '*/vndk-sp/*' 2>/dev/null) \
        | sort -u > "$2"
}
# The vndk/ + vndk-sp/ contents, kept separately: they are what a consumer that
# ITSELF lives in that namespace may load (vndk.cc search order 1), and the pool the
# allowlist intersection below draws from.
_collect_vndk() {   # $1 = lib dir, $2 = output file
    : > "$2"
    for d in "$1/vndk" "$1/vndk-sp"; do
        [ -d "$d" ] || continue
        while IFS= read -r p; do
            [ -f "$p" ] && printf '%s\n' "${p##*/}"
        done < <(find "$d" -maxdepth 2 -name '*.so' 2>/dev/null)
    done | sort -u > "$2"
}
_collect_libs "${VENDOR_DIR}/lib"   "${TMP}/resolvable32"
_collect_libs "${VENDOR_DIR}/lib64" "${TMP}/resolvable64"
_collect_vndk "${VENDOR_DIR}/lib"   "${TMP}/vndkdir32"
_collect_vndk "${VENDOR_DIR}/lib64" "${TMP}/vndkdir64"
# Everything below (VNDK, LLNDK, public.libraries, linker-provided) is added to
# both: those are delivered per-ABI in matching pairs.
cat "${TMP}/resolvable32" "${TMP}/resolvable64" | sort -u > "${TMP}/resolvable"

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
        # ${p##*/} rather than basename: see _collect_libs above -- basename is
        # toybox in a build action and xargs pipelines were the failure path.
        [ -d "$d" ] && while IFS= read -r p; do printf '%s\n' "${p##*/}"; done \
            < <(find "$d" -name '*.so' 2>/dev/null) >> "${TMP}/resolvable"
    done
fi

# --- the VNDK allowlist: which of vendor/lib*/vndk is actually an entry point --
#
# See _collect_libs above. vndk/ was excluded from the per-ABI sets; this puts
# back exactly the sonames the vendor->vndk namespace link permits, and only
# those that are really present on the vendor side (the APEX copies were already
# swept above, so a name missing from BOTH still reports as unresolved rather
# than being papered over).
: > "${TMP}/vndkallow"
for f in "${SYSTEM_DIR}/apex/com.android.vndk.current/etc/vndkcore.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/apex/com.android.vndk.current/etc/vndksp.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/apex/com.android.vndk.v${VNDK_VER}/etc/vndkcore.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/apex/com.android.vndk.v${VNDK_VER}/etc/vndksp.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/etc/vndkcore.libraries.${VNDK_VER}.txt" \
         "${SYSTEM_DIR}/etc/vndksp.libraries.${VNDK_VER}.txt"; do
    [ -f "$f" ] && grep -oE '^[A-Za-z0-9_.+-]+\.so' "$f" >> "${TMP}/vndkallow" 2>/dev/null
done
sort -u "${TMP}/vndkallow" -o "${TMP}/vndkallow"

# Positive control. If the allowlist cannot be found, EVERY vndk/ library looks
# unreachable and the report becomes thousands of false positives -- loud, but
# for the wrong reason. Refuse instead, the same way the resolvable floor does.
VNDKALLOW_N=$(grep -c . "${TMP}/vndkallow" 2>/dev/null || echo 0)
if [ -d "${SYSTEM_DIR}" ] && [ "${VNDKALLOW_N}" -lt 50 ]; then
    echo "!! REFUSING TO PASS: VNDK allowlist has ${VNDKALLOW_N} entries (expected ~160)" >&2
    echo "   looked for vndkcore/vndksp.libraries.${VNDK_VER}.txt under" >&2
    echo "     ${SYSTEM_DIR}/apex/com.android.vndk.current/etc/" >&2
    echo "     ${SYSTEM_DIR}/apex/com.android.vndk.v${VNDK_VER}/etc/" >&2
    echo "     ${SYSTEM_DIR}/etc/" >&2
    echo "   Without it this check cannot tell a reachable vndk/ library from an" >&2
    echo "   unreachable one, which is the exact hole that let build 68 ship." >&2
    exit 2
fi
for abi in 32 64; do
    comm -12 "${TMP}/vndkdir${abi}" "${TMP}/vndkallow" >> "${TMP}/resolvable${abi}"
    sort -u "${TMP}/resolvable${abi}" -o "${TMP}/resolvable${abi}"
done
cat "${TMP}/resolvable32" "${TMP}/resolvable64" >> "${TMP}/resolvable"

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

# --- sanity floor: refuse to conclude from an implausible resolvable set ----
#
# 🔴 Added 2026-08-11 because this check PASSED VACUOUSLY in its first real build.
#
# Wired into bacon, it printed:
#     vendor ELFs scanned : 1974
#     resolvable libraries: 190
#     OK: every DT_NEEDED resolves ...
#
# and the identical command on the identical tree, run by hand seconds later,
# printed 1375. With only 190 resolvable libraries and 1974 consumers, "zero
# unresolved" is arithmetically impossible -- yet nothing objected, because the
# script only ever asserts on the unresolved COUNT and never on whether it built
# a believable picture of the device first.
#
# The cause is not established. The inputs all pre-date the run (vendor/lib64
# 09:48 vs stamp 10:09) so it is not a staging race; the leading suspicion is
# that build actions execute sandboxed (`-u nobody -g nogroup` with restricted
# bind mounts), which could make parts of the tree unreadable to the action
# while leaving them perfectly readable to a shell. Recorded as unresolved
# rather than guessed at.
#
# The guard is correct regardless of the cause, and it is this project's oldest
# rule applied to the gate itself: *an empty variable makes every grep return 0,
# which reads as a clean pass* -- so print a count and prove the zero is real.
# A healthy tree measures ~1375 here (1544 vendor/lib64 + 963 vendor/lib +
# 162 VNDK apex, deduplicated by basename). 800 is comfortably below any
# legitimate variation and an order of magnitude above the vacuous case.
RESOLVABLE_N=$(grep -c . "${TMP}/resolvable" 2>/dev/null || echo 0)
RESOLVABLE_FLOOR=800
if [ "${RESOLVABLE_N}" -lt "${RESOLVABLE_FLOOR}" ]; then
    echo "!! REFUSING TO PASS: only ${RESOLVABLE_N} resolvable libraries found" >&2
    echo "   (floor ${RESOLVABLE_FLOOR}; a correctly staged tree measures ~1375)" >&2
    echo "   vendor/lib64 .so : $(grep -c . "${TMP}/resolvable64" 2>/dev/null || echo 0)" >&2
    echo "   vendor/lib   .so : $(grep -c . "${TMP}/resolvable32" 2>/dev/null || echo 0)" >&2
    echo "   VENDOR_DIR       : ${VENDOR_DIR}" >&2
    echo "   SYSTEM_DIR       : ${SYSTEM_DIR}" >&2
    echo "   VNDK_VER         : ${VNDK_VER:-<empty>}" >&2
    # What the check could actually SEE, at the moment it ran. The counts above
    # say "nothing was found"; these say whether that is because the tree is
    # absent, empty, or present-but-unreadable -- three different bugs that
    # otherwise look identical from a zero.
    echo "   cwd              : $(pwd)" >&2
    echo "   uid              : $(id -u 2>/dev/null)" >&2
    echo "   PATH             : ${PATH}" >&2
    for t in find basename xargs grep sort readelf; do
        w="$(command -v "$t" 2>/dev/null || echo '<not found>')"
        probe="$("$t" --version 2>&1 | head -1)"
        case "$probe" in
            *"not allowed"*) probe="REFUSED BY PATH INTERPOSER" ;;
        esac
        printf '   tool %-9s %s | %s\n' "$t" "$w" "$probe" >&2
    done
    for d in "${VENDOR_DIR}" "${VENDOR_DIR}/lib64" "${VENDOR_DIR}/lib64/mt6789" "${SYSTEM_DIR}"; do
        if [ -d "$d" ]; then
            echo "   dir ok, $(find "$d" -maxdepth 1 2>/dev/null | grep -c .) entries: $d" >&2
        else
            echo "   MISSING: $d" >&2
        fi
    done
    echo "" >&2
    echo "   This is NOT a clean result. The check cannot see enough of the" >&2
    echo "   device to decide anything, so every dependency would appear to" >&2
    echo "   resolve for the wrong reason. Fix the environment, not this floor." >&2
    exit 2
fi

# --- every vendor ELF's dependencies --------------------------------------
# The per-ABI sets are the vendor libraries only; the shared tail (VNDK, LLNDK,
# public.libraries, linker-provided) was appended to ${TMP}/resolvable after the
# split, so fold it back into each. Everything appended there ships in matching
# 32/64 pairs, so this cannot reintroduce the cross-ABI hole above.
comm -13 <(cat "${TMP}/resolvable32" "${TMP}/resolvable64" | sort -u) \
         <(sort -u "${TMP}/resolvable") > "${TMP}/resolvable_common"
sort -u "${TMP}/resolvable32" "${TMP}/resolvable_common" > "${TMP}/ok32"
sort -u "${TMP}/resolvable64" "${TMP}/resolvable_common" > "${TMP}/ok64"
# A consumer that itself lives in vndk/ or vndk-sp/ RUNS in the vndk namespace,
# where the allowlist does not apply and the whole directory is on search path 1
# (vndk.cc:70-77), with /vendor/${LIB} following at search path 3 (vndk.cc:94-97).
# Judging those consumers by the vendor `default` rule would report every
# intra-VNDK edge as broken -- e.g. libmemtrack.so -> memtrack-V1-ndk_platform.so.
sort -u "${TMP}/ok32" "${TMP}/vndkdir32" > "${TMP}/okvndk32"
sort -u "${TMP}/ok64" "${TMP}/vndkdir64" > "${TMP}/okvndk64"

: > "${TMP}/unresolved"
COUNT=0
while IFS= read -r f; do
    head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
    COUNT=$((COUNT + 1))
    # ELF class byte (offset 4): 1 = 32-bit, 2 = 64-bit. Check each consumer
    # against the libraries its own ABI can actually load.
    case "$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')" in
        2) _abi=64 ;;
        *) _abi=32 ;;
    esac
    # ...and against the namespace it will actually run in.
    case "$f" in
        */vndk/*|*/vndk-sp/*) _ok="${TMP}/okvndk${_abi}" ;;
        *)                    _ok="${TMP}/ok${_abi}" ;;
    esac
    "${READELF}" -d "$f" 2>/dev/null \
        | grep -oE 'Shared library: \[[^]]+\]' | sed 's/.*\[//; s/\]//' \
        | while IFS= read -r need; do
            grep -qxF "${need}" "${_ok}" \
                || printf '%s\t%s (%s-bit)\n' "${need}" "${f#"${VENDOR_DIR}"/}" "${_abi}" \
                   >> "${TMP}/unresolved"
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
            base="${impl##*/}"   # builtin; basename is toybox in a build action
            if [ -e "${VENDOR_DIR}/${abi}/hw/${base}" ]; then
                continue
            fi
            # 🔴 An exact-name miss is NOT a missing implementation. The
            # passthrough manager matches by PREFIX, not by filename:
            #
            #   system/libhidl/transport/ServiceManagement.cpp:253
            #     findFiles(path, "<package>@<version>-impl", ".so")
            #       -> base::StartsWith(name, prefix) && base::EndsWith(name, ".so")
            #
            # so a renamed impl still loads. This tree renames one:
            # android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so, because
            # hardware/mediatek/bootctrl has its own soong namespace and both
            # install rules survive otherwise. Comparing filenames flagged that
            # as missing on build 68 when the loader would have found it fine.
            #
            # Match what the loader matches: strip at "-impl" and look for any
            # file sharing that prefix.
            prefix="${base%%-impl*}-impl"
            if compgen -G "${VENDOR_DIR}/${abi}/hw/${prefix}*.so" >/dev/null 2>&1; then
                continue
            fi
            echo "MISSING IMPL: ${abi}/hw/${base}"
            IMPL_MISSING=$((IMPL_MISSING + 1))
        done < <(find "${STOCK_VENDOR}/${abi}/hw" -maxdepth 1 -name '*-impl*.so' 2>/dev/null)
    done
    echo "passthrough impls missing vs stock: ${IMPL_MISSING}"
elif [ -f "${IMPL_LIST}" ]; then
    while IFS= read -r rel; do
        [ -z "${rel}" ] && continue
        case "${rel}" in \#*) continue ;; esac
        if [ -e "${VENDOR_DIR}/${rel}" ]; then
            continue
        fi
        # Same prefix rule as the STOCK_VENDOR branch above, and this is the
        # branch the BUILD actually takes (Android.mk passes no STOCK_VENDOR).
        # The passthrough manager matches "<package>@<ver>-impl"* , so a renamed
        # impl still loads -- android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so
        # is one, and comparing filenames failed build 68 on a file the loader
        # would have found.
        ipfx="${rel%%-impl*}-impl"
        if compgen -G "${VENDOR_DIR}/${ipfx}"'*.so' >/dev/null 2>&1; then
            continue
        fi
        echo "MISSING IMPL: ${rel}"
        IMPL_MISSING=$((IMPL_MISSING + 1))
    done < "${IMPL_LIST}"
    echo "passthrough impls missing vs stock: ${IMPL_MISSING}"
else
    echo "NOTE: set STOCK_VENDOR=<stock vendor dir> to also check passthrough HAL impls."
    echo "      DT_NEEDED alone cannot detect a missing dlopen'd implementation."
fi

# --- a renamed vendor executable must keep its SELinux exec type ------------
#
# 🔴 Added 2026-08-18, after build 69 hung at the boot animation.
#
# extract-files.sh renames blobs that would collide with a platform module --
# ...wifi@1.0-service-stock, ...vibrator-service.mediatek-stock. Upstream
# file_contexts labels only the UNSUFFIXED spelling, so a renamed binary lands
# as plain vendor_file, init finds no domain transition and never execs it. The
# HAL is then silently absent: nothing fails to build, nothing fails to link,
# and this gate's DT_NEEDED pass is perfectly clean.
#
# The cost was a boot, not a feature. IVibrator and IVibratorManager are both
# DECLARED in the VINTF manifest, so a client blocks in waitForService forever
# and the boot animation never exits -- the same shape as build 68's keystore2
# hang one flash earlier. "A service running is not a service serving" has a
# predecessor: a binary INSTALLED is not a binary init will EXEC.
#
# The rule checked is narrow on purpose, so it reports regressions rather than
# pre-existing gaps: a path with NO domain-transition label whose canonical
# (de-`-stock`) spelling HAS one is a rename that lost its label. Three stock
# Transsion HALs in bin/hw have never had a label in any build, 61 onward; they
# are listed as a note and do not fail.
LABEL_BAD=0
FCTX="${VENDOR_DIR}/etc/selinux/vendor_file_contexts"
if [ -f "${FCTX}" ]; then
    # Positive control: the file must actually contain patterns, or every lookup
    # below returns "no label" and the check becomes noise instead of a verdict.
    FCTX_N=$(grep -cE '^/' "${FCTX}" 2>/dev/null || echo 0)
    if [ "${FCTX_N}" -lt 50 ]; then
        echo "!! REFUSING TO PASS: ${FCTX} has ${FCTX_N} patterns (expected many hundreds)" >&2
        exit 2
    fi
    _label() {  # _label <device path> -> prints the last matching context, or nothing
        local t="$1"
        awk -v t="$t" '$1 ~ /^\// && NF>=2 {
            pat="^" $1 "$"; if (t ~ pat) last=$NF
        } END { if (last != "") print last }' "${FCTX}" 2>/dev/null
    }
    for d in bin bin/hw; do
        [ -d "${VENDOR_DIR}/${d}" ] || continue
        for f in "${VENDOR_DIR}/${d}"/*; do
            [ -f "$f" ] && [ -x "$f" ] || continue
            base="${f##*/}"
            case "${base}" in *-stock*) ;; *) continue ;; esac
            dev="/vendor/${d}/${base}"
            canon="${dev//-stock/}"
            got="$(_label "${dev}")"
            want="$(_label "${canon}")"
            case "${got}" in ""|*vendor_file:s0) got="" ;; esac
            case "${want}" in ""|*vendor_file:s0) want="" ;; esac
            if [ -z "${got}" ] && [ -n "${want}" ]; then
                echo "UNLABELLED RENAME: ${dev}"
                echo "    gets no domain-transition label; ${canon} gets ${want}"
                echo "    -> add it to sepolicy/vendor/file_contexts (see the Wi-Fi entry)"
                LABEL_BAD=$((LABEL_BAD + 1))
            fi
        done
    done
    echo "renamed executables missing an exec type: ${LABEL_BAD}"
else
    echo "NOTE: no ${FCTX} -- cannot check exec types on renamed binaries."
fi

if [ ! -s "${TMP}/unresolved" ] && [ "${IMPL_MISSING}" -eq 0 ] && [ "${DANGLING}" -eq 0 ] \
   && [ "${PROP_BAD}" -eq 0 ] && [ "${SERVICE_MISSING}" -eq 0 ] \
   && [ "${MODULES_BAD}" -eq 0 ] && [ "${LABEL_BAD}" -eq 0 ]; then
    echo "OK: every DT_NEEDED resolves, no passthrough impl is missing vs stock,"
    echo "    no symlink dangles, no required vendor property is empty, every"
    echo "    init service has its binary, every renamed executable kept its"
    echo "    SELinux exec type, and every kernel module load list matches the"
    echo "    kernel package in both content and order"
    exit 0
fi
if [ "${MODULES_BAD}" -gt 0 ]; then
    echo
    echo "A module load list that differs from the kernel package is a boot"
    echo "failure with no logcat and no panic: module init hangs and the AP"
    echo "watchdog resets the device. Set BOARD_*_KERNEL_MODULES_LOAD in"
    echo "BoardConfig.mk -- leaving it unset does not mean 'default order',"
    echo "it means 'every .ko in \$(wildcard) order'."
fi
if [ "${PROP_BAD}" -gt 0 ]; then
    echo
    echo "An empty vendor property above will boot-loop the device via a path"
    echo "that never mentions the property. Fix it before flashing."
fi
if [ "${DANGLING}" -gt 0 ]; then
    echo
    echo "Fix the dangling symlinks first -- they make every other result here"
    echo "unreliable, and a library behind a broken link is unloadable."
fi
if [ ! -s "${TMP}/unresolved" ]; then
    # Link dependencies are clean, so name the check that actually failed rather
    # than blaming passthrough impls -- which is what this said until 2026-08-18,
    # when a missing SELinux exec type reported itself as a missing impl.
    echo "Link dependencies are clean. What failed:"
    [ "${IMPL_MISSING}" -gt 0 ]    && echo "  * ${IMPL_MISSING} passthrough HAL implementation(s) missing vs stock"
    [ "${LABEL_BAD}" -gt 0 ]       && echo "  * ${LABEL_BAD} renamed executable(s) with no SELinux exec type -- init will
    NOT exec them, so the HAL is silently absent. If its interface is DECLARED
    in the VINTF manifest, this is a BOOT HANG, not a missing feature."
    [ "${DANGLING}" -gt 0 ]        && echo "  * ${DANGLING} dangling symlink(s)"
    [ "${PROP_BAD}" -gt 0 ]        && echo "  * ${PROP_BAD} required vendor property empty"
    [ "${SERVICE_MISSING}" -gt 0 ] && echo "  * ${SERVICE_MISSING} init service(s) with no binary"
    [ "${MODULES_BAD}" -gt 0 ]     && echo "  * ${MODULES_BAD} kernel module load list mismatch(es)"
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
