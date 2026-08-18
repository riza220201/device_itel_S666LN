#!/bin/bash
#
# regen-vendor.sh <stock-vendor-dump>
#
# Regenerate vendor/itel/S666LN from the stock rev 28 dump, and put the Mali
# r38p1 driver back afterwards.
#
# WHY THIS EXISTS
# ---------------
# `extract-files.sh` defaults CLEAN_VENDOR=true: it WIPES the vendor directory
# and re-extracts everything from stock, which silently takes the GPU driver back
# to itel's r32p1 (Vulkan 1.1) over the r38p1 (Vulkan 1.3) the vendor repo
# carries. extract-files.sh detects that and PRINTS the restore command rather
# than doing it -- deliberately, so the regression shows up as two modified files
# in `git status` instead of as a silent loss discovered later by a user whose
# Winlator got slower. That comment is right, and it leaves a human step.
#
# On the VM that step belonged to `~/rebuild28.sh`. The GCP subscription ended,
# rebuild28.sh lived in `~` on that box, and it is gone. Every file that died
# lived in a home directory; every file that survived lived in a repo. So this
# one lives in the repo, and it does the step AND CHECKS IT, which is the part a
# human doing it from memory is worst at.
#
# 🔴 It is also the reason a build is possible at all right now. Measured
# 2026-08-18: the published vendor_itel_S666LN (390875d) carries ZERO `-stock`
# blobs, so `m nothing` fails with ten "module source path does not exist"
# errors -- the codec2 -stock set, wifi@1.0-service-stock, libbt-vendor.so,
# nfc_nci_nxp.so, libdtsaudio.so. Those files are produced by extract-files.sh's
# `src:dst` renames and blob_fixup at EXTRACTION time; on the VM they existed
# only in that machine's working tree and were never pushed. So the published
# vendor tree cannot build the published device tree, which is BLUEPRINT §1's own
# defect inside our own repos.
#
# ⚠ Do NOT "fix" that by hand-copying the ten missing files out of the stock
# dump. Seven are `-stock` renames that ALSO need blob_fixup's 58 patchelf edits
# (SONAME + DT_NEEDED repointing across the codec2 set and its MTK consumers).
# An A12 consumer against an unpatched A12 provider is exactly the
# `_C2FenceFactory::CreateNativeHandle` failure build 65 already paid for.
#
# USAGE
#     device/itel/S666LN/tools/regen-vendor.sh .build/work/vendor
#
# then, once it passes:
#     git -C vendor/itel/S666LN add -A && git -C vendor/itel/S666LN commit
#     git -C vendor/itel/S666LN push
#
set -euo pipefail

MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${MY_DIR}/.." && pwd)"
ANDROID_ROOT="$(cd "${DEVICE_DIR}/../../.." && pwd)"
VENDOR_DIR="${ANDROID_ROOT}/vendor/itel/S666LN"

# The r38p1 driver, pinned by content. Both ABIs, because gpu-driver-r38p1.sh's
# one recorded weakness was checking the 32-bit blob by SIZE only -- and size is
# not monotonic in DDK revision (r14p0 is 43.99 MB, r32p1 is 38.60 MB), which the
# 2026-08-12 sweep proved by finding two "unsampled gap" candidates that were
# both OLDER than what we ship. Sizes are kept as a second signal, not the test.
MALI64_REL="proprietary/vendor/lib64/egl/mt6789/libGLES_mali.so"
MALI32_REL="proprietary/vendor/lib/egl/mt6789/libGLES_mali.so"
MALI64_SHA="a457731ea0312e989be984b13b1f03d3b235771eee530cc8aa95c9f4808493c4"
MALI32_SHA="e9b631d00883eb4a43f5c46b480b84ec547f14b55526dacd6bc55a464b5b2207"
MALI64_SIZE=42401544
MALI32_SIZE=29117468
MALI_REV="r38p1"

die() { echo "!! $*" >&2; exit 1; }

# --verify-only checks the committed driver without extracting anything. It is
# how the Mali check below gets a positive control: a gate that has never been
# shown to fail is indistinguishable from one that passes, and this project has
# now shipped three such gates (KMI hooked to a target bacon never traverses, the
# vendor-deps gate passing vacuously at 190 resolvable libraries, and this
# script's own predecessor -- a restore step that existed only in a comment).
VERIFY_ONLY=0
if [ "${1:-}" = "--verify-only" ]; then VERIFY_ONLY=1; shift; fi

SRC="${1:-}"
if [ "${VERIFY_ONLY}" = "1" ]; then SRC="${SRC:-skip}"; fi
[ -n "${SRC}" ] || die "usage: regen-vendor.sh [--verify-only] <stock-vendor-dump>
   The path is REQUIRED and has no default. gen_proprietary_files.py once
   defaulted to a path and generated the whole blob list from a crDroid build
   output for every published revision of this tree (notes/AUDIT-2026-08-10.md)."
if [ "${VERIFY_ONLY}" = "0" ]; then
[ -d "${SRC}" ] || die "not a directory: ${SRC}"
SRC="$(cd "${SRC}" && pwd)"

# ── Provenance. The only legitimate source is the rev 28 extraction. ───────────
case "${SRC}" in
    *shipped*) die "refusing a path containing 'shipped': ${SRC}
   That is a ROM build's own vendor partition, not stock. Reading it is the
   defect notes/AUDIT-2026-08-10.md §A exists to describe." ;;
esac
# 🪤 extract-utils PREPENDS the path from proprietary-files.txt, and those paths
# begin `vendor/`. So the argument must be the directory CONTAINING vendor/, not
# the vendor partition itself. Both spellings are accepted here and normalised,
# because RESUME §3 names the source as ".build/work/vendor" -- which is the right
# DUMP and the wrong ROOT, and the two are easy to conflate.
#
# 🔴 The first version of this check tested `${SRC}/build.prop`, which is the
# vendor partition's OWN build.prop. Passed `.build/work/vendor` it therefore
# reported "source verified: sdk 31" and handed a root to extract-files.sh under
# which not one blob resolved: the vendor tree was wiped and all 2,331 files
# reported "file not found in source". A validation that encodes the same wrong
# assumption as the code it guards will pass for the wrong reason. (Recovered
# with `git checkout -- .` because the vendor tree is a repo; that is the only
# reason it cost nothing.)
if [ -f "${SRC}/vendor/build.prop" ]; then
    ROOT="${SRC}"
elif [ -f "${SRC}/build.prop" ] && [ "$(basename "${SRC}")" = "vendor" ]; then
    ROOT="$(dirname "${SRC}")"
    echo "== note: given the vendor partition; using its parent as the extract root"
else
    die "cannot find vendor/build.prop under ${SRC}.
   Pass the directory CONTAINING vendor/ (e.g. .build/work), or the vendor
   partition itself (.build/work/vendor) -- extract-utils prepends 'vendor/' to
   every path in proprietary-files.txt."
fi
SDK="$(grep -m1 '^ro.vendor.build.version.sdk=' "${ROOT}/vendor/build.prop" | cut -d= -f2 || true)"
INC="$(grep -m1 '^ro.vendor.build.version.incremental=' "${ROOT}/vendor/build.prop" | cut -d= -f2 || true)"
[ "${SDK}" = "31" ] || die "vendor sdk is '${SDK}', expected 31.
   itel's stock vendor is Android 12 (notes/AUDIT-2026-08-10.md §B1). A dump
   that is not sdk 31 is not the revision this tree's identity is pinned to."
# Prove the root actually resolves a blob, rather than merely looking plausible.
probe="$(grep -m1 -E '^-?vendor/lib64/[^:]+\.so$' "${DEVICE_DIR}/proprietary-files.txt" | sed 's/^-//')"
[ -f "${ROOT}/${probe}" ] || die "the extract root does not resolve blobs: ${ROOT}
   probed: ${probe}
   Nothing would be found and the vendor tree would be wiped for nothing."
echo "== source verified: sdk ${SDK}, incremental ${INC}"
echo "   root  ${ROOT}"
echo "   probe ${probe}  OK"
SRC="${ROOT}"
fi

[ -d "${VENDOR_DIR}/.git" ] || die "not a git checkout: ${VENDOR_DIR}
   The Mali restore below reads the committed copy, so this cannot run against
   an unversioned vendor directory."

# ── 1. extract. This wipes the vendor dir and calls setup-makefiles.sh itself. ─
if [ "${VERIFY_ONLY}" = "0" ]; then
    echo "== extract-files.sh (CLEAN_VENDOR=true -- this WIPES ${VENDOR_DIR})"
    XLOG="$(mktemp)"
    ( cd "${DEVICE_DIR}" && ./extract-files.sh "${SRC}" ) 2>&1 | tee "${XLOG}"

    # 🔴 extract-utils prints "file not found in source" and CARRIES ON, exit 0.
    # A half-populated vendor partition is a valid build that fails at runtime,
    # which is this project's most expensive shape of defect, so the miss count
    # is a hard failure here rather than a line in a log nobody re-reads.
    missing="$(grep -c 'file not found in source' "${XLOG}" || true)"
    if [ "${missing}" -ne 0 ]; then
        echo
        grep 'file not found in source' "${XLOG}" | head -5
        rm -f "${XLOG}"
        die "${missing} of the blobs were NOT FOUND in ${SRC}.

   The vendor directory has been wiped and is now incomplete. Recover with:
       git -C ${VENDOR_DIR} checkout -- . && git -C ${VENDOR_DIR} clean -fd

   If the count is ALL of them, the extract root is wrong (see the note above
   the source check). If it is a handful, proprietary-files.txt has drifted from
   the dump and each one is a decision, not a regression to paper over."
    fi
    rm -f "${XLOG}"

    # ── 2. restore the GPU driver from git ────────────────────────────────────
    echo "== restoring Mali ${MALI_REV} from git"
    git -C "${VENDOR_DIR}" checkout -- "${MALI64_REL}" "${MALI32_REL}"
else
    echo "== --verify-only: checking the driver in place, extracting nothing"
fi

# ── 3. VERIFY it. A restore that silently did nothing is the whole failure mode
#       this script exists to prevent: the build stays valid, nothing errors, and
#       Vulkan drops 1.3 -> 1.1 with no signal until a user notices. ───────────
fail=0
for pair in "${MALI64_REL}:${MALI64_SHA}:${MALI64_SIZE}" "${MALI32_REL}:${MALI32_SHA}:${MALI32_SIZE}"; do
    rel="${pair%%:*}"; rest="${pair#*:}"; want_sha="${rest%%:*}"; want_size="${rest#*:}"
    f="${VENDOR_DIR}/${rel}"
    [ -f "${f}" ] || { echo "!! MISSING after restore: ${rel}"; fail=1; continue; }
    got_sha="$(sha256sum "${f}" | cut -d' ' -f1)"
    got_size="$(stat -c%s "${f}")"
    got_rev="$(strings "${f}" | grep -oE 'r[0-9]+p[0-9]+-[0-9a-z]+' | head -1 || true)"
    if [ "${got_sha}" != "${want_sha}" ]; then
        echo "!! ${rel}"
        echo "     sha256 ${got_sha}"
        echo "     wanted ${want_sha}"
        echo "     size ${got_size} (wanted ${want_size}), revision '${got_rev}'"
        fail=1
    else
        echo "   ok  ${rel}  ${got_rev}  ${got_size} B"
    fi
done
if [ "${fail}" -ne 0 ]; then
    die "MALI RESTORE FAILED.

   The vendor tree now ships itel's stock r32p1 and Vulkan will report 1.1
   instead of 1.3, on a build that is otherwise perfectly valid and passes every
   other gate. Do NOT continue to a build.

   If the committed driver was deliberately changed, update MALI64_SHA/MALI32_SHA
   in this script IN THE SAME COMMIT, so the pin and the blob never disagree."
fi

if [ "${VERIFY_ONLY}" = "1" ]; then
    echo "== Mali OK (verify-only; nothing was extracted)"
    exit 0
fi

# ── 4. provenance: every blob must exist in stock ─────────────────────────────
# The path is passed explicitly. provenance-check.sh defaults to a location
# relative to the device tree, which resolves inside the ROM tree -- where
# .build/ does not exist, because the dump lives in the workspace repo. Letting
# it default here would abort the last gate on a path question.
echo "== provenance-check.sh"
"${MY_DIR}/provenance-check.sh" "${SRC}/vendor"

cat <<'NEXT'

== vendor tree regenerated.

   Next:
     1. m nothing                       # module-name / install-path collisions
     2. tools/v31-delta-check.py <built vendor> <v31 libs> <v33 libs>
        -- run it against the BUILT image, not this directory. Build 67 passed
           vendor-deps AND KMI and still hung at the boot logo.
     3. commit AND PUSH vendor/itel/S666LN. It has been stale since ~build 51,
        which is why the published tree could not be built by anyone.

   And on first boot after any driver change, wipe the shader caches -- a cache
   written by r32p1 and replayed under r38p1 is the RenderThread crash signature
   chased in session 1:
     rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache
NEXT
