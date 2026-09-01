#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/itel/S666LN

# NOTE: this tree deliberately does NOT force ADB on. The stock tree carried a
# block setting ro.secure=0 / ro.adb.secure=0 / ro.debuggable=1 /
# persist.sys.usb.config=adb. The three ro.* landed in vendor/build.prop and
# were inert (system's build.prop wins, ro.* is first-writer-wins), but
# persist.sys.usb.config is not a ro. property, so it applied — and
# post_process_props appends ",adb" whenever ro.debuggable=1, which
# UsbDeviceManager turns into adb_enabled=1 on first boot. The result was USB
# debugging enabled by default on user builds. Let the build variant decide.

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=erofs \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += \
    otapreopt_script \
    update_engine \
    update_engine_sideload \
    update_verifier

# Dynamic partitions / Virtual A/B.
# These are PRODUCT_* variables so they must be set from a product makefile —
# board_config.mk makes PRODUCT_* readonly before BoardConfig.mk is included.
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_VIRTUAL_AB_OTA := true

PRODUCT_PACKAGES += \
    fastbootd

# vndservicemanager. AOSP only installs this via
# PRODUCT_PACKAGES_SHIPPING_API_LEVEL_29 (base_vendor.mk), i.e. only for
# devices shipping at API <= 29 — and this device sets shipping API 31. But
# the Android-12 vendor blobs still open /dev/vndbinder, and with no context
# manager present /vendor/bin/pnpmgr retried roughly once a second forever.
#
# 🔴 The DAEMON is now stock's, in proprietary-files.txt. Built at A13 it holds
#     bin/vndservicemanager   UND _ZTVN7android2os14ConnectionInfoE
# i.e. a vtable v33's libbinder defines and v31's does not, so under a v31 vendor
# namespace it does not start -- and then nothing answers /dev/vndbinder and the
# exact pnpmgr retry loop this block exists to prevent comes back. Found by
# tools/v31-delta-check.py, which classifies it as reachable because
# vendor/etc/init/vndservicemanager.rc starts it by path.
#
# `vndservice` (the CLI) stays a source build: it is a separate process, it holds
# no v33-only reference, and nothing loads it into the daemon's address space.
PRODUCT_PACKAGES += \
    vndservice

# Launch API level. Stock declares ro.product.first_api_level=31, i.e. the device
# shipped originally on Android 12. This is what Treble/VSR requirements gate on,
# and it is NOT the same as the vendor's build SDK.
PRODUCT_SHIPPING_API_LEVEL := 31

# VNDK 31. THIS IS LOAD-BEARING; it is not a version-bump preference.
#
# Stock's vendor partition, both prop blocks, measured from the rev 28 dump:
#
#   ro.product.first_api_level      = 31    device launched on Android 12
#   ro.vendor.build.version.sdk     = 31    vendor was BUILT at Android 12
#   ro.vndk.version                 = 31
#
# (33 is the SYSTEM side — ro.build.version.sdk. An A13 system on an A12 vendor,
# exactly like every other MT6789 device. Three numbers that are easy to
# conflate, and conflating them is what caused the bug below.)
#
# The vendor blobs link A12-era AIDL sonames with the `_platform` suffix that
# AOSP dropped in Android 13 — android.hardware.power-V2-ndk_platform.so,
# gnss-V1-ndk_platform.so, memtrack-V1-ndk_platform.so, the three Trustonic
# keymint ones, vibrator-V2-ndk_platform.so, and more. Around twenty vendor ELFs
# in rev 28 need one. NONE of those libraries exists in stock's vendor or system
# partitions: they live inside com.android.vndk.v31.apex, which stock ships in
# /system_ext/apex/. Pinning 31 is what puts that apex on the device.
#
# 🔴 What happens without it, measured on hardware 2026-08-10 (build 24):
#   /apex/com.android.vndk.v33 is shipped instead, no `_platform` soname
#   resolves, so vendor.mediatek.hardware.mtkpower@1.0-service -- which IS the
#   AIDL android.hardware.power IPower/default provider that this device's
#   VINTF manifest declares -- cannot load. PowerManagerService.nativeInit()
#   then blocks forever waiting for a HAL the manifest promised:
#
#     Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on main
#       at PowerManagerService.nativeInit(Native Method)
#       at SystemServer.startBootstrapServices(SystemServer.java:1163)
#
#   system_server is killed at ~73 s and restarts forever. It presents as a boot
#   animation that never ends, with no tombstone and no crash.
#
# The earlier version of this comment claimed stock was VNDK 33 and that pinning
# 31 "would force the prebuilts/vndk/v31 snapshot under blobs built against 33".
# Both halves were wrong, and they came from measuring the SHIPPED crDroid build
# (.build/work/shipped/v) instead of the stock dump (.build/work/vendor). See
# notes/AUDIT-2026-08-10.md.
#
# 🔴 AND SO WAS THE FIX. PRODUCT_TARGET_VNDK_VERSION := 31 was committed here
# and is INERT: `grep -rn PRODUCT_TARGET_VNDK_VERSION build/make/` returns
# nothing on lineage-20.0. The variable this branch reads is BOARD_VNDK_VERSION
# (build/make/core/main.mk:225-231), and it is what sets ro.vndk.version. The
# built image proved it -- ro.vndk.version=33 and no v31 apex, exactly as before
# the "fix". A variable nobody reads is the vendor_mtk_powerhal_prop trap again:
# it compiles, changes nothing, and fails no check.
#
# Deliberately NOT setting BOARD_VNDK_VERSION := 31 either, even though it is
# the by-the-book way to set the property. It also controls what every vendor
# module in the tree is COMPILED against -- hardware/mediatek, the source-built
# power/vibrator/memtrack HALs, wpa_supplicant -- and fails with 967 soong
# errors. What is SHIPPED and what is COMPILED against are different questions.
#
# ✅ THE MECHANISM THAT WORKS, and it is two variables in two files.
# Proven on hardware 2026-08-13: with the v31 set in the vendor namespace,
# camerahalserver's incStrongRequireStrong aborts go 4+ per open -> 0 and the
# camera reaches CameraState{type=OPEN}, which has never happened on this tree.
#
#   1. PRODUCT_PACKAGES += com.android.vndk.v31.apex  (below)  SHIPS the apex.
#      It installs to /system_ext/apex/com.android.vndk.v31.apex -- byte for
#      byte the location stock uses. Purely additive: it changes nothing about
#      what is COMPILED, which is why it is safe where BOARD_VNDK_VERSION is not.
#
#      🔴 It is NOT `PRODUCT_EXTRA_VNDK_VERSIONS := 31`, and that variable is
#      NOT set by this tree. On lineage-20.0 it is INERT -- verified on the
#      build tree itself, not on a newer branch:
#
#        build/make/core/main.mk  define auto-included-modules
#            $(if $(BOARD_VNDK_VERSION),vndk_package) ...   <- no VNDK_VERSIONS
#        build/soong  android.deviceConfig.ExtraVndkVersions()  ZERO callers
#
#      All it does here is board_config.mk's check_vndk_version existence test.
#      The auto-included-modules line that WOULD ship the apex exists only on
#      A15/A16-era trees. Setting it and expecting an apex is the
#      PRODUCT_TARGET_VNDK_VERSION trap for the second time, three paragraphs
#      below where that trap is documented. Caught before build 64 only because
#      the check was re-run against the real branch.
#
#      The right module name matters too: `com.android.vndk.v31` is a PHONY
#      package that pulls the individual .vendor.31 libraries;
#      `com.android.vndk.v31.apex` is the one carrying LOCAL_MODULE_PATH
#      .../system_ext/apex and LOCAL_UNINSTALLABLE_MODULE := false. The current
#      VNDK ships as `com.android.vndk.current.apex`, same suffix -- that is the
#      control.
#
#   2. ro.vndk.version=31 in configs/properties/vendor.prop  POINTS the vendor
#      namespace at it. linkerconfig reads that property. Without it the apex
#      ships and nothing ever loads out of it.
#
# 🔴 Why (2) is in vendor.prop and NOT in PRODUCT_VENDOR_PROPERTIES, which is
# the obvious home for it. The generated /vendor/build.prop is assembled from
# labelled sections, measured on build 63's own copy:
#
#     line  31   from TARGET_VENDOR_PROP (configs/properties/vendor.prop)
#     line 709   from variable ADDITIONAL_VENDOR_PROPERTIES -> ro.vndk.version=33
#     line 727   from variable PRODUCT_VENDOR_PROPERTIES
#
# ro.* is write-once, so the FIRST declaration wins. The build system emits 33
# into ADDITIONAL_VENDOR_PROPERTIES and will keep doing so; a
# PRODUCT_VENDOR_PROPERTIES entry lands AFTER it and would silently lose.
# TARGET_VENDOR_PROP is the only section that precedes it. So the file declares
# the key twice with conflicting values -- the same shape as stock's own
# ro.sf.lcd_density 480/320 -- and here that is intended, resolved by ordering.
#
# ⚠ ASSERT IT, DO NOT TRUST IT. The failure mode of this entire family is a
# variable nobody reads: PRODUCT_TARGET_VNDK_VERSION compiled, changed nothing,
# and failed no check. After any build that touches this, confirm BOTH:
#
#     getprop ro.vndk.version           -> 31
#     ls -d /apex/com.android.vndk.v31  -> exists
#
# A 33 there means the section ordering above has changed and the camera fix is
# not in the build, however green everything else looks.
# The v31 libraries go into /vendor/lib*/vndk-sp, NOT into an apex.
#
# 🔴 The apex route is CLOSED on this branch, and build 65 is how that was
# learned. Shipping com.android.vndk.v31.apex works (it builds and stages to
# /system_ext/apex, byte for byte where stock puts it), but nothing would ever
# load out of it: the vendor namespace only searches an apex named by
# ro.vndk.version, and that property cannot be set to 31 here.
#
#   build/make/core/main.mk:224-230
#     ifdef BOARD_VNDK_VERSION
#       ifeq ($(BOARD_VNDK_VERSION),current)
#         ADDITIONAL_VENDOR_PROPERTIES := ro.vndk.version=$(PLATFORM_VNDK_VERSION)
#       else
#         ADDITIONAL_VENDOR_PROPERTIES := ro.vndk.version=$(BOARD_VNDK_VERSION)
#
#   build/make/core/config.mk:735   BOARD_VNDK_VERSION := current   (the default)
#
# So the build always emits ro.vndk.version=33, and declaring 31 in vendor.prop
# as well is not "first writer wins" -- post_process_props REFUSES it:
#
#     error: found duplicate sysprop assignments:
#     ro.vndk.version=31
#     ro.vndk.version=33
#
# The only lever is BOARD_VNDK_VERSION := 31, which changes what every vendor
# module COMPILES against and fails with 967 soong errors (see
# prebuilts/vndk31/Android.bp).
#
# ✅ None of that is needed, because ro.vndk.version=31 was never what fixed the
# camera. The configuration PROVEN on hardware 2026-08-13 ran with
# ro.vndk.version=33 and the v33 apex still installed -- the v31 libraries were
# found because BOTH namespaces search /vendor/${LIB}/vndk-sp first, measured on
# the device:
#
#   [vendor]  vndk.search.paths = /odm/${LIB}/vndk-sp
#                              += /vendor/${LIB}/vndk-sp   <- these win
#                              += /vendor/${LIB}/vndk
#                              += /apex/com.android.vndk.v33/${LIB}
#   [system]  vndk.search.paths = /odm/${LIB}/vndk-sp
#                              += /vendor/${LIB}/vndk-sp   <- and here too
#                              += /apex/com.android.vndk.v33/${LIB}
#
# 🔴 They go in vndk/, NOT vndk-sp/, and that is deliberate on two counts.
#
# (a) soong already owns a rule for vendor/lib{,64}/vndk-sp/libutils.so --
#     system/linkerconfig/testmodules/vndkext/libutils_vendor, a TEST module --
#     so PRODUCT_COPY_FILES there is a duplicate make rule and a parse-time
#     error. vendor/lib{,64}/vndk has ZERO soong rules, both ABIs.
#
# (b) it gives each namespace ONE coherent set instead of a mixture. The
#     [vendor] section searches vndk-sp then vndk then the apex, so vendor
#     processes get all-v31; the [system] section never searches vndk/ at all,
#     so system processes stay all-v33, exactly as they are today. Measured on
#     hardware: camerahalserver maps 139 libraries out of /vendor/lib64/vndk/,
#     SurfaceFlinger maps 0 of them.
#
#     The journal's warning about splitting was about SP libs in vndk-sp and
#     core libs in vndk -- an incoherent MIX inside one process, which killed
#     the gralloc mapper. A complete set in one directory is the opposite.
#
# The whole set must stay together for the same reason: never put part of it in
# vndk-sp and part in vndk.
#
# (c) PRODUCT_COPY_FILES cannot carry them at all -- the build rejects ELF
#     prebuilts there ("use cc_prebuilt_binary / cc_prebuilt_library_shared
#     instead"), and BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES is deliberately
#     NOT set: it disables that check for the entire product.
#
# So they are 136 cc_prebuilt_library_shared modules in
# prebuilts/vndk31-snapshot/ -- 130 carrying both ABIs plus the six per-arch
# libclang_rt sanitizer runtimes, whose filenames differ by architecture.
# (137/131 until libfmq was removed on 2026-08-26 -- see the block below.) Each is
# named <lib>-vndk31 with `stem` set back to the real soname, because the
# platform defines most of these names itself.
#
# vendor/lib*/vndk has no file_contexts rule, so these take vendor_file from the
# directory -- correct here, because only vendor processes ever search that path.
# (vndk_sp_file exists for the vndk-sp case, where a SYSTEM process loads them
# in-process, which is not what happens here.)
#
# ⚠ Provenance detail worth keeping: these are AOSP's snapshot, and 3 of the 133
# per ABI (libexpat, libgui, libstagefright_omx) are NOT byte-identical to the
# copies inside stock's own com.android.vndk.v31.apex -- itel built theirs from a
# different AOSP checkout. Both are VNDK 31 and ABI-frozen, and the hardware
# validation was re-run with THESE files rather than the apex ones, so what is
# shipped is what was tested.
#
# 🔴 libfmq IS DELIBERATELY NOT IN THIS SET -- 133 per ABI, not 134. Removed
# 2026-08-26; it is the one lib in the snapshot that was doing no work for the
# pin's purpose and was actively breaking things.
#
# The pin exists so A12 blobs get the A12 ABI. Measured against the whole rev 28
# vendor+odm dump (2,139 ELFs), libfmq fails that test in both directions:
#
#   symbols v31's libfmq has that v33's DROPPED, i.e. what the pin could protect:
#       EventFlag::createEventFlag(int, off_t, EventFlag**)
#       EventFlag::EventFlag(int, off_t, int*)          [C1 and C2]
#     vendor/odm ELFs referencing any of them ............... 0 of 2,139
#   positive controls, so that 0 is provably a real 0:
#     EventFlag::createEventFlag(atomic<uint>*, EventFlag**) . 31 ELFs  (v33 has it)
#     EventFlag::wake(uint) ................................. 11 ELFs  (v33 has it)
#     android::hardware::details::check, either overload ..... 0 ELFs
#
#   symbol v33's libfmq has that v31's LACKS:
#       android::hardware::details::check(bool, char const*)
#     Added in A13. Every A13-built vendor library that instantiates the FMQ
#     templates emits a reference to it, because MessageQueueBase's constructor
#     calls it inline. With v31 pinned, such a library cannot dlopen:
#       E vndksupport: dlopen failed: cannot locate symbol
#         "_ZN7android8hardware7details5checkEbPKc" referenced by
#         "/vendor/lib64/libbluetooth_audio_session_aidl.so"
#     That is what kept AOSP's Bluetooth audio HAL off this device (see the
#     Bluetooth section below), and it is a wall in front of ANY future
#     A13-built vendor component, not just that one.
#
# So the swap is additive for every blob on the device: v33's libfmq is a
# superset of what all 31 consumers actually reference. v33's own 27 undefined
# symbols resolve against the v31 libbase/libcutils/libutils/liblog it now sits
# beside (checked; the v31 control resolves the same 27).
#
# Dropping the module is enough -- nothing else is needed. The vendor namespace
# searches /vendor/${LIB}/vndk BEFORE /apex/com.android.vndk.v33/${LIB}, so with
# no file at the first path libfmq simply falls through to the apex. That
# fallback was already in use before this change (wpa_supplicant loads
# android.hardware.security.secureclock-V1-ndk.so from the apex), so it is a
# proven path, not a hoped-for one.
#
# ✅ VERIFIED ON HARDWARE 2026-08-26, staged alone via meta-overlayfs before the
# HAL change so the two could not be confused: boot clean in 25 s, 0 tombstones,
# 0 restarting services, and all 8 vendor processes that load libfmq out of
# vendor/lib64/vndk alive on the v33 copy -- camerahalserver (camera providers
# @2.4/@2.5/@2.6 registered), graphics.composer@2.3, media.c2@1.2-mediatek
# (IComponentStore @1.0/@1.1 registered), the audio HAL, sensors@2.0,
# mtkpower@1.0, vtservice_hidl, neuralnetworks-shim. The audio_policy module
# handles were byte-for-byte unchanged, which is the control: this change alone
# does nothing to Bluetooth.
PRODUCT_PACKAGES += \
    android.hardware.audio.common@2.0-vndk31 \
    android.hardware.authsecret-V1-ndk_platform-vndk31 \
    android.hardware.automotive.occupant_awareness-V1-ndk_platform-vndk31 \
    android.hardware.common-V2-ndk_platform-vndk31 \
    android.hardware.common.fmq-V1-ndk_platform-vndk31 \
    android.hardware.configstore-utils-vndk31 \
    android.hardware.configstore@1.0-vndk31 \
    android.hardware.configstore@1.1-vndk31 \
    android.hardware.confirmationui-support-lib-vndk31 \
    android.hardware.gnss-V1-ndk_platform-vndk31 \
    android.hardware.graphics.allocator@2.0-vndk31 \
    android.hardware.graphics.allocator@3.0-vndk31 \
    android.hardware.graphics.allocator@4.0-vndk31 \
    android.hardware.graphics.bufferqueue@1.0-vndk31 \
    android.hardware.graphics.bufferqueue@2.0-vndk31 \
    android.hardware.graphics.common-V2-ndk_platform-vndk31 \
    android.hardware.graphics.common@1.0-vndk31 \
    android.hardware.graphics.common@1.1-vndk31 \
    android.hardware.graphics.common@1.2-vndk31 \
    android.hardware.graphics.mapper@2.0-vndk31 \
    android.hardware.graphics.mapper@2.1-vndk31 \
    android.hardware.graphics.mapper@3.0-vndk31 \
    android.hardware.graphics.mapper@4.0-vndk31 \
    android.hardware.health.storage-V1-ndk_platform-vndk31 \
    android.hardware.identity-V3-ndk_platform-vndk31 \
    android.hardware.keymaster-V3-ndk_platform-vndk31 \
    android.hardware.light-V1-ndk_platform-vndk31 \
    android.hardware.media.bufferpool@2.0-vndk31 \
    android.hardware.media.omx@1.0-vndk31 \
    android.hardware.media@1.0-vndk31 \
    android.hardware.memtrack-V1-ndk_platform-vndk31 \
    android.hardware.memtrack@1.0-vndk31 \
    android.hardware.oemlock-V1-ndk_platform-vndk31 \
    android.hardware.power-V2-ndk_platform-vndk31 \
    android.hardware.power.stats-V1-ndk_platform-vndk31 \
    android.hardware.rebootescrow-V1-ndk_platform-vndk31 \
    android.hardware.renderscript@1.0-vndk31 \
    android.hardware.security.keymint-V1-ndk_platform-vndk31 \
    android.hardware.security.secureclock-V1-ndk_platform-vndk31 \
    android.hardware.security.sharedsecret-V1-ndk_platform-vndk31 \
    android.hardware.soundtrigger@2.0-core-vndk31 \
    android.hardware.soundtrigger@2.0-vndk31 \
    android.hardware.vibrator-V2-ndk_platform-vndk31 \
    android.hardware.weaver-V1-ndk_platform-vndk31 \
    android.hidl.memory.token@1.0-vndk31 \
    android.hidl.memory@1.0-impl-vndk31 \
    android.hidl.memory@1.0-vndk31 \
    android.hidl.safe_union@1.0-vndk31 \
    android.hidl.token@1.0-utils-vndk31 \
    android.hidl.token@1.0-vndk31 \
    android.system.keystore2-V1-ndk_platform-vndk31 \
    android.system.suspend@1.0-vndk31 \
    libRSCpuRef-vndk31 \
    libRSDriver-vndk31 \
    libRS_internal-vndk31 \
    libaudioroute-vndk31 \
    libaudioutils-vndk31 \
    libbacktrace-vndk31 \
    libbase-vndk31 \
    libbcinfo-vndk31 \
    libbinder-vndk31 \
    libblas-vndk31 \
    libbufferqueueconverter-vndk31 \
    libc++-vndk31 \
    libcamera_metadata-vndk31 \
    libcap-vndk31 \
    libcn-cbor-vndk31 \
    libcodec2-vndk31 \
    libcompiler_rt-vndk31 \
    libcrypto-vndk31 \
    libcrypto_utils-vndk31 \
    libcurl-vndk31 \
    libcutils-vndk31 \
    libdiskconfig-vndk31 \
    libdmabufheap-vndk31 \
    libdumpstateutil-vndk31 \
    libevent-vndk31 \
    libexif-vndk31 \
    libexpat-vndk31 \
    libgatekeeper-vndk31 \
    libgralloctypes-vndk31 \
    libgui-vndk31 \
    libhardware-vndk31 \
    libhardware_legacy-vndk31 \
    libhidlallocatorutils-vndk31 \
    libhidlbase-vndk31 \
    libhidlmemory-vndk31 \
    libion-vndk31 \
    libjpeg-vndk31 \
    libjsoncpp-vndk31 \
    libldacBT_abr-vndk31 \
    libldacBT_enc-vndk31 \
    liblz4-vndk31 \
    liblzma-vndk31 \
    libmedia_helper-vndk31 \
    libmedia_omx-vndk31 \
    libmemtrack-vndk31 \
    libminijail-vndk31 \
    libmkbootimg_abi_check-vndk31 \
    libnetutils-vndk31 \
    libnl-vndk31 \
    libpcre2-vndk31 \
    libpiex-vndk31 \
    libpng-vndk31 \
    libpower-vndk31 \
    libprocessgroup-vndk31 \
    libprocinfo-vndk31 \
    libradio_metadata-vndk31 \
    libspeexresampler-vndk31 \
    libsqlite-vndk31 \
    libssl-vndk31 \
    libstagefright_bufferpool@2.0-vndk31 \
    libstagefright_bufferqueue_helper-vndk31 \
    libstagefright_foundation-vndk31 \
    libstagefright_omx-vndk31 \
    libstagefright_omx_utils-vndk31 \
    libstagefright_xmlparser-vndk31 \
    libsysutils-vndk31 \
    libtinyalsa-vndk31 \
    libtinyxml2-vndk31 \
    libui-vndk31 \
    libunwindstack-vndk31 \
    libusbhost-vndk31 \
    libutils-vndk31 \
    libutilscallstack-vndk31 \
    libwifi-system-iface-vndk31 \
    libxml2-vndk31 \
    libyuv-vndk31 \
    libz-vndk31 \
    libziparchive-vndk31 \
    libclang_rt.scudo-aarch64-android-vndk31 \
    libclang_rt.scudo_minimal-aarch64-android-vndk31 \
    libclang_rt.ubsan_standalone-aarch64-android-vndk31 \
    libclang_rt.scudo-arm-android-vndk31 \
    libclang_rt.scudo_minimal-arm-android-vndk31 \
    libclang_rt.ubsan_standalone-arm-android-vndk31

# --- A12 AIDL soname aliases, into /vendor/lib{,64} ------------------------
#
# 🔴 The vndk31 snapshot above CANNOT supply these, and build 68 hung proving it.
#
# vendor/lib*/vndk is not a search path of the namespace a vendor process runs
# in (vendordefault.cc:38 lists /odm/${LIB}, /vendor/${LIB}, /vendor/${LIB}/hw,
# /vendor/${LIB}/egl and nothing else). It is reached only over an ALLOWLISTED
# link whose contents are vndkcore.libraries.33.txt + vndksp.libraries.33.txt --
# and those contain no `_platform` soname at all, because v33 renamed every AIDL
# NDK library. So the snapshot's `-ndk_platform` members are invisible to the
# vendor processes that need them, however correctly they are installed.
#
# hardware/lineage/compat/Android.bp already solves this. Each entry there is an
# empty forwarding library --
#     cc_library_shared {
#         name: "android.hardware.security.keymint-V1-ndk_platform",
#         shared_libs: ["android.hardware.security.keymint-V1-ndk"],
#         system_ext_specific: true, vendor_available: true,
#     }
# -- so the A12 soname exists on the default search path and its symbols resolve
# transitively from the real -V1-ndk library. Source-built, no prebuilt in
# /vendor/lib, and it pulls in the -V1-ndk .vendor variants, which is strictly
# better than build 63: there secureclock and sharedsecret resolved out of
# /apex/com.android.vndk.v33, i.e. a second VNDK generation inside the keymint
# process. These are vendor.33 builds that take their core libs from vndk31.
#
# ⚠ These modules own vendor/lib{,64}/<soname>.so. Giving the vndk31 snapshot
# that path instead -- by dropping its `relative_install_path: "vndk"` -- is a
# duplicate install rule and a kati parse error, EVEN THOUGH the compat module
# is not otherwise requested:
#     installs-lineage_S666LN.mk:180649: error: overriding commands for target
#       `.../vendor/lib64/android.hardware.authsecret-V1-ndk_platform.so'
# Only the six with a measured consumer are requested; the rest of the class
# stays unbuilt rather than installed on speculation.
#
#   keymint/secureclock/sharedsecret  <- android.hardware.security.keymint-service.trustonic
#   memtrack                          <- android.hardware.memtrack-service.mediatek
#   vibrator                          <- android.hardware.vibrator-service.mediatek-stock
#   keystore2                         <- libkeystore-engine-wifi-hidl.so
PRODUCT_PACKAGES += \
    android.hardware.memtrack-V1-ndk_platform.vendor \
    android.hardware.security.keymint-V1-ndk_platform.vendor \
    android.hardware.security.secureclock-V1-ndk_platform.vendor \
    android.hardware.security.sharedsecret-V1-ndk_platform.vendor \
    android.hardware.vibrator-V2-ndk_platform.vendor \
    android.system.keystore2-V1-ndk_platform.vendor

# JamesDSP, replacing AudioFX. OPTIONAL -- see fetch-jamesdsp.sh.
#
# Guarded on the APK actually being present. fetch-jamesdsp.sh generates both the
# APK and its Android.bp, so on a tree where the script was never run there is no
# JamesDSP module to request and AudioFX stays. Asking for it unconditionally
# would break every build that skipped the fetch.
#
# AudioFX is removed by overrides: in that generated Android.bp, not from here:
# it enters via an inherited makefile (vendor/lineage/config/common_full.mk) and
# PRODUCT_PACKAGES cannot be subtracted from.
ifneq ($(wildcard $(LOCAL_PATH)/prebuilts/JamesDSP/JamesDSP.apk),)
PRODUCT_PACKAGES += \
    JamesDSP
endif

# --- classic JamesDSP: the system-wide audio EFFECT --------------------------
#
# This is the other half of the JamesDSP question, and the one the operator
# actually wants: rootless JamesDSP needs DUMP granted through Shizuku or adb
# after every reboot and cannot process apps that set
# allowAudioPlaybackCapture="false". A system effect has neither limitation.
#
# Source is committed under jamesdsp/ (GPL-2.0, upstream james34602/
# JamesDSPManager, Main/libjamesdsp) rather than fetched, so it is unconditional:
# the build cannot be broken by a script nobody ran.
#
# 🔑 WHY THIS IS SAFE UNDER OPTION B, measured rather than assumed. Effects are
# dlopen'd by the VENDOR audio HAL -- /vendor/bin/hw/android.hardware.audio
# .service.mediatek, which on build 69 maps 113 libraries, 28 of them from the
# v31 snapshot. An A13-built C++ library there is the "which pair matches"
# failure this tree has paid for repeatedly. libjamesdsp escapes it entirely:
# it is pure C, built stl:"none", and its DT_NEEDED is liblog/libc/libm/libdl
# and nothing else -- strictly less than the stock effect libdynproc.so, which
# already pulls libcutils and libc++ in that same process.
#
# VALIDATED ON HARDWARE 2026-08-19, before this line was written, by overlaying
# the .so and audio_effects.xml with the meta-overlayfs KSU module and rebooting
# -- no flash. dumpsys media.audio_flinger then reported:
#     Library jamesdsp
#       path: /vendor/lib64/soundfx/libjamesdsp.so
#       JamesDSP v4.01 / James Fung
#         UUID: f27317f4-c984-4de6-9a90-545759495bf2
#         apiVersion: 00020000
# with zero EffectsFactory errors. The UUID must stay in step with
# configs/audio/audio_effects.xml and james.dsp's HeadsetService.java:64.
# 🔴 JamesDSPClassic REMOVED 2026-08-25 (v2 build 1). It was james34602's
# DSPManager, versionName 9.1 -- a Nougat-era UI, and a notification the user
# could not dismiss because HeadsetService called startForeground with
# setOngoing(true). The CONTROL APP is now the modern upstream
# (timschneeb/RootlessJamesDSP, rootFdroid flavor) built from source by
# tools/build-jamesdsp.sh and staged into prebuilts/JamesDSP/, which installs as
# module `JamesDSP` under the guard above.
#
# ⚠ THE EFFECT DID NOT CHANGE, and that is why the swap works: both apps drive
# the SAME system effect, verified by UUID rather than assumed --
#     configs/audio/audio_effects.xml         f27317f4-c984-4de6-9a90-545759495bf2
#     old app HeadsetService.java:64          f27317f4-...
#     new app JamesDspRemoteEngine.kt:300     f27317f4-...   (same, and it is the
#                                             REMOTE engine, i.e. the system effect)
# so `libjamesdsp` below stays exactly as it was.
PRODUCT_PACKAGES += \
    libjamesdsp

# --- Mali r54p1 shim (see mali/libr54shim.c; without it the driver will not
# load and SurfaceFlinger crash-loops) --------------------------------------
PRODUCT_PACKAGES += \
    libr54shim

# --- MediaTek GPU KPI reporting (see prebuilts/gedkpi/Android.bp) -----------
# ged's DVFS policy loop only runs when ged is told a frame happened. Stock does
# that from a libgui which dlopens libged_kpi.so; AOSP's libgui does not, so
# without these the GPU never leaves the OPP it powered on at. The matching hook
# is apply-overlays-v2 step 41 (frameworks/native libs/gui).
PRODUCT_PACKAGES += \
    libged_kpi \
    libged_sys

# Vendor variants of platform-built libraries.
#
# NOT optional. Without these the vendor partition contains HALs that cannot
# link. The 2026-08-05 build stalled at 46s on
#   HidlServiceManagement: Waited one second for android.hardware.boot@1.0::IBootControl/default
# because android.hardware.boot@{1.0,1.1,1.2}.so were absent from /vendor, so
# android.hardware.boot@1.2-service died in the linker and IBootControl never
# registered. The slot was then never marked successful and the bootloader
# rolled back to the other (empty) slot, which looked like an unrelated
# bootloop. An ELF audit of the built image found 501 unresolved DT_NEEDED
# references across 144 libraries.
#
# WHY THEY ARE NEEDED. These were once shipped as blobs and were dropped because
# their soong module names collide with platform modules of the same name. The
# platform does build them -- but only the SYSTEM variant, because every
# consumer here is a cc_prebuilt_* whose dependencies soong cannot see. Nothing
# requests the .vendor variant, so /vendor goes without while the build still
# succeeds.
#
# Neither of these is evidence that a file reaches /vendor:
#   - an install rule in out/soong/installs-*.mk (rules exist for modules
#     nothing requests, so they are never built into the image)
#   - the file existing under /system (a vendor process cannot link it)
#
# Re-derive after ANY blob change with tools/vendor-deps-check.sh, which reads
# DT_NEEDED from every vendor ELF and resolves it against /vendor, the VNDK
# apex, the LLNDK list and public.libraries.txt. It must report zero.
PRODUCT_PACKAGES += \
    android.frameworks.cameraservice.common@2.0.vendor \
    android.frameworks.cameraservice.device@2.0.vendor \
    android.frameworks.cameraservice.device@2.1.vendor \
    android.frameworks.cameraservice.service@2.0.vendor \
    android.frameworks.cameraservice.service@2.1.vendor \
    android.frameworks.cameraservice.service@2.2.vendor \
    android.frameworks.sensorservice@1.0.vendor \
    android.hardware.audio.common-util.vendor \
    android.hardware.audio.common@5.0.vendor \
    android.hardware.audio.common@6.0-util.vendor \
    android.hardware.audio.common@6.0.vendor \
    android.hardware.audio.common@7.0-enums.vendor \
    android.hardware.audio.common@7.0-util.vendor \
    android.hardware.audio.common@7.0.vendor \
    android.hardware.audio.effect@6.0.vendor \
    android.hardware.audio.effect@6.0-util.vendor \
    android.hardware.audio.effect@7.0-util.vendor \
    android.hardware.audio.effect@7.0.vendor \
    android.hardware.audio@6.0.vendor \
    android.hardware.audio@7.0-util.vendor \
    android.hardware.audio@7.0.vendor \
    android.hardware.biometrics.fingerprint@2.1.vendor \
    android.hardware.bluetooth.audio@2.0.vendor \
    android.hardware.bluetooth.audio@2.1.vendor \
    android.hardware.bluetooth@1.0.vendor \
    android.hardware.bluetooth@1.1.vendor \
    android.hardware.boot@1.0.vendor \
    android.hardware.boot@1.1.vendor \
    android.hardware.boot@1.2.vendor \
    android.hardware.camera.common@1.0.vendor \
    android.hardware.camera.device@1.0.vendor \
    android.hardware.camera.device@3.2.vendor \
    android.hardware.camera.device@3.3.vendor \
    android.hardware.camera.device@3.4.vendor \
    android.hardware.camera.device@3.5.vendor \
    android.hardware.camera.device@3.6.vendor \
    android.hardware.camera.provider@2.4.vendor \
    android.hardware.camera.provider@2.5.vendor \
    android.hardware.camera.provider@2.6.vendor \
    android.hardware.drm@1.0.vendor \
    android.hardware.drm@1.1.vendor \
    android.hardware.drm@1.2.vendor \
    android.hardware.drm@1.3.vendor \
    android.hardware.drm@1.4.vendor \
    android.hardware.gatekeeper@1.0.vendor \
    android.hardware.gnss-V1-ndk.vendor \
    android.hardware.gnss.measurement_corrections@1.0.vendor \
    android.hardware.gnss.measurement_corrections@1.1.vendor \
    android.hardware.gnss.visibility_control@1.0.vendor \
    android.hardware.gnss@1.0.vendor \
    android.hardware.gnss@1.1.vendor \
    android.hardware.gnss@2.0.vendor \
    android.hardware.gnss@2.1.vendor \
    android.hardware.graphics.composer@2.1-resources.vendor \
    android.hardware.graphics.composer@2.1.vendor \
    android.hardware.graphics.composer@2.2-resources.vendor \
    android.hardware.graphics.composer@2.2.vendor \
    android.hardware.graphics.composer@2.3.vendor \
    android.hardware.light-V1-ndk.vendor \
    android.hardware.light@2.0.vendor \
    android.hardware.media.c2@1.0.vendor \
    android.hardware.media.c2@1.1.vendor \
    android.hardware.media.c2@1.2.vendor \
    android.hardware.nfc@1.0.vendor \
    android.hardware.nfc@1.1.vendor \
    android.hardware.nfc@1.2.vendor \
    android.hardware.power@1.0.vendor \
    android.hardware.power@1.1.vendor \
    android.hardware.power@1.2.vendor \
    android.hardware.power@1.3.vendor \
    android.hardware.radio.config@1.0.vendor \
    android.hardware.radio.config@1.1.vendor \
    android.hardware.radio.config@1.2.vendor \
    android.hardware.radio.config@1.3.vendor \
    android.hardware.radio@1.2.vendor \
    android.hardware.radio@1.3.vendor \
    android.hardware.radio@1.4.vendor \
    android.hardware.radio@1.5.vendor \
    android.hardware.radio@1.6.vendor \
    android.hardware.secure_element@1.0.vendor \
    android.hardware.secure_element@1.1.vendor \
    android.hardware.secure_element@1.2.vendor \
    android.hardware.security.keymint-V1-ndk.vendor \
    android.hardware.sensors@1.0.vendor \
    android.hardware.sensors@2.0-ScopedWakelock.vendor \
    android.hardware.sensors@2.0.vendor \
    android.hardware.sensors@2.1.vendor \
    android.hardware.soundtrigger@2.1.vendor \
    android.hardware.soundtrigger@2.2.vendor \
    android.hardware.soundtrigger@2.3.vendor \
    android.hardware.tetheroffload.config@1.0.vendor \
    android.hardware.tetheroffload.control@1.0.vendor \
    android.hardware.tetheroffload.control@1.1.vendor \
    android.hardware.thermal@1.0.vendor \
    android.hardware.thermal@2.0.vendor \
    android.hardware.usb.gadget@1.0.vendor \
    android.hardware.usb.gadget@1.1.vendor \
    android.hardware.usb@1.0.vendor \
    android.hardware.usb@1.1.vendor \
    android.hardware.usb@1.2.vendor \
    android.hardware.usb@1.3.vendor \
    android.hidl.allocator@1.0.vendor \
    libaudiofoundation.vendor \
    libavservices_minijail.vendor \
    libchrome.vendor \
    libcodec2_hidl@1.0.vendor \
    libcodec2_hidl@1.1.vendor \
    libcodec2_hidl@1.2.vendor \
    libcodec2_soft_common.vendor \
    libcodec2_vndk.vendor \
    libcppbor_external.vendor \
    libdrm.vendor \
    libflatbuffers-cpp.vendor \
    libhidltransport.vendor \
    libhwbinder.vendor \
    libmediautils_vendor.vendor \
    libmemunreachable.vendor \
    libpcap.vendor \
    libruy.vendor \
    libsfplugin_ccodec_utils.vendor \
    libtextclassifier_hash.vendor \
    libvibratorutils.vendor \
    vendor.lineage.touch@1.0.vendor \
    vendor.mediatek.hardware.mtkpower@1.0.vendor \
    vendor.mediatek.hardware.mtkpower@1.1.vendor \
    vendor.mediatek.hardware.mtkpower@1.2.vendor \
    vendor.nxp.nxpese@1.0.vendor \
    vendor.nxp.nxpnfc@2.0.vendor


# Vendor-only libraries that soong already builds (mostly hardware/mediatek,
# which only compiles because BoardConfig sets BOARD_HAS_MTK_HARDWARE). These have
# no .vendor suffix because the module IS the vendor variant. Like the list above
# nothing referenced them, so they were absent from /vendor.
#
# These six must NOT be shipped as blobs as well: a proprietary-files.txt entry
# collides with the module and kati fails with
#   MODULE.TARGET.SHARED_LIBRARIES.libmtkperf_client_vendor already defined by
#   hardware/mediatek/libmtkperf_client
#
# The converse also bit once. Twelve other libraries looked soong-provided when
# checked with a grep of Android-*.mk, but only because unrelated blob entries
# were in the vendor tree AT THE TIME OF THE CHECK, so it was reading modules
# generated from those very blobs. They are genuinely stock-only and are listed
# in proprietary-files.txt. Verify against a CLEAN vendor tree, or let the build
# answer: PRODUCT_PACKAGES entries that do not exist fail with
#   includes non-existent modules in PRODUCT_PACKAGES
PRODUCT_PACKAGES += \
    ese_client \
    libprotobuf-cpp-full.vendor \
    libprotobuf-cpp-lite.vendor \
    libhwc2on1adapter \
    libhwc2onfbadapter \
    libmtkperf_client_vendor

# 🔴 nfc_nci_nxp is NOT requested here, deliberately. It used to be, and it
# broke NFC. Measured on hardware, build 46:
#
#   CANNOT LINK EXECUTABLE ".../android.hardware.nfc@1.2-service":
#     cannot locate symbol "_ZN13DwpEseUpdater11getInstanceEv"
#
# The NFC service is a STOCK blob (proprietary-files.txt), and it wants
# DwpEseUpdater -- NXP's embedded-secure-element updater, which itel's build of
# the NCI library exports and AOSP's does not:
#
#   stock  vendor/lib64/nfc_nci_nxp.so   330,640 B   exports it
#   source hardware/nxp/nfc/pn8x         209,368 B   exports it 0 times
#
# Requesting the source module installed AOSP's build over the same path, so a
# stock service was paired with a library missing the symbol it needs. Taking
# stock's library instead makes both halves stock, which is what the service was
# linked against.
#
# Same displacement class as libhapticgenerator, resolved the other way. There,
# our blob was standing in for a platform module that does the job, so the blob
# went. Here the platform module cannot do the job, so the request goes. The
# question is never "blob or source", it is which pair actually matches.
#
# Checked before switching, because getting this backwards is how libvibrator
# broke build 42: stock ships 64-bit only, matching the 64-bit service; every
# DT_NEEDED of stock's copy resolves in our vendor apart from libc/libm/libdl,
# which the linker always provides; and nothing else in the tree requests the
# soong module, so dropping the line leaves no duplicate install rule.


# Passthrough HAL implementations.
#
# These are dlopen'd by their service, never linked, so they appear in NO ELF's
# DT_NEEDED and tools/vendor-deps-check.sh is structurally blind to them. The
# 2026-08-05 build passed that gate with zero unresolved and still would not
# boot: android.hardware.boot@1.2-service linked fine and then found no
# implementation to load, so IBootControl never registered.
#
# Note the module name is not the installed filename:
#   module   android.hardware.boot@1.2-mtkimpl
#   installs vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so
# and stock ships the MediaTek implementation (-mtkimpl, from
# hardware/mediatek/bootctrl), NOT the generic AOSP one.
#
# android.hardware.bluetooth.audio@{2.0,2.1}-impl are deliberately NOT here.
# They are taken from stock in proprietary-files.txt instead.
#
# ⚠ The REASON below is now stale in one particular and is kept because the
# failure it describes is real and still applies to these two modules.
# libbluetooth_audio_session is NO LONGER a blob -- it builds from source as of
# 2026-08-26 (see the Bluetooth audio HAL block further down), so the header
# export it was missing now exists. These two impls stay stock anyway: they are
# ABI-matched to the providers stock ships and nothing needs them from source.
# Building them would be a change with no symptom behind it. The original note:
#
# ...because their dependency libbluetooth_audio_session was a blob on this
# device. A cc_prebuilt_library_shared exports no headers, so building the impl
# from source fails on
#     BluetoothAudioProvider.cpp:22:10: fatal error:
#         'BluetoothAudioSessionReport.h' file not found
# even though hardware/interfaces/bluetooth/audio/utils/ is present and its
# Android.bp does export session/. Shipping the impl as a blob also keeps it
# ABI-matched to the session library it is actually loaded against.
#
# ⚠ Not to be confused with audio.bluetooth.default, which IS built from source
# here as of 2026-08-26 -- see the Bluetooth audio HAL block further down. The
# providers stay stock and the HAL does not, and that asymmetry is the fix, not
# an inconsistency: the providers are ABI-bound to the blob session library,
# while the HAL had to move to the registry our Bluetooth stack writes into.
PRODUCT_PACKAGES += \
    android.hardware.renderscript@1.0-impl

# 🔴 android.hardware.boot@1.2-mtkimpl and android.hardware.audio.effect@6.0-impl
# were BOTH requested here and are both gone, because building them at A13 is
# what hung build 67 at the boot logo.
#
#   vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so
#       UND _ZN7android4base8TokenizeE...   = android::base::Tokenize, v33-only
#
# Under a v31 vendor namespace libbase comes from the v31 set and does not export
# it, so the impl fails to dlopen, IBootControl never registers, init's control
# queue saturates and the device sits on the logo with the kernel healthy
# throughout. Both gates passed on that build -- neither vendor-deps nor KMI can
# see a v33-only symbol reference. tools/v31-delta-check.py is what does, and it
# names both of these files.
#
# 🔑 Neither has a single consumer in any DT_NEEDED on the partition, and that is
# not evidence they are unused -- it is what a passthrough implementation looks
# like. ServiceManagement.cpp openLibs() builds the filename at runtime from the
# interface name (findFiles(path, "<package>@<ver>-impl", ".so")) and dlopens
# whatever matches, so no ELF ever names them. A reverse-dependency search would
# have called the boot blocker dead weight.
#
# Stock ships both, built against VNDK 31 by construction, so they move to
# proprietary-files.txt -- but they are NOT treated the same way, and the
# difference is the namespace their source module lives in:
#
#   audio.effect@6.0-impl   source is hardware/interfaces/audio/effect/6.0,
#                           i.e. the ROOT namespace, so our prebuilt DISPLACES it
#                           and no rename is needed. Same shape that has shipped
#                           android.hardware.audio.effect@7.0-impl as an unrenamed
#                           blob for months. Confirmed: no collision.
#   boot@1.0-impl-1.2-...   source is hardware/mediatek/bootctrl, which is its OWN
#                           namespace, so nothing is displaced and BOTH rules stay.
#                           Ships as `-stock`.
#
# 🪤 The boot one collided, and this file had already said it would:
#
#     out/soong/installs-lineage_S666LN.mk:182258: error: overriding commands for
#     target `.../vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so'
#
# The comment below ("It cannot be shipped as a blob instead") names BOTH failure
# modes -- same module name, and different module names sharing an install path.
# The module names differ here, so the first does not apply and the second does.
# That is build 64's lesson again: a unique `name:` is not enough, because the
# install PATH is a second dimension. A distinct filename is what actually fixes
# it, which is the pattern already used for libeffectsconfig-stock,
# libwifi-hal-stock, ese_spi_nxp-stock and the eleven codec2 -stock libraries.
#
# The `-stock` suffix is safe for a passthrough impl specifically: openLibs()
# matches on the PREFIX `<package>@<version>-impl`, so the renamed file is still
# found. And only ONE copy reaches the image -- the platform's rule exists but is
# orphaned (it is not in PRODUCT_PACKAGES, and `ninja -t query` shows its
# `outputs:` empty), so there is no second provider and no registration race.
#
# ⚠ bin/dumpsys is flagged by tools/v31-delta-check.py and deliberately NOT
# fixed. It is the ONE reachable finding that survives the whole A12 conversion.
#
# It cannot be fixed the usual way: `dumpsys_vendor` comes from
# build/make/target/product/base_vendor.mk:52, i.e. inherited, and
# PRODUCT_PACKAGES cannot subtract an inherited entry. Our blob would be named
# `dumpsys` (extract-utils derives it from the filename), which does not match
# the source module's name so it does not displace it, and installs to the same
# path so it collides. A `-stock` rename dodges the collision and produces a
# command nobody can type. The remaining option is a recipe-side module
# exclusion like apply-overlays step 36 does for the power HAL.
#
# Measured before accepting it: NOTHING on the vendor partition references
# /vendor/bin/dumpsys -- not an init rc, not a script, not another binary --
# on build 67's image or on the running device. base_vendor.mk installs it so a
# vendor-context shell can run it by hand. /system/bin/dumpsys is unaffected,
# and nothing on the boot path touches either. Cost of leaving it: that one
# hand-invoked binary will not run under a v31 namespace.
#
# So "the gate is clean" for this tree means ONE reachable finding, bin/dumpsys,
# not zero. Written down because an exit code with a standing exception is
# exactly the kind of thing that gets quietly ignored later.

# ⚠ The RECOVERY variant below is deliberately untouched. It installs to
# recovery/root/system/lib64/hw/, not to /vendor, and recovery has no VNDK
# namespace at all -- so it is a different consumer of the same source module and
# the v31 delta does not apply to it. Swapping it blind would put an A12 impl
# against the A13 libraries in the recovery ramdisk and cost the sideload path.

# android.hardware.boot@1.2-mtkimpl REQUIRES a build-tree patch. See
# apply-overlays.sh step 35. Its 32-bit variant does not compile here:
# LineageOS's generated_kernel_includes runs headers_install once, for
# ARCH=$(KERNEL_ARCH) = arm64, and exports the result to every ABI through a
# single cc_library_headers. asm/sigcontext.h then declares
#     __uint128_t vregs[32];
# in a compile targeting armv7a-linux-androideabi33, where that type does not
# exist:  error: unknown type name '__uint128_t'.
#
# It cannot be shipped as a blob instead. soong's prefer: only pairs a prebuilt
# with a source module in the SAME namespace. hardware/mediatek is its own
# namespace which this tree imports, so a vendor/itel/S666LN prebuilt never
# displaces it -- both modules stay enabled and kati aborts with either
#   "overriding commands for target .../android.hardware.boot@1.0-impl-1.2-mtkimpl.so"
# (different module names, same install path) or
#   "MODULE.TARGET.SHARED_LIBRARIES.android.hardware.boot@1.2-mtkimpl already
#    defined by hardware/mediatek/bootctrl" (same module name).
# The same rule is why vendor.mediatek.hardware.mtkpower@1.0 could not be
# blobbed. Contrast libbluetooth_audio_session, whose source module IS in the
# root namespace and IS displaced by its blob -- it emits zero make modules.

# ...and the same implementation again, for recovery. Without this line
# `adb sideload` fails in 1.2 seconds having transferred nothing:
#
#   [ERROR:boot_control_android.cc(65)] Error getting bootctrl HIDL module.
#   [ERROR:sideload_main.cc(147)] Error initializing the BootControlInterface.
#
# i.e. users cannot install an update. That makes this line the last thing
# standing between the ROM and an install path we own.
#
# There is no hwservicemanager in recovery, so `IBootControl::getService()`
# falls through to the passthrough manager, which dlopens by scanning its
# search paths for `android.hardware.boot@1.0-impl*.so`
# (ServiceManagement.cpp openLibs). update_engine_sideload is a recovery
# binary, not a vendor one, so __ANDROID_VNDK__ is undefined for it and
# HAL_LIBRARY_PATH_SYSTEM stays in that path list -- which is why the recovery
# copy belongs at system/lib64/hw and is still found there.
#
# Note what was NOT wrong, because the obvious diagnosis is misleading:
# `recovery/root/vendor/lib64/hw/` being empty is not the defect, and
# hardware/mediatek/bootctrl already carries `recovery_available: true`, so no
# build-tree patch is needed here (contrast step 35 above). soong had even
# emitted the install rule to
# recovery/root/system/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so
# and the make module `...-mtkimpl.recovery` -- but no android_recovery_*
# variant was ever built, because nothing requested it. Once more, and this
# time in our favour: the existence of a build rule is not evidence of an
# installed file.
PRODUCT_PACKAGES += \
    android.hardware.boot@1.2-mtkimpl.recovery


# Wi-Fi supplicant.
#
# proprietary-files.txt extracted stock's
# vendor/etc/init/android.hardware.wifi.supplicant-service.rc but NOT the
# /vendor/bin/hw/wpa_supplicant it starts, so the service could never run and
# Wi-Fi could not work. Nothing at build time notices: an init .rc naming a
# path that does not exist is not an error.
#
# Built from source rather than blobbed. external/wpa_supplicant_8 is synced and
# BOARD_WLAN_DEVICE := MediaTek / WPA_SUPPLICANT_VERSION := VER_0_8_X are already
# set; the module simply was never requested. It is LOCAL_PROPRIETARY_MODULE with
# LOCAL_MODULE_RELATIVE_PATH := hw, so it installs to the exact path the service
# expects.
#
# The stock .rc is dropped from proprietary-files.txt in the same change, for two
# reasons. It would collide -- the module carries
# LOCAL_INIT_RC=aidl/android.hardware.wifi.supplicant-service.rc and installs to
# the same path. And it is the wrong one: stock's declares the HIDL interfaces
# android.hardware.wifi.supplicant@{1.0..1.4}::ISupplicant, while this tree's
# VINTF fragment declares format="aidl" ISupplicant/default. The module's AIDL
# .rc is what matches the manifest.
# 🔴 STOCK'S DAEMONS NOW, not the source builds. See BoardConfig.mk: unsetting
# WPA_SUPPLICANT_VERSION un-defines both kati modules, so there is nothing to
# request here and nothing to collide with. Both binaries, their rc files and
# the ten HIDL interface libraries they need are in proprietary-files.txt, and
# configs/vintf/manifest/ carries stock's HIDL declarations in place of the AIDL
# ones. All-or-nothing: the framework tries AIDL first and only falls back to
# HIDL when AIDL is undeclared (SupplicantStaIfaceHal.java:812-822).
#
# The history below is kept because it is still the reason Wi-Fi works at all --
# the defect it records (a daemon with no init service) is exactly what stock's
# rc files now supply, and the next person to touch this needs to know that an
# installed daemon and a startable one are different things.
#
# hostapd -- the Wi-Fi hotspot / SoftAP daemon.
#
# 🔴 Declaration without implementation, the same defect as media.c2, sensors
# and the Wi-Fi HAL. configs/vintf/manifest/android.hardware.wifi.hostapd.xml
# declares format="aidl" IHostapd/default, and NOTHING provided it. Measured on
# build 54:
#
#   /vendor/bin/hw/hostapd        does not exist
#   /system/bin/hostapd           does not exist
#   /vendor/etc/init/*hostapd*    does not exist
#   WPA_BUILD_HOSTAPD             set nowhere in this tree
#
# external/wpa_supplicant_8/hostapd/Android.mk:15 wraps the ENTIRE file in
# `ifeq ($(WPA_BUILD_HOSTAPD),true)`, so without that variable the module is
# never defined and PRODUCT_PACKAGES cannot request it. With it, the module
# carries LOCAL_INIT_RC := hostapd.android.rc (line 1202, ungated) and its own
# AIDL fragment, so unlike wpa_supplicant there is no second variable to set.
# BOARD_HOSTAPD_DRIVER := NL80211 was already present and was doing nothing.
#
# ⚠ Verified ABSENT on hardware, not verified PRESENT -- there was no binary to
# start by hand the way wpa_supplicant was tested, so this one rests on the
# build. Confirm on the next flash: `ls /vendor/bin/hw/hostapd`, then turn the
# hotspot on. Found while triaging the 46 stock vendor init services missing
# from the build (see notes/RESUME.md item 2); `hostapd` and `wpa_supplicant`
# were both on that list and both were real.
# The Wi-Fi HAL itself. 🔴 Without it there is NO Wi-Fi AT ALL -- measured on
# hardware, the first build that booted far enough to try:
#
#   libc: Unable to set property "ctl.interface_start" to
#         "android.hardware.wifi@1.0::IWifi/default": error code: 0x20
#   ... once per second, forever; no wlan0 interface ever appears
#
# configs/vintf/manifest.xml declares android.hardware.wifi@1.6::IWifi/default
# and NOTHING provided it: no service binary in /vendor/bin/hw, no init service.
# The same declared-but-unimplemented shape as the media.c2 defect. The driver
# modules were loaded and wpa_supplicant was built -- only the HAL was missing.
#
# Built from source rather than taking stock's android.hardware.wifi@1.0-service-
# lazy blob, for two reasons. It is what BOARD_WLAN_DEVICE := MediaTek already
# exists for -- soong resolves libwifi-hal to libwifi-hal-mt66xx from
# hardware/mediatek/wlan, which this tree already syncs and which
# BOARD_HAS_MTK_HARDWARE already enables. And soong brings the dependency
# closure with it: stock's lazy blob additionally needs libwifi-hal.so,
# libwifi-system-iface.so and libnl.so, none of which are on this device.
#
# 🔴 The Wi-Fi HAL is STOCK's, not the platform's, and the difference is the
# whole of Wi-Fi working. proprietary-files.txt ships both halves renamed
# (...-service-stock, libwifi-hal-stock.so) with blob_fixup repointing them; see
# extract-files.sh for the collision reasoning.
#
# On MediaTek the chip is powered and wlan0/wlan1/p2p0 created by a write to
# /dev/wmtWifi. Only stock's library does that:
#
#   strings stock/lib64/libwifi-hal.so | grep -c wmtWifi   ->  1
#   strings built/lib64/libwifi-hal.so | grep -c wmtWifi   ->  0
#
# PROVEN ON HARDWARE, build 57: bind-mounting stock's library under the running
# platform service produced, in one step, [AF FUNC ON] w:2 + "WMT turn on WIFI
# success!", wlan0/wlan1/p2p0, ClientModeManager ROLE_CLIENT_PRIMARY,
# init.svc.wpa_supplicant=running, and a scan returning APs on 2.4 and 5 GHz.
# Without it, across an entire boot, the only w:2 power-on event was a manual
# `echo 1 > /dev/wmtWifi`.
#
# The platform's libwifi-hal is not fixable by configuration: it is a thin
# wrapper whole-static-linking libwifi-hal-mt66xx from hardware/mediatek/wlan,
# and that repo has SIX source files and zero references to wmtWifi.
#
# ⚠ HISTORY, so nobody flips this a third time. 93ff629 made exactly this change
# and I reverted it in 8948509 on the strength of a dmesg line -- [AF FUNC ON]
# w:2 during a failing enable on build 54 -- read as proof the platform HAL
# powers the chip. It was not: wlan0 already existed on that boot, so the chip
# was already on and the line said nothing about who turned it on. A causal
# claim from a log line without controlling for prior state. The revert was
# wrong; the supplicant rc it also carried was right and is kept.
#
# BOARD_WLAN_DEVICE := MediaTek stays, because frameworks/opt/net/wifi still
# needs LIB_WIFI_HAL resolved to build libwifi-hal at all -- it is simply no
# longer the library we ship.
#
# The dependency closure. Stock's binary links libnl and libwifi-system-iface,
# which exist only on /system and which a vendor process cannot link, plus the
# six HIDL interface libraries android.hardware.wifi@1.0..1.5.
#
# 🔴 Those six were installed for free while device.mk still requested the
# PLATFORM service -- soong pulled them in as its dependencies. Dropping that
# request took them with it, and build 58 died at the gate:
#
#   UNRESOLVED (missing library <- consumer), by number of consumers:
#         1 android.hardware.wifi@1.5.so
#         1 android.hardware.wifi@1.4.so   ... through @1.0
#
# Caught by tools/vendor-deps-check.sh at 99%, before a flash. Exactly the
# transitive-closure miss that failed build 50 on libdts-eagle-shared, and the
# reason that gate exists: a prebuilt binary's dependencies are invisible to
# soong, so removing an unrelated source module can silently strip them.
PRODUCT_PACKAGES += \
    libwifi-system-iface.vendor \
    libnl.vendor \
    android.hardware.wifi@1.0.vendor \
    android.hardware.wifi@1.1.vendor \
    android.hardware.wifi@1.2.vendor \
    android.hardware.wifi@1.3.vendor \
    android.hardware.wifi@1.4.vendor \
    android.hardware.wifi@1.5.vendor

# The HIDL interface libraries stock's supplicant and hostapd link.
#
# 🪤 These were briefly shipped as blobs and the build refused them:
#   base_rules.mk:338: MODULE.TARGET.SHARED_LIBRARIES.android.hardware.wifi.hostapd@1.0
#     already defined by hardware/interfaces/wifi/hostapd/1.0
#
# The reasoning that put them there was that a prebuilt DISPLACES a source module
# in the ROOT namespace, which is true and is why audio.effect@6.0-impl and
# vndservicemanager needed no rename. It does NOT hold for these: they are
# generated by `hidl_interface`, not declared as cc_library_shared, and a
# prebuilt does not replace a generated module. Same namespace, different
# mechanism -- so "root namespace" was the wrong predictor, and the right
# question is what DECLARES the module.
#
# Requesting the platform's .vendor variants is both simpler and what this file
# already does for android.hardware.wifi@1.0..1.5 immediately above. HIDL
# interfaces are versioned and ABI-stable by design, which is exactly what lets
# stock's A12 daemons link the platform's build of the same @version.
# 🔴 Three libraries the vendor-deps gate caught AFTER packaging build 68 --
# consumers of the stock binaries this conversion introduced, and each one takes
# a DIFFERENT route for the reason established today: what DECLARES a module
# decides whether a prebuilt can displace it.
#
#   android.hardware.audio.effect@6.0-util  .vendor variant, beside the @7.0-util
#       request that has always been there. Stock's @7.0-impl.so links
#       @7.0-util.so and gets it exactly this way, with no blob -- the @6.0 case
#       is the same shape and I simply had not noticed the precedent one line
#       above where I was editing.
#
#       🪤 I first shipped it as a BLOB, reasoning that a cc_library_shared in
#       hardware/interfaces is in the ROOT namespace and would be displaced.
#       It collided:
#         base_rules.mk:338: MODULE.TARGET.SHARED_LIBRARIES.
#           android.hardware.audio.effect@6.0-util already defined by
#           hardware/interfaces/audio/effect/all-versions/default/util
#       So "root namespace -> displaced" is NOT the rule, and it never was. The
#       cases where a blob did NOT collide -- audio.effect@6.0-impl,
#       vndservicemanager -- are ones where this tree had just REMOVED the only
#       PRODUCT_PACKAGES request, leaving the platform module unreachable and so
#       never exported to make. @6.0-util is still reachable (the audio stack
#       needs it), so its make module exists and the name is taken.
#
#       🔑 The real rule: a prebuilt's module name is free only when the
#       platform's module is not otherwise reachable in the build. Namespace was
#       a coincidence of the first two cases I looked at.
#   android.system.wifi.keystore@1.0        hidl_interface -> GENERATED, and a
#       prebuilt does not replace a generated module. .vendor variant, below.
#       Reached from stock's wpa_supplicant via stock's libkeystore-engine-wifi-hidl.
#   libmtk_bsg                              cc_library_shared, but in
#       hardware/mediatek, which declares its own soong_namespace -> nothing is
#       displaced and a blob would collide. .vendor variant, below. Consumed by
#       stock's boot@1.0-impl-1.2-mtkimpl.
#
# 🪤 All three were missed because I measured each new binary's DIRECT DT_NEEDED
# and not the TRANSITIVE closure of the libraries I had just added. The daemons'
# own dependencies were checked; their dependencies' dependencies were not.
PRODUCT_PACKAGES += \
    android.system.wifi.keystore@1.0.vendor

PRODUCT_PACKAGES += \
    android.hardware.wifi.supplicant@1.0.vendor \
    android.hardware.wifi.supplicant@1.1.vendor \
    android.hardware.wifi.supplicant@1.2.vendor \
    android.hardware.wifi.supplicant@1.3.vendor \
    android.hardware.wifi.supplicant@1.4.vendor \
    android.hardware.wifi.hostapd@1.0.vendor \
    android.hardware.wifi.hostapd@1.1.vendor \
    android.hardware.wifi.hostapd@1.2.vendor \
    android.hardware.wifi.hostapd@1.3.vendor

# vendor.transsion.hardware.wifi.hostapd@1.0 stays a BLOB: it is a Transsion
# vendor HIDL interface, defined nowhere in AOSP, so there is nothing to collide
# with and nothing to request.

# Overlays
DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

# PRODUCT-level overlay. Beats vendor/lineage's product overlay, which the
# DEVICE overlay above structurally cannot -- package_internal.mk reverses the
# combined list before aapt2, so PRODUCT_ entries win and the EARLIEST wins.
# lineage_S666LN.mk inherits this file (44) before vendor/lineage (47), so this
# lands first. Currently carries exactly one string: the DeviceConfig
# configurator role. See overlay-product/.../config.xml for the full reasoning.
PRODUCT_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay-product

# Init. rootdir/ carries the boot plumbing this tree owns and edits; every
# other .rc on the vendor partition (the ~134 HAL service files, plus the
# factory_init / meta_init / multi_init set) ships as a blob through the
# vendor tree instead, unmodified.
PRODUCT_PACKAGES += \
    init.insmod.sh

PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*.rc,$(LOCAL_PATH)/rootdir/etc/init/hw,$(TARGET_COPY_OUT_VENDOR)/etc/init/hw) \
    $(LOCAL_PATH)/rootdir/etc/init.insmod.mt6789.cfg:$(TARGET_COPY_OUT_VENDOR)/etc/init.insmod.mt6789.cfg

# ueventd reads /vendor/etc/ueventd.rc. The source keeps the platform suffix
# so it is obvious which SoC it describes.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/ueventd.mt6789.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc

# fstab. Needed twice: first-stage mount reads it out of the vendor_boot
# ramdisk, and later consumers read the copy on /vendor. Stock ships both, and
# stock's two copies are byte-identical.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6789:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.mt6789 \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6789:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.mt6789

# The swap fstab, which is what actually CREATES the zram device. Byte-identical
# to stock: "/dev/block/zram0 none swap defaults zramsize=55%".
#
# Without it this device runs with NO SWAP AT ALL, measured on build 61:
# /proc/swaps empty, /sys/block/zram0/disksize = 0. And the tree was already
# shipping the half of stock's configuration that TUNES zram --
# init.mt6789.rc:204-207 sets comp_algorithm lz4, page-cluster 0 and
# swappiness 100 -- on a device that never existed. The same "took some, left
# the rest" shape as the VINTF fragments, the dalvik heap and the audio effect
# libraries.
#
# init fires it already; nothing else is needed. Both gating properties come
# from our own vendor.prop and match stock, so this is deterministic on every
# install rather than a property of this one unit:
#   init.mt6789.rc:1180  on property:persist.vendor.swapfile_enable=true \
#                           && property:ro.vendor.memfusion2_2.support=false
#                            swapon_all /vendor/etc/fstab.enableswap
#   vendor.prop          persist.vendor.swapfile_enable = true
#                        ro.vendor.memfusion2_2.support = false
#
# Proven on hardware before shipping: bringing zram up by hand exactly as this
# fstab specifies (disksize, mkswap, swapon) succeeded and /proc/swaps showed
# the device, so the kernel side works and only the config was missing. The
# module is present in the kernel package and /sys/module/memfusion exists.
#
# 🔴 Stock's OTHER swap fstab is deliberately NOT shipped:
# /vendor/etc/memfusion2/fstab.enableswap asks for a 3 GB swapfile at
# /data/swapfile.db, which is Transsion's Memory Fusion feature -- the file is
# created and managed by a vendor service this tree does not ship, so shipping
# the fstab alone would swapon a file nothing creates. init.project.rc's
# `on boot swapon_all` for it is inert for the same reason and is left alone;
# it produced no log line at all on build 61, so it costs nothing.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/fstab.enableswap:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.enableswap

# Recovery. This is what makes `adb sideload` enumerate.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/init.recovery.mt6789.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.mt6789.rc

# Firmware in the vendor ramdisk. Without this there is no touchscreen and no
# haptic in recovery, measured on hardware 2026-08-11.
#
# These blobs are already in proprietary-files.txt, but that installs them to
# the vendor PARTITION -- which is not mounted in recovery. The drivers load
# them at probe through request_firmware(), so the ramdisk needs its own copy or
# the kernel firmware loader finds nothing:
#
#   /vendor/firmware/ and /lib/firmware/   did not exist in the ramdisk at all
#   [13.7] fts_initupg_work: FTS tran request firmware failed
#   fts_boot_mode: "tp is in boot mode"    <- controller stuck in its BOOTLOADER
#   mtk-tpd interrupts: 0                  <- alive on SPI, reporting nothing
#
# With the firmware present, probe succeeds at t=2.29s and the panel reports:
#   [2.23] fts_wait_tp_to_valid: TP Ready, Device ID:0x80
#   fts_boot_mode: "tp is in fw mode", fw_version 0b, interrupts climbing.
#
# 🔴 This is only half the fix. It does nothing without the one-byte patch to
# adaptive-ts.ko in the kernel package, which removes Transsion's refusal to
# initialise touch when bootmode==2 (RECOVERY_BOOT). Neither works alone: the
# gate stops the driver registering, and the missing firmware stops the
# registered driver reporting. They were found in that order, a flash apart.
#
# BOTH panel variants are shipped on purpose. RS4 units carry either a
# focaltech FT8057S (DPT) or an omnivision TD4160 (LCE) panel -- stock ships a
# firmware for each and both driver modules are in the load list. Shipping only
# the one this test device happens to have would leave touch dead in recovery
# for every user with the other panel, and it is not something they could
# diagnose. 427 KB total.
#
# The source paths are the extracted vendor tree rather than this repo: these
# are stock blobs, they already come down with extract-files.sh, and copying
# them into the device tree would duplicate 427 KB of firmware we do not own.
PRODUCT_COPY_FILES += \
    vendor/itel/S666LN/proprietary/vendor/firmware/ft8057s_dpt_fw.bin:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/vendor/firmware/ft8057s_dpt_fw.bin \
    vendor/itel/S666LN/proprietary/vendor/firmware/td4160_lce_fw.img:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/vendor/firmware/td4160_lce_fw.img \
    vendor/itel/S666LN/proprietary/vendor/firmware/aw8622x_haptic.bin:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/vendor/firmware/aw8622x_haptic.bin \
    vendor/itel/S666LN/proprietary/vendor/firmware/Conf_MultipleTest.ini:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/vendor/firmware/Conf_MultipleTest.ini

# VINTF. The generated device manifest is missing a thermal entry, so the
# vendor's android.hardware.thermal@2.0-service.mtk cannot register and init
# respawns it every ~5s. configs/vintf/manifest.xml adds it back for both
# major versions, matching the service's own .rc.
# DEVICE_MANIFEST_FILE takes a LIST (build/make/target/board/Android.mk:39).
# Every file listed is passed to assemble_vintf -i and merged into the single
# /vendor/etc/vintf/manifest.xml. That is how stock's 32 HAL fragments get
# installed here — see the note below the matrix.
DEVICE_MANIFEST_FILE := \
    $(LOCAL_PATH)/configs/vintf/manifest.xml \
    $(sort $(wildcard $(LOCAL_PATH)/configs/vintf/manifest/*.xml))
DEVICE_MATRIX_FILE := $(LOCAL_PATH)/configs/vintf/compatibility_matrix.xml

# DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE is required, and an earlier note
# here claimed the opposite. That note observed stock's only framework matrix
# holds two optional Transsion HALs this ROM does not ship, and concluded there
# was "nothing to require" -- conflating two different directions:
#
#   DEVICE_MATRIX_FILE   what this device REQUIRES of the framework
#                        (genuinely near-empty on this device)
#   this file            what the framework PERMITS the device to ADVERTISE
#
# With PRODUCT_ENFORCE_VINTF_MANIFEST=true, check_vintf rejects every device
# manifest instance that no framework matrix mentions -- all 75 non-AOSP HALs
# here (MediaTek, Transsion, NXP, Trustonic, fpsensor, lineage.touch, plus
# MediaTek's extra android.hardware.radio instances). The build then fails at
# "Package OTA", 99% in, with target-files already built.
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE := \
    $(LOCAL_PATH)/configs/vintf/framework_compatibility_matrix.xml

# Health
PRODUCT_PACKAGES += \
    android.hardware.health@2.1-impl \
    android.hardware.health@2.1-service

# Memtrack. Nothing shipped this and its absence hangs the boot: system_server
# reaches MemtrackProxyService, calls getService() on
# android.hardware.memtrack.IMemtrack/default, and blocks there forever. The
# only symptom is a boot animation that never exits plus
#
#   ServiceManager: Waited one second for android.hardware.memtrack.IMemtrack/default
#
# once a second -- which reads as noise next to a dozen other "waited one
# second" lines, and is not. It was the last SystemServerTiming entry ever
# logged, which is what identified it.
#
# 🔴 STOCK'S service now, not the source build. Option B: under a v31 vendor
# namespace the source-built `-mediatek-mali` binary asks for
# android.hardware.memtrack-V1-ndk.so, an Android 13 soname the v31 set does not
# carry -- it has the A12 spelling, `...-V1-ndk_platform.so`. Stock's binary asks
# for the _platform name natively, so the swap needs no rename at all.
#
# ⚠ I first reported memtrack as having NO stock counterpart. It has one; I had
# searched for the SOURCE module's name. Stock calls it
# android.hardware.memtrack-service.mediatek (no `-mali`), 29,176 B, and ships
# its own memtrack-mediatek.rc and memtrack-mediatek.xml.
#
# The Mali-specific reasoning above still holds and is not weakened by the swap:
# stock IS itel's own firmware for this exact Mali-G57 part, so its memtrack
# service is the vendor's own answer for this GPU, not the AOSP example that
# reports zeroes.
#
# The two names differ, so neither the module name nor the install path collides
# and the source module's rule is simply left orphaned. Its vintf_fragment goes
# with it, which is why stock's memtrack-mediatek.xml is now in
# configs/vintf/manifest/ -- the declaration and the implementation have to move
# together or this becomes the media.c2 / sensors / Wi-Fi defect for a fifth time.

# Power and vibrator: built from hardware/mediatek, NOT blobbed.
#
# Both were first added here as stock blobs, which failed the build immediately:
#
#   base_rules.mk:338: error: hardware/mediatek/aidl/power-mediatek:
#     MODULE.TARGET.SHARED_LIBRARIES.android.hardware.power-service-mediatek
#     already defined by vendor/itel/S666LN.
#
# hardware/mediatek/aidl/{power-mediatek,vibrator} define modules of exactly
# those names, so a blob of the same name is a duplicate definition rather than
# a fallback. They were simply never requested, which is why neither shipped.
#
# Taking the source module is also the better answer on its own terms: each
# carries its own LOCAL_VINTF_FRAGMENTS and LOCAL_INIT_RC, so the declaration
# and the implementation arrive together and cannot drift apart -- which is the
# precise failure that boot-looped this device (VINTF declared
# android.hardware.power, nothing provided it). And power-mediatek links
# android.hardware.power-V2-ndk, the Android 13 soname, so it does not depend on
# the VNDK 31 apex the way stock's prebuilt does.
#
# The stock service BINARY (vendor.mediatek.hardware.mtkpower@1.0-service) is
# still a blob and still needed -- it is what hosts the AIDL interface. Only the
# library and the vibrator executable moved to source.
# 🔴 android.hardware.power-service-mediatek is NOT requested here, on purpose.
#
# hardware/mediatek/aidl/power-mediatek builds a module of that name, and asking
# for it installs an implementation stock's own binary cannot use. Measured on
# hardware 2026-08-11: the HIDL half registered fine
#
#     mtkpower@1.0-service: mtkPowerService register IMtkPerf
#     HidlServiceManagement: Registered ...mtkpower@1.2::IMtkPerf/default
#
# and then the AIDL half aborted inside the constructor:
#
#     F DEBUG: #01 /vendor/lib64/android.hardware.power-service-mediatek.so
#                  (aidl::...::mediatek::Power::Power()+460)
#              #02 /vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service
#                  (mtkPowerAidlService(void*)+56)
#
# Power::Power() dlopens libpowerhal.so, resolves five symbols and calls
# libpowerhal_Init(1). No "Could not dlopen"/"Could not locate symbol" appeared,
# so it died inside libpowerhal_Init -- the source build (19,960 B) and stock's
# libpowerhal do not agree, where stock's own impl (23,936 B) does.
#
# So the AIDL impl is taken from the firmware instead, listed in
# proprietary-files.txt WITH a dash, i.e. as a cc_prebuilt_library_shared.
#
# It took three build failures to land on that, and each one ruled out a real
# option, so they are worth recording rather than repeating:
#
#   dash, before step 36   duplicate module -- hardware/mediatek defines
#                          android.hardware.power-service-mediatek too
#                          (base_rules.mk:533)
#   no dash                "found ELF prebuilt in PRODUCT_COPY_FILES, use
#                          cc_prebuilt_binary / cc_prebuilt_library_shared
#                          instead" -- AOSP forbids ELF via copy-files
#   dash, after step 36    works: the recipe scopes hardware/mediatek's module
#                          out for this device, freeing the module name
#
# The dependency is therefore two-sided and easy to break by accident: this
# entry needs apply-overlays-v2 step 36, and step 36 exists only for this entry.
# Remove either alone and the build fails -- loudly, at least.
#
# The lesson generalises: a prebuilt service binary and its implementation
# library are one unit. Swapping half of a matched pair for a source build is
# not an upgrade, it is a mismatch -- and it fails at runtime, not at build time.
# 🔴 STOCK'S vibrator service now, for the same reason as memtrack: the source
# build asks for android.hardware.vibrator-V2-ndk.so and the v31 set carries
# `...-V2-ndk_platform.so`. Stock's binary wants the _platform name natively.
#
# Unlike memtrack this one DOES need a rename. hardware/mediatek/aidl/vibrator
# defines `android.hardware.vibrator-service.mediatek` in **kati**
# (Android.mk:4), and a kati module name is defined on every build whether or not
# anything requests it -- there is no soong `prefer:` displacement to rescue it,
# which is the libvibrator / libeffectsconfig / wifi-service-lazy collision for
# the fourth time. So it ships as `-stock` and blob_fixup repoints the rc.
#
# 🔑 Stock's vintf fragment declares MORE than ours did: IVibrator/default AND
# IVibratorManager/default. Ours declared only the former, so the framework was
# falling back to its legacy single-vibrator path. Both are now in
# configs/vintf/manifest/vibrator-mtk-default.xml, matching what stock's binary
# actually registers.

# Stock's power AIDL impl links android.hardware.power-V2-ndk_platform.so, which
# blob_fixup renames to the Android 13 soname. Nothing else pulls that library
# in now that the source power HAL is not built, so request it explicitly --
# soong will not build a .vendor variant for a cc_prebuilt's benefit.
PRODUCT_PACKAGES += \
    android.hardware.power-V2-ndk.vendor

# VNDK 31 libraries for the A12 blobs that cannot run against platform VNDK 33.
# See prebuilts/vndk31/Android.bp for the measurements and the same-process
# caveat, and blob_fixup in extract-files.sh for which consumers are renamed
# onto them. Sourced from AOSP's prebuilts/vndk/v31 snapshot.
PRODUCT_PACKAGES += \
    libutils-v31 \
    libhidlbase-v31 \
    libcutils-v31 \
    libbinder-v31

# AIDL NDK libraries that stock's blobs need under their Android 13 names.
#
# extract-files.sh renames the A12 `_platform` sonames on five stock binaries to
# the names this branch builds. A rename only works if the target is actually
# installed to /vendor, and soong will not build a .vendor variant just because
# a cc_prebuilt names it -- prebuilts are invisible to its dependency graph.
# That is the trap that shipped a vendor partition with 501 unresolved
# references on 2026-08-05.
#
# light/gnss/keymint .vendor variants are already pulled in by other consumers.
#
# 🔴 The secureclock and sharedsecret requests that used to be here are GONE,
# and the claim that justified them was false. It read: "Verified present in
# /vendor/lib64 of a completed build before the matching rename was added. If
# either is dropped, the rename dangles silently."
#
# Measured 2026-08-18, on build 67's image AND on the running device: NEITHER is
# in /vendor, on either ABI. Only keymint-V1-ndk.so is, and it arrives via
# another consumer exactly as the first line says. The Trustonic binary was
# resolving the other two from the v33 APEX:
#
#   /proc/<pid>/maps, build 63, vendor.tee.googlekey.status = ok
#     /apex/com.android.vndk.v33/lib64/...secureclock-V1-ndk.so
#     /apex/com.android.vndk.v33/lib64/...sharedsecret-V1-ndk.so
#
# So the requests never installed anything and the renames they were supposed to
# satisfy were being served by a namespace we are about to stop using. Both the
# renames and these requests are removed together -- stock's binary asks for the
# `_platform` sonames, which the v31 set provides from /vendor.
#
# 🔑 The comment was not stale in the ordinary way. It NAMED the check that would
# have caught it ("verified present") and nobody re-ran it. A citation is a claim
# about the past, not a measurement of the present.

# Audio
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/audio,$(TARGET_COPY_OUT_VENDOR)/etc)
# configs/permissions/ — REMOVED 2026-08-25, and the reason matters.
#
# This installed privapp-permissions-gms-deviceconfig.xml, granting GMS
# WRITE_DEVICE_CONFIG so Phenotype could push DeviceConfig flags. It never
# worked, and never could have:
#
#   WRITE_DEVICE_CONFIG  protectionLevel="signature|verifier|configurator"
#
# It is NOT `privileged`, and a privapp-permissions allowlist only applies to
# the `privileged` flag. The file was inert from the day it shipped. The
# evidence looked like confirmation and was the opposite: PM emitted ZERO "not
# in privapp allowlist" warnings — because there was no allowlist question to
# answer — while GMS's genuinely privileged permissions (RECOVER_KEYSTORE,
# SEND_SAFETY_CENTER_UPDATE) were granted normally.
#
# The real mechanism is the configurator role, now set in
# overlay/frameworks/base/core/res/res/values/config.xml
# (config_deviceConfiguratorPackageName). See that comment for the full trace.

# 🔴 configs/permissions/ EXISTS AGAIN as of v2 build 2, for a different file
# and a different partition. The paragraph above is about
# privapp-permissions-gms-deviceconfig.xml and still stands; it is not about
# this.
#
# android.hardware.hardware_keystore — stock rev 28's own declaration, byte for
# byte, version 100. This device serves KeyMint V1 through Trustonic
# (IKeyMintDevice registered, keystore.app_attest_key already advertised), so
# the capability is real and undeclared. It is what banking / e-KYC apps query.
#
# ⚠ IT GOES ON PRODUCT, NOT VENDOR, AND THAT IS THE WHOLE POINT.
# Shipping it to /vendor/etc/permissions is a kati parse-time FATAL:
#   hardware/interfaces/security/keymint/aidl/default/Android.bp:49
#     prebuilt_etc { name: "android.hardware.hardware_keystore.xml",
#                    sub_dir: "permissions", vendor: true }
# claims that exact install path. A duplicate target definition is fatal EVEN
# THOUGH NOTHING REQUESTS IT — the AOSP default keymint service is not built
# here (we ship keymint-service.trustonic), so the platform file never installs
# and the device does not have it. That is build 1's revert (3f1170a), and
# re-landing it on /vendor would reproduce the same failure.
#
# ⚠ The platform's own copy is NOT a substitute: it declares version 200
# (KeyMint 2.0) where stock declares 100, and this device serves V1. Using it
# would declare a capability we do not have.
#
# SystemConfig reads /product/etc/permissions with ALLOW_ALL, so the feature is
# declared identically from there. Verified on hardware BEFORE writing this, with
# a positive control rather than from the source: three features already declared
# in /product/etc/permissions on build 1 (android.software.sip,
# android.software.sip.voip, android.sofware.nfc.beam — AOSP's own typo) all
# appear in `pm list features`.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/permissions/android.hardware.hardware_keystore.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/android.hardware.hardware_keystore.xml

# Wi-Fi resource overlay -- the 5 GHz hotspot fix.
#
# com.android.wifi.resources lives in an APEX, so DEVICE_PACKAGE_OVERLAYS cannot
# reach it the way it reaches framework-res; an RRO is the only mechanism. It sets
# config_wifi5ghzSupport=true, whose AOSP default is false, and without which
# ApConfigUtil refuses the 5 GHz band and SoftAP silently falls back to 2.4 GHz.
# Full reasoning, both call sites and the measurement, in the overlay's config.xml.
PRODUCT_PACKAGES += \
    S666LNWifiOverlay

# 🔴 Bluetooth audio HAL -- AOSP's, NOT stock's. This is the A2DP fix.
#
# Stock's vendor/lib*/hw/audio.bluetooth.default.so is dropped from
# proprietary-files.txt so that this source module installs instead. That is the
# whole change; everything else about Bluetooth audio stays stock.
#
# WHY. Both the AOSP and the MediaTek Bluetooth-audio stacks are present on this
# device, and they keep their sessions in two different process-global
# registries inside one process -- android.hardware.audio.service.mediatek:
#
#   android.hardware.bluetooth.audio@2.1-impl.so   -> libbluetooth_audio_session.so
#     serves android.hardware.bluetooth.audio@2.0 / @2.1        (AOSP registry)
#   vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so
#     -> libbluetooth_audio_session_mediatek.so
#     serves vendor.mediatek.hardware.bluetooth.audio@2.1 / @2.2  (MTK registry)
#
# Our Bluetooth stack is AOSP's, so it opens the AOSP factory and the session
# lands in the AOSP registry -- startSession_2_1 and OnSessionStarted both
# succeed. But stock's audio.bluetooth.default.so is MediaTek's build of the same
# AOSP source, relinked against the MTK interfaces (readelf DT_NEEDED:
# vendor.mediatek.hardware.bluetooth.audio@2.1/@2.2 and
# libbluetooth_audio_session_mediatek.so), so it polls the MTK registry, which
# nothing ever writes to:
#
#   init_session_type "is not ready"  x~100  ->  wait for session type timeout
#   -> open_output_stream fail -> -EINVAL -> APM: No output available for
#      device 0080 -> STREAM_MUSIC falls back to Devices: speaker(2)
#
# The user-visible symptom that this explains exactly: with the headset picked in
# the output chooser, its volume slider moves the SPEAKER volume, because the
# stream really is bound to speaker. Stock does not have the bug because stock's
# Bluetooth stack is MediaTek's and opens the MTK factory.
#
# AOSP's audio.bluetooth.default links libbluetooth_audio_session.so -- the
# registry our stack actually writes into -- so swapping the HAL is the fix, and
# the two -impl providers, both session libraries and the whole Bluetooth stack
# stay exactly as they are.
#
# ⚠ THE PREREQUISITE, and why this could not be done before: AOSP's HAL pulls
# libbluetooth_audio_session_aidl, which needs
# android::hardware::details::check(bool, char const*) -- an A13 addition to
# LIBFMQ (not to libhidlbase, which is where it was looked for first). The v31
# VNDK pin was serving A12's libfmq to every vendor process, so the library could
# not dlopen and the module loaded with Handle 0. Dropping libfmq from that pin
# is what unblocks it; the full measurement is in the VNDK section above. These
# two changes only work together.
#
# ⚠ libbluetooth_audio_session HAD TO COME WITH IT, and that was not a choice.
# It is also dropped from proprietary-files.txt, so it too builds from source.
# The blob cannot stay, because THE HAL WILL NOT COMPILE AGAINST IT:
#
#   device_port_proxy_hidl.cc:28:10: fatal error:
#       'BluetoothAudioSessionControl_2_1.h' file not found
#
# audio.bluetooth.default gets those headers transitively, from
# libbluetooth_audio_session's `export_include_dirs: ["session/"]`. A
# cc_prebuilt_library_shared exports no headers at all, so while the blob has
# prefer:true the include path does not exist. This is the identical failure
# already recorded above for android.hardware.bluetooth.audio@{2.0,2.1}-impl --
# same cause, same library, and the reason those two are still blobs.
#
# 🔴 So the A12 provider blobs now link OUR A13 session library. Checked by
# symbol before building, both providers and both ABIs -- not assumed:
#
#   @2.0-impl needs  8 symbols from it  -> 8/8 present in our A13 build  (lib, lib64)
#   @2.1-impl needs 12 symbols from it  -> 12/12 present                 (lib, lib64)
#   and the 15 this A13 HAL needs       -> also present in the A12 blob, so the
#                                          two are interchangeable in both directions
#
# The types crossing that boundary come from the frozen @2.0/@2.1 HIDL
# interfaces, identical in both builds. Verified on hardware afterwards, because
# a symbol table is not a running provider: all four factories still register
# (android@2.0, android@2.1, and MediaTek's @2.1/@2.2), and A2DP plays.
#
# libbluetooth_audio_session_mediatek STAYS A BLOB -- there is no source for it,
# and MediaTek's own @2.2-impl is the only thing that links it. Untouched.
#
# libbluetooth_audio_session_aidl is not listed here: it is a shared_libs
# dependency of the two modules above and soong installs it automatically. Its
# AIDL path is dead weight -- stock ships no AIDL Bluetooth-audio anything, and
# the bluetooth_audio.xml VINTF fragment that once declared one was removed in
# the 2026-08-10 remediation -- but it must still RESOLVE at dlopen, which is
# exactly what the libfmq change buys.
#
# ✅ VERIFIED ON HARDWARE 2026-08-26, staged via meta-overlayfs on build
# 20260826065107, headset "Lenovo ThinkPlus GM2 Pro":
#   "bluetooth" module Handle non-zero      (0 = failed to load; the previous
#                                            attempt's real failure, which read
#                                            as success because the -EINVAL had
#                                            merely stopped being reached)
#   "is not ready"                    ~100 -> 0
#   "No output available for device"       -> 0
#   STREAM_MUSIC   Devices: speaker(2)     -> Devices: bt_a2dp(80)
#   streamVolume 5, matching the bt_a2dp index (5), not the speaker index (14)
#   playback: BTAudioHalDeviceProxyHIDL Start -> ReportControlStatus SUCCESS
#             -> STARTED -> 187,264 frames written to the A2DP thread with a
#             real signal-power history -> Suspend -> STANDBY at track end
#   0 tombstones, 0 FATAL, 0 restarting services, no new denial class
PRODUCT_PACKAGES += \
    audio.bluetooth.default

# Media
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/media,$(TARGET_COPY_OUT_VENDOR)/etc)

# NFC. This board is the NXP variant of the reference design (pn553).
#
# libnfc-nxp_RF.conf is installed at the VENDOR PARTITION ROOT, not under
# etc/ with the other three. That is where stock puts it, and the path is
# hard-coded in the HAL: `strings vendor/lib64/nfc_nci_nxp.so` contains
# "/system/vendor/libnfc-nxp_RF.conf", and /system/vendor is a symlink to
# /vendor. It holds the 418 lines of NXP_RF_CONF_BLK_* antenna tuning, and
# libnfc-nxp.conf contains none of them, so this is the whole RF calibration
# for the device. Install it to etc/ and nothing errors — the HAL just falls
# back to firmware defaults and NFC range gets worse.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/nfc/libnfc-nci.conf:$(TARGET_COPY_OUT_VENDOR)/etc/libnfc-nci.conf \
    $(LOCAL_PATH)/configs/nfc/libnfc-nxp.conf:$(TARGET_COPY_OUT_VENDOR)/etc/libnfc-nxp.conf \
    $(LOCAL_PATH)/configs/nfc/libnfc-slm.conf:$(TARGET_COPY_OUT_VENDOR)/etc/libnfc-slm.conf \
    $(LOCAL_PATH)/configs/nfc/libnfc-nxp_RF.conf:$(TARGET_COPY_OUT_VENDOR)/libnfc-nxp_RF.conf

# NOTE on the 32 fragments in configs/vintf/manifest/ (merged via
# DEVICE_MANIFEST_FILE above, not copied):
#
# They cannot come through the vendor tree — extract-utils FORCE-creates a module
# for anything under etc/vintf/manifest/ regardless of the '-' prefix
# (extract_utils.sh:1219) and names it after the basename, so
# android.hardware.boot@1.2.xml collides with the android.hardware.boot@1.2
# library and soong fails "module already defined". Eleven of the 32 collide.
#
# They also cannot be PRODUCT_COPY_FILES: build/make/core/Makefile:72 hard-errors
# on any VINTF metadata copied that way ("use DEVICE_MANIFEST_FILE /
# DEVICE_MATRIX_FILE / vintf_compatibility_matrix / vintf_fragments instead").
#
# Merging is the better outcome anyway. assemble_vintf validates and unions at
# BUILD time instead of the runtime union VINTF would do over loose fragments, so
# a malformed or conflicting fragment fails the build rather than silently
# dropping a HAL. Four fragments overlap manifest.xml and are additive minor
# versions (boot 1.0+1.2, composer 2.1+2.3, sensors 2.0+2.1) plus one AIDL
# bluetooth.audio alongside the HIDL entry — all legal unions.

# Seccomp policies for the media stack
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/seccomp,$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy)

# Sensors. hals.conf names the sub-HALs the sensors multi-HAL should load;
# a name that does not resolve is not an error, multihal simply loads nothing
# and the device reports "No Sensors on the device". The single entry here —
# android.hardware.sensors@2.X-subhal-mediatek.so — was checked against
# vendor/lib64/hw in the revision 28 extraction and is present.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/sensors/hals.conf:$(TARGET_COPY_OUT_VENDOR)/etc/sensors/hals.conf

# Wi-Fi supplicant configuration
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/wifi,$(TARGET_COPY_OUT_VENDOR)/etc/wifi)

# Loose vendor configs
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/public.libraries.txt:$(TARGET_COPY_OUT_VENDOR)/etc/public.libraries.txt \
    $(LOCAL_PATH)/configs/task_profiles.json:$(TARGET_COPY_OUT_VENDOR)/etc/task_profiles.json

# Screen density. Panel is 720x1612; see the long note on ro.sf.lcd_density in
# configs/properties/vendor.prop. Keep TARGET_SCREEN_DENSITY (BoardConfig),
# ro.sf.lcd_density (vendor.prop) and this block consistent.
PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xhdpi

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH) \
    hardware/mediatek \
    vendor/itel/S666LN

# Inherit the proprietary blobs
$(call inherit-product, vendor/itel/S666LN/S666LN-vendor.mk)

# ---------------------------------------------------------------------------
# ro.rs4.build.stamp — what PackageManager compares to decide "is this an update?"
#
# 🔴 This ROM pins ro.build.version.incremental to the stock identity
# (251212V1661) on purpose, so e-KYC and Play Integrity see an honest device.
# AOSP's upgrade test is exactly that string, so mIsUpgrade is permanently false
# and everything gated on it is dead — measured on hardware, "Upgrading from"
# appeared 0 times in a boot that had just installed a new build, and build 73's
# GMS WRITE_DEVICE_CONFIG allowlist still read granted=false as a result.
#
# The fix patches what PackageManager COMPARES, never what the device REPORTS:
# frameworks/base PackageManagerService.getUpgradeStamp() reads this property and
# falls back to Build.VERSION.INCREMENTAL when it is absent. The fingerprint,
# the incremental and the whole reported identity are untouched.
#
# ⚠ GUARDED ON PURPOSE. If RS4_BUILD_STAMP is unset — any plain `m`, or anyone
# building this tree without the release script — the property is NOT emitted at
# all, getUpgradeStamp() falls back, and behaviour is exactly stock. An empty
# value would be equally safe (SystemProperties_getSS only overrides the default
# when value[0] is non-NUL, verified in core/jni), but not emitting it is
# clearer than emitting an empty string.
#
# ⚠ ONE VALUE PER RELEASE BUILD, not per `m`. crdroid-build-rc.sh exports it once
# so every artifact in a single release carries the same stamp; generating it
# here would change on every incremental re-run and make every boot an "upgrade".
ifneq ($(RS4_BUILD_STAMP),)
PRODUCT_SYSTEM_PROPERTIES += ro.rs4.build.stamp=$(RS4_BUILD_STAMP)
endif
