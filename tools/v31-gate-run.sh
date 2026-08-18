#!/bin/bash
#
# v31-gate-run.sh [<built-vendor-dir>]
#
# Prepare the three inputs tools/v31-delta-check.py needs and run it against a
# COMPLETED build.
#
# WHY A WRAPPER
# -------------
# The gate is not wired into the build, and that is a deliberate limitation
# rather than an oversight: its v33 input is the CURRENT platform VNDK, which
# exists only inside `com.android.vndk.current.apex`. prebuilts/vndk/ carries
# v28..v32 and stops -- there is no v33 snapshot to point at, so wiring it would
# mean unpacking an apex mid-build with debugfs.
#
# But "run it by hand afterwards" is how build 67 shipped. Its predecessor had
# already named the boot blocker by filename a day earlier and was not run
# against the build. So the wrapper exists to make running it one command, which
# is the whole difference between a documented step and a performed one.
#
#     device/itel/S666LN/tools/v31-gate-run.sh
#
# THE ACCEPTED EXCEPTION
# ----------------------
# bin/dumpsys is passed with --accept, and that is the only one. It cannot be
# fixed from this tree: `dumpsys_vendor` is an unconditional PRODUCT_PACKAGES
# entry in build/make/target/product/base_vendor.mk:52, i.e. inherited, and
# PRODUCT_PACKAGES cannot subtract. A blob named `dumpsys` does not match the
# source module so it cannot displace it, and installs to the same path so it
# collides; a `-stock` rename yields a command nobody can type.
#
# Measured before accepting: nothing on the vendor partition references
# /vendor/bin/dumpsys -- no rc, no script, no binary -- on build 67's image or on
# the running device, and /system/bin/dumpsys is unaffected.
#
# --accept does NOT rot: the gate FAILS on an accepted path that is no longer a
# finding, so if dumpsys is ever fixed this script stops working until the flag
# is removed.
#
set -euo pipefail

MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${MY_DIR}/.." && pwd)"
ANDROID_ROOT="$(cd "${DEVICE_DIR}/../../.." && pwd)"
OUT="${ANDROID_ROOT}/out/target/product/S666LN"
VENDOR_DIR="${1:-${OUT}/vendor}"
V31_DIR="${DEVICE_DIR}/prebuilts/vndk31-snapshot"

die() { echo "!! $*" >&2; exit 1; }

[ -d "${VENDOR_DIR}" ] || die "no built vendor tree at ${VENDOR_DIR}
   Build first. This gate reads the BUILT image, not the blob source: build 67
   passed vendor-deps AND KMI against its own artifacts and still hung at the
   logo, because neither can see a v33-only symbol reference."
[ -d "${V31_DIR}" ] || die "no v31 snapshot at ${V31_DIR}"

# ---- the v33 set, out of the platform's own apex.
APEX="${OUT}/system/apex/com.android.vndk.current.apex"
[ -f "${APEX}" ] || die "no ${APEX}
   That apex IS the v33 reference set; without it there is nothing to diff
   against and the gate would have an empty delta -- which is its documented way
   of passing vacuously. It refuses below 1,000 v33-only symbols, so this would
   exit 2 rather than lie, but fix the input rather than reading that as a pass."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
unzip -o -q "${APEX}" apex_payload.img -d "${TMP}"
# debugfs lives in /sbin, which is NOT on a normal user's PATH on Debian -- the
# same trap notes/kernel-modules-2026-08-04.md records for modprobe.
DEBUGFS=/sbin/debugfs; [ -x "${DEBUGFS}" ] || DEBUGFS="$(command -v debugfs)" || \
    die "debugfs not found (try /sbin/debugfs)"
mkdir -p "${TMP}/v33"
# The ownership warnings from a non-root rdump are expected and harmless: the
# file CONTENTS are what this reads.
"${DEBUGFS}" -R "rdump /lib64 ${TMP}/v33" "${TMP}/apex_payload.img" >/dev/null 2>&1 || true
"${DEBUGFS}" -R "rdump /lib   ${TMP}/v33" "${TMP}/apex_payload.img" >/dev/null 2>&1 || true
n="$(find "${TMP}/v33" -name '*.so' | wc -l)"
[ "${n}" -ge 200 ] || die "only ${n} libraries extracted from the v33 apex.
   Expected ~326 (163 per ABI). The gate's own floor would catch this, but a
   broken extraction should fail here rather than be reported as a verdict."
echo "== v33 reference set: ${n} libraries from $(basename "${APEX}")"

exec python3 "${MY_DIR}/v31-delta-check.py" \
    --accept bin/dumpsys \
    "${VENDOR_DIR}" "${V31_DIR}" "${TMP}/v33"
