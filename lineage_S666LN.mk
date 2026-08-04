#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

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

# Identity presented to the platform. These are the values itel ships; the
# second field of a build fingerprint is the PRODUCT name, which is why the
# stock fingerprint reads S666LN-OP while the model is "itel S666LN".
PRODUCT_SYSTEM_NAME := S666LN-OP
PRODUCT_SYSTEM_DEVICE := itel-S666LN

PRODUCT_GMS_CLIENTID_BASE := android-transsion

# Build fingerprint / description are deliberately NOT set here. They are a
# ROM-level decision (they must match the signing posture), so they belong in
# the build recipe, not in a device tree other ROMs are expected to reuse.
