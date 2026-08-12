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
PRODUCT_PACKAGES += \
    vndservice \
    vndservicemanager

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
# Deliberately NOT setting BOARD_VNDK_VERSION := 31 either. It would rebuild
# every vendor module in the tree against the v31 snapshot -- hardware/mediatek,
# the source-built power/vibrator/memtrack HALs, wpa_supplicant -- to satisfy
# one soname in one prebuilt binary. The proportionate fix is a blob_fixup
# rename in extract-files.sh, which is what this tree already does for
# android.hardware.light-V1-ndk_platform.so on vendor/bin/factory.
#
# What stock actually relies on, for the record: /apex/com.android.vndk.v31,
# which stock ships in /system_ext/apex/. If a future build ever shows A12 blobs
# misbehaving against platform VNDK 33 in ways a soname rename cannot explain,
# that apex -- not this variable -- is the thing to reach for.

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
# They are taken from stock in proprietary-files.txt instead, because their
# dependency libbluetooth_audio_session is a blob on this device. A
# cc_prebuilt_library_shared exports no headers, so building the impl from
# source fails on
#     BluetoothAudioProvider.cpp:22:10: fatal error:
#         'BluetoothAudioSessionReport.h' file not found
# even though hardware/interfaces/bluetooth/audio/utils/ is present and its
# Android.bp does export session/. Shipping the impl as a blob also keeps it
# ABI-matched to the session library it is actually loaded against.
PRODUCT_PACKAGES += \
    android.hardware.audio.effect@6.0-impl \
    android.hardware.boot@1.2-mtkimpl \
    android.hardware.renderscript@1.0-impl

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
PRODUCT_PACKAGES += \
    wpa_supplicant

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
PRODUCT_PACKAGES += \
    hostapd

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

# Overlays
DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

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
# The MediaTek AIDL service is Mali-specific and reads GPU memory out of sysfs,
# so it is the right one for a G57 rather than the AOSP example, which reports
# zeroes. It carries its own init_rc and vintf_fragments.
PRODUCT_PACKAGES += \
    android.hardware.memtrack-service.mediatek-mali

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
PRODUCT_PACKAGES += \
    android.hardware.vibrator-service.mediatek

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
# These two are not, and the Trustonic keymint service needs all three: it
# registers keymint, secureclock and sharedsecret from one binary, so a missing
# soname takes out the keybox -- Play Integrity and e-KYC with it.
#
# Verified present in /vendor/lib64 of a completed build before the matching
# rename was added. If either is dropped, the rename dangles silently.
PRODUCT_PACKAGES += \
    android.hardware.security.secureclock-V1-ndk.vendor \
    android.hardware.security.sharedsecret-V1-ndk.vendor

# Audio
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/audio,$(TARGET_COPY_OUT_VENDOR)/etc)

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
