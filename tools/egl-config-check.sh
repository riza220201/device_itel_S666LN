#!/bin/bash
#
# egl-config-check.sh [<baseline>]
#
# Compare the EGL config table the device's GPU driver actually advertises
# against a known-good baseline, and fail if they differ.
#
# WHY THIS EXISTS
#   The vendor tree ships a Mali driver taken from another vendor's firmware.
#   The five acceptance checks in mali_candidate_check.sh (sdk, revision, no
#   AIDL allocator, DT_NEEDED a strict subset, MTK symbols resolvable) are all
#   properties of the BINARY. None can see a runtime capability table.
#
#   2026-08-27: r38p1 shipped publicly advertising EGL_RECORDABLE_ANDROID on
#   ZERO configs and EGL_WINDOW_BIT on 6 instead of 21, because at r38p1 ARM
#   moved that table out of the driver and into ro.vendor.arm.egl.configs.*
#   properties that nothing set. Every camera/video GL pipeline got zero
#   matches from eglChooseConfig and died with EGL_BAD_CONFIG. WhatsApp's
#   camera force-closed. All five binary checks passed.
#
#   It also emits NO avc record: property-read refusals are dontaudit'd
#   (system/sepolicy/public/domain.te:146). No denial sweep can find this.
#
# The baseline is the table stock r32p1 reports on this hardware, captured with
# the stock driver staged over /vendor. Regenerate only against a driver known
# good on the DEVICE, never from a spec.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${1:-$DIR/egl-config-baseline.txt}"

[ -f "$BASE" ] || { echo "!! no baseline at $BASE" >&2; exit 2; }
adb get-state >/dev/null 2>&1 || { echo "!! no device" >&2; exit 2; }

# The binary is built beside its source, in egl-probe/. Older copies sat next to
# this script, so both are accepted rather than breaking anyone's muscle memory.
PROBE=""
for c in "$DIR/egl-probe/eglprobe" "$DIR/eglprobe"; do [ -x "$c" ] && { PROBE="$c"; break; }; done
[ -n "$PROBE" ] || {
  echo "!! eglprobe not built. From tools/egl-probe/ (NDK r27 is at" >&2
  echo "   /mnt/external_nvme/android-sdk/ndk/27.0.12077973):" >&2
  echo "     CC=<ndk>/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" >&2
  echo "     for f in eglprobe eglchoose ahbprobe; do" >&2
  echo "       \$CC --target=aarch64-linux-android33 -O1 -o \$f \$f.c -ldl; done" >&2
  exit 2; }
adb push "$PROBE" /data/local/tmp/eglprobe >/dev/null 2>&1 || {
  echo "!! push failed" >&2; exit 2; }
adb shell chmod 755 /data/local/tmp/eglprobe
NOW="$(adb shell /data/local/tmp/eglprobe 2>&1)"

# Sanity floor: a probe that enumerated nothing must not read as a clean pass.
n=$(printf '%s\n' "$NOW" | grep -cE "^ +[0-9]")
[ "$n" -ge 10 ] || { echo "!! probe returned $n configs — refusing a verdict"; exit 2; }

# 🔴 COMPARE CAPABILITY TOTALS, NOT ROWS. Until 2026-09-01 this diffed the table
# row by row against the baseline and failed on any difference. That is the wrong
# test the moment the driver generation changes: r54p1 advertises 65 configs where
# stock r32p1 advertises 25, and the IDs renumber, so a correct driver reported
# FAIL with 40 lines of noise. Worse, it is not the test the 2026-08-27 defect
# would have failed on its own terms -- what actually broke was the NUMBER of
# configs carrying a capability:
#
#     stock r32p1        25 configs   21 EGL_WINDOW_BIT    6 EGL_RECORDABLE_ANDROID
#     r38p1, shipped     ??            6                   0     <- the defect
#     r54p1, 01/09       65           61                  47
#
# Every camera and video GL pipeline died because eglChooseConfig returned zero
# matches for RECORDABLE. So the rule is a FLOOR, not equality: a driver may
# offer more than stock, never fewer.
tmp=$(mktemp); printf '%s\n' "$NOW" > "$tmp"
cnt() { # cnt <file> <window|recordable|total>
  case "$2" in
    total)      grep -cE "^ +[0-9]" "$1" ;;
    window)     grep -E "^ +[0-9]" "$1" | awk '{v=strtonum($10); if (and(v,0x4)) c++} END{print c+0}' ;;
    recordable) grep -E "^ +[0-9]" "$1" | awk '{if ($14==1) c++} END{print c+0}' ;;
  esac; }
rc=0
for k in total window recordable; do
  b=$(cnt "$BASE" $k); a=$(cnt "$tmp" $k)
  if [ "$a" -ge "$b" ]; then printf "  ✅ %-24s %s (baseline %s)\n" "$k" "$a" "$b"
  else printf "  ❌ %-24s %s -- BELOW the baseline %s\n" "$k" "$a" "$b"; rc=1; fi
done
# Informational only: the row-level diff still says WHAT moved, which is useful
# when a change is unexpected. It no longer decides the verdict.
if [ -n "${EGL_SHOW_DIFF:-}" ]; then
  echo; echo "  row diff vs baseline (informational; id surface_type native_visual recordable):"
  key() { grep -E "^ +[0-9]" "$1" | awk '{print $2, $10, $13, $14}'; }
  diff <(key "$BASE") <(key "$tmp") | sed 's/^/    /'
fi
rm -f "$tmp"
[ "$rc" -eq 0 ] && echo "PASS: $n configs; no capability total is below the stock baseline"
[ "$rc" -eq 0 ] || echo "FAIL: a capability total regressed against stock -- this is the 2026-08-27 shape"
exit $rc
