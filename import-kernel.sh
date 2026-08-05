#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# OPTIONAL: ship a kernel built by the separate custom-kernel project instead of
# the GKI source this tree compiles by default.
#
# WHY TWO KERNELS EXIST, AND WHY THEY MUST STAY SEPARATE
#   kernel/itel/S666LN   plain GKI android12-5.10-lts 5.10.260 + s666ln_defconfig.
#                        What this tree builds by default, and what anyone who
#                        clones it reproduces byte for byte.
#   itel-rs4-kernel      the custom kernel project. Applies BORE and NTSYNC
#                        before building. Those patches belong ONLY there.
#
#   Do not "fix" the GKI fork by committing those patches into it. The defconfig
#   in the fork does list CONFIG_SCHED_BORE and CONFIG_NTSYNC; Kconfig discards
#   both silently when the source lacks them, so a from-source build here is a
#   kernel without those features, not a broken one.
#
# WHAT THIS IMPORTS
#   Image.gz          the kernel itself
#   vmlinux.symvers   the symbol CRCs, so the KMI gate can verify an imported
#                     kernel against all 404 prebuilt vendor modules exactly as
#                     it verifies a source-built one. Without it the gate cannot
#                     run at all in prebuilt mode, because FULL_KERNEL_BUILD is
#                     false and $(KERNEL_OUT)/Module.symvers is never produced.
#   kernel.config     kept purely as provenance for what was built.
#
# The import is verified before it is accepted: a kernel whose module_layout is
# not 0x7c24b32d, or which disagrees on any symbol CRC, is rejected here rather
# than at flash time.
#
# To go back to the in-tree source build, delete the prebuilt directory.

set -e

MY_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_PROJECT="${KERNEL_PROJECT:-$HOME/itel-rs4-kernel}"
VARIANT="${1:-vanilla}"
SRC="${KERNEL_PROJECT}/out/${VARIANT}"
DEST="${MY_DIR}/../S666LN-kernel/prebuilt"
KMI_LAYOUT="0x7c24b32d"

if [ ! -d "${SRC}" ]; then
    echo "!! no such build: ${SRC}" >&2
    echo "!! build it first:  (cd ${KERNEL_PROJECT} && ./build.sh ${VARIANT})" >&2
    echo "!! or set KERNEL_PROJECT=/path/to/itel-rs4-kernel" >&2
    exit 1
fi

for f in Image.gz vmlinux.symvers; do
    if [ ! -f "${SRC}/${f}" ]; then
        echo "!! ${SRC}/${f} is missing -- incomplete kernel build?" >&2
        exit 1
    fi
done

echo "Importing ${VARIANT} kernel from ${SRC}"

# Verify BEFORE installing, against both module sets. A kernel that fails here
# would build a ROM that flashes cleanly and bootloops.
for set in vendor_dlkm vendor_boot; do
    dir="${MY_DIR}/../S666LN-kernel/modules/${set}"
    [ -d "${dir}" ] || continue
    echo "  checking KMI against ${set}..."
    if ! python3 "${MY_DIR}/kmi-check.py" "${SRC}/vmlinux.symvers" "${dir}" "${KMI_LAYOUT}"; then
        echo "!! KMI check FAILED for ${set} -- refusing to import." >&2
        echo "!! This kernel cannot load the stock vendor modules and would not boot." >&2
        exit 1
    fi
done

mkdir -p "${DEST}"
cp -f "${SRC}/Image.gz"        "${DEST}/Image.gz"
cp -f "${SRC}/vmlinux.symvers" "${DEST}/vmlinux.symvers"
[ -f "${SRC}/kernel.config" ] && cp -f "${SRC}/kernel.config" "${DEST}/kernel.config"

{
    echo "variant:  ${VARIANT}"
    echo "source:   ${SRC}"
    echo "imported: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "sha256:"
    (cd "${DEST}" && sha256sum Image.gz vmlinux.symvers | sed 's/^/  /')
} > "${DEST}/IMPORTED"

echo
echo "Imported to ${DEST}"
echo "  BoardConfig.mk picks this up automatically (TARGET_FORCE_PREBUILT_KERNEL)."
echo "  The ROM will now ship this kernel instead of building kernel/itel/S666LN."
echo "  Delete ${DEST} to go back to the source build."
