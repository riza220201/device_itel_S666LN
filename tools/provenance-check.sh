#!/bin/bash
# provenance-check.sh [stock-vendor-dump]
#
# Asserts that every path in proprietary-files.txt exists in the STOCK rev 28
# vendor partition. Run it before any commit that touches the blob list, and
# before publishing the vendor tree.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-10 an audit found 44 entries in proprietary-files.txt that are not
# in itel's firmware at all. They came from `.build/work/shipped/v` -- the
# crDroid FINAL12 build's vendor partition, which was produced by the device
# tree this project exists to stop depending on. gen_proprietary_files.py had
# that path as its DEFAULT argument while its docstring said "from the stock
# vendor dump", so the wrong dump was read for every revision from the initial
# commit onward, and the binaries reached the published vendor_itel_S666LN.
#
# It was not only a provenance problem. Because FINAL12 replaced stock's AIDL
# power provider (vendor.mediatek.hardware.mtkpower@1.0-service) with its own
# libperfmgr build, the stock one was never extracted -- while the VINTF
# manifest still declared android.hardware.power. PowerManagerService.nativeInit()
# then blocked forever on a HAL that was promised and absent, Watchdog killed
# system_server at ~73 s, and the device boot-looped with no tombstone.
#
# The lesson worth keeping: `.build/work/vendor` and `.build/work/shipped/v`
# look identical -- both are ~2,500 vendor ELFs, both answer every question you
# ask them. Only the path tells them apart, and a default argument decided it.
#
# WHY IT IS NOT PART OF tools/vendor-deps-check.sh
# ------------------------------------------------
# That gate runs during the build, on the build VM, which does not have the
# 1.1 GB stock extraction. This check needs the stock dump, so it belongs on the
# workstation. Do not "fix" that by making the build gate skip when the dump is
# absent: a check that silently skips is the failure mode this project has been
# bitten by three times (see notes/JOURNAL.md on the KMI gate).
set -euo pipefail

# Default assumes the workspace layout (device_itel_S666LN/ beside .build/).
# In a ROM tree the dump will not be here, so pass the path explicitly.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STOCK="${1:-$HERE/../.build/work/vendor}"
LIST="$HERE/proprietary-files.txt"

[ -f "$LIST" ]  || { echo "no proprietary-files.txt at $LIST" >&2; exit 2; }
[ -d "$STOCK" ] || { echo "stock dump not found: $STOCK" >&2
                     echo "extract rev 28's super.img first, or pass the path" >&2; exit 2; }

case "$(readlink -f "$STOCK")" in
  *shipped*) echo "REFUSING: '$STOCK' looks like a shipped ROM dump, not stock." >&2
             echo "That is exactly the mistake this script exists to catch." >&2; exit 2;;
esac

# Sanity-count first: an empty list would make every check pass. This project
# has been caught by that shape of false pass before.
total=$(grep -cvE '^\s*(#|$)' "$LIST")
[ "$total" -gt 1000 ] || { echo "only $total entries parsed from $LIST -- refusing to" >&2
                           echo "call that a pass. Check the parser, not the tree." >&2; exit 2; }

missing=0
while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    spec="${line#-}"; spec="${spec%%;*}"; spec="${spec%%:*}"
    case "$spec" in vendor/*) ;; *) continue;; esac
    if [ ! -e "$STOCK/${spec#vendor/}" ]; then
        [ "$missing" -eq 0 ] && echo "NOT PRESENT IN STOCK REV 28:"
        echo "    $spec"
        missing=$((missing + 1))
    fi
done < "$LIST"

# Blobs committed INTO the device tree, which the loop above cannot see because
# they are not in proprietary-files.txt. prebuilts/codec2-stock/ holds stock's
# A12 codec2 set: those libraries collide with AOSP soong module names, so they
# ship as hand-written blueprints with a unique `name` and a `stem`, which is a
# path around the blob list -- and therefore a path around this gate. Byte
# equality is the check, not mere existence: these are committed copies, so a
# stale or edited one would otherwise never be noticed.
prebuilt_bad=0 prebuilt_n=0
PREBUILT_DIR="$HERE/prebuilts/codec2-stock/lib64"
if [ -d "$PREBUILT_DIR" ]; then
    for f in "$PREBUILT_DIR"/*.so; do
        [ -e "$f" ] || continue
        prebuilt_n=$((prebuilt_n + 1))
        if ! cmp -s "$f" "$STOCK/lib64/$(basename "$f")"; then
            [ "$prebuilt_bad" -eq 0 ] && echo "COMMITTED PREBUILT DIFFERS FROM STOCK REV 28:"
            echo "    prebuilts/codec2-stock/lib64/$(basename "$f")"
            prebuilt_bad=$((prebuilt_bad + 1))
        fi
    done
    # An empty directory would pass every check above. Say so instead.
    [ "$prebuilt_n" -gt 0 ] || { echo "$PREBUILT_DIR exists but holds no .so" >&2; exit 2; }
fi

echo
echo "entries checked : $total"
echo "committed blobs : $prebuilt_n  (prebuilts/codec2-stock)"
echo "stock dump      : $STOCK"
if [ "$missing" -ne 0 ]; then
    echo "NOT IN STOCK    : $missing"
    echo
    echo "Every one of these is either (a) content from another tree that must not"
    echo "ship, or (b) a HAL this tree builds from source, which belongs in"
    echo "PRODUCT_PACKAGES and not in the blob list. There is no third case."
    exit 1
fi
echo "NOT IN STOCK    : 0"
if [ "$prebuilt_bad" -ne 0 ]; then
    echo "PREBUILTS BAD   : $prebuilt_bad"
    echo
    echo "A committed prebuilt is not byte-identical to the stock dump. Either it"
    echo "was edited in place, or it came from somewhere other than rev 28. Both"
    echo "are the failure this gate exists for -- re-copy it from \$STOCK."
    exit 1
fi
echo "PREBUILTS BAD   : 0"
echo "PASS - every blob is traceable to itel rev 28."
