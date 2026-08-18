#!/usr/bin/env python3
"""Authorise adb in RECOVERY, for a -user build, as a separate flashable image.

    patch-recovery-adb.py <vendor_boot.img> <output.img>

WHY THIS EXISTS
    On a `-user` release, recovery's adb demands authorisation and cannot get
    it: /data is encrypted so no key under /data/misc/adb is trusted, and the
    supported way to bake one in is refused by design --

        build/make/core/product_config.mk:435
          # Reset ADB keys for non-debuggable builds
          ifeq (,$(filter eng userdebug,$(TARGET_BUILD_VARIANT)))
            PRODUCT_ADB_KEYS :=

    so `adb shell` in recovery is unavailable on exactly the builds that ship.
    `adb sideload` still works, which is how build 63 was restored on
    2026-08-17 -- installing is fine, DIAGNOSING is what is missing.

    This produces a debug vendor_boot with recovery's adb opened up, flashed by
    fastboot when needed. It is the same pattern the kernel work already uses:
    the release stays honest and unmodified, and the capability lives in a
    separate artifact you flash deliberately (flash/boot63-ksunext.img).

🔴 NEVER SHIP THIS. It is a diagnostic image. `ro.adb.secure=0` in recovery means
   any USB host gets a root shell there, with /data unlocked to whatever recovery
   can reach. Build it, flash it, use it, flash the real vendor_boot back.

WHAT IS PATCHED, AND WHY IT IS SAFE TO DO IN PLACE
    One property in the recovery fragment's prop.default, the same length as its
    replacement, so nothing moves:

        ro.adb.secure=1   ->   ro.adb.secure=0

    default.prop is a symlink to prop.default, so there is one file to touch.

    🔴 ro.debuggable is NOT touched. See PATCHES below -- our own recovery rc
    starts adbd from a trigger gated on ro.debuggable=0, so "helpfully" setting
    it to 1 deletes adb rather than enabling it.

    The edit is made INSIDE the cpio byte stream, not by extract-and-repack.
    Extracting a ramdisk as a non-root user silently rewrites every file's owner,
    which is how a repack quietly breaks a boot image -- recorded when the touch
    patch was built (tools/patch-touch-in-recovery.py). Parsing the cpio and
    writing within one entry's data region leaves ordering, permissions and root
    ownership untouched by construction.

    And the patch is scoped to that entry rather than done as a global replace:
    a blind byte replace across the whole ramdisk would also rewrite any other
    file containing the string, including ones this has never inspected.

⚠ Repacking changes the image digest. That is fine HERE and only here: this
  device's vbmeta ships `Flags: 2` (VERIFICATION_DISABLED), so the digest is not
  checked -- the same reason the hand-patched ksunext boot.img works. Do not
  carry that assumption to a device that verifies.
"""
import os
import struct
import subprocess
import sys
import tempfile

# 🔴 ONLY ro.adb.secure. ro.debuggable is deliberately NOT touched, and getting
# that wrong would have removed adb entirely while looking like it enabled it:
#
#   rootdir/etc/init.recovery.mt6789.rc:20   (OUR file, authored 2026-08-03)
#       on fs && property:ro.debuggable=0
#           write /sys/class/udc/musb-hdrc/device/cmode 2
#           start adbd
#
# adbd in recovery is started by a trigger gated on ro.debuggable=0. Flipping it
# to 1 means the trigger never fires and there is no adbd to authorise against.
# ro.adb.secure is the one that governs AUTHENTICATION, which is the actual
# complaint; adbd already runs as root in recovery, so nothing else is needed.
PATCHES = [(b"ro.adb.secure=1", b"ro.adb.secure=0")]
TARGET = b"prop.default"


def die(msg):
    print(f"!! {msg}", file=sys.stderr)
    sys.exit(1)


def cpio_find(data, name):
    """(data_offset, data_size) of `name` in a newc cpio, or None.

    newc header is 110 ASCII-hex bytes; namesize and filesize are fields 11 and
    6. Both the name and the data are padded to 4 bytes.
    """
    off = 0
    while off + 110 <= len(data):
        if data[off:off + 6] != b"070701":
            return None
        try:
            filesize = int(data[off + 54:off + 62], 16)
            namesize = int(data[off + 94:off + 102], 16)
        except ValueError:
            return None
        nstart = off + 110
        nm = data[nstart:nstart + namesize - 1]
        dstart = (nstart + namesize + 3) & ~3
        if nm == b"TRAILER!!!":
            return None
        if nm == name or nm == b"./" + name:
            return dstart, filesize
        off = (dstart + filesize + 3) & ~3
    return None


def main():
    if len(sys.argv) != 3:
        die("usage: patch-recovery-adb.py <vendor_boot.img> <output.img>")
    src, dst = sys.argv[1], sys.argv[2]
    for tool in ("unpack_bootimg", "mkbootimg", "lz4"):
        if subprocess.call(["which", tool], stdout=subprocess.DEVNULL) != 0:
            die(f"{tool} not on PATH")

    with tempfile.TemporaryDirectory() as tmp:
        up = os.path.join(tmp, "up")
        out = subprocess.run(["unpack_bootimg", "--boot_img", src, "--out", up],
                             capture_output=True, text=True)
        if out.returncode != 0:
            die(f"unpack_bootimg failed:\n{out.stderr}")
        info = out.stdout
        if "VNDRBOOT" not in info:
            die("not a vendor_boot image")

        # The RECOVERY fragment is the one with type 0x2. Find it by NAME rather
        # than assuming it is fragment 01: the ordering is a property of this
        # build, not of the format, and a wrong guess here patches the platform
        # ramdisk instead -- which is the fragment that supplies modules at
        # NORMAL boot on this device.
        byname = os.path.join(up, "vendor-ramdisk-by-name")
        cand = [f for f in os.listdir(byname)] if os.path.isdir(byname) else []
        rec = [f for f in cand if "recovery" in f]
        if len(rec) != 1:
            die(f"expected exactly one recovery fragment, found {cand}")
        frag = os.path.join(byname, rec[0])
        print(f"== recovery fragment: {rec[0]}  ({os.path.getsize(frag)} B)")

        raw = subprocess.run(["lz4", "-dc", frag], capture_output=True)
        if raw.returncode != 0 or not raw.stdout:
            die("could not lz4-decompress the recovery fragment")
        cpio = bytearray(raw.stdout)

        found = cpio_find(bytes(cpio), TARGET)
        if not found:
            die(f"{TARGET.decode()} not found in the recovery fragment")
        doff, dsize = found
        region = bytes(cpio[doff:doff + dsize])
        print(f"== {TARGET.decode()}: {dsize} B at cpio offset {doff}")

        applied = 0
        for old, new in PATCHES:
            n = region.count(old)
            if n == 0:
                print(f"   !! not present: {old.decode()}")
                continue
            region = region.replace(old, new)
            applied += n
            print(f"   {old.decode()} -> {new.decode()}   ({n} occurrence(s))")
        if applied == 0:
            die("nothing was patched -- refusing to emit an image that changes nothing")
        if len(region) != dsize:
            die("patched region changed size; that would corrupt the cpio")
        cpio[doff:doff + dsize] = region

        # positive control, before repacking
        again = cpio_find(bytes(cpio), TARGET)
        chk = bytes(cpio[again[0]:again[0] + again[1]])
        if b"ro.adb.secure=1" in chk:
            die("ro.adb.secure=1 still present after patching")

        newfrag = os.path.join(tmp, "recovery.lz4")
        with open(newfrag, "wb") as f:
            p = subprocess.run(["lz4", "-l", "-9", "-c"], input=bytes(cpio),
                               stdout=f, stderr=subprocess.DEVNULL)
        if p.returncode != 0:
            die("lz4 recompression failed")

        plat = [f for f in cand if "recovery" not in f]
        if len(plat) != 1:
            die(f"expected exactly one platform fragment, found {plat}")
        platfrag = os.path.join(byname, plat[0])

        def val(key, cast=str):
            for line in info.splitlines():
                if line.strip().startswith(key):
                    return cast(line.split(":", 1)[1].strip())
            die(f"could not read '{key}' from unpack_bootimg")

        # 🪤 Per-fragment args must come BEFORE --vendor_ramdisk_fragment, not
        # after. mkbootimg slices each group as everything UP TO AND INCLUDING
        # that flag (parse_vendor_ramdisk_args: `idx = index(FLAG) + 2;
        # group = args_list[:idx]`), so trailing --ramdisk_name lands in the NEXT
        # group and the current one fails "required: --ramdisk_name".
        #
        # And the names are not both empty: the platform fragment is unnamed but
        # the recovery one is literally named "recovery" -- mkbootimg REJECTS
        # duplicate names (add_entry: "Duplicated vendor ramdisk name"), so
        # guessing "" for both could not have worked either. Read them from the
        # by-name filenames, which are `ramdisk_<name>`.
        pname = plat[0][len("ramdisk_"):]
        rname = rec[0][len("ramdisk_"):]
        cmd = ["mkbootimg", "--header_version", "4",
               "--pagesize", str(int(val("page size"), 16)),
               "--vendor_cmdline", val("vendor command line args"),
               "--dtb", os.path.join(up, "dtb"),
               "--ramdisk_type", "platform", "--ramdisk_name", pname,
               "--vendor_ramdisk_fragment", platfrag,
               "--ramdisk_type", "recovery", "--ramdisk_name", rname,
               "--vendor_ramdisk_fragment", newfrag,
               "--vendor_boot", dst]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            die(f"mkbootimg failed:\n{r.stderr}\ncmd: {' '.join(cmd)}")

    # ---- AVB footer. The source image carries one, and the proven procedure
    # for a hand-patched boot artifact on this device (the ksunext boot.img,
    # 2026-08-12) re-adds it with the ORIGINAL salt and partition size, algorithm
    # NONE. Only the digest moves. vbmeta ships Flags: 2 so the digest is not
    # checked, but an image with no footer at all is a different shape from the
    # one that was validated, and this is not the place to introduce a variable.
    # avbtool lives in the ROM tree, and this script is run from BOTH the
    # canonical device tree (outside it) and the copy inside it, so a single
    # relative path cannot work. Search, and say so if it is not found rather
    # than silently emitting a footerless image.
    here = os.path.dirname(os.path.abspath(__file__))
    cands = []
    if os.environ.get("AVBTOOL"):
        cands.append(os.environ["AVBTOOL"])
    if os.environ.get("ANDROID_BUILD_TOP"):
        cands.append(os.path.join(os.environ["ANDROID_BUILD_TOP"],
                                  "external/avb/avbtool.py"))
    cands += [os.path.normpath(os.path.join(here, "../../../../external/avb/avbtool.py")),
              "/mnt/external_nvme/crdroid/external/avb/avbtool.py",
              os.path.expanduser("~/crdroid/external/avb/avbtool.py")]
    avbtool = None
    if subprocess.call(["which", "avbtool"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL) == 0:
        avbtool = ["avbtool"]
    else:
        for c in cands:
            if c and os.path.isfile(c):
                avbtool = ["python3", c]
                break
    if avbtool:
        info = subprocess.run(avbtool + ["info_image", "--image", src],
                              capture_output=True, text=True).stdout
        salt = size = None
        for line in info.splitlines():
            t = line.strip()
            if t.startswith("Salt:"):
                salt = t.split(":", 1)[1].strip()
            elif t.startswith("Image size:"):
                size = t.split(":", 1)[1].strip().split()[0]
        if salt and size:
            r = subprocess.run(avbtool + ["add_hash_footer", "--image", dst,
                                          "--partition_name", "vendor_boot",
                                          "--partition_size", size,
                                          "--salt", salt, "--algorithm", "NONE"],
                               capture_output=True, text=True)
            if r.returncode != 0:
                die(f"avbtool add_hash_footer failed:\n{r.stderr}")
            print(f"== AVB footer re-added (salt {salt[:16]}..., partition_size {size})")
        else:
            print("   !! could not read salt/size from the source image -- NO footer added")
    else:
        print("   !! avbtool not found -- NO AVB footer added")

    print(f"== wrote {dst} ({os.path.getsize(dst)} B)")
    print("\n🔴 DIAGNOSTIC IMAGE -- do not ship it, and flash the real vendor_boot back after.")
    print("   fastboot flash vendor_boot " + dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
