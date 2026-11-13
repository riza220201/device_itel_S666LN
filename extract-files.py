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
#   * Every `-ndk_platform` AIDL soname must be rewritten: A16 has neither the
#     spelling nor (unlike lineage-20's hardware/lineage/compat) a forwarding
#     library for it. Nine are rewritten to the frozen `-V<N>-ndk` library A16
#     still generates (aidl_api/<iface>/<N> present for all nine); four are
#     stock's own files and stay (arm.graphics, libneuron_platform, trannet,
#     power-V1).
#   * A stock blob whose former-VNDK ABI broke between A12 and A16 gets a
#     `lib*-v31.so` (AOSP prebuilts/vndk/v31, soname rewritten, device tree
#     prebuilts/vndk31). Which blobs, is measured -- v31-delta-check.py against
#     the first build's vendor libs -- not copied from the A13 list. The pq group
#     below is the one carried over: it was measured on hardware.
#   * extract-utils now writes shared_libs from each blob's DT_NEEDED and the
#     build runs check_elf on them, so a soname nothing provides is a BUILD error
#     here, not a boot loop.

import sys
from os import path

from extract_utils.elf import file_needs_lib
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
    # NEW on lineage-23.2. lineage-20 served these five from hardware/lineage/
    # compat forwarding libraries (or the v31 set); A16 has neither. The keymint
    # service is the Trustonic keybox's HAL: Play Integrity and e-KYC hang off it.
    'vendor/bin/hw/android.hardware.security.keymint-service.trustonic':
        platform_to_ndk(
            ('android.hardware.security.keymint', 1),
            ('android.hardware.security.secureclock', 1),
            ('android.hardware.security.sharedsecret', 1),
        ),
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
