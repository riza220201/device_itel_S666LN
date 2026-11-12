#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# AICP product for the itel RS4. Everything ROM-independent -- and why each
# line of it is there -- lives in product_common.mk.
#
# AICP w16.2 (LineageOS 23.2 + AICP's forks) is the ROM this lineage-23.2 tree is
# built and tested as (operator, 2026-11-12).
include device/itel/S666LN/product_common.mk

# Inherit some common AICP stuff (vendor/aicp = AICP's vendor/lineage)
$(call inherit-product, vendor/aicp/config/common_full_phone.mk)

PRODUCT_NAME := aicp_S666LN
