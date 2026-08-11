#!/usr/bin/env python3
"""Repoint .gnu.version_r entries after a DT_NEEDED rename.

`patchelf --replace-needed libbinder.so libbinder-v31.so` rewrites DT_NEEDED and
leaves the version-needs section alone. That is fine right up until the renamed
library stops ALSO answering to its old soname, at which point the loader fails:

    CANNOT LINK EXECUTABLE ".../android.hardware.audio.service.mediatek":
      cannot find "libbinder.so" from verneed[0] in DT_NEEDED list

Measured on hardware 2026-08-11 (build 46). The sequence is worth knowing,
because each step was individually correct:

  1. blob_fixup renames DT_NEEDED libbinder.so -> libbinder-v31.so, so the A12
     blob binds to the v31 library instead of the platform's v33.
  2. .gnu.version_r still says "the versioned symbols I need come from a library
     called libbinder.so". Harmless while libbinder-v31.so declared
     SONAME=libbinder.so -- the loader matched the verneed entry against the
     loaded library's soname and was satisfied.
  3. c2b72d9 patched those SONAMEs (correctly -- without it one version served
     the whole process and platform libraries lost symbols). Now nothing in the
     process answers to "libbinder.so", the verneed entry matches nothing, and
     the loader refuses the executable outright.

So this tool is the other half of the SONAME work, not a separate idea. Run it
on any file where blob_fixup renames a DT_NEEDED entry that also appears in the
version-needs section.

WHAT IT DOES

For each Verneed entry whose vn_file names OLD, point vn_file at the .dynstr
offset of NEW. Nothing else changes: no section moves, no string is added (NEW
is already in .dynstr, because DT_NEEDED refers to it), and the file size is
identical. If NEW is somehow absent from .dynstr it refuses rather than
inventing one.

USAGE
    patch-verneed.py <elf> <old-soname> <new-soname> [...]
    patch-verneed.py --verify <elf> <old-soname>      exit 1 if OLD still named

Idempotent: an already-patched file reports "already" and is left alone.
"""
import struct
import sys

EI_CLASS, ELFCLASS64 = 4, 2
SHT_GNU_VERNEED = 0x6FFFFFFE


def _sections(b):
    """Yield (name_off, sh_type, sh_offset, sh_size, sh_link, sh_entsize)."""
    if b[:4] != b"\x7fELF" or b[EI_CLASS] != ELFCLASS64:
        raise SystemExit("not a 64-bit ELF")
    e_shoff = struct.unpack_from("<Q", b, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", b, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", b, 0x3C)[0]
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        yield struct.unpack_from("<I", b, o)[0], \
              struct.unpack_from("<I", b, o + 4)[0], \
              struct.unpack_from("<Q", b, o + 0x18)[0], \
              struct.unpack_from("<Q", b, o + 0x20)[0], \
              struct.unpack_from("<I", b, o + 0x28)[0], \
              struct.unpack_from("<Q", b, o + 0x38)[0]


def _dynstr_for(b, link_idx):
    e_shoff = struct.unpack_from("<Q", b, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", b, 0x3A)[0]
    o = e_shoff + link_idx * e_shentsize
    off = struct.unpack_from("<Q", b, o + 0x18)[0]
    size = struct.unpack_from("<Q", b, o + 0x20)[0]
    return off, size


def _cstr(b, base, off):
    end = b.index(b"\0", base + off)
    return b[base + off:end].decode("utf-8", "replace")


def process(path, old, new, verify=False):
    b = bytearray(open(path, "rb").read())
    vn = [s for s in _sections(b) if s[1] == SHT_GNU_VERNEED]
    if not vn:
        return "no .gnu.version_r (nothing to do)"
    _, _, vn_off, vn_size, vn_link, _ = vn[0]
    ds_off, ds_size = _dynstr_for(b, vn_link)

    # Offset of NEW inside .dynstr. It must already be there: DT_NEEDED points
    # at it. Refuse rather than append -- growing .dynstr would move everything.
    needle = new.encode() + b"\0"
    idx = b.find(needle, ds_off, ds_off + ds_size)
    if idx == -1 and not verify:
        return f"FAIL: '{new}' is not in .dynstr -- was DT_NEEDED renamed first?"
    new_off = idx - ds_off if idx != -1 else None

    hits, cur, changed = 0, vn_off, False
    while cur < vn_off + vn_size:
        vn_version, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from("<HHIII", b, cur)
        name = _cstr(b, ds_off, vn_file)
        if name == old:
            hits += 1
            if not verify:
                struct.pack_into("<I", b, cur + 4, new_off)
                changed = True
        if vn_next == 0:
            break
        cur += vn_next

    if verify:
        return f"STILL NAMES '{old}' in verneed" if hits else "clean"
    if not changed:
        return "already"
    open(path, "wb").write(bytes(b))
    return f"patched {hits} verneed entr{'y' if hits == 1 else 'ies'}: {old} -> {new}"


def main():
    a = sys.argv[1:]
    verify = False
    if a and a[0] == "--verify":
        verify, a = True, a[1:]
    if (verify and len(a) != 2) or (not verify and len(a) != 3):
        sys.exit(__doc__.strip().split("USAGE")[1].strip())

    if verify:
        r = process(a[0], a[1], a[1], verify=True)
        print(f"{r}: {a[0]}")
        sys.exit(1 if r.startswith("STILL") else 0)

    r = process(a[0], a[1], a[2])
    print(f"{r}: {a[0]}")
    sys.exit(1 if r.startswith("FAIL") else 0)


if __name__ == "__main__":
    main()
