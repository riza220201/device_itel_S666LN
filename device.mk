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

# VNDK is deliberately NOT pinned here.
#
# It was previously set to 31, which was wrong. Stock's vendor partition says:
#
#   ro.product.first_api_level      = 31    device launched on Android 12
#   ro.vendor.build.version.sdk     = 33    vendor was BUILT at Android 13
#   ro.vndk.version                 = 33
#
# Three different numbers that are easy to conflate. The vendor blobs in this
# tree are VNDK 33, which is also the platform VNDK on the Android 13 branch, so
# no snapshot is needed and PRODUCT_TARGET_VNDK_VERSION should stay unset.
# Pinning 31 would force the prebuilts/vndk/v31 snapshot under blobs built
# against 33.
#
# Note this device is unusual among MT6789 phones: Infinix, Tecno, Xiaomi and
# Samsung all ship an Android-12 vendor (sdk 31) under a newer system. itel
# actually rebased theirs to Android 13 — while still carrying the A12-era Mali
# r32p1 and A12 AIDL soname conventions (see blob_fixup in extract-files.sh).

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
    libchrome.vendor \
    libcodec2_hidl@1.0.vendor \
    libcodec2_hidl@1.1.vendor \
    libcodec2_hidl@1.2.vendor \
    libcodec2_soft_common.vendor \
    libcodec2_vndk.vendor \
    libcppbor_external.vendor \
    libdrm.vendor \
    libeffectsconfig.vendor \
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
    ese_spi_nxp \
    libhwc2on1adapter \
    libhwc2onfbadapter \
    libmtkperf_client_vendor \
    nfc_nci_nxp


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
