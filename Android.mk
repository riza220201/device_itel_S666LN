#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),S666LN)
include $(call all-makefiles-under,$(LOCAL_PATH))

# /vendor/lib*/foo.so -> mt6789/foo.so (634 of stock's 640; see symlinks.mk)
include $(LOCAL_PATH)/symlinks.mk

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

# Capture the script path NOW, with ':='. LOCAL_PATH is recursively expanded and
# every later makefile reassigns it, so a bare $(LOCAL_PATH) inside the recipe
# below expands at RULE-EXECUTION time to whatever was included last (in practice
# build/make/core) and the gate dies with
#   python3: can't open file '.../build/make/core/kmi-check.py'
# Prerequisites expand at parse time, so those were always correct; only the
# recipe body was wrong, and the bug stayed invisible for exactly as long as the
# gate was hooked to a target nothing ever built.
S666LN_KMI_SCRIPT := $(LOCAL_PATH)/kmi-check.py

# BOTH module sets are checked. vendor_dlkm is 198 modules and vendor_boot is
# 206, and a kernel that satisfies one is not automatically right for the other
# -- they are separate .ko sets that happen to share a KMI. Checking only
# vendor_dlkm, as this gate originally did, leaves 206 modules unverified.
$(S666LN_KMI_STAMP): $(TARGET_PREBUILT_INT_KERNEL) $(S666LN_KMI_SCRIPT)
	@echo "----- Verifying KMI against stock vendor modules -----"
	$(hide) python3 $(S666LN_KMI_SCRIPT) \
	    $(KERNEL_OUT)/Module.symvers \
	    $(KMI_VENDOR_MODULES_DIR) \
	    $(BOARD_KMI_MODULE_LAYOUT)
	$(hide) $(if $(wildcard $(KMI_RAMDISK_MODULES_DIR)),python3 $(S666LN_KMI_SCRIPT) \
	    $(KERNEL_OUT)/Module.symvers \
	    $(KMI_RAMDISK_MODULES_DIR) \
	    $(BOARD_KMI_MODULE_LAYOUT))
	$(hide) mkdir -p $(dir $@) && touch $@

# Hooking this to droidcore alone was useless: `mka bacon` never builds
# droidcore. bacon depends only on INTERNAL_OTA_PACKAGE_TARGET
# (vendor/lineage/build/tasks/bacon.mk:24), so a full ROM built, packaged and
# shipped with the gate never once running -- exactly the silent failure it
# exists to prevent.
#
# vendor_dlkm.img is the right hook: it is the artifact that CONTAINS the modules
# being verified, so every build that can produce a flashable image must build
# it. The literal path is used rather than INSTALLED_VENDOR_DLKMIMAGE_TARGET
# because build/make/core/Makefile is parsed after device Android.mk files, so
# that variable is still empty here. Adding a prerequisite to a rule defined
# later is fine; only its commands cannot be redefined.
droidcore: $(S666LN_KMI_STAMP)
$(PRODUCT_OUT)/vendor_dlkm.img: $(S666LN_KMI_STAMP)

else
$(warning S666LN: KMI_VENDOR_MODULES_DIR unset or missing - KMI gate DISABLED.)
$(warning         A config drift will produce a kernel that builds and does not boot.)
endif
endif

endif
