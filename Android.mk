#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),S666LN)
include $(call all-makefiles-under,$(LOCAL_PATH))

# ---------------------------------------------------------------------------
# KMI gate
#
# Only meaningful when the kernel is built from source. Every prebuilt vendor
# module on this device is version-checked at load time, and the set includes
# storage, display and the GPU — so a kernel whose symbol CRCs disagree does not
# boot. Critically it also does not fail to BUILD, so without this the first
# symptom is a bootloop on hardware.
#
# The CRCs come from the kernel CONFIG, not the source (see kmi-check.py), which
# is exactly the kind of drift a ROM build can introduce silently.
#
# Variable names verified against vendor/lineage/build/tasks/kernel.mk on the
# Android 13 branch: KERNEL_OUT is line 90, TARGET_PREBUILT_INT_KERNEL line 123.
# ---------------------------------------------------------------------------
ifneq ($(TARGET_KERNEL_SOURCE),)
ifneq ($(wildcard $(KMI_VENDOR_MODULES_DIR)),)

S666LN_KMI_STAMP := $(PRODUCT_OUT)/kmi_verified.stamp

$(S666LN_KMI_STAMP): $(TARGET_PREBUILT_INT_KERNEL) $(LOCAL_PATH)/kmi-check.py
	@echo "----- Verifying KMI against stock vendor modules -----"
	$(hide) python3 $(LOCAL_PATH)/kmi-check.py \
	    $(KERNEL_OUT)/Module.symvers \
	    $(KMI_VENDOR_MODULES_DIR) \
	    $(BOARD_KMI_MODULE_LAYOUT)
	$(hide) mkdir -p $(dir $@) && touch $@

droidcore: $(S666LN_KMI_STAMP)

else
$(warning S666LN: KMI_VENDOR_MODULES_DIR unset or missing - KMI gate DISABLED.)
$(warning         A config drift will produce a kernel that builds and does not boot.)
endif
endif

endif
