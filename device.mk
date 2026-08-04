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
# No DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE. The only framework matrix in
# stock revision 28 is /product/etc/vintf/compatibility_matrix.xml, and its
# entire content is two optional="true" Transsion HALs (deviceauthen, hap) for
# HiOS apps this ROM does not ship. There is nothing to require.

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
