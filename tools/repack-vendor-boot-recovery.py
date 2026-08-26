#!/usr/bin/env python3
"""Swap ONLY the recovery ramdisk fragment inside a vendor_boot image.

    repack-vendor-boot-recovery.py <donor vendor_boot.img> <new recovery ramdisk> <out.img>
    repack-vendor-boot-recovery.py <donor vendor_boot.img> --control

WHY NOT LET THE RECOVERY TREE BUILD ITS OWN vendor_boot
------------------------------------------------------
This device has no recovery partition; recovery lives in vendor_boot, and 🔴 the
recovery fragment supplies the vendor ramdisk at NORMAL boot too. The PLATFORM
fragment carries the kernel modules and the four touch firmware blobs plus the
patched adaptive-ts.ko -- drop or regenerate it and you get a touch UI with no
touch input, or a device that does not boot at all.

⚠ CORRECTED 2026-08-19. An earlier version of this comment claimed the ROM
would fail to boot on a foreign vendor_boot. That is WRONG, and JOURNAL.md had
already retracted it once: the kernel mounts super unaided and SECOND-stage init
loads vendor_dlkm's 198 modules from there, so the vendor_boot modules are not
required to reach userspace -- demonstrated by OrangeFox, whose platform ramdisk
is a bare first_stage_ramdisk with ZERO modules, on which this ROM boots fine.

The real reason to keep the ROM's platform fragment is RECOVERY, not the ROM:
that fragment carries the four touch firmware blobs and the patched
adaptive-ts.ko, and BOTH fragments are loaded in recovery. PBRP's own platform
fragment is FOUR BYTES, so a PBRP-built vendor_boot flashed as-is gives a touch
UI with no touch input.

(The AOSPA lesson still applies in its proper form -- a ROM must not depend on
something a recovery overwrites -- but that dependency here is a cmdline param
we do not have, not ramdisk content.)

So the recovery image is the ROM's OWN vendor_boot with exactly one fragment
replaced -- same cmdline, same dtb, same platform fragment, byte for byte. Same
shape as the boot*-ksunext.img recipe: take the shipped artifact, swap one
component, keep everything else identical.

THE CONTROL
-----------
--control repacks using the ORIGINAL recovery fragment and requires the result
to be byte-identical to the donor. If that fails, this script's understanding of
the header is wrong and its output must not be trusted -- so it refuses to
produce a modified image unless the control has passed in the same run.

⚠ mkbootimg per-fragment arguments must come BEFORE their
--vendor_ramdisk_fragment, and the fragment names on this device are "" for the
platform fragment and "recovery" for the recovery one. Getting either wrong
produces an image that unpacks fine and boots nothing.
"""
import os, re, shutil, struct, subprocess, sys, tempfile

HOST = os.environ.get("HOST_BIN", "/mnt/external_nvme/crdroid/out/host/linux-x86/bin")
MKBOOTIMG = os.path.join(HOST, "mkbootimg")
UNPACK = os.path.join(HOST, "unpack_bootimg")
AVBTOOL = os.path.join(HOST, "avbtool")


def avb_info(img):
    """Footer facts, read from the donor. vendor_boot carries an AVB hash footer,
    so a repack of the CONTENT is shorter than the file: 23,498,752 vs the
    67,108,864 the partition is padded to. The footer must be reproduced with the
    donor's own salt -- ⚠ avbtool generates a RANDOM salt per build, so reusing a
    salt from a previous image silently produces a wrong digest."""
    r = subprocess.run([AVBTOOL, "info_image", "--image", img],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    o = r.stdout
    m = re.search(r"Original image size:\s+(\d+)", o)
    if not m:
        return None
    info = dict(orig_size=int(m.group(1)))
    m = re.search(r"Image size:\s+(\d+)", o)
    info["part_size"] = int(m.group(1))
    m = re.search(r"Partition Name:\s+(\S+)", o)
    info["part_name"] = m.group(1)
    m = re.search(r"Salt:\s+([0-9a-f]+)", o)
    info["salt"] = m.group(1)
    info["props"] = re.findall(r"Prop:\s+(\S+)\s+->\s+'([^']*)'", o)
    return info


def add_footer(img, info):
    argv = [AVBTOOL, "add_hash_footer", "--image", img,
            "--partition_name", info["part_name"],
            "--partition_size", str(info["part_size"]),
            "--algorithm", "NONE", "--salt", info["salt"]]
    for k, v in info["props"]:
        argv += ["--prop", "%s:%s" % (k, v)]
    r = subprocess.run(argv, capture_output=True, text=True)
    if r.returncode != 0:
        die("avbtool add_hash_footer failed:\n" + r.stderr[-1500:])


def die(msg):
    print("!! " + msg, file=sys.stderr)
    sys.exit(2)


def parse_header(path):
    """vendor_boot_img_hdr_v4, from the image itself rather than BoardConfig."""
    with open(path, "rb") as f:
        d = f.read(4096)
    if d[:8] != b"VNDRBOOT":
        die("%s is not a vendor_boot image" % path)
    (hdr_ver, page_size, kernel_addr, ramdisk_addr, vendor_ramdisk_size) = struct.unpack_from("<5I", d, 8)
    cmdline = d[28:28 + 2048].split(b"\x00")[0].decode("ascii", "replace")
    off = 28 + 2048
    (tags_addr,) = struct.unpack_from("<I", d, off)
    name = d[off + 4:off + 4 + 16].split(b"\x00")[0].decode("ascii", "replace")
    (hdr_size, dtb_size) = struct.unpack_from("<2I", d, off + 20)
    (dtb_addr,) = struct.unpack_from("<Q", d, off + 28)
    return dict(hdr_ver=hdr_ver, page_size=page_size, kernel_addr=kernel_addr,
                ramdisk_addr=ramdisk_addr, cmdline=cmdline, tags_addr=tags_addr,
                name=name, dtb_size=dtb_size, dtb_addr=dtb_addr)


def unpack(img, out):
    os.makedirs(out, exist_ok=True)
    subprocess.run([UNPACK, "--boot_img", img, "--out", out],
                   check=True, capture_output=True)
    frags = sorted(f for f in os.listdir(out) if f.startswith("vendor_ramdisk") and f[-2:].isdigit())
    if len(frags) != 2:
        die("expected exactly 2 vendor ramdisk fragments, found %d: %s\n"
            "   This device ships a platform fragment AND a recovery fragment; a\n"
            "   donor with a different shape is not the image this tool is for."
            % (len(frags), frags))
    return [os.path.join(out, f) for f in frags]


def build(h, platform_frag, recovery_frag, dtb, out):
    # base 0 and absolute addresses as offsets: mkbootimg computes addr = base + offset,
    # so this reproduces the donor's addresses exactly without hardcoding BoardConfig.
    argv = [MKBOOTIMG,
            "--header_version", str(h["hdr_ver"]),
            "--pagesize", str(h["page_size"]),
            "--base", "0x00000000",
            "--kernel_offset", hex(h["kernel_addr"]),
            "--ramdisk_offset", hex(h["ramdisk_addr"]),
            "--tags_offset", hex(h["tags_addr"]),
            "--vendor_cmdline", h["cmdline"],
            "--board", h["name"]]
    if h["dtb_size"]:
        argv += ["--dtb", dtb, "--dtb_offset", hex(h["dtb_addr"])]
    # ⚠ per-fragment args FIRST, then the fragment itself.
    argv += ["--ramdisk_type", "platform", "--ramdisk_name", "",
             "--vendor_ramdisk_fragment", platform_frag,
             "--ramdisk_type", "recovery", "--ramdisk_name", "recovery",
             "--vendor_ramdisk_fragment", recovery_frag,
             "--vendor_boot", out]
    r = subprocess.run(argv, capture_output=True, text=True)
    if r.returncode != 0:
        die("mkbootimg failed:\n" + r.stderr[-2000:])


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    donor = sys.argv[1]
    control_only = sys.argv[2] == "--control"
    for t in (MKBOOTIMG, UNPACK):
        if not os.path.exists(t):
            die("missing host tool %s (set HOST_BIN)" % t)
    if not os.path.exists(donor):
        die("no donor image at %s" % donor)

    h = parse_header(donor)
    tmp = tempfile.mkdtemp(prefix="vbrepack.")
    try:
        plat, rec = unpack(donor, os.path.join(tmp, "u"))
        dtb = os.path.join(tmp, "u", "dtb")
        print("donor      : %s" % donor)
        print("  cmdline  : %r" % h["cmdline"])
        print("  platform : %d B" % os.path.getsize(plat))
        print("  recovery : %d B" % os.path.getsize(rec))
        print("  dtb      : %d B" % h["dtb_size"])

        # --- the control, always, before anything is emitted
        avb = avb_info(donor)
        if avb:
            print("  avb      : %s, orig %d B, partition %d B, salt %s..."
                  % (avb["part_name"], avb["orig_size"], avb["part_size"], avb["salt"][:16]))
        ctl = os.path.join(tmp, "control.img")
        build(h, plat, rec, dtb, ctl)
        if avb:
            add_footer(ctl, avb)
        donor_bytes = open(donor, "rb").read()
        ctl_bytes = open(ctl, "rb").read()
        if donor_bytes != ctl_bytes:
            die("CONTROL FAILED: repacking with the ORIGINAL recovery fragment did not\n"
                "   reproduce the donor (%d vs %d bytes). This script's understanding of\n"
                "   the header is wrong, so its output cannot be trusted. Refusing."
                % (len(ctl_bytes), len(donor_bytes)))
        print("CONTROL    : ✅ byte-for-byte identical with the original fragment (incl. AVB footer)")
        if control_only:
            return

        new_rec, out = sys.argv[2], sys.argv[3]
        if not os.path.exists(new_rec):
            die("no recovery ramdisk at %s" % new_rec)
        build(h, plat, new_rec, dtb, out)
        # ⚠ MEASURE BEFORE add_footer. avbtool pads the image out to the full
        # partition size, so a size taken afterwards is ALWAYS exactly the
        # partition size -- which made the overflow guard below dead code and
        # printed "headroom: 0 B" on every run regardless of the real usage.
        # Caught 2026-08-19 when a fragment that grew by 5.3 MB still reported
        # zero headroom.
        size = os.path.getsize(out)
        if avb:
            add_footer(out, avb)
        print("new recovery fragment: %d B (was %d B)" % (os.path.getsize(new_rec), os.path.getsize(rec)))
        print("output     : %s  (%d B unpadded)" % (out, size))
        # the partition is 64 MiB on this device; refuse to emit something that cannot be flashed
        limit = 67108864
        if size > limit:
            die("output is %d B, larger than the %d B vendor_boot partition." % (size, limit))
        print("headroom   : %d B of %d" % (limit - size, limit))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
