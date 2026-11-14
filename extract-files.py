#!/usr/bin/env -S PYTHONPATH=../../../tools/extract-utils python3
#
# SPDX-FileCopyrightText: 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Extracts the proprietary blobs this device needs from a stock dump.
# The blobs themselves are itel/MediaTek's; this script only lists and copies
# them. Pin the source to firmware revision 28 (build 251212V1661) -- a newer
# dump would ship blobs that no longer match the fingerprint the ROM presents.
#
#     ./extract-files.py <dump of stock rev 28>      (a directory with vendor/ ...)
#
# lineage-23.2 port of the lineage-20.0 extract-files.sh. Every fixup below was
# MEASURED there, on hardware; each keeps a one-paragraph reason here, and the
# full record (crash lines, closures, build numbers) stays in
#     git show lineage-20.0:extract-files.sh
#
# WHAT CHANGED FOR ANDROID 16 (route L, 2026-11-13)
#   There is no VNDK on this branch: no ro.vndk.version, no VNDK apex, no
#   /vendor/lib*/vndk. The vendor namespace resolves everything from /vendor/lib*,
#   where the build installs A16's own vendor variants of the former-VNDK libs.
#   Consequences here:
#   * An `-ndk_platform` AIDL soname has no A16 library behind it: A16 has
#     neither the spelling nor (unlike lineage-20's hardware/lineage/compat) a
#     forwarding library for it. Six interfaces are rewritten to the frozen
#     `-V<N>-ndk` library A16 still generates (light, gnss, power-V2, memtrack,
#     vibrator, keystore2; aidl_api/<iface>/<N> present for each); four are
#     stock's own files and stay (arm.graphics, libneuron_platform, trannet,
#     power-V1); the Trustonic KeyMint service keeps its three and gets the v31
#     files (see below).
#   * A stock blob whose former-VNDK ABI broke between A12 and A16 gets a
#     `lib*-v31.so` (AOSP prebuilts/vndk/v31, soname rewritten, device tree
#     prebuilts/vndk31) -- or, where A16 only renamed a symbol or changed an
#     argument type, a thunk library (shims/). Which blobs, is measured --
#     tools/route-l-abi-check.py over a built image -- not copied from the A13
#     list. The pq group below is the one carried over: measured on hardware.
#   * extract-utils now writes shared_libs from each blob's DT_NEEDED and the
#     build runs check_elf on them, so a soname nothing provides is a BUILD error
#     here, not a boot loop.

import hashlib
import sys
from os import path

from extract_utils.elf import file_needs_lib
from extract_utils.elf_parser import ELFFile
from extract_utils.file import File
from extract_utils.fixups_blob import (
    BlobFixupCtx,
    blob_fixup,
    blob_fixups_user_type,
)
from extract_utils.fixups_lib import (
    lib_fixups,
    lib_fixups_user_type,
)
from extract_utils.main import (
    ExtractUtils,
    ExtractUtilsModule,
)
from extract_utils.utils import file_path_sha1

# The device tree imports this vendor namespace and this one imports it back:
# blobs depend on the device tree's lib*-v31 modules (prebuilts/vndk31). Soong
# namespace imports are plain search lists, mutual imports are allowed
# (build/soong/android/namespace.go FindNamespaceImports).
namespace_imports = [
    'device/itel/S666LN',
    'hardware/mediatek',
]

# No lib_fixups of our own. lineage-23.2's first answer to libalsautils lived here
# (;MODULE_SUFFIX=_vendor + lib_fixup_vendor_suffix): it cleared soong's
# "partition is different: system(libalsautils) != vendor(prebuilt_libalsautils)"
# but not kati -- A16's libalsautils is vendor_available, so its vendor variant
# always gets an install rule at /vendor/lib*/libalsautils.so, and a renamed
# MODULE still collided on the PATH ("overriding commands for target
# .../vendor/lib64/libalsautils.so", 2026-11-13). The blob is now
# libalsautils-stock.so; see blob_fixups.
lib_fixups: lib_fixups_user_type = {
    **lib_fixups,
}


def must_not_need(*libs: str):
    """Fail extraction if a rewrite left any of these sonames behind.

    patchelf --replace-needed is a silent no-op when the name is absent, so a
    stale fixup would otherwise pass and leave exactly the defect it exists for.
    """

    def check(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        for lib in libs:
            if file_needs_lib(file_path, lib):
                raise AssertionError(f'{file.dst}: still needs {lib} after the fixup')

    return check


def must_contain(text: str):
    """Fail extraction if a regex edit of a text file did not land."""

    def check(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        with open(file_path) as f:
            if text not in f.read():
                raise AssertionError(f'{file.dst}: "{text}" missing -- pattern stale')

    return check


def platform_to_ndk(*pairs: tuple[str, str]) -> blob_fixup:
    """`<iface>-V<N>-ndk_platform.so` -> `<iface>-V<N>-ndk.so`, then prove it."""
    fixup = blob_fixup()
    for iface, version in pairs:
        fixup = fixup.replace_needed(
            f'{iface}-V{version}-ndk_platform.so', f'{iface}-V{version}-ndk.so'
        )
    return fixup.call(
        must_not_need(*(f'{i}-V{v}-ndk_platform.so' for i, v in pairs)),
        need_tmp_dir=False,
    )


# --- the A12 codec2 generation, shipped renamed -------------------------------
# With an A12 vendor the MTK C2 HAL needs A12 partners; the platform's copies
# crash-looped it (`hardware::details::check`). These are AOSP libraries soong
# builds vendor variants of regardless, so stock's ship under distinct names
# (`-stock`), SONAME patched too (else the first loaded wins the name for the
# whole process). The eleven move as ONE generation: proven both directions on
# hardware (stock libcodec2_vndk + platform libcodec2_hidl fails on
# `_C2FenceFactory::CreateNativeHandle`).
C2_STOCK_LIBS = [
    'android.hardware.media.c2@1.0',
    'android.hardware.media.c2@1.1',
    'android.hardware.media.c2@1.2',
    'libcodec2_hidl@1.0',
    'libcodec2_hidl@1.1',
    'libcodec2_hidl@1.2',
    'libcodec2_hidl_plugin',
    'libcodec2_vndk',
    'libcodec2_soft_common',
    'libsfplugin_ccodec_utils',
    'libstagefright_bufferpool@2.0.1',
]


def c2_stock_repoint() -> blob_fixup:
    fixup = blob_fixup()
    for lib in C2_STOCK_LIBS:
        fixup = fixup.replace_needed(f'{lib}.so', f'{lib}-stock.so')
    return fixup.call(must_not_need(*(f'{lib}.so' for lib in C2_STOCK_LIBS)), need_tmp_dir=False)


C2_STOCK_FILES = tuple(f'vendor/lib64/{lib}-stock.so' for lib in C2_STOCK_LIBS)

# Every /vendor consumer of libcodec2_vndk.so, enumerated on hardware: the C2
# service and the MTK component libraries it dlopens.
C2_CONSUMERS = (
    'vendor/bin/hw/android.hardware.media.c2@1.2-mediatek-64b',
    'vendor/lib64/libcodec2_mtk_c2store.so',
    'vendor/lib64/libcodec2_mtk_vdec.so',
    'vendor/lib64/libcodec2_mtk_venc.so',
    'vendor/lib64/libcodec2_soft_mtk_alacdec.so',
    'vendor/lib64/libcodec2_soft_mtk_apedec.so',
    'vendor/lib64/libcodec2_soft_mtk_imaadpcmdec.so',
    'vendor/lib64/libcodec2_soft_mtk_mp3dec.so',
    'vendor/lib64/libcodec2_soft_mtk_msadpcmdec.so',
    'vendor/lib64/libcodec2_vpp_qt_plugin.so',
    'vendor/lib64/libcodec2_vpp_rs_plugin.so',
)

c2_stock_self = blob_fixup().fix_soname()
c2_stock_self.merge(c2_stock_repoint())

blob_fixups: blob_fixups_user_type = {
    # ---- `-ndk_platform` -> frozen `-V<N>-ndk` (A16 has no _platform names) ----
    # factory + lights service: the light HAL. Lights is boot-blocking --
    # LightsService waitForDeclaredService() holds system_server's main thread.
    ('vendor/bin/factory', 'vendor/bin/hw/android.hardware.lights-service.mediatek'):
        platform_to_ndk(('android.hardware.light', 1)),
    ('vendor/bin/hw/android.hardware.gnss-service.mediatek',
     'vendor/lib64/hw/android.hardware.gnss-impl-mediatek.so'):
        platform_to_ndk(('android.hardware.gnss', 1)),
    # The AIDL IPower/default provider -- its absence boot-looped the device
    # (2026-08-10: PowerManagerService.nativeInit blocked, Watchdog at ~73 s).
    ('vendor/lib64/android.hardware.power-service-mediatek.so',
     'vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service'):
        platform_to_ndk(('android.hardware.power', 2)),
    # NEW on lineage-23.2. lineage-20 served these from hardware/lineage/compat
    # forwarding libraries (or the v31 set); A16 has neither.
    # NOT the Trustonic KeyMint service (the keybox's HAL: Play Integrity and
    # e-KYC hang off it): it subclasses IRemotelyProvisionedComponent V1, which
    # A14 moved out of the keymint library, so a rewrite to keymint-V1-ndk leaves
    # six symbols unresolved (tools/route-l-abi-check.py). It keeps its stock
    # `_platform` NEEDED and gets the v31 files (prebuilts/vndk31), as on A13.
    'vendor/bin/hw/android.hardware.memtrack-service.mediatek':
        platform_to_ndk(('android.hardware.memtrack', 1)),
    'vendor/bin/hw/android.hardware.vibrator-service.mediatek-stock':
        platform_to_ndk(('android.hardware.vibrator', 2)),
    'vendor/lib64/libkeystore-engine-wifi-hidl.so':
        platform_to_ndk(('android.system.keystore2', 1)),

    # ---- former-VNDK ABI: lib*-v31 (route L) ---------------------------------
    # Measured on hardware 2026-08-11, crash-looping every ~5 s with no denial
    # and no missing symbol: pq@2.2-service 'incStrongRequireStrong() ... isn't
    # already owned' (a libutils RefBase assertion: two libutils). Renamed PER
    # PROCESS -- libutils/libhidlbase/libcutils are loaded into whatever
    # dlopens them, so a service and its passthrough impl move together.
    # The rest of the -v31 set is measured by v31-delta-check.py on the first
    # build, not guessed (camerahalserver, c2, thermal are the known suspects).
    ('vendor/bin/hw/vendor.mediatek.hardware.pq@2.2-service',
     'vendor/lib/hw/mt6789/vendor.mediatek.hardware.pq@2.15-impl.so',
     'vendor/lib64/hw/mt6789/vendor.mediatek.hardware.pq@2.15-impl.so'): blob_fixup()
        .replace_needed('libutils.so', 'libutils-v31.so')
        .replace_needed('libhidlbase.so', 'libhidlbase-v31.so')
        .replace_needed('libcutils.so', 'libcutils-v31.so'),

    # ---- stock pairs: a stock blob must load stock's partner, not A16's ------
    # libaudiofoundation.so is loaded by the audio service + impls and NEVER
    # used (0 symbols), and it references _ZTVN7android5media11AudioDeviceE,
    # which exists nowhere in stock. Repointing it at liblog.so (already loaded,
    # 0 symbols taken) prunes seven libraries out of the process -- including
    # libaudioclient_aidl_conversion, the one that killed build 46. Proven live
    # 2026-08-13 on a KSU overlay, whole boot.
    ('vendor/bin/hw/android.hardware.audio.service.mediatek',
     'vendor/lib/hw/android.hardware.audio@6.0-impl-mediatek.so',
     'vendor/lib64/hw/android.hardware.audio@6.0-impl-mediatek.so',
     'vendor/lib/hw/android.hardware.audio@7.0-impl-mediatek.so',
     'vendor/lib64/hw/android.hardware.audio@7.0-impl-mediatek.so'): blob_fixup()
        .replace_needed('libaudiofoundation.so', 'liblog.so')
        .call(must_not_need('libaudiofoundation.so'), need_tmp_dir=False),
    # nfc_nci_nxp.so needs global-namespace `Mutex::~Mutex()` (_ZN5MutexD1Ev),
    # defined only by stock's ese_spi_nxp.so (131,520 B), not the source build.
    ('vendor/lib64/nfc_nci_nxp.so', 'vendor/bin/hw/android.hardware.nfc@1.2-service'):
        blob_fixup().replace_needed('ese_spi_nxp.so', 'ese_spi_nxp-stock.so'),
    # Stock's boot-control impl (a source build at A13 needed a v33-only
    # Tokenize and hung build 67's predecessor at the logo); libmtk_bsg renamed
    # because hardware/mediatek owns the module name.
    'vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so':
        blob_fixup().replace_needed('libmtk_bsg.so', 'libmtk_bsg-stock.so'),
    # Stock's Wi-Fi HAL powers the chip through /dev/wmtWifi; the platform's
    # libwifi-hal cannot (0 wmtWifi strings, 77 KB vs 201 KB). Proven build 57.
    'vendor/bin/hw/android.hardware.wifi@1.0-service-stock':
        blob_fixup().replace_needed('libwifi-hal.so', 'libwifi-hal-stock.so'),
    # Stock's effects factory must use stock's config parser: the A13 one's
    # struct layout moved and strdup read library names as pointers (SIGSEGV
    # at ASCII addresses, 37 crashes per boot, build 48).
    ('vendor/lib/libeffects.so', 'vendor/lib64/libeffects.so'):
        blob_fixup().replace_needed('libeffectsconfig.so', 'libeffectsconfig-stock.so'),

    # ---- init scripts following renamed binaries ------------------------------
    # Only the exec path changes; service names and `interface` lines stay as
    # stock wrote them (hwservicemanager lazy-starts on those).
    'vendor/etc/init/android.hardware.wifi@1.0-service-stock.rc': blob_fixup()
        .regex_replace(r'(?m)(/vendor/bin/hw/android\.hardware\.wifi@1\.0-service)-lazy$', r'\1-stock')
        .call(must_contain('/vendor/bin/hw/android.hardware.wifi@1.0-service-stock'), need_tmp_dir=False),
    'vendor/etc/init/vibrator-mtk-default.rc': blob_fixup()
        .regex_replace(r'(?m)(/vendor/bin/hw/android\.hardware\.vibrator-service\.mediatek)$', r'\1-stock')
        .call(must_contain('vibrator-service.mediatek-stock'), need_tmp_dir=False),
    # Stock ships TWO c2 binaries and ONE rc, naming the 32-bit one; this tree
    # is 64-bit-only for codec2, so the rc is pointed at -64b.
    'vendor/etc/init/android.hardware.media.c2@1.2-mediatek.rc': blob_fixup()
        .regex_replace(r'(?m)(/vendor/bin/hw/android\.hardware\.media\.c2@1\.2-mediatek)$', r'\1-64b')
        .call(must_contain('mediatek-64b'), need_tmp_dir=False),

    # Mali r54p1 (proprietary-files-r54p1.txt): the driver imports two libged and
    # one libgpu_aux symbol stock rev 28 lacks; libr54shim (device tree) has them.
    ('vendor/lib/egl/mt6789/libGLES_mali.so', 'vendor/lib64/egl/mt6789/libGLES_mali.so'):
        blob_fixup().add_needed('libr54shim.so'),
    # libgpud NEEDs graphics.common-V6-ndk but imports 0 of its 44 symbols (and 0 of
    # its dependency common-V2-ndk's 9), both ABIs; control: the donor's
    # allocator-V2-ndk imports ExtendableType read/writeToParcel from it. Kept, it
    # is a DT_NEEDED soong turns into a dependency -- next to libgralloctypes'
    # common-V7 that is "depends on multiple versions of the same aidl_interface"
    # (analysis 10). Dropped rather than repointed: there is nothing to bind.
    ('vendor/lib/libgpud.so', 'vendor/lib64/libgpud.so'): blob_fixup()
        .remove_needed('android.hardware.graphics.common-V6-ndk.so')
        .call(must_not_need('android.hardware.graphics.common-V6-ndk.so'), need_tmp_dir=False),

    # ---- stock's A12 libalsautils as libalsautils-stock.so ---------------------
    # A distinct filename + soname, the libeffectsconfig-stock pattern: stock's
    # audio HALs and factory keep the alsa_device_profile ABI they were built
    # against, and A16's own libalsautils keeps /vendor/lib*/libalsautils.so.
    # Consumers enumerated by DT_NEEDED over the whole vendor tree (5 files).
    ('vendor/lib/libalsautils-stock.so', 'vendor/lib64/libalsautils-stock.so'):
        blob_fixup().fix_soname(),
    ('vendor/bin/factory',
     'vendor/lib/hw/audio.primary.mediatek.so', 'vendor/lib64/hw/audio.primary.mediatek.so',
     'vendor/lib/hw/audio.usb.default.so', 'vendor/lib64/hw/audio.usb.default.so'):
        blob_fixup()
        .replace_needed('libalsautils.so', 'libalsautils-stock.so')
        .call(must_not_need('libalsautils.so'), need_tmp_dir=False),

    # ---- the renamed A12 codec2 set, and the blobs that consume it ------------
    C2_STOCK_FILES: c2_stock_self,
    C2_CONSUMERS: c2_stock_repoint(),
}  # fmt: skip


# ---- route L: A12 -> A16 ABI, measured ---------------------------------------
# Every entry below comes from tools/route-l-abi-check.py over a built image (the
# vendor namespace as linkerconfig makes it, real LLNDK libraries, DT_NEEDED
# closures) and soong's check_elf on the same build. Classes:
#   shims     A16 renamed a symbol or changed an argument type: the blob NEEDs a
#             device-tree thunk library (shims/Android.bp), one generation per
#             process instead of a second, A12 copy of a stateful library.
#   soname    a `-stock` (or misnamed) file must declare its own file name, or
#             soong's check_elf refuses it and every consumer's shared_libs.
#   underlink stock blobs that use liblog/libcutils/libutils/... without NEEDing
#             them (they work because the host process loaded it first); the
#             NEEDED makes that explicit and lets check_elf pass.
#   rc        host_init_verifier knows only interfaces with an hidl_interface
#             module; vendor-only HIDL interfaces of disabled diagnostics are
#             dropped (they lose lazy start, nothing else).

def must_not_contain(text: str):
    """Fail extraction if a regex removal of a text line did not land."""

    def check(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        with open(file_path) as f:
            if text in f.read():
                raise AssertionError(f'{file.dst}: "{text}" still present -- pattern stale')

    return check


def patch_bytes(offset: int, old: bytes, new: bytes):
    """Replace `old` with `new` at a fixed file offset; fail unless `old` is there."""

    def patch(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        with open(file_path, 'r+b') as f:
            f.seek(offset)
            cur = f.read(len(old))
            if cur != old:
                raise AssertionError(f'{file.dst}: expected {old.hex()} at {offset:#x}, found {cur.hex()}')
            f.seek(offset)
            f.write(new)

    return patch


def rename_import(old: bytes, new: bytes):
    """Rename an imported symbol in place (.dynstr); same length, exactly one occurrence."""
    assert len(old) == len(new), (old, new)

    def patch(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        with open(file_path, 'rb') as f:
            data = f.read()
        if data.count(old) != 1 or new in data:
            raise AssertionError(f'{file.dst}: {old!r} x{data.count(old)}, {new!r} x{data.count(new)}')
        with open(file_path, 'wb') as f:
            f.write(data.replace(old, new))

    return patch


def sha256_is(digest: str):
    """Fail extraction unless the fixed-up file is exactly the binary proven on hardware."""

    def check(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        with open(file_path, 'rb') as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != digest:
            raise AssertionError(f'{file.dst}: sha256 {got}, expected {digest}')

    return check


def shim(lib: str) -> blob_fixup:
    return blob_fixup().add_needed(lib)


def needed_first(lib: str):
    """Fail extraction unless `lib` is DT_NEEDED[0] (the lookup order is the fix)."""

    def check(ctx: BlobFixupCtx, file: File, file_path: str, *args, **kwargs):
        with open(file_path, 'rb') as f:
            libs = list(ELFFile(f).get_libs())
        if not libs or libs[0] != lib:
            raise AssertionError(f'{file.dst}: NEEDED[0] is {libs[:1]}, expected {lib}')

    return check


ROUTE_L_FIXUPS = [
    # libbase: Trim / Basename / WriteStringToFd(const std::string&).
    (('vendor/bin/hw/android.hardware.sensors@2.0-service.multihal-mediatek',
      'vendor/bin/hw/android.hardware.usb@1.2-service-mediatekv2',
      'vendor/bin/hw/vendor.mediatek.hardware.tranHwInfo@1.0-service',
      'vendor/bin/meta_tst',
      'vendor/lib64/ese_spi_nxp-stock.so',
      'vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so',
      'vendor/lib/libavservices_minijail_vendor.so',
      'vendor/lib64/libavservices_minijail_vendor.so',
      'vendor/lib64/libcodec2_hidl@1.0-stock.so',
      'vendor/lib64/libcodec2_hidl@1.1-stock.so',
      'vendor/lib64/libcodec2_hidl@1.2-stock.so',
      'vendor/lib/libnvram.so',
      'vendor/lib64/libnvram.so',
      'vendor/lib64/libsysenv.so'), shim('libshim_base.so')),
    # libcrypto: sk_dup, CBS_init.
    (('vendor/bin/hw/hostapd', 'vendor/bin/hw/wpa_supplicant'), shim('libshim_crypto.so')),
    # libprocessgroup: C-linkage SetTaskProfiles.
    ('vendor/lib64/hw/hwcomposer.mtk_common.so', shim('libshim_processgroup.so')),
    # libui: GraphicBufferMapper::lock(..., int*, int*) and unlock(handle).
    ('vendor/lib64/libcodec2_vndk-stock.so', shim('libshim_ui.so')),
    # libstagefright_bufferqueue_helper: getHGraphicBufferProducer().
    (('vendor/lib64/libcodec2_hidl@1.0-stock.so',
      'vendor/lib64/libcodec2_hidl@1.1-stock.so',
      'vendor/lib64/libcodec2_hidl@1.2-stock.so'), shim('libshim_bqhelper.so')),
    # libhidlbase: the goodix interface library reads details::gBnConstructorMap
    # (data), which A16 no longer exports; the shim exports it as an IFUNC that
    # resolves to libhidlbase's real map (shims/hidlbase.cpp). The resolver runs
    # while the goodix library is relocated, so the service executable NEEDs the
    # shim: it is then linked at process start, before the HAL module's dlopen.
    ('vendor/bin/hw/android.hardware.biometrics.fingerprint@2.1-service',
     shim('libshim_hidlbase.so')),
    ('vendor/lib64/libvendor.goodix.hardware.biometrics.fingerprint@2.1.so',
     shim('libshim_hidlbase.so')),

    # tinyxml2 8 -> 11: XMLDocument grew from 776 to 880 bytes. Stock code
    # stack-allocates it with the old size and A16's constructor writes over the
    # caller's saved registers (second A16 boot: libpowerhal returned from
    # loadRscTable with x19/x21-x24 zeroed; the audio HAL returned to address 0).
    # Every stock consumer gets the v31 library (prebuilts/vndk31).
    (('vendor/lib/hw/audio.primary.mediatek.so',
      'vendor/lib64/hw/audio.primary.mediatek.so',
      'vendor/lib/hw/mt6789/vendor.mediatek.hardware.pq@2.15-impl.so',
      'vendor/lib64/hw/mt6789/vendor.mediatek.hardware.pq@2.15-impl.so',
      'vendor/lib/libeffectsconfig-stock.so',
      'vendor/lib64/libeffectsconfig-stock.so',
      'vendor/lib/libpowerhal.so',
      'vendor/lib64/libpowerhal.so',
      'vendor/lib/librt_extamp_intf.so',
      'vendor/lib64/librt_extamp_intf.so'), blob_fixup()
     .replace_needed('libtinyxml2.so', 'libtinyxml2-v31.so')
     .call(must_not_need('libtinyxml2.so'), need_tmp_dir=False)),

    # android::Looper grew from 224 to 264 bytes (arm64; the operator new sizes in
    # v31's and A16's own Looper::prepare). Stock's thermal impl does
    # `new Looper(false)` itself -- `mov w0, #0xe0` before operator new -- and A16's
    # constructor then fills 264 bytes: a 40-byte heap overflow. A12's Looper.h
    # inlines nothing that touches a field (pollOnce/pollAll forward to out-of-line
    # methods), so allocating A16's size is the whole fix. arm64 only: the
    # service is 64-bit; the 32-bit impl is not loaded by it.
    ('vendor/lib64/hw/android.hardware.thermal@2.0-impl.so', blob_fixup()
     .call(patch_bytes(0x11744, bytes.fromhex('001c8052'), bytes.fromhex('00218052')), need_tmp_dir=False)),

    # libmtkutils.so is MediaTek's own fork of libutils, older than StaticString16:
    # it defines 242 of A16 libutils' exported android:: symbols, and its
    # String16(const String16&) refcounts unconditionally (SharedBuffer::acquire,
    # ldadd) where A16's checks kIsSharedBufferAllocated first. On A13 that never
    # mattered: libbinder/libutils lived in the VNDK namespace, a separate lookup
    # scope that could not see a vendor-only library. Route L puts A16 libbinder
    # and libutils in /vendor/lib64, the SAME namespace, so breadth-first DT_NEEDED
    # order decides -- and mtkfusionrild reaches libmtkutils first (breadth-first
    # position 13, libutils 36). A16 libbinder's static
    # constructors then copy their StaticString16 descriptors through MTK's copy
    # constructor, which writes into libbinder's .rodata: mtkfusionrild died with
    # SEGV_ACCERR in libmtkutils SharedBuffer::acquire before main(), so the RIL
    # never reached the modem and no SIM was ever detected.
    # libutils.so as DT_NEEDED[0] puts A16's definitions first for everything
    # loaded at startup. libmtkutils keeps binding to itself (its symbols are
    # PROTECTED), and libmtk-ril.so, dlopen'ed later, still resolves in its own
    # load group. Proven on hardware with this exact file (patchelf 0.18
    # --add-needed, bind-mounted): SIM LOADED, by.U on LTE. (Stock's atcid has
    # the same order, libmtkutils 1 vs libutils 19, but this tree does not ship it;
    # if it is ever added to proprietary-files.txt it needs this fixup too.)
    ('vendor/bin/hw/mtkfusionrild', blob_fixup()
     .add_needed('libutils.so')
     .call(needed_first('libutils.so'), need_tmp_dir=False)),

    # Video decode, two layout bugs in the codec2 process, each proven live on its own:
    # (1) AHandler. A16 added Mutex mLock + three fields and widened mMessageCounter, behind an
    # INLINE constructor; stock libcodec2_mtk_vdec/venc and libcodec2_soft_common register
    # A12-layout handlers, and A16's out-of-line deliverMessage() locked "mLock" in their own
    # fields: the HEVC decoder thread spun a core all boot (AHandler::deliverMessage ->
    # MutexLockWithTimeout) and MediaProvider hung behind it. v31's deliverMessage touches only
    # A12's fields, safe for the A16-layout handlers of libstagefright_bufferqueue_helper in the
    # same process too, so v31 must win for EVERYONE there: DT_NEEDED[0] of the service, and the
    # thirteen stock foundation users are repointed so they never load A16's at all.
    (('vendor/lib64/libcodec2_mtk_c2store.so',
      'vendor/lib64/libcodec2_mtk_vdec.so',
      'vendor/lib64/libcodec2_mtk_venc.so',
      'vendor/lib64/libcodec2_soft_common-stock.so',
      'vendor/lib64/libcodec2_soft_mtk_alacdec.so',
      'vendor/lib64/libcodec2_soft_mtk_apedec.so',
      'vendor/lib64/libcodec2_soft_mtk_imaadpcmdec.so',
      'vendor/lib64/libcodec2_soft_mtk_mp3dec.so',
      'vendor/lib64/libcodec2_soft_mtk_msadpcmdec.so',
      'vendor/lib64/libcodec2_vndk-stock.so',
      'vendor/lib64/libcodec2_vpp_qt_plugin.so',
      'vendor/lib64/libcodec2_vpp_rs_plugin.so',
      'vendor/lib64/libsfplugin_ccodec_utils-stock.so'), blob_fixup()
     .replace_needed('libstagefright_foundation.so', 'libstagefright_foundation-v31.so')
     .call(must_not_need('libstagefright_foundation.so'), need_tmp_dir=False)),
    ('vendor/bin/hw/android.hardware.media.c2@1.2-mediatek-64b', blob_fixup()
     .add_needed('libstagefright_foundation-v31.so')
     .call(needed_first('libstagefright_foundation-v31.so'), need_tmp_dir=False)),
    # (2) GraphicBuffer. A16 appended DependencyMonitor (every earlier member keeps its offset)
    # and grew the object 256 -> 3,376 B; stock libcodec2_vndk allocates it itself
    # (mov w0,#0x100; bl operator new; bl GraphicBuffer ctor) at three sites, so A16's
    # constructor wrote ~3 KB past each allocation: with (1) alone the video still never
    # started, the VcodecProcess thread spinning on a trampled std::mutex
    # (vcodec::util::Tasklet::consumeTask). The allocations now ask for A16's size; A16's
    # constructor and destructor do the rest (operator delete is size-agnostic).
    ('vendor/lib64/libcodec2_vndk-stock.so', blob_fixup()
     .call(patch_bytes(0x65ef8, bytes.fromhex('00208052'), bytes.fromhex('00a68152')), need_tmp_dir=False)
     .call(patch_bytes(0x67368, bytes.fromhex('00208052'), bytes.fromhex('00a68152')), need_tmp_dir=False)
     .call(patch_bytes(0x68360, bytes.fromhex('00208052'), bytes.fromhex('00a68152')), need_tmp_dir=False)),

    # The camera. (1) Thread::run. A12's run() took the thread's first strong reference
    # itself (`mHoldSelf = this`); A16's does sp<Thread>::fromExisting(this) and aborts
    # unless an sp<> already owns the object. MediaTek's camera stack calls run() from its
    # constructors (AppStreamMgr::CallbackHandler::CallbackHelper): camerahalserver died
    # with "incStrongRequireStrong() called on ... which isn't already owned" on EVERY
    # camera open ("error while setting up the session"). Every stock camera library that
    # imports Thread::run gets it RENAMED to libshim_thread's A12-contract wrapper
    # (shims/thread.cpp; identical to Thread::run for an owned object). A rename, not
    # interposition: these are dlopen'ed, and resolve libutils first in their load group.
    (('vendor/lib64/mt6789/libcam.iopipe.so',
      'vendor/lib64/mt6789/libcam.utils.sensorprovider.so',
      'vendor/lib64/mt6789/libmtkcam_3rdparty.customer.so',
      'vendor/lib64/mt6789/libmtkcam_device3_app.so',
      'vendor/lib64/mt6789/libmtkcam_device3_hal.so',
      'vendor/lib64/mt6789/libmtkcam_device3_utils.so',
      'vendor/lib64/mt6789/libmtkcam.featurepipe.capture.so',
      'vendor/lib64/mt6789/libmtkcam.featurepipe.depthmap.so',
      'vendor/lib64/mt6789/libmtkcam.featurepipe.streaming.so',
      'vendor/lib64/mt6789/libmtkcam_hwnode.so',
      'vendor/lib64/mt6789/libmtkcam_hwutils.so',
      'vendor/lib64/mt6789/libmtkcam_pipelinemodel_isp.so'), blob_fixup()
     .call(rename_import(b'_ZN7android6Thread3runEPKcim', b's666ln_a12_thread_run_compat'),
           need_tmp_dir=False)
     .add_needed('libshim_thread.so')),
    # (2) GraphicBuffer, the codec2 bug above in the camera stack: isptuning and halisp
    # allocate A12's 256 B (`mov w0, #0x100`), the morpho stabilizer an even older 224 B
    # (`orr w0, wzr, #0xe0`), each right before A16's 3,376-byte constructor.
    ('vendor/lib64/mt6789/libcam.isptuning.so', blob_fixup()
     .call(patch_bytes(0xb236c, bytes.fromhex('00208052'), bytes.fromhex('00a68152')), need_tmp_dir=False)),
    ('vendor/lib64/mt6789/libcam.halisp.so', blob_fixup()
     .call(patch_bytes(0x1dbe4, bytes.fromhex('00208052'), bytes.fromhex('00a68152')), need_tmp_dir=False)),
    ('vendor/lib64/mt6789/libmorpho_video_stabilizer.so', blob_fixup()
     .call(patch_bytes(0x254ae8, bytes.fromhex('e00b1b32'), bytes.fromhex('00a68152')), need_tmp_dir=False)),
    # (3) RAW / DNG. Stock's HI5022Q static metadata never lists RAW in
    # android.request.availableCapabilities, so no app can ask for a DNG -- and
    # Aperture on Lineage 23 records DNG as soon as the HAL advertises it. These are
    # our own edits to our own stock libmtkcam_metastore.so (a1229dfb), three parts:
    #   1  constructCustStaticMetadata_..._HI5022Q_MIPI_RAW pushes a sixth capability,
    #      3 (RAW), using the 180-byte error-logging branch IMetadata::update()'s
    #      success path skips as a code cave (cbz -> nop; the cave re-runs update());
    #   2  a RAW_SENSOR (format 0x20) 4096x3072 OUTPUT stream configuration, its
    #      min-frame-duration and stall-duration rows;
    #   3  the JPEG (BLOB) maximum at 4096x3072, so the JPEG matches the RAW frame.
    # No 8192x6144 rows: on this vendor no capture fills them (remosaic and RAW are
    # mutually exclusive in MTK's scenario table). Rear camera only; the front
    # (GC08A8) has its own constructor and keeps BACKWARD_COMPATIBLE..BURST_CAPTURE.
    # Proven 2026-11-14 with this exact file (cf902179) overlaid on build 16: camera 0
    # reports RAW, Aperture saved a 4096x3072 GRBG DNG (10-bit, black 64, white 1023,
    # both green sites 181.8 / 182.1, no zero padding).
    ('vendor/lib64/mt6789/libmtkcam_metastore.so', blob_fixup()
     .call(patch_bytes(0x57a6c, bytes.fromhex('c0050034f403002af30300f0739645f9680240b9a8020036'),
                       bytes.fromhex('1f2003d568008052e8430039a04301d1e143009174f60194')), need_tmp_dir=False)
     .call(patch_bytes(0x57a8c, bytes.fromhex('e5'),
                       bytes.fromhex('e1')), need_tmp_dir=False)
     .call(patch_bytes(0x57a90, bytes.fromhex('c806805261feffd0216c2f9142feffd0'),
                       bytes.fromhex('a24301d1e00313aa5ef6019422000014')), need_tmp_dir=False)
     .call(patch_bytes(0x57b48, bytes.fromhex('3a048052'),
                       bytes.fromhex('d6000014')), need_tmp_dir=False)
     .call(patch_bytes(0x57b5d, bytes.fromhex('fc81'),
                       bytes.fromhex('0082')), need_tmp_dir=False)
     .call(patch_bytes(0x57b71, bytes.fromhex('7d'),
                       bytes.fromhex('80')), need_tmp_dir=False)
     .call(patch_bytes(0x57e9c, bytes.fromhex('80070034f303002af40300f0949645f9880240b9a8020036a04301d152f50194e503002a881c805261feffd0216c2f9142feffd042640c9103feff9063181291c0008052841c8052e603132ae70303aa69fefff029a93191e907'),
                       bytes.fromhex('3c0000141a048052fa0b00f9a04301d1e143009188f5019408008252e80b00f9a04301d1e143009183f5019408808152e80b00f9a04301d1e14300917ef50194ff0b00f9a04301d1e14300917af5019416109e52565fa072f60b')), need_tmp_dir=False)
     .call(patch_bytes(0x57ef8, bytes.fromhex('e80300b949f50194880240b9490180521f01096a00040054e0430091e1031f2a0280805245f50194a04301d1'),
                       bytes.fromhex('a04301d1e143009174f50194b40a9452943fa072f40b00f9a04301d1e14300916ef501943a0480520bffff17')), need_tmp_dir=False)
     .call(sha256_is('cf9021796adfc30f7d221a6f04a73be95b6f84f5144b1f4a8627fe516756a67c'),
           need_tmp_dir=False)),

    # The stock composer generation. Stock's HWC service compiles the composer HAL's
    # header-inline code (ComposerClientImpl, ComposerResources() = default) against
    # A12's ComposerResources, which A16 changed: create() allocates 0x70 = 112 B in
    # stock's composer@2.1-resources, 0x60 = 96 B in A16's. With A16's library the
    # first boot died in addPhysicalDisplay (`__next_prime overflow`, an unordered_map
    # rehash of garbage) and SurfaceFlinger never saw a display. Stock's two resources
    # libraries ship as -stock and the service + stock 2.2-resources use them.
    (('vendor/bin/hw/android.hardware.graphics.composer@2.3-service',
      'vendor/lib64/android.hardware.graphics.composer@2.2-resources-stock.so'), blob_fixup()
     .replace_needed('android.hardware.graphics.composer@2.1-resources.so',
                     'android.hardware.graphics.composer@2.1-resources-stock.so')
     .replace_needed('android.hardware.graphics.composer@2.2-resources.so',
                     'android.hardware.graphics.composer@2.2-resources-stock.so')
     .call(must_not_need('android.hardware.graphics.composer@2.1-resources.so',
                         'android.hardware.graphics.composer@2.2-resources.so'), need_tmp_dir=False)),
    (('vendor/lib64/android.hardware.graphics.composer@2.1-resources-stock.so',
      'vendor/lib64/android.hardware.graphics.composer@2.2-resources-stock.so'), blob_fixup().fix_soname()),

    # soname = file name (check_elf; and a stock copy beside an A16 namesake must
    # not answer to the A16 name). Nothing NEEDs any of the old sonames.
    (('vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so',
      'vendor/lib64/ese_spi_nxp-stock.so',
      'vendor/lib/libeffectsconfig-stock.so',
      'vendor/lib64/libeffectsconfig-stock.so',
      'vendor/lib64/libmtk_bsg-stock.so',
      'vendor/lib64/libwifi-hal-stock.so',
      'vendor/lib64/hw/gf_fingerprint.default.so',
      'vendor/lib/libspeech_enh_lib.so',
      'vendor/lib64/libspeech_enh_lib.so',
      'vendor/lib64/libnir_neon_driver_ndk.mtk.vndk.so',
      'vendor/lib/libpcap-stock.so',
      'vendor/lib64/libpcap-stock.so'), blob_fixup().fix_soname()),

    # libpkm needs pcap_findalldevs_interfaces, which A16's libpcap dropped and
    # stock's has: stock's ships as libpcap-stock (not a VNDK library, so no v31).
    (('vendor/lib/libpkm.so', 'vendor/lib64/libpkm.so'), blob_fixup()
     .replace_needed('libpcap.so', 'libpcap-stock.so')
     .call(must_not_need('libpcap.so'), need_tmp_dir=False)),

    # underlinked stock blobs
    (('vendor/lib64/lib3a.ae.pipe.so',
      'vendor/lib64/mt6789/lib3a.ae.stat.so',
      'vendor/lib64/mt6789/lib3a.flash.so',
      'vendor/lib64/mt6789/lib3a.sensors.color.so',
      'vendor/lib64/mt6789/lib3a.sensors.flicker.so'), blob_fixup().add_needed('liblog.so')),
    ('vendor/lib64/mt6789/libmnl.so', blob_fixup().add_needed('libcutils.so')),
    ('vendor/lib64/mt6789/libmorpho_video_stabilizer.so', blob_fixup().add_needed('libutils.so')),
    ('vendor/lib64/mt6789/libsegmention.so',
     blob_fixup().add_needed('libtflite_native_gainference.so')),

    # rc interface lines host_init_verifier cannot know (all four services are
    # `disabled`). hostapd keeps its four android.hardware lines, which is what
    # lazy-starts it for the hotspot; only Transsion's own interface goes.
    ('vendor/etc/init/hostapd.android.rc', blob_fixup()
     .regex_replace(r'(?m)^[ \t]*interface vendor\.transsion\.hardware\.wifi\.hostapd@1\.0::IHostapd default\n', '')
     .call(must_not_contain('vendor.transsion.hardware.wifi.hostapd'), need_tmp_dir=False)
     .call(must_contain('android.hardware.wifi.hostapd@1.3::IHostapd'), need_tmp_dir=False)),
    (('vendor/etc/init/dmc_core.rc',
      'vendor/etc/init/em_hidl_user.rc',
      'vendor/etc/init/md_monitor.rc'), blob_fixup()
     .regex_replace(r'(?m)^[ \t]*interface vendor\.mediatek\.hardware\.[^\n]*\n', '')
     .call(must_not_contain('interface vendor.mediatek.hardware.'), need_tmp_dir=False)),
]


def per_file(fixups: blob_fixups_user_type, extra) -> blob_fixups_user_type:
    """One FRESH blob_fixup per file, merging every entry that names it.

    extract-utils' flatten_fixups merges a repeated file into the first fixup
    object it saw -- an object a tuple key shares with every other file it names,
    so the extra steps would leak onto those files too.
    """
    out: blob_fixups_user_type = {}
    for files, fixup in [*fixups.items(), *extra]:
        for f in (files,) if isinstance(files, str) else files:
            if f not in out:
                out[f] = blob_fixup()
            out[f].merge(fixup)
    return out


blob_fixups = per_file(blob_fixups, ROUTE_L_FIXUPS)

module = ExtractUtilsModule(
    'S666LN',
    'itel',
    blob_fixups=blob_fixups,
    lib_fixups=lib_fixups,
    namespace_imports=namespace_imports,
)
R54P1_LIST = 'proprietary-files-r54p1.txt'
module.add_proprietary_file(R54P1_LIST)


def r54p1_pins_hold() -> bool:
    """Every r54p1 file in the vendor tree must equal its pin.

    extract-utils only warns when a pinned file is missing from the backup and
    the source's copy hashes differently -- and it then skips the fixups and
    keeps that copy. Re-extracting from stock would so put stock's r38p1
    libGLES_mali/libgpud back over the r54p1 kbase, with exit status 0
    (ExtractUtils.run() also returns normally after "Some files failed").
    """
    ok, n = True, 0
    with open(path.join(module.device_path, R54P1_LIST)) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            spec, *pins = line.split('|')
            dst = spec.lstrip('-').split(';')[0].split(':')[-1]
            n += 1
            if not pins:
                print(f'r54p1 gate: {dst} is not pinned')
                ok = False
                continue
            p = path.join(module.vendor_path, 'proprietary', dst)
            got = file_path_sha1(p) if path.isfile(p) else 'missing'
            if got != pins[-1]:
                print(f'r54p1 gate: {dst} is {got}, pin {pins[-1]}')
                ok = False
    print(f'r54p1 gate: {n} files, {"all match their pins" if ok else "FAILED"}')
    return ok and n > 0


if __name__ == '__main__':
    utils = ExtractUtils.device(module)
    utils.run()
    if not r54p1_pins_hold():
        sys.exit(1)
