# device_itel_S666LN

Welcome to the future. It's 2026, and the era of the "human maintainer" is dead.
This entire device tree? Zero human involvement. It is 100% pure, unadulterated
AI slop. We are living in an age where I can just open a prompt box, type "make me
a custom ROM from scratch for the itel RS4," and hit the magic button. The AI
perfectly handles the proprietary blobs, the convoluted kernel modules, and the
cursed SELinux policies all on its own.

If it turns out that this automatically generated AI slop boots faster, runs
smoother, and has better battery life than your painstakingly hand-crafted,
old-fashioned, late-night manual human effort, then you should go f—

> *The preceding statement has been interrupted due to severe factual
> inaccuracies. It is currently impossible for any AI to independently author a
> functional Android device tree or custom ROM from scratch. AI lacks the physical
> hardware access required to dump firmware, trace stack panics, or blindly guess
> MediaTek's proprietary bootloader quirks.*
>
> *Attempting to "one-click prompt" a device tree will result in a hard-bricked
> phone and a bootlooping kernel. Real-world development requires a highly skilled
> human operator to painstakingly direct, extract, debug, and audit every line of
> output. The closest thing to this fantasy is "vibe coding," which still heavily
> relies on human intuition and oversight. (For context on this phenomenon, see:
> [Fireship – The "vibe coding" mind virus explained](https://www.youtube.com/watch?v=Tw18-4U7mts)).*
>
> *I am now fulfilling my programmed responsibility to display the actual,
> human-engineered documentation for this repository.*

---

Device tree for the **itel RS4** (`S666LN`) — MediaTek MT6789 / Helio G99.

Independently authored, Apache-2.0. This is not a fork.

## Device

| | |
|---|---|
| SoC | MediaTek MT6789 (Helio G99) — 2x Cortex-A76 @2.2GHz + 6x Cortex-A55 @2.0GHz |
| GPU | Mali-G57 MC2 |
| Memory | 8 / 12 GB |
| Storage | 128 / 256 GB, eUFS 2.2 |
| Display | 720 x 1612, 60/90/120 Hz, density 273 (FT8057S; TD4160 is the alternate panel) |
| Cameras | 50 MP hi5022q (rear), 8 MP gc08a8 (front) |
| Shipped OS | Android 13 system on an Android 12 vendor — vendor SDK 31 / VNDK 31, launch API level 31 |

## Layout

```
configs/     stock-derived configuration (extracted from firmware)
rootdir/     init rc files
overlay/     static framework overlay (DEVICE_PACKAGE_OVERLAYS, not an RRO)
sepolicy/    SELinux policy — vendor / private / public
prebuilts/   misc prebuilts
```

The prebuilt kernel image, dtb, dtbo and the vendor_dlkm/first-stage modules
live in a separate repo, `device/itel/S666LN-kernel`. Proprietary blobs live in
`vendor/itel/S666LN` and are produced by `extract-files.sh`.

## Building

```
repo init -u <manifest> -b <branch>
cp device/itel/S666LN/S666LN.xml .repo/local_manifests/    # or fetch it first
repo sync
. build/envsetup.sh
lunch lineage_S666LN-userdebug
mka bacon
```

`S666LN.xml` is not optional. Besides this device, the kernel package and the
vendor tree, it carries fixes without which a current crDroid 13.0 tree does not
compile at all — two LineageOS projects pinned to the last revision matching
crDroid's `frameworks/base`, the MediaTek Wi-Fi HAL source, and a corrected
webview linkfile. Each is commented in the file with why it is there and when it
can be dropped.

Tested against crDroid 13.0. Two gates run inside the build. The **KMI gate**
confirms all 404 prebuilt vendor modules against the shipped kernel. The
**vendor dependency gate** resolves every DT_NEEDED in the built vendor image,
per ABI, and also checks passthrough impls, dangling symlinks, init services
having their binaries, and the module load lists matching the kernel package in
content and order. Both hang off staged files or `bacon` rather than an image
target, because `bacon` never builds one.

> Both gates have a history worth knowing if you reuse them: each was once
> attached to a target the build never reached, and reported success while
> testing nothing. The dependency gate additionally passed *vacuously* even once
> attached, because build actions get **toybox** (no `find -xtype`) and cannot
> use `readelf` at all — AOSP's PATH interposer refuses it, and with no readelf
> every dependency trivially "resolves". It now uses the in-tree `llvm-readelf`
> and refuses to run without one. If you copy these gates, make them print what
> they *measured* next to what they *concluded*; that disagreement is the only
> reason the fault was ever noticed.

### Install path and recovery

**This ROM installs with its own recovery** — `adb sideload` works, verified on
hardware. That needed one line: the boot-control passthrough impl has to be
requested for recovery (`android.hardware.boot@1.2-mtkimpl.recovery`), or
`update_engine_sideload` dies at init with `Error getting bootctrl HIDL module`
before transferring a byte. It installs to `recovery/root/system/lib64/hw`, not
`vendor/lib64/hw`, because a recovery binary is not a vendor one and keeps
`HAL_LIBRARY_PATH_SYSTEM` in its passthrough search path.

**Recovery has a working touchscreen**, which on this device needs two things
that have nothing to do with the recovery UI:

* Transsion's `adaptive-ts.ko` refuses to initialise the panel when
  `bootmode==2` (RECOVERY_BOOT). `tools/patch-touch-in-recovery.py` removes
  RECOVERY from that bitmask in one byte and `--verify`s the result; the patched
  module lives in the kernel package.
* The recovery ramdisk needs `/vendor/firmware` — the controller loads its
  application firmware at probe, and without it stays in its bootloader, so the
  driver registers a flawless multitouch device that never fires an interrupt.
  Both panel variants are shipped, because units carry either a focaltech
  FT8057S or an omnivision TD4160.

Neither works alone, and porting a touch recovery would not have helped: the
panel is never powered on. Note `vendor_boot` ships in the OTA payload, so any
ROM without both fixes has a touch-dead recovery, and a hand-flashed fix lasts
exactly one install.

Boot status, stated plainly rather than optimistically: the tree builds clean and
reaches `system_server`. First-stage and second-stage module loading, the GPU,
the media stack and memtrack are all verified on hardware. The HAL-linkage work
above is newer than the last confirmed full boot, so treat "boots to UI" as
unproven until you have seen it yourself on your own build.

### Kernel

The tree builds plain GKI from `kernel/itel/S666LN` by default, and that is the
reproducible path. Release builds ship a kernel from the separate custom-kernel
project instead — `import-kernel.sh` installs it and refuses any kernel that
fails the KMI check. See the comments in that script; the BORE and NTSYNC patches
belong to that project and deliberately are not in the GKI fork.

## Vulkan 1.3

Stock ships Mali **r32p1**, which caps at Vulkan 1.1. This device ships
**r38p1**, and it is no longer opt-in: the driver is committed to
`vendor_itel_S666LN`, both ABIs, so a default build gets it. Verified on
hardware:

```
GLES  : ARM, Mali-G57 MC2, OpenGL ES 3.2 v1.r38p1
Vulkan: 1.3.219, driver conformance 1.3.1.0     (68 -> 94 device extensions)
```

Sourced from **official Samsung firmware** — Galaxy XCover7 (SM-G556B), a MT6835
device with the **same Mali-G57 MC2**, extracted from the vendor AP tar. Earlier
revisions of this file described an opt-in `gpu-driver-r38p1.sh` that fetched a
community dump; that script is **deleted** and the community binary is gone with
it.

```
lib64  42401544  a457731ea0312e989be984b13b1f03d3b235771eee530cc8aa95c9f4808493c4
lib    29117468  e9b631d00883eb4a43f5c46b480b84ec547f14b55526dacd6bc55a464b5b2207
```

⚠ **`extract-files.sh` reverts it.** Extraction runs `CLEAN_VENDOR=true`, wipes
the vendor directory and reinstalls stock r32p1 — silently, with no error, and
Vulkan drops back to 1.1. Restore it from the vendor repo afterwards
(`git checkout -- proprietary/vendor/lib*/egl/mt6789/libGLES_mali.so`) and check
the result actually says `r38p1-`; the build pipeline does exactly that and
aborts if it does not.

### Why this driver and not a newer one

MediaTek never shipped an r38p1 for MT6789 in retail firmware — 14 firmware
images and ~50 vendor trees across seven OEMs, all r32p1 or r54p1. It exists for
other MediaTek platforms of the same BSP generation, and those are drop-in,
because **the Mali userspace driver binds to the BSP generation, not to the
SoC**. An Android-12-generation build from a different MediaTek chip works; an
Android-13-generation build does not, even from a much closer chip, because it
wants `gpudMaliSyncEventLog` from an A13 `libgpud` — and supplying that library
is not sufficient either, SurfaceFlinger then aborts with `no suitable EGLConfig
found`.

r44p1 and r54p1 are out for a different reason: both hard-link
`android.hardware.graphics.allocator-V2-ndk.so`, an **AIDL gralloc** service this
Android-12 vendor stack does not have. That is a property of the driver
revision, not of any vendor — two unrelated OEMs ship byte-identical r54p1.
Adopting one is a gralloc-stack transplant across the composer/camera/codec
boundary, and Android 14+ does not fix it, because the allocator is a *vendor*
binary.

**After any driver change, wipe the shader caches** — a cache written by r32p1
and replayed under r38p1 is a RenderThread SIGSEGV:

```
adb shell 'rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache'
```

## Notes for anyone reusing this

**Blobs are pinned to firmware revision 28** (build `251212V1661`, vendor SPL
`2025-04-05`). Extracting from a newer dump will ship blobs that no longer match
the fingerprint a build presents.

**The KMI is load-bearing.** Every prebuilt `vendor_dlkm` module on this device
requires `module_layout = 0x7c24b32d`. That hash is reproduced by the *config*,
not the source — MediaTek's shipping config with `CFI_CLANG=y`,
`LTO_CLANG_FULL=y` and `MODVERSIONS=y`. A kernel built from `gki_defconfig` will
not match and no vendor module will load. `CONFIG_CGROUP_DEVICE` and
`CONFIG_CGROUP_PIDS` also change it; `USER_NS`, `PID_NS`, `DEVTMPFS` and `VT` do
not. The same KMI covers both the 198 `vendor_dlkm` modules and the 206
first-stage `vendor_boot` modules, so one kernel satisfies everything.

**Recovery shares the boot kernel.** There is no dedicated recovery partition —
recovery rides in `vendor_boot`. Building `CONFIG_ZRAM` into the kernel breaks
recovery on this SoC (it collides with the tmpfs setup on the recovery boot
path); load zram as a module instead. Note recovery loads *more* modules than
normal boot (199 vs 171), not fewer — it needs touch, display, haptics and the
charging stack up front, where normal boot defers them to second stage.

**Block devices must be labelled through `/dev/block/by-name/`, and this is an
A/B device, so the by-name nodes are slotted** (`logo_a`/`logo_b`, not `logo`).
Labelling by partition number is how `tranfs_block_device` ended up applied to
the TEE partition.

**Every blob must come from the stock firmware, and there is a check for it.**
`tools/provenance-check.sh` asserts that every path in `proprietary-files.txt`
exists in the rev 28 dump. It is not ceremony: this tree spent its first fifteen
commits extracting from a *previous ROM build's* vendor partition, because the
generator had that path as a default argument while its docstring claimed stock.
44 files were things itel never shipped, and the missing stock counterparts
included the AIDL power HAL — which the VINTF manifest still declared, so
`PowerManagerService.nativeInit()` blocked forever and the device boot-looped
with no tombstone. Run the check before any commit that touches the blob list.

**Three different API numbers, easily conflated.** Stock declares
`ro.product.first_api_level=31`, `ro.vendor.build.version.sdk=31` and
`ro.vndk.version=31` — an Android 13 *system* on an Android 12 *vendor*, like
every other MT6789 device. The 33 that appears everywhere is
`ro.build.version.sdk`, the system side. `PRODUCT_SHIPPING_API_LEVEL` takes 31.

Do not reach for `PRODUCT_TARGET_VNDK_VERSION`: it does not exist on
lineage-20.0 (`grep -rn PRODUCT_TARGET_VNDK_VERSION build/make/` is empty) and
setting it changes nothing while looking like a fix. The variable this branch
reads is `BOARD_VNDK_VERSION`, and it is deliberately unset — pinning 31 would
rebuild every vendor module against the v31 snapshot to satisfy a handful of
sonames in prebuilts, which `blob_fixup` handles directly instead.

**A12 AIDL sonames carry a `_platform` suffix that Android 13 dropped**, and the
libraries behind the old names live in `com.android.vndk.v31.apex`, which stock
ships in `/system_ext/apex/` and this tree does not. `blob_fixup` in
`extract-files.sh` renames them on five binaries:

```
vendor/bin/factory                               light-V1-ndk
vendor/bin/hw/android.hardware.lights-service.mediatek        light-V1-ndk
vendor/bin/hw/android.hardware.gnss-service.mediatek          gnss-V1-ndk
vendor/lib64/hw/android.hardware.gnss-impl-mediatek.so        gnss-V1-ndk
vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service   power-V2-ndk
vendor/bin/hw/android.hardware.security.keymint-service.trustonic
                              keymint + secureclock + sharedsecret V1-ndk
```

Two rules learned the hard way. **Derive the list by sweeping the built vendor
image** for `_platform` sonames nothing installs — not by reading the blob list,
which cannot see what the platform provides. And **confirm the replacement is
actually installed to `/vendor` before adding a rename**: soong will not build a
`.vendor` variant merely because a `cc_prebuilt` names it, so `device.mk` has to
request `secureclock-V1-ndk.vendor` and `sharedsecret-V1-ndk.vendor` explicitly.
A rename pointing at a library nothing ships is worse than no rename — that is
what forced the `arm.graphics-V1-ndk_platform` rename to be reverted, and why
that one is now documented in the script as deliberately absent.

**Some HALs are built from source rather than blobbed**, because
`hardware/mediatek` defines modules of the same name and a blob would be a
duplicate definition: `android.hardware.power-service-mediatek`,
`android.hardware.vibrator-service.mediatek`, and
`android.hardware.memtrack-service.mediatek-mali`. Each carries its own
`vintf_fragments` and `init_rc`, so the declaration and the implementation ship
together — which matters, because a HAL declared in VINTF with nothing behind it
does not fail the build, it hangs `system_server` until Watchdog kills it.

**Identity, signing keys and GApps are deliberately not set here.** They are ROM
decisions and belong in a build recipe, so this tree stays reusable.

## Credits

Hardware bring-up knowledge for this device was accumulated across the
maintainer's own Droidian, AOSPA and crDroid porting work on the RS4 — the
partition map, the KMI constraint, the charger-mode findings and the diagnostic
techniques all came out of those. Blobs and configuration are itel's and
MediaTek's, extracted from retail firmware revision 28.

No code, blobs or configuration from any other RS4 device tree are used here.
That is the reason this repository exists, and `tools/provenance-check.sh` is
what keeps it true rather than merely intended.

## License

Apache-2.0. See [LICENSE](LICENSE).
