#!/usr/bin/env python3
"""Let the touchscreen initialise in recovery, by one byte.

Transsion's touch abstraction refuses to bring the panel up in recovery. It is
not subtle about it -- on an unpatched device, in recovery:

    [tran_touch-ERROR]mtk_get_boot_mode 213:bootmode=2 don't load touch !
    [tran_touch-ERROR]tpd_device_init  575:bootmode don't load touch !
    /proc/bus/input/devices  ->  4 devices, none of them a touchscreen

bootmode 2 is MediaTek's RECOVERY_BOOT. The gate lives in adaptive-ts.ko, NOT in
focaltech_ft8057s_spi.ko where one would look first, and of the 206 modules in
the vendor_boot set it is the only one that contains the string.

WHAT IS PATCHED

`mtk_get_boot_mode` classifies the boot mode with two bitmasks:

    5c5c: lsl w8, #1, w3     w8 = 1 << bootmode
    5c60: mov w9, #0x52      bits 1,4,6 = META / FACTORY / ATE   -> return 2
    5c74: mov w9, #0x304     bits 2,8,9 = RECOVERY + 2 charging  -> return 1
    5c78: tst w8, w9 / b.eq  not in either set                   -> return 0

Return 0 is "load touch" and is what a normal boot yields. Changing 0x304 to
0x300 removes bit 2 (RECOVERY) and leaves bits 8 and 9 (KERNEL_POWER_OFF_CHARGING
and LOW_POWER_OFF_CHARGING) set, so recovery now takes the same path a normal
boot takes while touch stays correctly disabled during off-mode charging.

    MOVZ w9, #0x304   0x52806089
    MOVZ w9, #0x300   0x52806009      one byte: 0x89 -> 0x09 at offset 0x6c74

Nothing else changes. Size is identical, the __versions section is untouched so
module_layout stays 0x7c24b32d, and stock's modules carry no appended signature,
so there is none to invalidate.

PROVENANCE

Derived by disassembling itel's own stock module -- stock content plus our own
modification, which BLUEPRINT §2 permits. The banned tree also patches this
module (36 bytes, against stock's 131368-byte original), and that copy was read
only to establish that the gate was bypassable at all. Not one of its bytes is
used here, and it is vermagic 5.10.226 against our 5.10.237 in any case.

🔴 THIS IS HALF THE FIX. A patched module registers a perfect multitouch device
that never fires an interrupt, because the touch controller loads its firmware
at probe via request_firmware() and the recovery ramdisk has no /vendor/firmware
unless device.mk puts one there. Gate patched + firmware absent measures as:
"tp is in boot mode", 0 interrupts. See the PRODUCT_COPY_FILES block in
device.mk; the two belong together.

USAGE
    patch-touch-in-recovery.py <adaptive-ts.ko> [more.ko ...]     patch in place
    patch-touch-in-recovery.py --verify <adaptive-ts.ko> [...]    check only

Exit 0 if every file ends up patched, 1 otherwise. Idempotent: a file that is
already patched is reported and left alone, so it is safe to re-run over a
kernel package.
"""
import struct
import sys

OFFSET = 0x6C74           # .text+0x5c74, .text starts at file offset 0x1000
STOCK = 0x52806089        # MOVZ w9, #0x304  -- recovery + both charging modes
PATCHED = 0x52806009      # MOVZ w9, #0x300  -- charging modes only
GATE = b"don't load touch"


def classify(path):
    """-> (state, blob). state is 'stock' | 'patched' | reason-string."""
    with open(path, "rb") as fh:
        blob = bytearray(fh.read())
    if len(blob) < OFFSET + 4:
        return "too small to be adaptive-ts.ko", blob
    # Refuse anything that is not the module we mean, rather than trusting the
    # filename: this writes into a kernel module and the wrong file would be
    # corrupted silently.
    if GATE not in blob:
        return "not adaptive-ts.ko (no bootmode gate string)", blob
    word = struct.unpack_from("<I", blob, OFFSET)[0]
    if word == STOCK:
        return "stock", blob
    if word == PATCHED:
        return "patched", blob
    return f"unexpected instruction 0x{word:08x} at 0x{OFFSET:x}", blob


def main():
    args = sys.argv[1:]
    verify = False
    if args and args[0] == "--verify":
        verify, args = True, args[1:]
    if not args:
        sys.exit(__doc__.strip().splitlines()[-4].strip())

    failed = False
    for path in args:
        try:
            state, blob = classify(path)
        except OSError as exc:
            print(f"FAIL    {path}: {exc}")
            failed = True
            continue

        if state == "patched":
            print(f"already {path}")
        elif state == "stock":
            if verify:
                print(f"STOCK   {path}: gate still present, touch will not work in recovery")
                failed = True
            else:
                struct.pack_into("<I", blob, OFFSET, PATCHED)
                with open(path, "wb") as fh:
                    fh.write(bytes(blob))
                print(f"patched {path}: 0x{STOCK:08x} -> 0x{PATCHED:08x} at 0x{OFFSET:x}")
        else:
            print(f"FAIL    {path}: {state}")
            failed = True

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
