#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# REQUIRED on lineage-23.2: import the kernel built by the separate custom-kernel
# project. This branch never compiles a kernel and has no from-source fallback
# (BoardConfig.mk stops the build without the import).
#
# WHY TWO KERNELS EXIST, AND WHY THEY MUST STAY SEPARATE
#   kernel/itel/S666LN   plain GKI android12-5.10-lts 5.10.260 + s666ln_defconfig.
#                        On lineage-23.2 it is read for headers only; it is
#                        never compiled into the ROM.
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
# The kernel package TRACKS prebuilt/ on lineage-23.2: commit it after an import.

set -e

MY_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_PROJECT="${KERNEL_PROJECT:-$HOME/itel-rs4-kernel}"
VARIANT="${1:-vanilla}"
# Since v9 (2026-10-28) the kernel project builds with Neutron clang into
# .build/out-<variant> (build.sh: KOUT) and keeps only the PUBLISHED artifacts in
# out/<variant> (PUB_DIR): the flashable boot image and the AnyKernel3 zip. The
# kernel is read from KOUT and then proven to be the published one (below).
KOUT="${KOUT:-${KERNEL_PROJECT}/.build/out-${VARIANT}}"
PUB_DIR="${PUB_DIR:-${KERNEL_PROJECT}/out/${VARIANT}}"
IMAGE="${KOUT}/arch/arm64/boot/Image.gz"
SYMVERS="${KOUT}/vmlinux.symvers"
CONFIG="${KOUT}/.config"
KPKG="${MY_DIR}/../S666LN-kernel"
DEST="${KPKG}/prebuilt"
KMI_LAYOUT="0x7c24b32d"

for f in "${IMAGE}" "${SYMVERS}" "${CONFIG}"; do
    if [ ! -f "${f}" ]; then
        echo "!! missing: ${f} -- incomplete kernel build?" >&2
        echo "!! build it first:  (cd ${KERNEL_PROJECT} && ./build.sh ${VARIANT})" >&2
        echo "!! or set KERNEL_PROJECT / KOUT" >&2
        exit 1
    fi
done

# Ship the Image that was BOOTED, not a rebuild of it: a build in another out
# dir is not byte-identical (objtree strings, build-id). So the Image must hash
# equal to the kernel inside the published boot image (header v3/v4: kernel at
# 4096, size at offset 8, header_version at 40).
BOOTIMG=$(ls -t "${PUB_DIR}"/ItelRS4-boot-"${VARIANT}"-*.img 2>/dev/null | head -1)
if [ -z "${BOOTIMG}" ]; then
    if [ "${ALLOW_UNPUBLISHED:-0}" != 1 ]; then
        echo "!! no published boot image in ${PUB_DIR} to prove this kernel against." >&2
        echo "!! Set ALLOW_UNPUBLISHED=1 to import a kernel that was never released." >&2
        exit 1
    fi
    echo "  !! importing an UNPUBLISHED kernel (ALLOW_UNPUBLISHED=1)"
else
    BOOT_SHA=$(python3 -I - "${BOOTIMG}" <<'PY'
import hashlib, struct, sys
d = open(sys.argv[1], 'rb').read()
if d[:8] != b'ANDROID!':
    sys.exit('not an Android boot image: ' + sys.argv[1])
ksize, = struct.unpack_from('<I', d, 8)
hver, = struct.unpack_from('<I', d, 40)
if hver not in (3, 4):
    sys.exit('boot header v%d: only v3/v4 are parsed here' % hver)
print(hashlib.sha256(d[4096:4096 + ksize]).hexdigest())
PY
)
    IMAGE_SHA=$(sha256sum "${IMAGE}" | cut -d' ' -f1)
    if [ "${BOOT_SHA}" != "${IMAGE_SHA}" ]; then
        echo "!! ${IMAGE} (${IMAGE_SHA:0:16}) is NOT the kernel inside" >&2
        echo "!! ${BOOTIMG} (${BOOT_SHA:0:16}) -- rebuilt since publishing? Refusing." >&2
        exit 1
    fi
    echo "  = the kernel inside $(basename "${BOOTIMG}") (${IMAGE_SHA:0:16})"
fi

BANNER=$(zcat "${IMAGE}" | strings -a | LC_ALL=C grep -a -m1 -E '^Linux version [0-9]' || true)
echo "Importing ${VARIANT} kernel from ${KOUT}"
echo "  ${BANNER:-!! no Linux banner found in the Image}"

# Verify BEFORE installing, against both module sets. A kernel that fails here
# would build a ROM that flashes cleanly and bootloops. A missing module set is
# a FAILURE, not a skip: a gate that silently does not run passes everything.
for set in vendor_dlkm vendor_boot; do
    dir="${KPKG}/modules/${set}"
    if [ ! -d "${dir}" ]; then
        echo "!! ${dir} is missing -- the KMI gate cannot run. Sync device/itel/S666LN-kernel first." >&2
        exit 1
    fi
    echo "  checking KMI against ${set}..."
    if ! python3 "${MY_DIR}/kmi-check.py" "${SYMVERS}" "${dir}" "${KMI_LAYOUT}"; then
        echo "!! KMI check FAILED for ${set} -- refusing to import." >&2
        echo "!! This kernel cannot load the stock vendor modules and would not boot." >&2
        exit 1
    fi
done

mkdir -p "${DEST}"
cp -f "${IMAGE}"   "${DEST}/Image.gz"
cp -f "${SYMVERS}" "${DEST}/vmlinux.symvers"
cp -f "${CONFIG}"  "${DEST}/kernel.config"

{
    echo "variant:   ${VARIANT}"
    echo "source:    ${KOUT}"
    echo "published: ${BOOTIMG:-NONE (ALLOW_UNPUBLISHED=1)}"
    echo "kernel:    ${BANNER}"
    echo "imported:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "sha256:"
    (cd "${DEST}" && sha256sum Image.gz vmlinux.symvers kernel.config | sed 's/^/  /')
} > "${DEST}/IMPORTED"

echo
echo "Imported to ${DEST}"
echo "  BoardConfig.mk picks this up automatically (TARGET_FORCE_PREBUILT_KERNEL)."
echo "  On lineage-23.2 prebuilt/ is TRACKED in the kernel package: commit it there."
echo "  There is no source build to go back to -- without prebuilt/ the build stops."
