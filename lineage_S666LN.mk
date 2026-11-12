#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# LineageOS product for the itel RS4. Everything ROM-independent -- and why each
# line of it is there -- lives in product_common.mk.
include device/itel/S666LN/product_common.mk

# Inherit some common Lineage stuff
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME := lineage_S666LN
