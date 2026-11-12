#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/aicp_S666LN.mk \
    $(LOCAL_DIR)/lineage_S666LN.mk

# bp4a = this branch's BUILD_ID (BP4A.251205.006, build/make/core/build_id.mk);
# since Android 14 a lunch target is <product>-<release>-<variant>.
COMMON_LUNCH_CHOICES := \
    aicp_S666LN-bp4a-userdebug \
    aicp_S666LN-bp4a-user \
    lineage_S666LN-bp4a-userdebug \
    lineage_S666LN-bp4a-user
