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
| Shipped OS | Android 13 — vendor built at SDK 33 / VNDK 33, launch API level 31 |

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

Tested against crDroid 13.0. Build verified end to end on 2026-08-05:
`crDroidAndroid-13.0-20260805-S666LN-v9.20.zip`, with the KMI gate confirming all
404 prebuilt vendor modules against the shipped kernel.

### Kernel

The tree builds plain GKI from `kernel/itel/S666LN` by default, and that is the
reproducible path. Release builds ship a kernel from the separate custom-kernel
project instead — `import-kernel.sh` installs it and refuses any kernel that
fails the KMI check. See the comments in that script; the BORE and NTSYNC patches
belong to that project and deliberately are not in the GKI fork.

## Vulkan 1.3

Stock ships Mali **r32p1**, which caps at Vulkan 1.1. This tree runs **r38p1**,
verified on hardware:

```
GLES  : ARM, Mali-G57 MC2, OpenGL ES 3.2 v1.r38p1
Vulkan: 1.3.219, driver conformance 1.3.1.0
```

MediaTek never shipped an r38p1 for MT6789 in retail firmware — 14 firmware
images and ~50 vendor trees across seven OEMs were checked, all r32p1 or r54p1.
It does exist for other MediaTek platforms of the same BSP generation, and those
are drop-in compatible, because **the Mali userspace driver binds to the BSP
generation, not to the SoC**. An Android-12-generation build from a different
MediaTek chip works. An Android-13-generation build does not, even from a much
closer chip, because it wants `gpudMaliSyncEventLog` from an A13 `libgpud`;
supplying that library is not sufficient either — SurfaceFlinger then aborts with
`no suitable EGLConfig found`.

`gpu-driver-r38p1.sh` fetches and checksum-verifies the driver. Run it **after
every `extract-files.sh`** — extraction defaults to `CLEAN_VENDOR=true`, wipes the
vendor directory and silently restores stock r32p1, dropping Vulkan back to 1.1
with no error.

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

**Three different API numbers, easily conflated.** Stock declares
`ro.product.first_api_level=31` (the device launched on Android 12),
`ro.vendor.build.version.sdk=33` and `ro.vndk.version=33` (the vendor was built
at Android 13). `PRODUCT_SHIPPING_API_LEVEL` takes the launch level, 31.
`PRODUCT_TARGET_VNDK_VERSION` is deliberately **unset**: the vendor is VNDK 33,
which matches the platform on this branch, and the nine blobs that want older
VNDK ship `libutils-v31.so`, `libhidlbase-v31.so`, `libbinder-v31.so`,
`libutils-v32.so` and `libstagefright_foundation-v32.so` inside the vendor
partition itself. Pinning a snapshot is neither needed nor correct.

**itel is unusual among MT6789 phones.** Infinix, Tecno, Xiaomi and Samsung all
ship an Android-12 vendor under a newer system; itel actually rebased theirs to
Android 13 — while still carrying A12-era AIDL sonames, which `blob_fixup` in
`extract-files.sh` renames (`arm.graphics-V1-ndk_platform.so` →
`arm.graphics-V1-ndk.so`, likewise for the light HAL). Those five renames across
five files are derived by scanning the blobs' own `DT_NEEDED`; the command to
re-derive them after a firmware bump is in the script.

**Identity, signing keys and GApps are deliberately not set here.** They are ROM
decisions and belong in a build recipe, so this tree stays reusable.

## Credits

Hardware bring-up knowledge for this device was accumulated across the Droidian,
AOSPA and crDroid ports of the RS4. Blobs and configuration are itel's and
MediaTek's.

## License

Apache-2.0. See [LICENSE](LICENSE).
