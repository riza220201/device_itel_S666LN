#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Dalvik heap. 🔴 NOT optional, and its absence is not a tuning question --
# without it system_server runs out of Java heap and the device never finishes
# booting. Measured on hardware, build 51:
#
#   FATAL EXCEPTION IN SYSTEM PROCESS
#   java.lang.OutOfMemoryError: Failed to allocate a 392192 byte allocation with
#     260544 free bytes and 254KB until OOM, target footprint 16777216,
#     growth limit 16777216
#     at FileUtils.readTextFile / Parcel.nativeReadString16 / ...
#
# 16777216 is 16 MiB: AOSP's fallback when NO dalvik heap configuration is
# inherited at all. system_server reached ~242 services, exhausted the heap and
# restarted, forever. `getprop | grep dalvik.vm.heap` on the device returned
# nothing whatsoever.
#
# How it went missing: configs/properties/vendor.prop was generated from stock
# with `dalvik.vm.heap*` deliberately excluded as "build-system owned". True in
# principle -- the build system does own them -- but only if a heap makefile is
# inherited, and this tree inherited none. The exclusion was right and the
# replacement was never added.
#
# phone-xhdpi-6144 rather than 4096: its six values are BYTE-IDENTICAL to what
# stock's vendor/build.prop declares (start 16m, growth 256m, size 512m,
# utilization 0.5, minfree 8m, maxfree 32m). The 4096 file differs on three of
# them (8m/192m/0.6/16m). The name says 6144 MB but the match to stock is what
# selects it, and this device has ~11.4 GiB of RAM in any case.
#
# Verified live before committing: setting these six by hand and restarting the
# framework took the device from a permanent boot loop to sys.boot_completed=1
# and the setup wizard.
$(call inherit-product, frameworks/native/build/phone-xhdpi-6144-dalvik-heap.mk)

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit from S666LN device
$(call inherit-product, $(LOCAL_PATH)/device.mk)

# Inherit some common Lineage stuff
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME := lineage_S666LN
PRODUCT_DEVICE := S666LN
PRODUCT_MANUFACTURER := ITEL
PRODUCT_BRAND := Itel
PRODUCT_MODEL := itel S666LN

# The retail name of this device is "itel RS4"; the model string itel ships
# already contains the brand, so ro.product.marketname is set in
# configs/properties/system.prop instead — a value containing a space cannot
# go through PRODUCT_*_PROPERTIES (entries there are whitespace-separated).
# (That was true as a plan before it was true as code: until 2026-08-10 this
# comment described the intent while the property was actually being appended
# by the build recipe. It is now really in system.prop.)

# Identity presented to the platform. These are the values itel ships; the
# second field of a build fingerprint is the PRODUCT name, which is why the
# stock fingerprint reads S666LN-OP while the model is "itel S666LN".
PRODUCT_SYSTEM_NAME := S666LN-OP
PRODUCT_SYSTEM_DEVICE := itel-S666LN

PRODUCT_GMS_CLIENTID_BASE := android-transsion

# Build fingerprint / description are deliberately NOT set here. They are a
# ROM-level decision (they must match the signing posture), so they belong in
# the build recipe, not in a device tree other ROMs are expected to reuse.
