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

adb push "$DIR/eglprobe" /data/local/tmp/eglprobe >/dev/null 2>&1 || {
  echo "!! push failed (build it: see egl-config-check.README)" >&2; exit 2; }
adb shell chmod 755 /data/local/tmp/eglprobe
NOW="$(adb shell /data/local/tmp/eglprobe 2>&1)"

# Sanity floor: a probe that enumerated nothing must not read as a clean pass.
n=$(printf '%s\n' "$NOW" | grep -cE "^ +[0-9]")
[ "$n" -ge 10 ] || { echo "!! probe returned $n configs — refusing a verdict"; exit 2; }

# Compare the three columns that carry capability, not the whole line.
key() { grep -E "^ +[0-9]" "$1" | awk '{print $2, $10, $13, $14}'; }
d=$(diff <(key "$BASE") <(printf '%s\n' "$NOW" > /tmp/.eglnow.$$; key /tmp/.eglnow.$$); rm -f /tmp/.eglnow.$$)
if [ -n "$d" ]; then
  echo "FAIL: EGL config table differs from baseline (id surface_type native_visual recordable)"
  echo "$d"
  exit 1
fi
echo "PASS: $n configs, capability columns match baseline"
