#!/usr/bin/env python3
"""dlopen-check.py -- find blobs this tree ships that ask for a library by NAME.

`vendor-deps-check.sh` resolves DT_NEEDED, and it passes. It structurally cannot
see the other half of the loader's work: `dlopen("libfoo.so")` is a string
literal, not a dynamic-section entry, so a missing dlopen target is invisible to
every link-time check, at build time and at gate time alike.

That gap shipped a real defect. Build 71's RIL logged, every boot:

    RfxVsimUtils: [initVsimHandler] dlopen failed in libmtk-fusion-ril-prop-vsim.so:
                  dlopen failed: library "libmtk-fusion-ril-prop-vsim.so" not found

The library is in stock's own vendor/lib64 and was simply never listed in
proprietary-files.txt. Nothing caught it because nothing was looking: the gate
suite modelled the linker, and the linker was not the thing that failed.

    device_itel_S666LN/tools/dlopen-check.py .build/work
    device_itel_S666LN/tools/dlopen-check.py .build/work --device      # subtract what a
                                                                      # connected phone has
    device_itel_S666LN/tools/dlopen-check.py .build/work --have out/…/system-sonames.txt

Findings are split by whether the answer is actionable:

  MISSING   referenced by a blob we ship, present in the stock dump, not shipped
            and not available anywhere else.  -> add it to proprietary-files.txt
  ABSENT    referenced, but not in stock either.  MediaTek probes for optional
            operator/vendor libraries this firmware does not have -- benign, and
            listed only so a future reader does not re-investigate them.

🔴 A string literal is not proof of a dlopen at runtime; it is proof that the
name is compiled in. Confirm on hardware before claiming a fix, the way the vsim
finding was confirmed: stage the library through the KSU metamodule, reboot, and
watch that one error disappear while the known-benign ones stay.
"""

import argparse
import os
import re
import subprocess
import sys

SONAME = re.compile(rb"(?<![\w./-])(lib[\w.+-]+\.so|[\w.+-]+\.so)(?:\.\d+)*$")
SCAN_DIRS = ("lib/", "lib64/", "bin/")


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def dt_needed(path):
    try:
        out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    except FileNotFoundError:
        sys.exit("readelf not found (binutils)")
    return set(re.findall(r"Shared library: \[([^\]]+)\]", out))


def strings_sonames(path):
    """Every `*.so` token that appears as a printable string in the file."""
    try:
        out = subprocess.run(["strings", "-a", path], capture_output=True).stdout
    except FileNotFoundError:
        sys.exit("strings not found (binutils)")
    found = set()
    for line in out.split(b"\n"):
        tok = line.strip()
        if tok.endswith(b".so") and 4 < len(tok) < 128 and SONAME.match(tok):
            found.add(tok.decode("utf-8", "replace"))
    return found


def shipped_entries(tree):
    """Paths listed in proprietary-files.txt, minus prefixes and rename targets."""
    p = os.path.join(tree, "proprietary-files.txt")
    out = set()
    for line in open(p):
        line = line.split("#")[0].strip()
        if not line:
            continue
        line = line.lstrip("-")
        for sep in (";", ":", "|"):
            line = line.split(sep)[0]
        out.add(line.strip())
    return out


def device_sonames():
    cmd = ["adb", "shell", "su -c 'find /vendor /system /system_ext /product /odm /apex "
           "-name \"*.so\" 2>/dev/null'"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit("--device: could not list libraries (is the phone connected and rooted?)")
    return {os.path.basename(l.strip()) for l in r.stdout.splitlines() if l.strip()}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump", help="stock extraction root, e.g. .build/work")
    ap.add_argument("--tree", default="device_itel_S666LN")
    ap.add_argument("--device", action="store_true",
                    help="subtract libraries a connected device already has")
    ap.add_argument("--have", help="file of sonames already available, one per line")
    args = ap.parse_args()

    shipped = shipped_entries(args.tree)
    shipped_sonames = {os.path.basename(e) for e in shipped if e.endswith(".so")}

    # Everything the stock extraction contains, by basename -> where it lives.
    in_stock = {}
    for root, _, files in os.walk(args.dump):
        for f in files:
            if f.endswith(".so"):
                in_stock.setdefault(f, []).append(
                    os.path.relpath(os.path.join(root, f), args.dump))

    have = set(shipped_sonames)
    if args.have:
        have |= {l.strip() for l in open(args.have) if l.strip()}
    if args.device:
        have |= device_sonames()

    refs = {}          # soname -> set of referring blobs   (dlopen, by string)
    scanned = 0
    for entry in sorted(shipped):
        if not entry.startswith(("vendor/", "odm/")):
            continue
        rel = entry.split("/", 1)[1]
        if not rel.startswith(SCAN_DIRS):
            continue
        path = os.path.join(args.dump, entry)
        if not os.path.isfile(path) or not is_elf(path):
            continue
        scanned += 1
        needed = dt_needed(path)
        # 🔴 DT_NEEDED IS NOT CHECKED HERE, ON PURPOSE. An earlier revision of
        # this file did check it and was WRONG in the dangerous direction: it
        # reported "0 unresolved" for a blob set that then failed the real gate
        # at build time on two libraries, and that false zero is what made a
        # 17-minute build look safe to start.
        #
        # The reason is not a bug that can be fixed here. Whether a vendor blob's
        # DT_NEEDED resolves depends on what actually LANDS in /vendor, and that
        # set is not derivable from the stock dump plus this list:
        #   * platform-built `<module>.vendor` targets land in /vendor without
        #     appearing in proprietary-files.txt at all (libhwbinder,
        #     libhidltransport, the android.hardware.*@x.y interface libraries…)
        #   * libc, liblog, libc++ and friends are reached over linker namespaces
        #     and are not in stock's vendor/lib at all
        # Modelling "available" as the device's filesystem counts /system, which
        # a vendor ELF cannot link against; modelling it as the blob list plus
        # the stock dump reports 255 findings, nearly all of them platform-built.
        #
        # device_itel_S666LN/tools/vendor-deps-check.sh already answers this
        # correctly, against the BUILT vendor image, and it runs as a build step
        # (out/…/vendor_deps_verified.stamp) so it cannot be skipped. Two gates
        # for one question, one of them approximate, is worse than one gate.
        for name in strings_sonames(path) - needed - {os.path.basename(entry)}:
            if name not in have:
                refs.setdefault(name, set()).add(os.path.basename(entry))

    missing = {n: r for n, r in refs.items() if n in in_stock}
    absent = {n: r for n, r in refs.items() if n not in in_stock}

    print(f"scanned {scanned} shipped vendor/odm ELFs against {len(have)} available libraries\n")
    print(f"MISSING -- in the stock dump, referenced by a shipped blob, not shipped ({len(missing)})")
    for n in sorted(missing):
        print(f"  {n}")
        print(f"      stock: {', '.join(sorted(in_stock[n]))}")
        print(f"      asked by: {', '.join(sorted(missing[n]))}")
    if not missing:
        print("  (none)")

    print(f"\nABSENT -- not in stock either; optional probes, informational ({len(absent)})")
    for n in sorted(absent):
        print(f"  {n:<38} asked by: {', '.join(sorted(absent[n]))}")

    print("\nDT_NEEDED is NOT checked here -- device_itel_S666LN/tools/vendor-deps-check.sh\n"
          "owns that question, against the BUILT vendor image, as a build step. See the\n"
          "comment in the scan loop for why it cannot be answered from this data.")

    if not (args.device or args.have):
        print("\n⚠ Run with --device or --have: without a list of what is already\n"
              "  available, platform libraries (libc, liblog, …) look unresolved and\n"
              "  both sections above are noise.")

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
