#!/usr/bin/env python3
"""KMI gate — refuse to ship a kernel the stock vendor modules would reject.

    kmi-check.py <Module.symvers> <dir-with-vendor .ko> [expected_module_layout]

Every prebuilt vendor module on this device is version-checked against the
kernel at load time. If a single symbol CRC disagrees, that module is rejected
by the loader — and since the set includes storage, display and the GPU, a
KMI-broken kernel does not boot. It also does not fail at *build* time, which is
why this exists: without it the first symptom is a bootloop on hardware.

The CRCs are reproduced by the kernel CONFIG, not by the source. MediaTek's
shipping config with CFI_CLANG=y, LTO_CLANG_FULL=y and MODVERSIONS=y yields
module_layout = 0x7c24b32d. A kernel built from gki_defconfig will not.
CONFIG_CGROUP_DEVICE and CONFIG_CGROUP_PIDS also move it; USER_NS, PID_NS,
DEVTMPFS and VT do not.

Ported from the S666LN kernel project's lib/kmi_check.py, with pyelftools
dropped so it runs inside a ROM build with no extra host dependencies.
"""
import glob
import os
import struct
import sys

EXPECTED_DEFAULT = "0x7c24b32d"


def sections(path):
    """Minimal ELF64 section reader — enough to find __versions."""
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF" or d[4] != 2:            # ELF64 only; all .ko here are arm64
        return {}
    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    if not e_shoff or not e_shnum:
        return {}
    def sh(i):
        o = e_shoff + i * e_shentsize
        name, _type = struct.unpack_from("<II", d, o)
        off, size = struct.unpack_from("<QQ", d, o + 0x18)
        return name, off, size
    _, stroff, _ = sh(e_shstrndx)
    out = {}
    for i in range(e_shnum):
        nameoff, off, size = sh(i)
        end = d.index(b"\x00", stroff + nameoff)
        out[d[stroff + nameoff:end].decode("latin1")] = d[off:off + size]
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: kmi-check.py <Module.symvers> <vendor_ko_dir> [expected_module_layout]")
    symvers_path, ko_dir = sys.argv[1], sys.argv[2]
    expected = int((sys.argv[3] if len(sys.argv) > 3 else EXPECTED_DEFAULT), 16)

    if not os.path.exists(symvers_path):
        sys.exit(f"KMI GATE: {symvers_path} not found — was the kernel built from source?")

    sv = {}
    with open(symvers_path) as f:
        for ln in f:
            p = ln.split("\t")
            if len(p) >= 2:
                try:
                    sv[p[1].strip()] = int(p[0], 16) & 0xFFFFFFFF
                except ValueError:
                    pass

    kos = sorted(glob.glob(os.path.join(ko_dir, "*.ko")))
    if not kos:
        sys.exit(f"KMI GATE: no .ko found in {ko_dir}")

    total = match = missing = 0
    bad_modules, ml_seen = {}, set()
    for ko in kos:
        data = sections(ko).get("__versions")
        if not data:
            continue
        for i in range(0, len(data) - 63, 64):      # modversion_info: 8B crc + 56B name
            crc = struct.unpack_from("<Q", data, i)[0] & 0xFFFFFFFF
            name = data[i + 8:i + 64].split(b"\x00")[0].decode("latin1")
            if not name:
                continue
            total += 1
            if name == "module_layout":
                ml_seen.add(crc)
            if name not in sv:
                missing += 1
            elif sv[name] == crc:
                match += 1
            else:
                bad_modules.setdefault(os.path.basename(ko), []).append(
                    (name, crc, sv[name]))

    print(f"KMI gate: {len(kos)} modules, {total} symbol refs, {match} matched, "
          f"{missing} absent from this kernel")

    fail = False
    if ml_seen != {expected}:
        got = ", ".join(f"0x{c:08x}" for c in sorted(ml_seen)) or "none"
        print(f"  FAIL module_layout: expected 0x{expected:08x}, modules want {got}")
        fail = True
    else:
        print(f"  ok   module_layout = 0x{expected:08x}")

    if bad_modules:
        print(f"  FAIL {len(bad_modules)} module(s) have CRC mismatches:")
        for mod, syms in list(bad_modules.items())[:5]:
            n, c, k = syms[0]
            print(f"       {mod}: {n} wants 0x{c:08x}, kernel has 0x{k:08x}"
                  f"{f' (+{len(syms)-1} more)' if len(syms) > 1 else ''}")
        fail = True
    else:
        print("  ok   no CRC mismatches")

    if fail:
        sys.exit(
            "\nKMI GATE FAILED — this kernel would be rejected by the stock vendor\n"
            "modules and the device would not boot. Do not flash it.\n"
            "Cause is almost always the kernel CONFIG, not the source: verify\n"
            "CFI_CLANG, LTO_CLANG_FULL and MODVERSIONS are set as MediaTek ships them.")
    print("  KMI gate PASSED")


if __name__ == "__main__":
    main()
