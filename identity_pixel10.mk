#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Identity: Google Pixel 10 "frankel" (operator, 2026-11-14) -- the identity the
# One UI port shipped, board included. itel never shipped Android 16 on the RS4, so
# "itel|Itel|itel S666LN|16|36" is a device+OS pair that does not exist, and
# e-KYC's server-side check (MANUFACTURER|BRAND|MODEL|RELEASE|SDK) rejects it;
# "Google|google|Pixel 10|16|36" exists. Values from Google's frankel factory image
# BD1A.250702.001. Opt-in: AICP includes this file always; lineage_S666LN.mk (LineageOS,
# Axion, crDroid) only when the build exports S666LN_IDENTITY=pixel10 (the ROM recipes do).
# product_common.mk keeps itel's identity as the tree default.
#
# Only the REPORTED identity changes. Key attestation must stay untouched, and that is a
# per-ROM check: AICP's KeyboxImitationHooks only act on a user-supplied keybox (read
# 2026-11-14), so the device's genuine hardware keybox still attests there. Read each other
# ROM's spoofing/attestation hooks before turning this on for it. The OTA package keeps pre-device S666LN
# (TARGET_OTA_ASSERT_DEVICE, BoardConfig.mk), so recoveries still accept it;
# ro.board.platform stays mt6789 (HAL module selection); S666LN_BOARD_NAME renames
# only the board (ro.product.board; BoardConfig.mk says why that is safe).
PRODUCT_BRAND := google
PRODUCT_MANUFACTURER := Google
PRODUCT_MODEL := Pixel 10
PRODUCT_SYSTEM_NAME := frankel
PRODUCT_SYSTEM_DEVICE := frankel
PRODUCT_GMS_CLIENTID_BASE := android-google
PRODUCT_BUILD_PROP_OVERRIDES += \
    DeviceName=frankel \
    DeviceProduct=frankel \
    BuildFlavor=frankel-user \
    BuildId=BD1A.250702.001 \
    BuildNumber=13724644 \
    BuildFingerprint=google/frankel/frankel:16/BD1A.250702.001/13724644:user/release-keys
S666LN_BOARD_NAME := frankel
# Values with spaces, and the optional (?=) build props the override list does not
# reach: product/etc/build.prop carries its own ro.build.description, and
# vendor/build.prop's ro.vendor.build.id comes from make's sysprop.mk.
S666LN_IDENTITY_PROP := device/itel/S666LN/configs/properties/identity-pixel10.prop
S666LN_IDENTITY_PRODUCT_PROP := device/itel/S666LN/configs/properties/identity-pixel10-product.prop
S666LN_IDENTITY_VENDOR_PROP := device/itel/S666LN/configs/properties/identity-pixel10-vendor.prop
