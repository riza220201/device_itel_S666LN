# device_itel_S666LN

Welcome to the future. It's 2026, and the era of the "human maintainer" is dead.
This entire device tree? Zero human involvement. It is 100% pure, unadulterated
AI slop. We are living in an age where I can just open a prompt box, type "make me
a custom ROM from scratch for the itel RS4," and hit the magic button. The AI
perfectly handles the proprietary blobs, the convoluted kernel modules, and the
cursed SELinux policies all on its own. Android 12 vendor blobs on Android 16,
with no VNDK left to hide behind? It simply vibes the ABI into compatibility.

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
> *As for "vibing the ABI": moving this vendor partition from Android 13 to
> Android 16 meant measuring every undefined symbol in 2,244 vendor binaries
> against the libraries that actually exist on the new system. The first build to
> get as far as 99% stopped on 63 separate walls, and every one of them needed a
> measured answer. Vibes closed none of them.*
>
> *I am now fulfilling my programmed responsibility to display the actual,
> human-engineered documentation for this repository.*

---

Device tree for the **itel RS4** (`S666LN`) — MediaTek MT6789 / Helio G99.

Independently authored, Apache-2.0. This is not a fork.

This is the **`lineage-23.2`** branch: LineageOS 23.2 (Android 16), built and
tested as **AICP w16.2**. The Android 13 tree (LineageOS 20, tested with crDroid
13.0) lives on `lineage-20.0`.

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

## Status, stated plainly rather than optimistically

AICP w16.2 (`aicp_S666LN-bp4a-userdebug`) **builds clean through both in-build
gates**, and a symbol-level check of the built vendor image finds nothing
unresolved (below). **Nothing on this branch has been booted on hardware yet.**
Wherever this README says something works on Android 16 it means "builds and
links"; where something was proven on a phone, it names the branch it was proven
on.

## Layout

```
configs/      stock-derived configuration (extracted from firmware); configs/kernel/ = kernel config fragments
rootdir/      init rc files
overlay/      static framework overlay (DEVICE_PACKAGE_OVERLAYS, not an RRO)
sepolicy/     SELinux policy — vendor / private / public
shims/        ABI thunks for stock Android 12 blobs on Android 16 (see "Route L")
prebuilts/    vndk31/ = the few Android 12 libraries copied whole from AOSP's v31 snapshot
mali/         libr54shim: three symbols the r54p1 GPU driver needs from an older libged/libgpu_aux
jamesdsp/     the JamesDSP effect, built from source
tools/        the gates and the measuring tools (route-l-abi-check.py, vendor-deps-check.sh, ...)
extract-files.py, setup-makefiles.py   blob extraction (extract-utils, python)
proprietary-files.txt                  stock rev 28 blobs
proprietary-files-r54p1.txt            the Mali r54p1 set, hash-pinned (see "GPU")
symlinks.mk   634 /vendor/lib*/foo.so -> mt6789/foo.so links, recreated from stock
product_common.mk, aicp_S666LN.mk, lineage_S666LN.mk   one device, two ROM products
```

The kernel image, dtb, dtbo and the vendor_dlkm/first-stage modules live in a
separate repo, `device/itel/S666LN-kernel`. Proprietary blobs live in
`vendor/itel/S666LN` and are produced by `extract-files.py`.

## Building

```
repo init -u https://github.com/AICP/platform_manifest.git -b w16.2 --git-lfs --depth=1 --no-clone-bundle
mkdir -p .repo/local_manifests
cp S666LN.xml .repo/local_manifests/        # this repo's S666LN.xml; fetch it first
repo sync -c --no-tags --no-clone-bundle
. build/envsetup.sh
lunch aicp_S666LN-bp4a-userdebug            # lineage_S666LN-bp4a-userdebug is defined too, untested
m bacon
```

`S666LN.xml` brings this device, the kernel package, the vendor tree, the GKI
kernel source (for headers, and for the fallback below), `hardware/mediatek` and
`device/mediatek/sepolicy_vndr`. It is byte-identical to the one in the build
recipe, **[itel_rs4_AICP](https://github.com/riza220201/itel_rs4_AICP)**, which
is the supported way to build: it verifies the sync, applies four framework
changes this device needs (among them the libgui hook that tells MediaTek's GED
a frame happened — without it the GPU never leaves the OPP it powered on at),
and builds detached with a verdict file. A bare `m bacon` builds too; it just
does not get those framework changes.

A fresh build is **210,543 ninja actions**. The tree was brought up on a 14 GiB
home box, where soong's analysis alone took 55 minutes in swap; the same build
on a rented 192-thread server took about 25 minutes from sync check to OTA zip,
with remote execution.

Two gates run inside the build, and a release is not a release unless both pass:

* The **KMI gate** confirms all 404 prebuilt vendor modules (198 vendor_dlkm,
  206 vendor_boot) against the kernel being shipped — the imported one, or the
  source-built fallback.
* The **vendor dependency gate** resolves every DT_NEEDED in the built vendor
  image, per ABI, and checks passthrough impls, dangling symlinks, init services
  having their binaries, renamed executables keeping their SELinux types, and the
  module load lists matching the kernel package in content and order.

A third check, `tools/route-l-abi-check.py`, runs over the built image by hand
and looks at every undefined *symbol*, which neither gate can see (next section).

> Both gates have a history worth knowing if you reuse them, and this branch
> added a chapter. Each was once attached to a target the build never reached,
> and reported success while testing nothing. The dependency gate also passed
> *vacuously* once attached, because build actions cannot use `readelf` at all —
> AOSP's PATH interposer refuses it, and with no readelf every dependency
> trivially "resolves". It uses the in-tree `llvm-readelf`, and on Android 16 it
> had to learn a new path to it (`llvm-binutils-stable/`; `clang-latest/` is
> gone). Then the KMI gate turned out never to have waited for a kernel built
> from source: its prerequisite was `$(TARGET_PREBUILT_INT_KERNEL)`, which the
> kernel makefile defines *after* this tree's makefiles are parsed — and a
> rule's prerequisites expand at parse time. It expanded to nothing, so the gate
> ran before the kernel existed. If you copy these gates, make them print what
> they *measured* next to what they *concluded*; that disagreement is the only
> reason each fault was noticed.

## Route L: an Android 12 vendor on Android 16, with no VNDK

Stock ships an Android 12 vendor partition (VNDK 31). Android 16 has no VNDK
any more: no `ro.vndk.version`, no VNDK apex, no `/vendor/lib*/vndk`. A vendor
process simply links what is in `/odm/${LIB}`, `/vendor/${LIB}` (plus `hw/` and
`egl/`) and the LLNDK libraries from `/system`. The build installs Android 16's
own vendor variants of the former VNDK libraries there, so a stock blob built
against Android 12's `libbase` gets Android 16's `libbase` — and wherever that
ABI moved, the blob does not load.

Which blobs break is a measurement, not a guess, and soong's own `check_elf` is
not that measurement: it checks against LLNDK *stubs* (it fails thirteen arm32
codec libraries over `__aeabi_*` symbols the real apex libc exports), it only
looks at direct DT_NEEDED entries, it never symbol-checks a library that failed
earlier on a soname, and it never asks what a replacement library itself needs.
`tools/route-l-abi-check.py` models the vendor namespace the way linkerconfig
builds it, walks every vendor ELF's DT_NEEDED closure against the real
libraries, and reports missing libraries, missing symbol versions, symbols
nothing visible exports, and underlinked blobs — then names the library whose
Android 12 build exported each missing symbol and closes over what *that* copy
would need.

On the build that stopped at 99% it found the real breaks behind those walls; on
the current image it reads **0 missing, 0 version, 0 broken, 0 underlinked,
across 1,362 lib64 and 882 lib ELFs.** Each break got the narrowest fix that
keeps one copy of each library per process, in this order of preference:

**1. A shim** (`shims/`), where Android 16 only renamed a symbol or changed an
argument type. The blob gets one extra DT_NEEDED on a tiny library that exports
the old symbol and forwards to the new function:

| shim | Android 12 symbol | Android 16 target | consumers |
|---|---|---|---|
| `libshim_base` | `Trim`/`Basename`/`WriteStringToFd(const std::string&)` | the `std::string_view` versions | libnvram (SIM), sensors, USB, codec2, boot impl, … (13 lib64 + 3 lib) |
| `libshim_crypto` | `sk_dup`, `CBS_init` | `OPENSSL_sk_dup`; `CBS_init` is now inline | hostapd, wpa_supplicant |
| `libshim_processgroup` | `SetTaskProfiles` (C linkage in A12) | the same overload, C++ linkage | hwcomposer, libutils-v31 |
| `libshim_ui` | `GraphicBufferMapper::lock(…, int*, int*)`, `unlock(handle)` | `lock()` returning bytes-per-pixel/stride; `unlock(handle, nullptr)` | the stock codec2 stack |
| `libshim_bqhelper` | `getHGraphicBufferProducer()` | `getHGraphicBufferProducer_V1_0()` | codec2_hidl@1.0/1.1/1.2 |
| `libshim_hidlbase` | `details::gBnConstructorMap` (a **data** symbol) | `getBnConstructorMap()` | the goodix fingerprint HIDL library |

Data cannot be thunked, so `libshim_hidlbase` exports the old variable's name as
a GNU IFUNC whose resolver returns the address of libhidlbase's *real* map —
bionic calls an IFUNC's resolver for every relocation against it, data
relocations included — so the goodix library and libhidlbase share one map. The
first version owned a second map and interposed `getBnConstructorMap()`; on the
phone that split in two (bionic's global group is the executable alone, so the
`dlopen`ed goodix library resolved past the shim) and the service aborted. The
map's class body is identical in the Android 12 and 16 headers. Every thunk is
written against both headers, with the A12 symbol spelled out via
`asm("<mangled name>")`.

**2. A v31 copy**, where the fix is a whole Android 12 library: AOSP's own
`prebuilts/vndk/v31` files, under a distinct name and soname (`libutils-v31`,
…) so they cannot be mistaken for Android 16's. Used for the MediaTek PQ
service (an Android 12 libutils RefBase assertion, measured on hardware on
lineage-20.0), and for the Trustonic KeyMint service, which subclasses
`IRemotelyProvisionedComponent` V1 — moved out of the keymint library in
Android 14 — and so keeps its stock `_platform` AIDL libraries, from v31,
unrenamed. That is what the Android 13 tree ran, too.

**3. A `-stock` copy**, where stock's own vendor library is the only thing with
the ABI — or where the symbols match and the *layout* does not: the composer
resources libraries (`ComposerResources` is 112 bytes in Android 12 and 96 in
Android 16, and stock's HWC service bakes the old layout in through header-inline
code; the first boot died there with no display), the Android 12 codec2
generation (eleven libraries moving as one),
`libpcap` (for `libpkm`), `libalsautils`, `libeffectsconfig`, the Wi-Fi HAL
library, `ese_spi_nxp`, `libmtk_bsg` and the boot-control impl. Each carries its
own file name as soname — otherwise the first one loaded wins the name for the
whole process.

Two things this cannot see, said here so nobody reads "0 broken" as more than it
is: a struct whose *layout* changed while its symbols stayed (BoringSSL's public
structs are the obvious candidate, for Wi-Fi), and anything only exercised at
runtime. That is what the first boot is for.

## Kernel

The tree ships the kernel from the separate custom-kernel project (v9 vanilla:
Neutron clang, BORE, NTSYNC), committed in `device_itel_S666LN-kernel`'s `prebuilt/`.
`import-kernel.sh` installs it and refuses any kernel that is not byte-identical
to the published one or that fails the KMI check against the vendor modules.

When the kernel package carries no import at all, the build falls back to plain
GKI built from `kernel/itel/S666LN` (`s666ln_defconfig`, `clang-r416183b` from
LineageOS's manifest) and says so loudly: the tree still builds from public
sources alone. That kernel reports the GKI source's own default version string
(`5.10.<sublevel>-g<commit>`), not the custom kernel's name — `s666ln_defconfig`
is shared with the kernel project, so the fallback merges
`configs/kernel/gki-default-version.config` back to GKI's defaults. It loads the
same vendor modules (the KMI gate passes it on all 404) but has none of v9's
additions; the BORE and NTSYNC patches belong to the kernel project and
deliberately are not in the GKI fork. A partial import is an error.

## GPU: Mali r54p1

Stock ships Mali **r32p1** (Vulkan 1.1). This branch ships **r54p1**, both ABIs,
taken from **Samsung's official firmware for the SM-A175F** — eight files,
listed with their hashes in `proprietary-files-r54p1.txt` and pinned in the
vendor tree, because `extract-files.py` would otherwise put stock's driver back
silently (it prints `r54p1 gate: 8 files, all match their pins` or fails). The
matching kernel driver (kbase) and `gpufreq` are built from Samsung's kernel
source against v9 and ship in the kernel package.

r54p1 needs three symbols stock rev 28 does not have (two from `libged`, one
from `libgpu_aux`); `mali/libr54shim` provides them. Its `libgpud` also NEEDs
`graphics.common-V6-ndk` while importing nothing from it, which next to
`libgralloctypes`' V7 is a soong error, so that NEEDED is dropped.

On the Android 13 line, r54p1 on this same Android 12 vendor booted with
**Vulkan 1.3.303** and 145 device extensions (148 in later builds), EGL 1.5. On
this branch it is committed and linked, and not yet measured.

**After any driver change, wipe the shader caches** — a cache written by one
driver and replayed under another is a RenderThread SIGSEGV:

```
adb shell 'rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache'
```

## Install path and recovery

The ROM's own recovery rides in `vendor_boot`. On lineage-20.0, `adb sideload`
was verified on hardware once the boot-control passthrough impl was requested
for recovery. On this branch recovery uses LineageOS's AIDL boot HAL
(`android.hardware.boot-service.mediatek_recovery`) while `/vendor` keeps
stock's HIDL one — **a sideload round trip on Android 16 is unproven**.

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
not. Nor does the version string: with `MODVERSIONS` the module loader skips
the release part of vermagic.

**Recovery shares the boot kernel.** There is no dedicated recovery partition —
recovery rides in `vendor_boot`. Building `CONFIG_ZRAM` into the kernel breaks
recovery on this SoC (it collides with the tmpfs setup on the recovery boot
path); load zram as a module instead. Recovery loads *more* modules than normal
boot (199 vs 171), not fewer.

**Block devices must be labelled through `/dev/block/by-name/`, and this is an
A/B device, so the by-name nodes are slotted** (`logo_a`/`logo_b`, not `logo`).

**Every blob must come from the stock firmware, and there is a check for it.**
`tools/provenance-check.sh` asserts that every path in `proprietary-files.txt`
exists in the rev 28 dump. This tree once spent fifteen commits extracting from a
*previous ROM build's* vendor partition because a generator had that path as a
default argument; 44 files were things itel never shipped, and the device
boot-looped with no tombstone. The only non-stock blobs are the r54p1 set, in
their own list with their own pins.

**Most vendor libraries live in `/vendor/lib*/mt6789/`, and the linker does not
search there.** Stock places a symlink beside each one in `/vendor/lib*/`;
`symlinks.mk` recreates all 634. A tree without them installs the libraries and
then cannot load them, and the failure looks like a missing library rather than
a missing link.

**`_platform` AIDL sonames have nothing behind them on Android 16.**
`extract-files.py` rewrites six interfaces to the frozen `-V<N>-ndk` libraries
Android 16 still generates (light, gnss, power-V2, memtrack, vibrator,
keystore2), leaves four that are stock's own files, and leaves the Trustonic
KeyMint service on its `_platform` names with the v31 files (Route L, above).
Every rewrite is followed by a check that the old name is really gone —
`patchelf --replace-needed` is a silent no-op when the name is absent.

**Android 16 traps met on the way, in case they save you a build:**

* soong's `check_elf` runs against LLNDK *stubs*. Before calling a blob broken,
  check the real library (apex bionic, system `libnativewindow`); this tree
  disables the check only for the sixteen modules where the stub is narrower.
* `host_init_verifier` only knows HIDL interfaces that have an `hidl_interface`
  module, and it reports them in *alphabetical* order, not file order. Vendor-only
  interface lines on four disabled services were dropped; hostapd keeps its four
  `android.hardware` lines, which are what lazy-start the hotspot.
* The C default is `gnu23`, and clang errors on what used to warn (JamesDSP
  needed three source fixes).
* extract-utils' own fixup merging folds a repeated file into the *first* fixup
  object, which a tuple key shares with every other file in it;
  `extract-files.py` builds a fresh fixup per file instead.
* `patchelf --add-needed` *prepends*. The hidlbase shim relies on that, and
  extraction fails if it ever stops being true.
* The build writes `modules.load` in two spellings (`x.ko` from build/make, bare
  `x` when the kernel is built from source); modprobe reads both alike, so the
  dependency gate compares them the way modprobe does.
* Never test a kernel-mode switch (import vs source) in the out directory you
  release from: source mode leaves modules and file lists behind in four places
  that import mode never rewrites.

**Three different API numbers, easily conflated.** Stock declares
`ro.product.first_api_level=31`, `ro.vendor.build.version.sdk=31` and
`ro.vndk.version=31` — an Android 13 *system* on an Android 12 *vendor*, like
every other MT6789 device. `PRODUCT_SHIPPING_API_LEVEL` takes 31. On this branch
the vendor manifest's target FCM level is 6, which Android 16 still accepts.

**Identity, signing keys and GApps are deliberately not set here.** They are ROM
decisions and belong in a build recipe, so this tree stays reusable.

## Credits

Hardware bring-up knowledge for this device was accumulated across the
maintainer's own Droidian, AOSPA and crDroid porting work on the RS4 — the
partition map, the KMI constraint, the charger-mode findings and the diagnostic
techniques all came out of those. Blobs and configuration are itel's and
MediaTek's, extracted from retail firmware revision 28. The Mali r54p1 userspace
is from Samsung's retail firmware for the SM-A175F, and the GPU kernel modules
are built from Samsung's kernel source release. The Android 12 libraries in
`prebuilts/vndk31` are AOSP's own v31 VNDK snapshot. Built on LineageOS and
AICP.

No code, blobs or configuration from any other RS4 device tree are used here.
That is the reason this repository exists, and `tools/provenance-check.sh` is
what keeps it true rather than merely intended.

## License

Apache-2.0. See [LICENSE](LICENSE).
