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

# Which symvers to verify against. KMI_SYMVERS is set by BoardConfig.mk only when
# a custom kernel has been imported; otherwise the file comes from the in-tree
# source build. $(KERNEL_OUT) is not defined this early, so the fallback stays
# recursively expanded ('=') and resolves when the recipe runs.
ifneq ($(KMI_SYMVERS),)
S666LN_KMI_SYMVERS := $(KMI_SYMVERS)
S666LN_KMI_KERNEL_DEP := $(TARGET_PREBUILT_KERNEL)
else
S666LN_KMI_SYMVERS = $(KERNEL_OUT)/Module.symvers
S666LN_KMI_KERNEL_DEP = $(TARGET_PREBUILT_INT_KERNEL)
endif

# BOTH module sets are checked. vendor_dlkm is 198 modules and vendor_boot is
# 206, and a kernel that satisfies one is not automatically right for the other
# -- they are separate .ko sets that happen to share a KMI. Checking only
# vendor_dlkm, as this gate originally did, leaves 206 modules unverified.
$(S666LN_KMI_STAMP): $(S666LN_KMI_KERNEL_DEP) $(S666LN_KMI_SCRIPT)
	@echo "----- Verifying KMI against stock vendor modules -----"
	$(hide) python3 $(S666LN_KMI_SCRIPT) \
	    $(S666LN_KMI_SYMVERS) \
	    $(KMI_VENDOR_MODULES_DIR) \
	    $(BOARD_KMI_MODULE_LAYOUT)
	$(hide) $(if $(wildcard $(KMI_RAMDISK_MODULES_DIR)),python3 $(S666LN_KMI_SCRIPT) \
	    $(S666LN_KMI_SYMVERS) \
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
# Hooking this correctly took three tries; the first two both "worked" in the
# sense that the build succeeded and the gate never ran.
#
#   droidcore              `mka bacon` never builds droidcore.
#   vendor_dlkm.img        `mka bacon` never builds that either. bacon goes
#                          bacon -> OTA -> target-files -> STAGED FILES, and
#                          add_img_to_target_files creates the .img files itself
#                          at packaging time. Confirmed with
#                          `ninja -t query` / `-n bacon`: no .img target appears
#                          anywhere in bacon's graph.
#
# What target-files actually consumes is the staged tree, so the gate has to hang
# off files that get staged. symlinks.mk has already registered 634 of ours in
# ALL_DEFAULT_INSTALLED_MODULES by the time this runs, all under
# $(TARGET_OUT_VENDOR), and every one of them is a direct input to the
# target-files zip.
#
# Order-only ('|') on purpose: the stamp must exist before our vendor files are
# installed, but its timestamp must not make them perpetually dirty.
#
# The $(error) is the point of the whole block. Both earlier attempts failed
# SILENTLY -- a detached gate looks exactly like a passing one. If this filter
# ever comes up empty the build stops instead of quietly shipping unverified.
S666LN_KMI_HOOK := $(filter $(TARGET_OUT_VENDOR)/%,$(ALL_DEFAULT_INSTALLED_MODULES))
ifeq ($(S666LN_KMI_HOOK),)
$(error S666LN: KMI gate has nothing to attach to. It would not run, and the \
        build would ship a kernel that was never checked against the vendor \
        modules. Fix the hook rather than removing this check.)
endif
$(S666LN_KMI_HOOK): | $(S666LN_KMI_STAMP)

# Kept for `m`/`make` and for image-only builds, which do reach these.
droidcore: $(S666LN_KMI_STAMP)
$(PRODUCT_OUT)/vendor_dlkm.img: $(S666LN_KMI_STAMP)

else
$(warning S666LN: KMI_VENDOR_MODULES_DIR unset or missing - KMI gate DISABLED.)
$(warning         A config drift will produce a kernel that builds and does not boot.)
endif
endif

# ---------------------------------------------------------------------------
# Vendor dependency gate -- the userspace counterpart of the KMI gate above
#
# The KMI gate catches a kernel that builds and cannot boot. This catches a
# VENDOR PARTITION that builds and cannot link: the 2026-08-05 image compiled,
# packaged, release-signed and flashed cleanly with 501 unresolved DT_NEEDED
# references across 144 libraries, and stalled at 46 s waiting for a boot HAL
# that had died in the linker.
#
# 🔴 It is hooked DIFFERENTLY from the KMI gate, and copying that hook here
# would produce a gate that reports success while testing nothing.
#
#   KMI gate       verifies INPUTS (prebuilt .ko vs the kernel's symvers). Those
#                  exist before anything is staged, so it hangs off
#                  ALL_DEFAULT_INSTALLED_MODULES as an ORDER-ONLY prerequisite
#                  -- deliberately running BEFORE our vendor files install.
#   this gate      verifies the OUTPUT: the staged /vendor tree, complete. Run
#                  it at the same point and it reads a half-populated directory
#                  and fails on files that were about to be written.
#
# So it has to run after staging and still be inside `bacon`'s graph, and the
# journal already established that bacon reaches no image target at all
# (bacon -> OTA -> target-files -> staged files; add_img_to_target_files builds
# the .img files itself at packaging time). What bacon DOES reach is the
# target-files zip, and everything staged is a prerequisite of it -- so
# depending on that zip is what buys "after staging" without naming the
# thousands of files individually.
#
# The zip is nameable this early only because FILE_NAME_TAG is assigned at
# build/make/core/main.mk:63-67, before the subdir makefiles are included at
# line 547. The name is built exactly as build/make/core/Makefile:5448-5455
# builds it, _debug suffix included.
#
# Both ways this can break are LOUD, which is the property the KMI gate lacked
# through two silent "passes":
#   * wrong zip path  -> make: *** No rule to make target ... needed by
#                        vendor_deps_verified.stamp
#   * detached hook   -> impossible. `bacon` is a phony that always exists, so
#                        the dependency cannot quietly attach to nothing the
#                        way $(PRODUCT_OUT)/vendor_dlkm.img did.
#
# Cost measured against build 41's tree: 35 seconds, 1,972 ELFs.
# ---------------------------------------------------------------------------
S666LN_VDEPS_SCRIPT := $(LOCAL_PATH)/tools/vendor-deps-check.sh

ifeq ($(wildcard $(S666LN_VDEPS_SCRIPT)),)
$(error S666LN: tools/vendor-deps-check.sh is missing. Restore it rather than \
        dropping this gate: without it a vendor partition whose HALs cannot \
        link builds, signs and flashes without complaint.)
endif
ifeq ($(FILE_NAME_TAG),)
$(error S666LN: FILE_NAME_TAG is empty, so the target-files path below cannot \
        be constructed and the vendor dependency gate would not run.)
endif

S666LN_VDEPS_NAME := $(TARGET_PRODUCT)
ifeq ($(TARGET_BUILD_TYPE),debug)
S666LN_VDEPS_NAME := $(S666LN_VDEPS_NAME)_debug
endif
S666LN_VDEPS_NAME := $(S666LN_VDEPS_NAME)-target_files-$(FILE_NAME_TAG)

S666LN_VDEPS_TF    := $(PRODUCT_OUT)/obj/PACKAGING/target_files_intermediates/$(S666LN_VDEPS_NAME).zip
S666LN_VDEPS_STAMP := $(PRODUCT_OUT)/vendor_deps_verified.stamp

# S666LN_VDEPS_SCRIPT is assigned with ':=' above for the same reason as the KMI
# script path: $(LOCAL_PATH) is recursively expanded, and a bare reference to it
# inside a recipe resolves at RULE-EXECUTION time to whatever makefile was
# included last -- in practice build/make/core. Simply-expanded freezes it here.
$(S666LN_VDEPS_STAMP): $(S666LN_VDEPS_TF) $(S666LN_VDEPS_SCRIPT)
	@echo "----- Verifying vendor DT_NEEDED resolution, per ABI -----"
	$(hide) $(S666LN_VDEPS_SCRIPT) $(TARGET_OUT_VENDOR) $(TARGET_OUT)
	$(hide) mkdir -p $(dir $@) && touch $@

bacon: $(S666LN_VDEPS_STAMP)

# 🔴 And the RELEASE path, which is a DIFFERENT target and was not covered.
#
# Everything above reasons about `bacon`, because that is what a test build
# runs. A release does not run bacon at all:
#
#   crdroid-build-eng.sh  ->  mka bacon                  (test)
#   crdroid-build-rc.sh   ->  mka target-files-package   (RELEASE)
#
# so this gate did not execute on build 61 or build 62 -- the only two release
# builds this project has ever produced. Measured, not inferred: zero gate
# output in either log, and $(PRODUCT_OUT)/vendor_deps_verified.stamp still
# carried the timestamp of an older eng run while build 62's target-files zip
# was hours newer. Run by hand against build 62 afterwards it passes
# (1,996 ELFs, 1,387 resolvable, six checks), so nothing shipped broken -- but
# it was verified by someone remembering to, which is not a gate.
#
# This is the KMI gate's own history, one week later and one path over: on
# 2026-08-05 that gate was hooked to `droidcore` and `vendor_dlkm.img`, neither
# of which `bacon` traverses. The lesson recorded then was "hook the staged
# INPUTS, which every packaging path must produce". This gate cannot do that --
# it verifies the COMPLETE staged tree, so it must run after staging -- and the
# alternative, naming every packaging path, is only correct while the list is
# complete. It is exactly two entries, both in this file, both loud if wrong:
# a phony that does not exist would make the build fail with "No rule to make
# target", not pass quietly.
#
# target-files-package is real and is what the release path builds:
#   build/make/core/Makefile:6190  .PHONY: target-files-package
#   build/make/core/Makefile:6191  target-files-package: $(BUILT_TARGET_FILES_PACKAGE)
target-files-package: $(S666LN_VDEPS_STAMP)

# droidcore is deliberately NOT hooked here, unlike the KMI gate. droidcore
# builds images without building target-files, so hooking it would drag the
# whole target-files zip into image-only builds to satisfy this stamp.

endif
