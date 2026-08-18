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
#
# Two shapes, and a build produces the easy one. soong emits a FLATTENED apex --
# a plain directory of lib/ and lib64/ -- so the reference set can be read
# straight off disk. The .apex FILE form only appears in a stock dump, and that
# is the one needing unzip + debugfs.
#
# ⚠ The flattened path is `com.android.vndk.current`, with no `.apex` suffix and
# no version in the name. Looking for com.android.vndk.current.apex finds
# nothing on a freshly built tree, which is what this script did first.
APEX_DIR="${OUT}/system/apex/com.android.vndk.current"
APEX_FILE="${OUT}/system/apex/com.android.vndk.current.apex"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if [ -d "${APEX_DIR}/lib64" ]; then
    V33_DIR="${APEX_DIR}"
    n="$(find "${APEX_DIR}" -name '*.so' | wc -l)"
    echo "== v33 reference set: ${n} libraries from the flattened apex"
elif [ -f "${APEX_FILE}" ]; then
    unzip -o -q "${APEX_FILE}" apex_payload.img -d "${TMP}"
    # debugfs lives in /sbin, off a normal user's PATH on Debian -- the same trap
    # notes/kernel-modules-2026-08-04.md records for modprobe.
    DEBUGFS=/sbin/debugfs; [ -x "${DEBUGFS}" ] || DEBUGFS="$(command -v debugfs)" || \
        die "debugfs not found (try /sbin/debugfs)"
    mkdir -p "${TMP}/v33"
    "${DEBUGFS}" -R "rdump /lib64 ${TMP}/v33" "${TMP}/apex_payload.img" >/dev/null 2>&1 || true
    "${DEBUGFS}" -R "rdump /lib   ${TMP}/v33" "${TMP}/apex_payload.img" >/dev/null 2>&1 || true
    V33_DIR="${TMP}/v33"
    n="$(find "${V33_DIR}" -name '*.so' | wc -l)"
    echo "== v33 reference set: ${n} libraries from $(basename "${APEX_FILE}")"
else
    die "no VNDK apex at either
     ${APEX_DIR}          (flattened, what a build produces)
     ${APEX_FILE}         (packed, what a stock dump has)
   That apex IS the v33 reference set; without it the delta is empty, which is
   this gate's documented way of passing vacuously. It refuses below 1,000
   v33-only symbols and would exit 2 rather than lie -- but fix the input rather
   than reading that as a pass."
fi
[ "${n}" -ge 200 ] || die "only ${n} libraries in the v33 set (expected ~326, 163 per ABI).
   A broken extraction should fail here rather than be reported as a verdict."

exec python3 "${MY_DIR}/v31-delta-check.py" \
    --accept bin/dumpsys \
    "${VENDOR_DIR}" "${V31_DIR}" "${V33_DIR}"
