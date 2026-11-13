#!/usr/bin/env python3
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
"""route-L ABI check: every vendor symbol the A16 vendor namespace cannot resolve.

    route-l-abi-check.py --image <PRODUCT_OUT> --v31 <prebuilts/vndk/v31/arm64>
                         [--fill <vendor tree proprietary/>] [--stock <stock vendor/>]
                         [--json FILE]

WHY THIS EXISTS
    This tree runs stock Android 12 vendor blobs on an Android 16 system with no
    VNDK ("route L"): a blob links the A16 vendor variants of libbase, libutils,
    libcrypto, ... and where A16 changed their ABI, the blob gets a NEEDED rewrite
    to an `<lib>-v31.so` copy taken from prebuilts/vndk/v31. Which libraries need
    a copy is a measurement, and soong's check_elf_files is not that measurement:
      - it checks against LLNDK STUBS, so it reports symbols the real apex libc /
        system libnativewindow do export (false failures);
      - it checks only DIRECT NEEDED entries (underlinked stock blobs fail it and
        still work, because the host process's global group has the symbol);
      - a module that fails it early on a SONAME mismatch is never symbol-checked;
      - it never asks what a -v31 copy itself needs from the A16 libraries.

WHAT IT MODELS (per ABI, lib64 and lib)
    Visible to a vendor process: files in /odm/${LIB}, /vendor/${LIB},
    /vendor/${LIB}/hw and /vendor/${LIB}/egl (symlinks followed inside the
    image -- this device keeps most libraries in mt6789/ with a link beside
    them), plus the real LLNDK libraries named by system/etc/llndk.libraries.txt
    (bionic from apex/com.android.runtime, the rest from system/${LIB}).
    An LLNDK library lives in the system namespace, so only its own exports
    count; its dependencies are not searched.

    For every vendor/odm ELF: walk the DT_NEEDED closure, then check
      MISSING   a NEEDED name nothing visible provides;
      VERSION   a verneed (file, version) the providing library does not define
                (bionic refuses to load the whole library);
      BROKEN    an undefined non-weak symbol that NO visible library exports;
      UNDERLINK an undefined symbol outside the closure but exported by some
                visible library: works only if the host process loaded that
                library first (add_needed keeps check_elf honest).
    A BROKEN symbol names the NEEDED library whose v31 build exports it: that is
    a -v31 candidate. The candidates are then closed: each copy's own NEEDED
    resolve against A16 libraries (or other copies), and whatever that leaves
    unresolved pulls in the next copy, until nothing changes.

    --fill supplies vendor files a failed build never installed (a module that
    failed check_elf is not in the image); every filled file is listed.
"""

import argparse
import collections
import json
import os
import shutil
import subprocess
import sys

try:
    from elftools.elf.elffile import ELFFile
    from elftools.elf.dynamic import DynamicSection
    from elftools.elf.gnuversions import GNUVerDefSection, GNUVerNeedSection, GNUVerSymSection
    from elftools.elf.sections import SymbolTableSection
except ImportError:
    sys.exit('needs pyelftools (python3 -m venv V && V/bin/pip install pyelftools)')

ABIS = {'lib64': {'elfclass': 64, 'v31': 'arch-arm64-armv8-a'},
        'lib': {'elfclass': 32, 'v31': 'arch-arm-armv8-a'}}
BIONIC = {'libc.so', 'libm.so', 'libdl.so', 'libdl_android.so'}
# Libraries whose copies hold process-wide state; two generations in one process
# split that state (seen on this device: libhidlbase's gBnConstructorMap).
STATEFUL = {'libhidlbase.so', 'libbinder.so', 'libutils.so', 'libui.so', 'libprocessgroup.so',
            'libhwbinder.so', 'libcutils.so', 'libbase.so', 'libvndksupport.so'}


class Elf:
    __slots__ = ('path', 'elfclass', 'soname', 'needed', 'undef', 'defs', 'verdefs', 'verneed')

    def __init__(self, path):
        self.path = path
        self.soname = None
        self.needed = []
        self.undef = {}            # name -> (file, version) or None
        self.defs = {}             # name -> set of version names ('' = unversioned)
        self.verdefs = set()
        self.verneed = {}          # file -> set of versions
        with open(path, 'rb') as f:
            e = ELFFile(f)
            self.elfclass = e.elfclass
            idx_name = {}
            for s in e.iter_sections():
                if isinstance(s, GNUVerNeedSection):
                    for vn, auxs in s.iter_versions():
                        for a in auxs:
                            idx_name[a['vna_other']] = (vn.name, a.name)
                            self.verneed.setdefault(vn.name, set()).add(a.name)
                elif isinstance(s, GNUVerDefSection):
                    for vd, auxs in s.iter_versions():
                        name = next(iter(auxs)).name
                        if not vd['vd_flags'] & 0x1:      # VER_FLG_BASE names the file
                            self.verdefs.add(name)
                            idx_name[vd['vd_ndx']] = (None, name)
            versym = next((s for s in e.iter_sections() if isinstance(s, GNUVerSymSection)), None)
            for s in e.iter_sections():
                if isinstance(s, DynamicSection):
                    for t in s.iter_tags():
                        if t.entry.d_tag == 'DT_NEEDED':
                            self.needed.append(t.needed)
                        elif t.entry.d_tag == 'DT_SONAME':
                            self.soname = t.soname
            dynsym = e.get_section_by_name('.dynsym')
            if not isinstance(dynsym, SymbolTableSection):
                return
            for i, sym in enumerate(dynsym.iter_symbols()):
                if not sym.name:
                    continue
                bind = sym['st_info']['bind']
                ndx = versym.get_symbol(i).entry['ndx'] if versym else 0
                ndx = ndx & 0x7fff if isinstance(ndx, int) else 0
                ver = idx_name.get(ndx)
                if sym['st_shndx'] == 'SHN_UNDEF':
                    if bind == 'STB_GLOBAL':
                        self.undef[sym.name] = ver
                elif bind in ('STB_GLOBAL', 'STB_WEAK', 'STB_GNU_UNIQUE') and \
                        sym['st_other']['visibility'] in ('STV_DEFAULT', 'STV_PROTECTED'):
                    self.defs.setdefault(sym.name, set()).add(ver[1] if ver else '')

    def exports(self, name, ver):
        v = self.defs.get(name)
        if v is None:
            return False
        if ver is None or not self.verdefs:
            return True
        return ver[1] in v


_cache = {}


def load(path):
    if path not in _cache:
        try:
            _cache[path] = Elf(path)
        except Exception:                    # not ELF / truncated: never a provider
            _cache[path] = None
    return _cache[path]


def is_elf(path):
    try:
        with open(path, 'rb') as f:
            return f.read(4) == b'\x7fELF'
    except OSError:
        return False


class Image:
    """The device's file tree: the built image, holes filled from --fill."""

    def __init__(self, image, fill):
        self.image, self.fill, self.filled = image, fill, set()

    def real(self, rel):
        """rel = 'vendor/lib64/x.so' -> host path of the file it finally names, or None."""
        for _ in range(16):
            host = None
            for root in (self.image, self.fill):
                if not root:
                    continue
                p = os.path.join(root, rel)
                if os.path.islink(p) or os.path.exists(p):
                    host = p
                    break
            if host is None:
                return None
            if os.path.islink(host):
                t = os.readlink(host)
                rel = os.path.normpath(t.lstrip('/') if t.startswith('/') else
                                       os.path.join(os.path.dirname(rel), t))
                continue
            if self.fill and host.startswith(self.fill):
                self.filled.add(rel)
            return host
        return None


def demangle(names):
    cf = shutil.which('c++filt') or shutil.which('llvm-cxxfilt')
    if not cf or not names:
        return {n: n for n in names}
    out = subprocess.run([cf], input='\n'.join(names), capture_output=True, text=True).stdout.split('\n')
    return dict(zip(names, out))


def check_abi(args, abi, rep):
    conf = ABIS[abi]
    img = Image(args.image, args.fill)
    search = [f'odm/{abi}', f'vendor/{abi}', f'vendor/{abi}/hw', f'vendor/{abi}/egl']

    def visible_vendor(name):
        for d in search:
            p = img.real(f'{d}/{name}')
            if p:
                e = load(p)
                if e and e.elfclass == conf['elfclass']:
                    return p
        return None

    llndk_list = os.path.join(args.image, 'system/etc/llndk.libraries.txt')
    llndk = set(open(llndk_list).read().split())

    def visible_llndk(name):
        if name not in llndk:
            return None
        cands = [f'apex/com.android.runtime/{abi}/bionic/{name}'] if name in BIONIC else []
        cands.append(f'system/{abi}/{name}')
        for c in cands:
            p = os.path.join(args.image, c)
            if os.path.exists(p):
                return os.path.realpath(p)
        return None

    def resolve(name, override=None):
        """-> (host path, is_llndk) of what the vendor namespace loads for NEEDED name."""
        if override and name in override:
            return override[name], False
        p = visible_vendor(name)
        if p:
            return p, False
        p = visible_llndk(name)
        return (p, True) if p else (None, False)

    def closure(root, override=None):
        """BFS over DT_NEEDED as bionic loads it. -> (ordered providers, missing names)."""
        seen, order, missing, queue = {root.path}, [root], [], collections.deque([(root, False)])
        while queue:
            e, ll = queue.popleft()
            if ll:
                continue                        # LLNDK deps live in the system namespace
            for n in e.needed:
                p, is_ll = resolve(n, override)
                if not p:
                    missing.append(n)
                    continue
                if p in seen:
                    continue
                seen.add(p)
                d = load(p)
                if d is None:
                    missing.append(n)
                    continue
                order.append(d)
                queue.append((d, is_ll))
        return order, missing

    # every vendor-visible library, for the UNDERLINK class
    visible_all = []
    for d in search:
        for root in (args.image, args.fill):
            if not root or not os.path.isdir(os.path.join(root, d)):
                continue
            for n in os.listdir(os.path.join(root, d)):
                p = visible_vendor(n) if n.endswith('.so') else None
                if p:
                    visible_all.append((n, p))
    for n in sorted(llndk):
        p = visible_llndk(n)
        if p:
            visible_all.append((n, p))
    visible_all = list(dict.fromkeys(visible_all))

    def who_exports(sym, ver):
        return [n for n, p in visible_all if (load(p) and load(p).exports(sym, ver))]

    v31dir = os.path.join(args.v31, conf['v31'], 'shared')

    def v31_path(name):
        for sub in ('vndk-core', 'vndk-sp'):
            p = os.path.join(v31dir, sub, name)
            if os.path.exists(p):
                return p
        return None

    v31_index = None

    def v31_any(sym):
        """every v31 library exporting sym (for a NEEDED name that changed, e.g. _platform)."""
        nonlocal v31_index
        if v31_index is None:
            v31_index = collections.defaultdict(list)
            for sub in ('vndk-core', 'vndk-sp'):
                d = os.path.join(v31dir, sub)
                for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                    e = load(os.path.join(d, n))
                    for s in (e.defs if e else ()):
                        v31_index[s].append(n)
        return v31_index.get(sym, [])

    def v31_needed_prov(e, sym):
        return [n for n in e.needed if v31_path(n) and load(v31_path(n)) and sym in load(v31_path(n)).defs]

    def stock_has(name, sym):
        if not args.stock:
            return False
        for d in (f'{abi}', f'{abi}/mt6789', f'{abi}/hw'):
            p = os.path.join(args.stock, d, name)
            if os.path.exists(p):
                e = load(os.path.realpath(p))
                return bool(e and sym in e.defs)
        return False

    # enumerate vendor + odm ELFs of this ABI (real files only)
    elfs = {}
    for root in (args.image, args.fill):
        if not root:
            continue
        for part in ('vendor', 'odm'):
            top = os.path.join(root, part)
            for dp, _, fns in os.walk(top):
                for fn in fns:
                    p = os.path.join(dp, fn)
                    rel = os.path.relpath(p, root)
                    if rel in elfs or os.path.islink(p) or not is_elf(p):
                        continue
                    e = load(p)
                    if e is None or e.elfclass != conf['elfclass']:
                        continue
                    if root == args.fill:
                        if os.path.exists(os.path.join(args.image, rel)):
                            continue
                        img.filled.add(rel)
                    elfs[rel] = p

    res = rep.setdefault(abi, {'elfs': len(elfs), 'missing': {}, 'version': {}, 'broken': {},
                               'underlink': {}, 'candidates': {}})
    cand_consumers = collections.defaultdict(set)
    for rel, p in sorted(elfs.items()):
        e = load(p)
        order, missing = closure(e)
        if missing:
            res['missing'][rel] = sorted(set(missing))
        # VERSION: each verneed file must be a NEEDED provider defining the version
        by_soname = {}
        for d in order[1:]:
            by_soname[d.soname or os.path.basename(d.path)] = d
            by_soname.setdefault(os.path.basename(d.path), d)
        for f, vers in e.verneed.items():
            d = by_soname.get(f)
            if d and d.verdefs:
                bad = sorted(v for v in vers if v not in d.verdefs)
                if bad:
                    res['version'].setdefault(rel, []).append(f'{f}: {" ".join(bad)}')
        for sym, ver in e.undef.items():
            if any(d.exports(sym, ver) for d in order):
                continue
            # A NEEDED library whose v31 build exports the symbol is the A12->A16 break,
            # even when some unrelated vendor blob happens to export a static copy
            # (libtflite_mtk carries libbase's): that blob is not loaded in this process.
            prov = v31_needed_prov(e, sym)
            elsewhere = who_exports(sym, ver)
            if elsewhere and not prov:
                res['underlink'].setdefault(rel, {})[sym] = elsewhere[:3]
                continue
            stock = [n for n in e.needed if stock_has(n, sym)]
            res['broken'].setdefault(rel, {})[sym] = {
                'v31': prov, 'v31_any': [] if prov else v31_any(sym)[:3],
                'stock_vendor': stock, 'incidental': elsewhere[:3]}
            for n in prov[:1]:
                cand_consumers[n].add(rel)

    # close the candidate set over the copies' own needs
    cands = set(cand_consumers)
    unresolvable = {}
    changed = True
    while changed:
        changed = False
        unresolvable = {}                       # only the last (complete) round counts
        override = {n: v31_path(n) for n in cands}
        for n in sorted(cands):
            e = load(v31_path(n))
            order, missing = closure(e, override)
            for sym, ver in e.undef.items():
                if any(d.exports(sym, ver) for d in order):
                    continue
                prov = v31_needed_prov(e, sym)
                if prov:
                    if prov[0] not in cands:
                        cands.add(prov[0])
                        cand_consumers[prov[0]].add(f'(copy) {n}-v31')
                        changed = True
                elif not who_exports(sym, ver):
                    unresolvable.setdefault(f'{n}-v31', set()).add(sym)
            for m in missing:                   # a NEEDED A16 dropped: copy it too, if v31 has it
                if v31_path(m):
                    if m not in cands:
                        cands.add(m)
                        cand_consumers[m].add(f'(copy) {n}-v31')
                        changed = True
                else:
                    unresolvable.setdefault(f'{n}-v31', set()).add(f'NEEDED {m}')
    for n in sorted(cands):
        e = load(v31_path(n))
        res['candidates'][n] = {
            'consumers': sorted(cand_consumers[n]),
            'rewrite_needed_inside': sorted(m for m in e.needed if m in cands),
            'stateful': n in STATEFUL,
        }
    res['unresolvable_with_v31'] = {k: sorted(v) for k, v in unresolvable.items()}
    res['filled'] = sorted(img.filled)


def report(rep):
    allsyms = set()
    for r in rep.values():
        for d in r['broken'].values():
            allsyms.update(d)
    dm = demangle(sorted(allsyms))
    for abi, r in rep.items():
        print(f'===== {abi}: {r["elfs"]} vendor/odm ELFs, {len(r["filled"])} filled from --fill')
        print(f'MISSING (NEEDED nothing visible provides): {len(r["missing"])} ELFs')
        for k, v in sorted(r['missing'].items()):
            print(f'  {k}: {" ".join(v)}')
        print(f'VERSION (required symbol version not defined): {len(r["version"])} ELFs')
        for k, v in sorted(r['version'].items()):
            print(f'  {k}: {"; ".join(v)}')
        nb = sum(len(v) for v in r['broken'].values())
        print(f'BROKEN (no visible library exports it): {nb} symbols in {len(r["broken"])} ELFs')
        for k, v in sorted(r['broken'].items()):
            print(f'  {k}')
            for s, d in sorted(v.items()):
                where = (' v31:' + ','.join(d['v31'])) if d['v31'] else ' v31:-'
                where += (' v31-elsewhere:' + ','.join(d['v31_any'])) if d['v31_any'] else ''
                where += (' stock:' + ','.join(d['stock_vendor'])) if d['stock_vendor'] else ''
                where += (' incidental:' + ','.join(d['incidental'])) if d['incidental'] else ''
                print(f'      {dm.get(s, s)[:110]}  [{where.strip()}]')
        print(f'UNDERLINK (outside the closure, exported elsewhere): {len(r["underlink"])} ELFs')
        for k, v in sorted(r['underlink'].items()):
            libs = sorted({l for ls in v.values() for l in ls})
            print(f'  {k}: {len(v)} symbols, e.g. {next(iter(v))[:60]} <- {" ".join(libs[:4])}')
        print(f'-v31 CANDIDATES (closed): {len(r["candidates"])}')
        for n, c in sorted(r['candidates'].items()):
            flag = '  !! STATEFUL: two generations in one process' if c['stateful'] else ''
            inner = (' rewrite inside: ' + ' '.join(c['rewrite_needed_inside'])) if c['rewrite_needed_inside'] else ''
            print(f'  {n} <- {len(c["consumers"])} consumers{inner}{flag}')
            for x in c['consumers']:
                print(f'      {x}')
        if r['unresolvable_with_v31']:
            print('UNRESOLVABLE even with v31 copies:')
            for k, v in sorted(r['unresolvable_with_v31'].items()):
                print(f'  {k}: {" ".join(v[:6])}{" ..." if len(v) > 6 else ""}')
        if r['filled']:
            print('FILLED from --fill (not in the image):')
            for f in r['filled']:
                print(f'  {f}')
        print()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--image', required=True, help='PRODUCT_OUT (out/target/product/S666LN)')
    ap.add_argument('--v31', required=True, help='prebuilts/vndk/v31/arm64')
    ap.add_argument('--fill', help='vendor tree proprietary/ dir, for files a failed build did not install')
    ap.add_argument('--stock', help='stock vendor dir, to say whether stock vendor itself carried a symbol')
    ap.add_argument('--json')
    a = ap.parse_args()
    for d in (a.image, a.v31, a.fill, a.stock):
        if d and not os.path.isdir(d):
            sys.exit(f'not a directory: {d}')
    rep = {}
    for abi in ABIS:
        check_abi(a, abi, rep)
    report(rep)
    if a.json:
        with open(a.json, 'w') as f:
            json.dump(rep, f, indent=1, sort_keys=True)
    bad = sum(len(r['missing']) + len(r['version']) + len(r['broken']) for r in rep.values())
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
