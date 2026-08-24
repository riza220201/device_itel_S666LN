#!/bin/bash
# spl-check.sh — assert the security patch level the build will ship.
#
# WHY THIS EXISTS
#   On 2026-08-24 build 73 was measured shipping ro.build.version.security_patch
#   = 2024-09-05, seventeen months behind. It was a REGRESSION: the "Tier B"
#   merges that had taken the SPL to 2026-02-01 (verified on hardware
#   2026-07-27) lived as LOCAL commits in repos this project does not own
#   (crdroidandroid/*), and died with the build VM on 2026-08-17. The local
#   re-sync silently restored crDroid's frozen forks.
#
#   Builds 68-73 all shipped the stale SPL and every other gate stayed green,
#   because no gate asserted this. That is the whole reason for this file:
#   a 17-month security regression must not be invisible to a green build.
#
# CONVENTIONS (same as tools/v31-delta-check.py)
#   Every path is a REQUIRED argument. Nothing defaults. A gate that defaults a
#   path is how FINAL12 blobs reached every published revision of this tree.
#   exit 0 = clean · 1 = findings · 2 = inputs do not describe a build tree.
#
# USAGE
#   tools/spl-check.sh <android-tree-root> <expected-spl> [--recovery <tree>] [build.prop ...]
#   tools/spl-check.sh /mnt/external_nvme/crdroid 2026-02-01
#   tools/spl-check.sh ~/crdroid 2026-02-01 out/target/product/S666LN/system/build.prop

set -u

TREE="${1:-}"
EXPECT="${2:-}"
shift 2 2>/dev/null || true
RECOVERY_TREE=""
if [ "${1:-}" = "--recovery" ]; then RECOVERY_TREE="${2:-}"; shift 2 2>/dev/null || true; fi

fail()  { echo "  ✗ $*"; FINDINGS=$((FINDINGS+1)); }
pass()  { echo "  ✓ $*"; }
FINDINGS=0

# ---- input sanity floor -----------------------------------------------------
# A gate's characteristic way of passing vacuously is an empty input making
# every check trivially true. Refuse a verdict unless the inputs are real.
if [ -z "$TREE" ] || [ -z "$EXPECT" ]; then
  echo "usage: $0 <android-tree-root> <expected-spl YYYY-MM-DD> [build.prop ...]" >&2
  exit 2
fi
case "$EXPECT" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "FATAL: expected-spl must be YYYY-MM-DD, got '$EXPECT'" >&2; exit 2;;
esac
VD="$TREE/build/make/core/version_defaults.mk"
if [ ! -f "$VD" ]; then
  echo "FATAL: not an Android tree — $VD does not exist" >&2
  exit 2
fi

echo "SPL gate — expecting $EXPECT"
echo "tree: $TREE"
echo

# ---- CHECK 1: what the build system will stamp ------------------------------
GOT=$(sed -n 's/^[[:space:]]*PLATFORM_SECURITY_PATCH[[:space:]]*:=[[:space:]]*\([0-9-]*\).*/\1/p' "$VD" | head -1)
if [ -z "$GOT" ]; then
  fail "CHECK 1  could not read PLATFORM_SECURITY_PATCH from $VD"
elif [ "$GOT" != "$EXPECT" ]; then
  fail "CHECK 1  build/make declares $GOT, expected $EXPECT"
  echo "           -> the lineage-20.0 merge into build/make is missing."
  echo "              A plain \`repo sync\` discards it: the merge is a LOCAL"
  echo "              commit in crdroidandroid/android_build, which we do not own."
else
  pass "CHECK 1  build/make declares $GOT"
fi

# ---- CHECK 2: the merges the SPL string is supposed to REPRESENT -------------
# Bumping the string alone would be dishonest: it claims 17 months of patches
# the build does not contain. So assert the code is there, not just the number.
check_symbol() {  # <file> <needle> <label>
  local f="$TREE/$1" needle="$2" label="$3"
  if [ ! -f "$f" ]; then fail "CHECK 2  missing file for '$label': $1"; return; fi
  if grep -q -- "$needle" "$f"; then pass "CHECK 2  $label"
  else fail "CHECK 2  $label — ABSENT, so the SPL string would be a claim without the patch"; fi
}
check_symbol "frameworks/base/mms/java/com/android/internal/telephony/IMms.aidl" \
             "in int callingUser" "IMms carries callingUser (lineage MMS hardening)"
check_symbol "frameworks/base/telephony/common/com/android/internal/telephony/TelephonyPermissions.java" \
             "boolean isShell(int" "TelephonyPermissions.isShell(int) present"
check_symbol "system/core/fs_mgr/libdm/dm.cpp" \
             "edact" "libdm redacts dm-crypt keys (ASB 13.0.0_r26)"

# ---- CHECK 3: the backward pins must be gone --------------------------------
# packages/services/{Mms,Telephony} were pinned to OLD revisions to match
# crDroid's frozen frameworks/base, each giving up a security feature. With the
# merge in place they must be unpinned, or the build silently loses them again.
MAN="$TREE/.repo/local_manifests/S666LN.xml"
if [ -f "$MAN" ]; then
  if grep -q '4c511b7d21424a8c23a3db9a08ccee07d88dd153\|f1e9284296c768b6a537d8c07a186c044ee7a678' "$MAN"; then
    fail "CHECK 3  local manifest still pins packages/services/{Mms,Telephony} backwards"
  else
    pass "CHECK 3  Mms/Telephony not pinned backwards"
  fi
else
  echo "  – CHECK 3  skipped, no local manifest at $MAN"
fi

# ---- CHECK 4: any built artifact must agree ---------------------------------
for prop in "$@"; do
  p="$prop"; [ -f "$p" ] || p="$TREE/$prop"
  if [ ! -f "$p" ]; then fail "CHECK 4  build.prop not found: $prop"; continue; fi
  PGOT=$(sed -n 's/^ro\.build\.version\.security_patch=//p' "$p" | head -1)
  if [ "$PGOT" != "$EXPECT" ]; then
    fail "CHECK 4  $(basename "$(dirname "$p")")/build.prop says '$PGOT', expected $EXPECT"
  else
    pass "CHECK 4  built artifact stamps $PGOT"
  fi
done

# ---- CHECK 5: the RECOVERY must agree, and nothing else checks this ----------
# 🔴 THIS IS THE CHECK WHOSE ABSENCE COST A SESSION. Tier B moved the ROM's SPL
# 17 months; recovery_itel_S666LN/BoardConfig.mk still declared the old value;
# KeyMint then refused the metadata key in recovery and PBRP could not open
# /data at all. The rule was written in capitals in that BoardConfig
# ("THESE THREE MUST MATCH THE ROM EXACTLY... If the ROM's security patch level
# ever changes, change it here too") and was still broken, because a rule in a
# comment in another repo enforces nothing.
#
# A recovery BEHIND the ROM can never open the key: Android's vold upgrades a
# key blob forward (system/vold/KeyStorage.cpp CommitUpgradedKey), and there is
# no downgrade path.
if [ -n "$RECOVERY_TREE" ]; then
  RBC="$RECOVERY_TREE/BoardConfig.mk"
  if [ ! -f "$RBC" ]; then
    fail "CHECK 5  --recovery given but $RBC does not exist"
  else
    RSPL=$(sed -n 's/^[[:space:]]*PLATFORM_SECURITY_PATCH[[:space:]]*:=[[:space:]]*\([0-9-]*\).*/\1/p' "$RBC" | head -1)
    if [ "$RSPL" != "$EXPECT" ]; then
      fail "CHECK 5  recovery declares $RSPL, ROM is $EXPECT — PBRP will not decrypt /data"
    else
      pass "CHECK 5  recovery fallback SPL matches the ROM ($RSPL)"
    fi
    # the dynamic sync makes the hardcoded value a FALLBACK rather than the
    # only answer; assert it is actually wired, or a mismatch becomes fatal again
    SYNC="$RECOVERY_TREE/recovery/root/system/bin/sync-rom-spl.sh"
    RRC="$RECOVERY_TREE/recovery/root/init.recovery.mt6789.rc"
    if [ -x "$SYNC" ] && grep -q 'sync-rom-spl.sh' "$RRC" 2>/dev/null; then
      # and it must run BEFORE keymint, or it sets the props too late to matter
      if [ "$(grep -n 'sync-rom-spl.sh' "$RRC" | cut -d: -f1 | head -1)" \
           -lt "$(grep -n 'start vendor.keymint-trustonic' "$RRC" | cut -d: -f1 | head -1)" ]; then
        pass "CHECK 5  dynamic SPL sync present and ordered before keymint"
      else
        fail "CHECK 5  sync-rom-spl.sh runs AFTER keymint starts — too late to matter"
      fi
    else
      fail "CHECK 5  dynamic SPL sync missing; recovery is pinned to the hardcoded value"
    fi
  fi
else
  # A silent skip is how this whole class hides. Say it loudly.
  echo "  ⚠ CHECK 5  SKIPPED — no --recovery <tree> given, so the cross-repo"
  echo "             invariant (recovery SPL == ROM SPL) was NOT checked."
fi

echo
if [ "$FINDINGS" -eq 0 ]; then echo "PASSED"; exit 0; fi
echo "FAILED — $FINDINGS finding(s)"; exit 1
