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
# Stock's Android-12 codec2 set, shipped alongside the platform's Android-13 one.
#
# WHY THEY ARE RENAMED AT ALL. With the vendor namespace on VNDK 31 the MTK C2
# HAL needs A12 partners: the platform's copies crash-loop it every 5 s on
# `hardware::details::check`, a v33-only symbol. But these are AOSP libraries and
# soong builds VENDOR VARIANTS of them whether or not the product asks -- with
# all nine `.vendor` entries removed from device.mk, `mediaswcodec` and
# `libmedia_codecserviceregistrant` still pull them in. So a prebuilt installing
# to the same /vendor path is a duplicate make rule:
#
#   installs-lineage_S666LN.mk: error: overriding commands for target
#     `.../vendor/lib64/android.hardware.media.c2@1.0.so'
#
# That failed build 64. A unique soong `name` with a `stem` does NOT fix it --
# `stem` avoids the module-NAME clash, which is the one the journal documents,
# and leaves the install PATH identical. Distinct filenames are the only route,
# and it is the pattern this tree already uses four times (libeffectsconfig-stock,
# libwifi-hal-stock, ese_spi_nxp-stock, the wifi service).
#
# The eleven move as one generation. Proven both directions on hardware:
# stock libcodec2_vndk with the platform's libcodec2_hidl fails on
# `_C2FenceFactory::CreateNativeHandle`, and holding back
# libcodec2_hidl_plugin / soft_common / ccodec_utils works at runtime but each
# links libcodec2_vndk.so, so leaving them platform-built defeats the swap.
C2_STOCK_LIBS="android.hardware.media.c2@1.0 android.hardware.media.c2@1.1 \
android.hardware.media.c2@1.2 libcodec2_hidl@1.0 libcodec2_hidl@1.1 \
libcodec2_hidl@1.2 libcodec2_hidl_plugin libcodec2_vndk libcodec2_soft_common \
libsfplugin_ccodec_utils libstagefright_bufferpool@2.0.1"

# Repoint every reference to the renamed set, then prove none survived.
#
# 🔴 `local` is MANDATORY on the loop variable. blob_fixup() is called from
# inside extract()'s own loop and shares its scope; extract_utils.sh:305 counts
# with `for (( i=1; i<COUNT+1; i++ ))`, so a bare loop variable there restarts
# the whole extraction forever -- observed once already, 45,106 log lines.
# patchelf --replace-needed is a silent no-op (exit 0) when the dependency is
# absent, so this needs no error suppression and real failures stay visible.
function c2_stock_repoint() {
    local target="${1}" lib
    for lib in ${C2_STOCK_LIBS}; do
        "${PATCHELF}" --replace-needed "${lib}.so" "${lib}-stock.so" "${target}"
    done
    for lib in ${C2_STOCK_LIBS}; do
        if "${PATCHELF}" --print-needed "${target}" | grep -qx "${lib}.so"; then
            echo "!! blob_fixup: ${target} still needs ${lib}.so after repointing" >&2
            exit 1
        fi
    done
}

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
        vendor/bin/hw/android.hardware.audio.service.mediatek | \
        vendor/lib/hw/android.hardware.audio@6.0-impl-mediatek.so | \
        vendor/lib64/hw/android.hardware.audio@6.0-impl-mediatek.so | \
        vendor/lib/hw/android.hardware.audio@7.0-impl-mediatek.so | \
        vendor/lib64/hw/android.hardware.audio@7.0-impl-mediatek.so)
            # Drop ONE vestigial dependency, and the whole A12/A13 audio cascade
            # goes with it. PROVEN LIVE 2026-08-13 on a KSU overlay, whole boot:
            # init.svc.vendor.audio-hal running, media.audio_policy found.
            #
            # libaudiofoundation.so is loaded by these three and NEVER USED:
            #
            #   symbols the service needs from it        0
            #   symbols either impl needs from it        0
            #   anything else in /vendor linking it      nothing
            #
            # and it references _ZTVN7android5media11AudioDeviceE, a symbol that
            # exists NOWHERE in the entire stock firmware -- not vendor, system,
            # system_ext, product, nor stock's own com.android.vndk.v31.apex. So
            # on stock this path is never taken; our dependency CHAIN differs
            # from stock's, not merely our libraries.
            #
            # Renaming that string to liblog.so -- shorter, already loaded, and
            # zero symbols taken from it -- prunes SEVEN libraries out of the
            # process's runtime set, measured by closure:
            #
            #   libaudioclient_aidl_conversion.so   <-- the one that killed
            #   audioclient-types-aidl-cpp.so           build 46
            #   audio_common-aidl-cpp.so
            #   framework-permission-aidl-cpp.so
            #   shared-file-region-aidl-cpp.so
            #   libshmemcompat.so   libshmemutil.so
            #
            # That is why NONE of stock's AOSP audio interface libraries has to
            # be shipped: the A13 copies this tree builds are never reached.
            # Validated by omission -- the overlay carried no interface libs and
            # the stack came up clean.
            #
            # 🔴 The four -v31 renames that used to be here are GONE, along with
            # their patch-verneed repair. They were the per-blob workaround for
            # platform VNDK 33; device.mk now ships the v31 apex and vendor.prop
            # points ro.vndk.version at it, so these blobs get the A12 ABI they
            # were built against by NAMESPACE, with no renaming anywhere. That is
            # what stock does, and it is why stock's vendor contains zero
            # -v3?.so files.
            #
            # No verneed repair is needed for this rename: checked on all five
            # files, none names libaudiofoundation in .gnu.version_r.
            "${PATCHELF}" --replace-needed "libaudiofoundation.so" "liblog.so" "${2}"
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
        vendor/lib64/nfc_nci_nxp.so | vendor/bin/hw/android.hardware.nfc@1.2-service)
            # Point stock's NFC stack at stock's secure-element library.
            #
            # NFC has failed on every build of this tree, four restarts per boot:
            #
            #   CANNOT LINK EXECUTABLE "/vendor/bin/hw/android.hardware.nfc@1.2-service":
            #     cannot locate symbol "_ZN5MutexD1Ev"
            #     referenced by "/vendor/lib64/nfc_nci_nxp.so"
            #
            # Measured rather than guessed. `_ZN5MutexD1Ev` is `Mutex::~Mutex()`
            # in the GLOBAL namespace -- not android::Mutex, which would mangle
            # as _ZN7android5MutexD1Ev -- and exactly one stock vendor library
            # defines it:
            #
            #   stock     lib64/ese_spi_nxp.so   131,520 B  sha 0f4ef106  DEFINES it
            #   installed lib64/ese_spi_nxp.so    95,816 B  sha 80db376c  does NOT
            #
            # nfc_nci_nxp.so already lists ese_spi_nxp.so in its DT_NEEDED, so
            # nothing was missing -- the file present at that path was simply a
            # different library. device.mk requested `ese_spi_nxp` from source,
            # and that build does not export the symbol stock's blob needs.
            #
            # The fourth instance of one pattern, after libhapticgenerator,
            # nfc_nci_nxp itself and libeffectsconfig: a stock blob paired with a
            # platform-built library that does not match it. The question is
            # never "blob or source", it is WHICH PAIR ACTUALLY MATCHES.
            #
            # Shipped renamed because `ese_spi_nxp` is already a module name
            # (three definitions in the soong export), and dropping it from
            # PRODUCT_PACKAGES does not undefine it -- the libvibrator/
            # libeffectsconfig lesson. Both stock consumers are repointed here;
            # a sweep of every stock vendor ELF found exactly three references to
            # ese_spi_nxp.so -- this service, nfc_nci_nxp.so, and the library
            # itself -- so this reaches all of them.
            "${PATCHELF}" --replace-needed "ese_spi_nxp.so" \
                "ese_spi_nxp-stock.so" "${2}"
            ;;
        vendor/bin/hw/android.hardware.wifi@1.0-service-stock)
            # Stock's Wi-Fi HAL, and it has to be stock's. PROVEN ON HARDWARE,
            # build 57: the chip is powered and wlan0/wlan1/p2p0 created by a
            # write to /dev/wmtWifi, and only stock's libwifi-hal.so does it.
            #
            #   strings stock/lib64/libwifi-hal.so | grep -c wmtWifi   ->  1
            #   strings built/lib64/libwifi-hal.so | grep -c wmtWifi   ->  0
            #
            # Bind-mounting stock's library under the platform service on a
            # running build 57 produced, in one step:
            #   [WMT-CORE] [AF FUNC ON] ... w:2
            #   [MTK-WIFI] WIFI_write[I]: WMT turn on WIFI success!
            #   wlan0 wlan1 p2p0, ClientModeManager ROLE_CLIENT_PRIMARY,
            #   init.svc.wpa_supplicant=running, scan returns APs on 2.4+5 GHz
            # and without it, across a whole boot, the ONLY w:2 power-on event
            # was a manual `echo 1 > /dev/wmtWifi`.
            #
            # The platform's libwifi-hal cannot do it and cannot be fixed by
            # configuration: it is a thin wrapper (driver_tool.cpp, hal_tool.cpp)
            # whole-static-linking libwifi-hal-mt66xx from hardware/mediatek/wlan,
            # and that repo contains SIX source files and zero references to
            # wmtWifi. 77,272 bytes against stock's 201,024.
            #
            # 🔴 Ruled out before settling on this, each by measurement:
            #   * wlan_assistant powering the chip -- its three wmtWifi strings
            #     are "/dev/wmtWifi", "is not a char device", "was removed, need
            #     to exit". It MONITORS the node, it never writes it.
            #   * the supplicant dac_override/dac_read_search denials -- zero of
            #     them occur in the working run; they were fallout from the HAL
            #     dying first.
            #
            # Both the binary and the library are renamed because `libwifi-hal`
            # and `android.hardware.wifi@1.0-service-lazy` are BOTH unconditional
            # kati modules (frameworks/opt/net/wifi/libwifi_hal/Android.mk:139,
            # hardware/interfaces/wifi/1.6/default/Android.mk:132), so each is
            # defined on every build whether or not anything requests it. That is
            # what failed build 55. Renaming the library then makes it unloadable
            # by the platform service -- its DT_NEEDED still says libwifi-hal.so
            # and a platform binary cannot be patched from here -- so the stock
            # binary has to come along. They are a matched A12 pair in any case,
            # which is the rule this tree learned from libhapticgenerator,
            # nfc_nci_nxp and libeffectsconfig.
            "${PATCHELF}" --replace-needed "libwifi-hal.so" \
                "libwifi-hal-stock.so" "${2}"
            ;;
        vendor/etc/init/android.hardware.wifi@1.0-service-stock.rc)
            # Follow the binary rename into its init script.
            #
            # Only the exec PATH changes. The service name (vendor.wifi_hal_legacy)
            # and all six `interface` lines are left exactly as stock wrote them,
            # because those are what hwservicemanager matches to lazy-start the
            # HAL -- renaming them would break the start trigger, which is the
            # entire point of a lazy service.
            #
            # Renamed rather than shipped under its stock name because the
            # platform module carries
            #   LOCAL_INIT_RC := android.hardware.wifi@1.0-service-lazy.rc
            # (hardware/interfaces/wifi/1.6/default/Android.mk:163) and installs
            # to the same /vendor/etc/init path. base_rules.mk writes that install
            # rule even for a module nothing requests -- the 2026-08-04 finding --
            # so the stock name is a second collision waiting to happen.
            sed -i 's|\(/vendor/bin/hw/android\.hardware\.wifi@1\.0-service\)-lazy$|\1-stock|' "${2}"
            # Loud, because a sed that silently matches nothing leaves exactly the
            # defect it was added to fix and the build would not notice.
            grep -q '/vendor/bin/hw/android\.hardware\.wifi@1\.0-service-stock$' "${2}" || {
                echo "!! blob_fixup: wifi rc was not repointed to -stock -- pattern stale" >&2
                exit 1
            }
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
        # ---- the renamed A12 codec2 set ------------------------------------
        # SONAME is patched as well as DT_NEEDED, and it is not optional: the
        # platform's A13 copy keeps the canonical name and stays installed, so
        # if both ever land in one process the first loaded wins the name for
        # all of it. That is the defect prebuilts/vndk31/Android.bp documents.
        # The soname comes from the destination filename, so it cannot drift
        # from proprietary-files.txt's rename.
        vendor/lib64/android.hardware.media.c2@1.0-stock.so | \
        vendor/lib64/android.hardware.media.c2@1.1-stock.so | \
        vendor/lib64/android.hardware.media.c2@1.2-stock.so | \
        vendor/lib64/libcodec2_hidl@1.0-stock.so | \
        vendor/lib64/libcodec2_hidl@1.1-stock.so | \
        vendor/lib64/libcodec2_hidl@1.2-stock.so | \
        vendor/lib64/libcodec2_hidl_plugin-stock.so | \
        vendor/lib64/libcodec2_vndk-stock.so | \
        vendor/lib64/libcodec2_soft_common-stock.so | \
        vendor/lib64/libsfplugin_ccodec_utils-stock.so | \
        vendor/lib64/libstagefright_bufferpool@2.0.1-stock.so)
            "${PATCHELF}" --set-soname "$(basename "${2}")" "${2}"
            c2_stock_repoint "${2}"
            ;;
        # ---- the MTK blobs that consume them --------------------------------
        # Every /vendor consumer of libcodec2_vndk.so, enumerated on hardware
        # rather than guessed. The C2 service binary is the important one; the
        # rest are the MTK component libraries it dlopens.
        vendor/bin/hw/android.hardware.media.c2@1.2-mediatek-64b | \
        vendor/lib64/libcodec2_mtk_c2store.so | \
        vendor/lib64/libcodec2_mtk_vdec.so | \
        vendor/lib64/libcodec2_mtk_venc.so | \
        vendor/lib64/libcodec2_soft_mtk_alacdec.so | \
        vendor/lib64/libcodec2_soft_mtk_apedec.so | \
        vendor/lib64/libcodec2_soft_mtk_imaadpcmdec.so | \
        vendor/lib64/libcodec2_soft_mtk_mp3dec.so | \
        vendor/lib64/libcodec2_soft_mtk_msadpcmdec.so | \
        vendor/lib64/libcodec2_vpp_qt_plugin.so | \
        vendor/lib64/libcodec2_vpp_rs_plugin.so)
            c2_stock_repoint "${2}"
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
