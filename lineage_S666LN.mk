#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# LineageOS product for the itel RS4. Everything ROM-independent -- and why each
# line of it is there -- lives in product_common.mk.
include device/itel/S666LN/product_common.mk

# The Pixel 10 identity (identity_pixel10.mk), opt-in: the ROM recipes building this product
# (LineageOS, Axion, crDroid) export S666LN_IDENTITY=pixel10; a plain lunch keeps itel's.
ifeq ($(S666LN_IDENTITY),pixel10)
include device/itel/S666LN/identity_pixel10.mk
endif

# Inherit some common Lineage stuff
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME := lineage_S666LN
AXION_MAINTAINER := SuzunaProject

ifeq ($(WITH_GAPPS),true)
$(call inherit-product, vendor/gapps/arm64/arm64-vendor.mk)
endif
