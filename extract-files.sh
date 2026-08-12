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
        # ---- VNDK 31: blobs that abort against platform VNDK 33 -------------
        #
        # Measured on hardware 2026-08-11, both crash-looping every ~5 s from
        # the first seconds of boot, with NO SELinux denial and NO missing
        # symbol -- the giveaway that it is an ABI problem and not a packaging
        # one:
        #
        #   pq@2.2-service   'incStrongRequireStrong() ... isn't already owned'
        #                    (a libutils RefBase assertion: two libutils)
        #   audio.service    'terminating' (uncaught C++ exception)
        #
        # The audio one blocks boot -- AudioPolicyService never publishes and
        # system_server hangs in native_list_audio_product_strategies.
        #
        # 🔴 Renamed PER PROCESS, not per file. libutils/libhidlbase/libcutils
        # are vndk-SP and get loaded into the same address space as whatever
        # dlopens them, so a service and its passthrough impl must move
        # together -- half-renaming a process is how you CREATE the two-libutils
        # condition this fixes. pq@2.2-service and both ABIs of its
        # pq@2.15-impl are therefore one group.
        #
        # Deliberately NOT renamed: camerahalserver, media.c2@1.2-mediatek-64b
        # and thermal@2.0-impl. The previous device tree patched all three, so
        # they will probably need it eventually -- but none of them aborts today
        # and none blocks boot, and speculative renames are how the arm.graphics
        # one got in. Add them when they misbehave, with the measurement.
        vendor/bin/hw/vendor.mediatek.hardware.pq@2.2-service | \
        vendor/lib/hw/mt6789/vendor.mediatek.hardware.pq@2.15-impl.so | \
        vendor/lib64/hw/mt6789/vendor.mediatek.hardware.pq@2.15-impl.so)
            "${PATCHELF}" --replace-needed "libutils.so"    "libutils-v31.so"    "${2}"
            "${PATCHELF}" --replace-needed "libhidlbase.so" "libhidlbase-v31.so" "${2}"
            "${PATCHELF}" --replace-needed "libcutils.so"   "libcutils-v31.so"   "${2}" 2>/dev/null || true
            ;;
        vendor/bin/hw/android.hardware.audio.service.mediatek)
            "${PATCHELF}" --replace-needed "libutils.so"    "libutils-v31.so"    "${2}"
            "${PATCHELF}" --replace-needed "libhidlbase.so" "libhidlbase-v31.so" "${2}"
            "${PATCHELF}" --replace-needed "libcutils.so"   "libcutils-v31.so"   "${2}"
            "${PATCHELF}" --replace-needed "libbinder.so"   "libbinder-v31.so"   "${2}"
            # 🔴 patchelf does NOT update .gnu.version_r, and this binary has one.
            # Measured on hardware 2026-08-11, build 46:
            #
            #   CANNOT LINK EXECUTABLE ".../android.hardware.audio.service.mediatek":
            #     cannot find "libbinder.so" from verneed[0] in DT_NEEDED list
            #
            # The loader requires every version-needs entry to name a library that
            # is also in DT_NEEDED. The rename above removed libbinder.so from
            # DT_NEEDED and left the verneed entry pointing at it.
            #
            # This was LATENT until c2b72d9. While libbinder-v31.so still declared
            # SONAME=libbinder.so the verneed matched the loaded library by soname
            # and the loader was satisfied. Patching the SONAMEs was correct --
            # without it one version served the whole process -- and it is exactly
            # what exposed this. Two correct changes, one broken binary.
            #
            # Of the four renames above only libbinder appears in this file's
            # verneed, and none of the pq blobs' verneed entries name a library we
            # rename (they name libc/liblog/libsync/libdl). The tool is a no-op
            # where there is nothing to do, so it is safe to widen if that changes.
            "${MY_DIR}/tools/patch-verneed.py" "${2}" "libbinder.so" "libbinder-v31.so"
            "${MY_DIR}/tools/patch-verneed.py" --verify "${2}" "libbinder.so" || {
                echo "!! verneed still names libbinder.so -- the audio HAL will not link" >&2
                exit 1
            }
            ;;
        vendor/lib64/android.hardware.power-service-mediatek.so | \
        vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service)
            # This binary is the AIDL android.hardware.power IPower/default
            # provider -- the HAL whose absence boot-looped the device on
            # 2026-08-10 (PowerManagerService.nativeInit blocked, Watchdog killed
            # system_server at ~73 s, forever).
            #
            # It links android.hardware.power-V2-ndk_platform.so, which exists
            # nowhere in stock's vendor OR system: stock resolves it from
            # /apex/com.android.vndk.v31, which this ROM does not ship. Without
            # the rename it dies in the linker and the boot loop returns.
            #
            # The replacement genuinely exists here, which is what makes this
            # rename safe where the arm.graphics one was not: device.mk requests
            # android.hardware.power-service-mediatek from
            # hardware/mediatek/aidl/power-mediatek, and that module pulls in
            # android.hardware.power-V2-ndk. Confirmed in the built image at
            # /vendor/lib64/android.hardware.power-V2-ndk.so (55,200 bytes).
            #
            # If that PRODUCT_PACKAGES entry is ever dropped, this rename starts
            # pointing at nothing and the boot loop comes back. The two belong
            # together.
            "${PATCHELF}" --replace-needed "android.hardware.power-V2-ndk_platform.so" \
                "android.hardware.power-V2-ndk.so" "${2}"
            ;;
        vendor/lib/libeffects.so | vendor/lib64/libeffects.so)
            # Point stock's effects factory at stock's config parser.
            #
            # PROVEN on hardware, build 48: this blob crash-looped the audio HAL
            # 37 times per boot because it was calling the PLATFORM's
            # libeffectsconfig, which is AOSP's A13 build:
            #
            #   SIGSEGV  fault addr 0x72657a69 ("izer"), 0x7265 ("er")
            #     __strlen_aarch64 <- strdup
            #     <- libeffects.so EffectLoadXmlEffectConfig+256
            #
            # EffectLoadXmlEffectConfig gets a config struct back from the
            # parser; the layout moved between A12 and A13, so a string field is
            # read where a pointer belongs and handed to strdup. Every fault
            # address is ASCII because it is literally reading the library names
            # out of audio_effects.xml. Bind-mounting stock's parser on the
            # running device fixed it outright: HAL restarting -> running,
            # crashes 10 -> 0, and media.audio_policy finally published.
            #
            # Stock's parser is shipped as libeffectsconfig-STOCK.so rather than
            # under its own name, because the plain name collides:
            #
            #   base_rules.mk:338: MODULE.TARGET.SHARED_LIBRARIES.libeffectsconfig
            #     already defined by frameworks/av/media/libeffects/config
            #
            # and dropping libeffectsconfig.vendor from PRODUCT_PACKAGES does NOT
            # avoid that -- the clash is on the make module NAME, which soong
            # emits for the platform module regardless of who requests it. Same
            # collision that broke build 42 on libvibrator, and build 49 here.
            # Renaming the blob sidesteps it entirely and is the technique this
            # tree already uses for the v31 libraries.
            #
            # Only libeffects.so links libeffectsconfig, both ABIs, and it is
            # itself a stock blob -- so this rename reaches every consumer. It
            # has no .gnu.version_r entry for it either (liblog/libc/libdl only),
            # so no verneed repair is needed here.
            "${PATCHELF}" --replace-needed "libeffectsconfig.so" \
                "libeffectsconfig-stock.so" "${2}"
            ;;
        vendor/etc/init/android.hardware.media.c2@1.2-mediatek.rc)
            # Not a soname fixup -- an init service pointed at a binary this
            # tree does not install.
            #
            # Stock ships TWO c2 binaries and exactly ONE rc, and the rc names
            # the 32-bit one:
            #
            #   bin/hw/android.hardware.media.c2@1.2-mediatek       8,204 B  32-bit
            #   bin/hw/android.hardware.media.c2@1.2-mediatek-64b  15,616 B  64-bit
            #   etc/init/...mediatek.rc -> service ... /vendor/bin/hw/...-mediatek
            #
            # This tree is 64-bit-only for codec2: proprietary-files.txt carries
            # the -64b binary and the lib64 halves of libcodec2_mtk_{c2store,
            # vdec,venc}, and NOT their 32-bit halves. So as extracted, the rc
            # names a binary that is never installed, while the binary that IS
            # installed has no rc anywhere -- stock has none for -64b either.
            # Net effect: no MediaTek C2 service starts at all, while the merged
            # VINTF manifest still declares
            #     android.hardware.media.c2@1.2::IComponentStore/default
            # That is the same declared-but-unimplemented shape that boot-looped
            # this device on the power HAL, and it is what mediaserver was
            # retrying once a second in the 2026-08-06 logs.
            #
            # Repointing at -64b rather than shipping the 32-bit stack, because
            # 64-bit is what the tree already committed to: f7c72b1 exists
            # specifically to put libavservices_minijail.so into lib64 so this
            # binary could link. The alternative costs three more blobs (~1.9 MB)
            # to run a service in the ABI we deliberately dropped.
            #
            # Label-neutral: no file_contexts entry exists for EITHER binary, in
            # sepolicy_vndr or here, so both take the same generic label from
            # their shared directory. Verified before changing the path.
            sed -i 's|\(/vendor/bin/hw/android\.hardware\.media\.c2@1\.2-mediatek\)$|\1-64b|' "${2}"
            # Loud, because a sed that silently matches nothing leaves exactly
            # the defect it was added to fix, and the build would not notice.
            grep -q 'mediatek-64b$' "${2}" || {
                echo "!! blob_fixup: c2 rc was not repointed to -64b -- pattern stale" >&2
                exit 1
            }
            ;;
        # The rest of the _platform class, found by sweeping the BUILT vendor
        # image for sonames nothing installs -- not by reading the blob list.
        # Each replacement below was confirmed PRESENT in /vendor/lib64 of a
        # completed build before the rename was added here; that check is the
        # whole difference between this and the arm.graphics mistake.
        vendor/bin/hw/android.hardware.lights-service.mediatek)
            # Boot-blocking. LightsService calls waitForDeclaredService() and
            # blocks system_server's main thread until Watchdog kills it, which
            # is where the boot loop moved to once the power HAL was fixed.
            "${PATCHELF}" --replace-needed "android.hardware.light-V1-ndk_platform.so" \
                "android.hardware.light-V1-ndk.so" "${2}"
            ;;
        vendor/bin/hw/android.hardware.gnss-service.mediatek | \
        vendor/lib64/hw/android.hardware.gnss-impl-mediatek.so)
            "${PATCHELF}" --replace-needed "android.hardware.gnss-V1-ndk_platform.so" \
                "android.hardware.gnss-V1-ndk.so" "${2}"
            ;;
        vendor/bin/hw/android.hardware.security.keymint-service.trustonic)
            # One binary serves all three interfaces, so all three sonames move.
            # keymint-V1-ndk.vendor is already installed as a dependency of
            # something else; secureclock and sharedsecret are not, which is why
            # device.mk requests their .vendor variants explicitly. Without that
            # this rename would point at nothing -- and this is the HAL behind
            # the Trustonic keybox, i.e. Play Integrity and e-KYC.
            # 🔴 Unrolled ON PURPOSE. Do not "tidy" this into a for-loop.
            #
            # blob_fixup() is called from inside extract()'s own loop and shares
            # its scope. extract_utils.sh:305 counts with `for (( i=1; i<COUNT+1;
            # i++ ))`, so a `for i in ...` here leaves i="sharedsecret", which
            # the arithmetic evaluates as 0 -- and the entire extraction restarts
            # from the first blob, forever. Observed: 45,106 log lines, 766
            # unique, every path emitted exactly 60 times before it was killed.
            #
            # Any loop variable added here must be `local`, or named something
            # extract_utils cannot be using. Not worth the risk for three lines.
            "${PATCHELF}" --replace-needed "android.hardware.security.keymint-V1-ndk_platform.so" \
                "android.hardware.security.keymint-V1-ndk.so" "${2}"
            "${PATCHELF}" --replace-needed "android.hardware.security.secureclock-V1-ndk_platform.so" \
                "android.hardware.security.secureclock-V1-ndk.so" "${2}"
            "${PATCHELF}" --replace-needed "android.hardware.security.sharedsecret-V1-ndk_platform.so" \
                "android.hardware.security.sharedsecret-V1-ndk.so" "${2}"
            ;;
        # NOTE: arm.graphics-V1-ndk_platform is deliberately NOT renamed here.
        #
        # The android.hardware.light-V1-ndk rename above IS correct -- that AIDL
        # library really did drop the _platform suffix on the Android 13 branch,
        # and soong builds android.hardware.light-V1-ndk plus a .vendor variant.
        #
        # arm.graphics did not. soong on this branch builds the module
        # arm.graphics-V1-ndk_platform, WITH the suffix, and stock ships
        # arm.graphics-V1-ndk_platform.so. Renaming by analogy with the light HAL
        # left both copies of android.hardware.graphics.mapper@4.0-impl-mediatek.so
        # depending on a soname nothing on the device provides, which an ELF
        # dependency audit of the built vendor image caught.
        #
        # Check before reinstating any rename here:
        #   grep '^LOCAL_MODULE := arm.graphics' out/soong/Android-*.mk
    esac
}

setup_vendor "${DEVICE}" "${VENDOR}" "${ANDROID_ROOT}" false "${CLEAN_VENDOR}"
extract "${MY_DIR}/proprietary-files.txt" "${SRC}" "${KANG}" --section "${SECTION}"

"${MY_DIR}/setup-makefiles.sh"

# CLEAN_VENDOR defaults to true, so the run above WIPED the vendor directory and
# re-extracted everything from stock -- including the GPU driver.
#
# The vendor repository carries Mali r38p1 (Vulkan 1.3) committed at
#   proprietary/vendor/lib64/egl/mt6789/libGLES_mali.so
#   proprietary/vendor/lib/egl/mt6789/libGLES_mali.so
# and a clean extraction has just replaced both with itel's stock r32p1
# (Vulkan 1.1). No error, no warning -- the build is perfectly valid, it is
# simply two Khronos versions behind.
#
# This is deliberately left VISIBLE rather than automated away. Those two paths
# stay listed in proprietary-files.txt, so an extraction always produces a
# working driver even on a tree that has never seen r38p1, and the difference
# shows up as two modified files in `git status` instead of as a silent
# regression discovered later by a user whose Winlator got slower.
if git -C "${ANDROID_ROOT}/vendor/${VENDOR}/${DEVICE}" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "${ANDROID_ROOT}/vendor/${VENDOR}/${DEVICE}" diff --quiet -- \
            proprietary/vendor/lib64/egl/mt6789/libGLES_mali.so 2>/dev/null; then
        echo
        echo "NOTE: the Mali driver is now stock r32p1 (Vulkan 1.1)."
        echo "      The vendor repo has r38p1 committed. To restore Vulkan 1.3:"
        echo "          git -C vendor/${VENDOR}/${DEVICE} checkout -- \\"
        echo "              proprietary/vendor/lib64/egl/mt6789/libGLES_mali.so \\"
        echo "              proprietary/vendor/lib/egl/mt6789/libGLES_mali.so"
        echo "      Then wipe the shader caches on first boot:"
        echo "          rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache"
    fi
fi
