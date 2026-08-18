#!/usr/bin/env python3
"""v31 delta gate — find every vendor file that a v31 VNDK namespace would break.

    v31-delta-check.py <built-vendor-dir> <v31-lib-dir> <v33-lib-dir>

All three paths are REQUIRED and none has a default. That is deliberate:
`gen_proprietary_files.py` once defaulted to a path and silently generated the
whole blob list from the wrong dump for every published revision of this tree
(notes/AUDIT-2026-08-10.md §A). A gate that can be pointed at the wrong artifact
by omission is worse than no gate, because it answers confidently either way.

WHY THIS EXISTS
    Moving the vendor VNDK namespace to v31 is what makes the camera work
    (proven on hardware 2026-08-13: incStrongRequireStrong aborts 4+/open -> 0,
    CameraState OPEN). It also silently breaks every vendor binary that was
    built against VNDK 33, because our v31 set exports 29,795 symbols where the
    v33 apex exports 37,131.

    Build 67 shipped anyway and hung at the boot logo:

        vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so
            UND android::base::Tokenize        <- v33-only

    IBootControl never registered, init's control-message queue saturated, and
    the device sat on the logo with the kernel healthy throughout. The predecessor
    of this script had already named that exact file a day earlier; it was not run
    against the build.

    So: run this against the BUILT image, every build, until it reports 0.

WHAT IT CHECKS

  Check A — v33-only symbol references.
    Symbols the v33 set exports and the v31 set does not, then every vendor ELF
    holding an undefined reference to one. A hit is only a real risk if nothing
    in /vendor supplies the symbol itself, because the vendor namespace searches
    /vendor before the VNDK. Without that filter MediaTek's own libcurl-md and
    libssl-md report as broken (they want CRYPTO_free/CRYPTO_malloc and the
    vendor partition carries them) -- 4 false positives out of 14 raw hits.

  Check B — libraries that exist ONLY in the v33 set.
    This is the one the earlier tool did not have, and it is the one that turns
    a fixable list into a project. Our v31 set is 134 libraries; the v33 apex has
    162. The 28 extra are A13-era with no v31 counterpart:

        android.hardware.wifi.supplicant-V1-ndk.so   v33 only
        wpa_supplicant  DT_NEEDED ->  that library

    wpa_supplicant would take v31 libutils/libbinder from /vendor and that AIDL
    library from the v33 apex, which drags v33's core in behind it. That is the
    two-libutils condition relocated into Wi-Fi, and no library swap fixes it --
    there is nothing to swap to. Check A cannot see it: the symbols resolve.

  Both checks resolve PER ABI. A 64-bit process cannot load a 32-bit library,
  and a gate that merges lib/ and lib64/ by basename reports "every DT_NEEDED
  resolves" while the 64-bit codec2 HAL dies in the linker every boot -- which
  is exactly what happened to tools/vendor-deps-check.sh before it was split.

EXIT
    0   nothing at risk
    1   findings (the file list is the work)
    2   the inputs do not describe a believable device -- see the sanity floor.
        A gate that has never been shown to fail is indistinguishable from one
        that passes, and this one has a specific way of passing vacuously: point
        it at an empty or wrong directory and every set is empty, so the delta is
        empty and nothing is ever flagged.
"""
import os
import re
import struct
import sys

# A v31 set materially smaller than this is not the VNDK snapshot. Stock's own
# com.android.vndk.v31.apex and AOSP's prebuilts/vndk/v31 both carry 134 per ABI
# (133 top-level .so + hw/android.hidl.memory@1.0-impl.so, which is silently
# omitted if you stage only the top level).
MIN_VNDK_LIBS = 100
MIN_VENDOR_ELFS = 500

# A real v31 -> v33 delta measures ~8,500 symbols per ABI (8,492 lib64, against
# stock's own com.android.vndk.v33 apex). If it comes out near zero the two
# directories are the same snapshot, or the "v33" argument is another copy of
# v31 -- in which case every delta is empty and the gate passes having tested
# nothing.
#
# 🔑 This floor exists because the gate's OWN first negative control was a
# vacuous pass: it ran with v33 = a copy of v31, found 0 v33-only symbols, and
# reported PASSED. That looked like a clean control and proved nothing. The
# real control is stock's vendor partition against stock's real v33 apex --
# 8,492 v33-only symbols and still zero findings, because stock pins
# ro.vndk.version=31 and ships exactly that vendor. A control needs a control.
MIN_V33_ONLY_SYMBOLS = 1000


class Elf:
    """Just enough ELF to read symbols and DT_NEEDED, for both classes.

    pyelftools is deliberately not used -- kmi-check.py dropped it so the gates
    run inside a build with no host dependencies, and this keeps that property.
    """

    def __init__(self, path):
        self.path = path
        self.ok = False
        with open(path, "rb") as f:
            d = f.read()
        self.d = d
        if len(d) < 64 or d[:4] != b"\x7fELF":
            return
        self.cls = d[4]                      # 1 = ELF32, 2 = ELF64
        if self.cls not in (1, 2) or d[5] != 1:   # little-endian only
            return
        self.bits = 64 if self.cls == 2 else 32
        if self.cls == 2:
            self.shoff, = struct.unpack_from("<Q", d, 0x28)
            self.shent, self.shnum, self.shstrndx = struct.unpack_from("<HHH", d, 0x3A)
        else:
            self.shoff, = struct.unpack_from("<I", d, 0x20)
            self.shent, self.shnum, self.shstrndx = struct.unpack_from("<HHH", d, 0x2E)
        if not self.shoff or not self.shnum:
            return
        self.ok = True

    def _shdr(self, i):
        o = self.shoff + i * self.shent
        d = self.d
        if self.cls == 2:
            name, typ = struct.unpack_from("<II", d, o)
            off, size = struct.unpack_from("<QQ", d, o + 0x18)
            link, = struct.unpack_from("<I", d, o + 0x28)
            entsize, = struct.unpack_from("<Q", d, o + 0x38)
        else:
            name, typ = struct.unpack_from("<II", d, o)
            off, size = struct.unpack_from("<II", d, o + 0x10)
            link, = struct.unpack_from("<I", d, o + 0x18)
            entsize, = struct.unpack_from("<I", d, o + 0x24)
        return name, typ, off, size, link, entsize

    @staticmethod
    def _cstr(d, base, off):
        end = d.index(b"\x00", base + off)
        return d[base + off:end].decode("latin1")

    def _sections(self):
        out = []
        for i in range(self.shnum):
            try:
                out.append(self._shdr(i))
            except (struct.error, IndexError):
                return out
        return out

    def symbols(self):
        """(defined, undefined) sets of global/weak symbol names."""
        defined, undef = set(), set()
        if not self.ok:
            return defined, undef
        secs = self._sections()
        for _n, typ, off, size, link, entsize in secs:
            if typ != 11:                    # SHT_DYNSYM
                continue
            if link >= len(secs):
                continue
            strbase = secs[link][2]
            step = entsize or (24 if self.cls == 2 else 16)
            d = self.d
            for p in range(off, off + size - step + 1, step):
                try:
                    if self.cls == 2:
                        st_name, st_info, _o, st_shndx = struct.unpack_from("<IBBH", d, p)
                    else:
                        st_name, = struct.unpack_from("<I", d, p)
                        st_info, _o, st_shndx = struct.unpack_from("<BBH", d, p + 12)
                    if not st_name:
                        continue
                    if (st_info >> 4) not in (1, 2):      # GLOBAL, WEAK
                        continue
                    nm = self._cstr(d, strbase, st_name)
                except (struct.error, ValueError, IndexError):
                    continue
                (undef if st_shndx == 0 else defined).add(nm)
        return defined, undef

    def needed(self):
        """(soname, [DT_NEEDED...])"""
        soname, deps = None, []
        if not self.ok:
            return soname, deps
        secs = self._sections()
        for _n, typ, off, size, link, _e in secs:
            if typ != 6:                     # SHT_DYNAMIC
                continue
            if link >= len(secs):
                continue
            strbase = secs[link][2]
            step = 16 if self.cls == 2 else 8
            fmt = "<QQ" if self.cls == 2 else "<II"
            d = self.d
            for p in range(off, off + size - step + 1, step):
                try:
                    tag, val = struct.unpack_from(fmt, d, p)
                except struct.error:
                    break
                if tag == 0:                 # DT_NULL
                    break
                try:
                    if tag == 1:             # DT_NEEDED
                        deps.append(self._cstr(d, strbase, val))
                    elif tag == 14:          # DT_SONAME
                        soname = self._cstr(d, strbase, val)
                except (ValueError, IndexError):
                    continue
        return soname, deps


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def walk_elfs(root):
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            if is_elf(p):
                yield p


def collect_libset(root, label):
    """{bits: {soname_or_basename: (path, defined_symbols)}}"""
    out = {32: {}, 64: {}}
    for p in walk_elfs(root):
        e = Elf(p)
        if not e.ok:
            continue
        defined, _u = e.symbols()
        soname, _d = e.needed()
        key = soname or os.path.basename(p)
        out[e.bits][key] = (p, defined)
    n32, n64 = len(out[32]), len(out[64])
    print(f"  {label:24s} lib {n32:4d}   lib64 {n64:4d}   ({root})")
    return out


_AIDL_NDK = re.compile(r"^(?P<stem>.+)-V(?P<ver>\d+)-ndk\.so$")


def _v31_alias(dep, v31_names):
    """Return the v31 name for an A13-named AIDL NDK library, or None.

    Android 11/12 spelled these `<iface>-V<n>-ndk_platform.so`; Android 13
    dropped the `_platform` suffix and frequently bumped the interface version
    at the same time (light V1->V2, power V2->V3, keymint V1->V2, gnss V1->V2).
    So match on the interface stem and accept any version, reporting which one
    was found -- a version delta is a real compatibility question for the
    caller to answer, but it is still a rename rather than a missing library.
    """
    m = _AIDL_NDK.match(dep)
    if not m:
        return None
    stem, want = m.group("stem"), m.group("ver")
    exact = f"{stem}-V{want}-ndk_platform.so"
    if exact in v31_names:
        return exact
    for name in v31_names:
        if name.startswith(f"{stem}-V") and name.endswith("-ndk_platform.so"):
            return name
    return None


def _same_ver(dep, alt):
    a, b = _AIDL_NDK.match(dep), re.match(r"^.+-V(\d+)-ndk_platform\.so$", alt or "")
    return bool(a and b and a.group("ver") == b.group(1))


def die_unbelievable(msg):
    """Exit 2 — the inputs do not describe a device, so there is no verdict.

    Distinct from exit 1 (findings) on purpose: a caller that treats "not 0" as
    "broken" would otherwise read a misconfigured gate as a real result, and a
    caller that treats "not 1" as "clean" would read it as a pass.
    """
    print(f"\n{msg}", file=sys.stderr)
    sys.exit(2)


def main():
    if len(sys.argv) != 4:
        die_unbelievable("usage: v31-delta-check.py <built-vendor-dir> <v31-lib-dir> <v33-lib-dir>")
    vendor_dir, v31_dir, v33_dir = sys.argv[1:4]
    for p in (vendor_dir, v31_dir, v33_dir):
        if not os.path.isdir(p):
            die_unbelievable(f"v31 delta gate: not a directory: {p}")

    print("v31 delta gate")
    v31 = collect_libset(v31_dir, "v31 set")
    v33 = collect_libset(v33_dir, "v33 set")

    # ---- sanity floor. See the module docstring: this gate's specific way of
    # passing vacuously is an empty input, which makes every delta empty.
    for bits in (32, 64):
        if v33[bits] and len(v33[bits]) < MIN_VNDK_LIBS:
            die_unbelievable(
                f"v31 delta gate: only {len(v33[bits])} lib{bits} libraries in the v33 set "
                f"({v33_dir}).\nThat is not a VNDK snapshot -- refusing to report a verdict.")
    if not v33[64] or not v31[64]:
        die_unbelievable("v31 delta gate: one of the library sets has no 64-bit content.\n"
                         f"  v31 {v31_dir}\n  v33 {v33_dir}")

    # ---- vendor side, per ABI
    vendor = {32: [], 64: []}
    vendor_defines = {32: set(), 64: set()}
    vendor_sonames = {32: set(), 64: set()}
    for p in walk_elfs(vendor_dir):
        e = Elf(p)
        if not e.ok:
            continue
        defined, undef = e.symbols()
        soname, deps = e.needed()
        vendor[e.bits].append((p, undef, deps))
        vendor_defines[e.bits] |= defined
        vendor_sonames[e.bits].add(soname or os.path.basename(p))
    total = len(vendor[32]) + len(vendor[64])
    print(f"  {'vendor ELFs':24s} lib {len(vendor[32]):4d}   lib64 {len(vendor[64]):4d}   ({vendor_dir})")
    if total < MIN_VENDOR_ELFS:
        die_unbelievable(f"v31 delta gate: only {total} vendor ELFs under {vendor_dir}.\n"
                         "A built vendor partition for this device is ~2,000. "
                         "Refusing to report a verdict.")

    # ---- Check A: v33-only symbols referenced by vendor ELFs
    findings_a = {}
    for bits in (32, 64):
        exp31 = set()
        for _p, syms in v31[bits].values():
            exp31 |= syms
        exp33 = set()
        for _p, syms in v33[bits].values():
            exp33 |= syms
        only33 = exp33 - exp31
        print(f"\n  lib{bits}: v31 exports {len(exp31):6d}   v33 exports {len(exp33):6d}   "
              f"v33-only {len(only33):6d}")
        if bits == 64 and len(only33) < MIN_V33_ONLY_SYMBOLS:
            die_unbelievable(
                f"v31 delta gate: only {len(only33)} v33-only lib64 symbols "
                f"(expected ~8,500).\nThe two library sets look like the same snapshot:\n"
                f"  v31 {v31_dir}\n  v33 {v33_dir}\n"
                "With an empty delta this gate cannot find anything, so a PASS here would\n"
                "mean nothing. Point the v33 argument at a real com.android.vndk.v33 set.")
        for path, undef, _deps in vendor[bits]:
            # the vendor namespace searches /vendor first, so a symbol the
            # partition supplies itself is never served by the VNDK
            hits = sorted((undef & only33) - vendor_defines[bits])
            if hits:
                findings_a[path] = (bits, hits)

    # ---- Check B: DT_NEEDED on a library that exists only in the v33 set
    #
    # Split into two classes, because they cost wildly different amounts of work
    # and conflating them is how "15 files" and "a project" got confused:
    #
    #   RENAMEABLE  the same AIDL interface exists in v31 under the Android 11/12
    #               naming, i.e. with the `_platform` suffix AOSP dropped in
    #               Android 13 (android.hardware.light-V2-ndk.so <-> ...-V1-ndk_
    #               platform.so). blob_fixup already does exactly this rename for
    #               arm.graphics and android.hardware.light, so it is a known,
    #               cheap fix -- mind the version number, which often moves too.
    #   ABSENT      no v31 equivalent under ANY name. Not fixable by a rename,
    #               because there is nothing to rename to. This is the class
    #               android.hardware.wifi.supplicant-V1-ndk.so is in, and it is
    #               what makes the Wi-Fi daemons a project rather than a swap.
    findings_b = {}          # ABSENT -- the expensive class
    findings_b_rename = {}   # RENAMEABLE -- the cheap class
    for bits in (32, 64):
        only33_libs = set(v33[bits]) - set(v31[bits])
        v31_names = set(v31[bits])
        for path, _undef, deps in vendor[bits]:
            absent, renameable = [], []
            for d in deps:
                # a dep the vendor partition ships itself resolves before the VNDK
                if d not in only33_libs or d in vendor_sonames[bits]:
                    continue
                alt = _v31_alias(d, v31_names)
                (renameable if alt else absent).append((d, alt))
            if absent:
                findings_b[path] = (bits, sorted(d for d, _a in absent))
            if renameable:
                findings_b_rename[path] = (bits, sorted(renameable))

    rel = lambda p: os.path.relpath(p, vendor_dir)

    print(f"\n  CHECK A  v33-only symbol references : {len(findings_a)} file(s)")
    for path in sorted(findings_a):
        bits, hits = findings_a[path]
        shown = ", ".join(hits[:3]) + (f" (+{len(hits)-3} more)" if len(hits) > 3 else "")
        print(f"    [{bits}] {rel(path)}\n           {shown}")

    print(f"\n  CHECK B1 v33-only DT_NEEDED, RENAMEABLE to a v31 name : "
          f"{len(findings_b_rename)} file(s)")
    for path in sorted(findings_b_rename):
        bits, hits = findings_b_rename[path]
        for dep, alt in hits:
            note = "" if _same_ver(dep, alt) else "   ⚠ interface version differs"
            print(f"    [{bits}] {rel(path)}\n           {dep}  ->  {alt}{note}")

    print(f"\n  CHECK B2 v33-only DT_NEEDED, NO v31 counterpart : {len(findings_b)} file(s)")
    for path in sorted(findings_b):
        bits, hits = findings_b[path]
        print(f"    [{bits}] {rel(path)}\n           {', '.join(hits)}")

    if not findings_a and not findings_b and not findings_b_rename:
        print("\n  v31 delta gate PASSED — nothing at risk under a v31 vendor namespace")
        return 0

    print("\nv31 DELTA GATE FAILED.")
    if findings_b_rename:
        print("  Check B1 is the CHEAP class: the same AIDL interface exists in v31 under\n"
              "  the Android 11/12 `_platform` naming. blob_fixup already does this rename\n"
              "  for arm.graphics and android.hardware.light. Where the interface VERSION\n"
              "  also moved, confirm the vendor consumer actually tolerates the older one\n"
              "  before renaming -- a rename that compiles is not a rename that works.")
    if findings_a:
        print("  Check A files each have a stock A12 counterpart; ship stock's copy.\n"
              "  Mind the module-name AND install-path collisions -- a unique `name:` is\n"
              "  not enough, `stem` leaves the install path identical and that is a\n"
              "  parse-time error (build 64). Distinct filenames plus blob_fixup\n"
              "  repointing is the pattern that works (build 65's codec2 set).")
    if findings_b:
        print("  Check B2 is NOT fixable by swapping or renaming -- there is no v31 copy to\n"
              "  swap to under any name. Each of these needs its consumer moved to stock's\n"
              "  A12 daemon, which for wpa_supplicant/hostapd means re-deriving the whole\n"
              "  2026-08-12 Wi-Fi fix against the HIDL stack. That is the project, not a\n"
              "  step in it.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
