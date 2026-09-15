"""SPIKE-J (#266) — assert-the-absence check for the addendum's non-negotiable
acceptance criterion (2a / L1): *no GPL-licensed binary in the shipped
artifact*. A build failure, not a memory — see the issue body.

Two independent checks, because "no GPL dependency" and "no GPL-tool binary"
fail differently:

1. **Every Python distribution actually installed in the build venv** is
   checked against its own metadata (`License` field and `Classifier:
   License ::` entries) for a GPL/AGPL family license. This is a stronger
   check than scanning only what `--copy-metadata` copied into the frozen
   tree, because a mis-scoped `--exclude-module` could leave a GPL dependency
   *compiled in* without its `.dist-info` ever reaching the artifact — the
   venv is the ground truth for what got linked.
2. **The frozen artifact tree** is scanned for a binary literally named
   `osmium` (or `osmium.exe`) — the GPL-3.0 `osmium-tool` CLI addendum L1
   names by name. pyosmium (this spike's dependency) ships no such binary;
   finding one would mean something pulled the CLI in transitively.

Exit 0 and print a summary on a clean pass; exit 1 and name the offender
otherwise. LGPL is reported but does not fail this check — the addendum's
concern (2a) is specifically GPL-3 "osmium extract", not the weak-copyleft
family, and LGPL's dynamic-linking exception is a different analysis than
this mechanical scan can do (that's a case-by-case call, not "assert the
absence").

Usage: python check_no_gpl.py --venv PATH/TO/.venv --dist PATH/TO/frozen/tree
"""

from __future__ import annotations

import argparse
import importlib.metadata as im
import sys
from pathlib import Path

GPL_MARKERS = ("GPL-1", "GPL-2", "GPL-3", "GPLV", "AGPL", "GNU GENERAL PUBLIC")
LGPL_MARKERS = ("LGPL", "GNU LESSER")

# Never shipped in the frozen artifact — the *build* toolchain, not a runtime
# dependency PyInstaller's static analysis pulls into the sidecar. Excluded
# here rather than left to false-positive, because PyInstaller itself really
# is GPL-2.0-or-later, and scanning the venv naively flags it on every build
# this project has ever done. Its actual on-disk footprint in a frozen build
# is the compiled bootloader stub under the GPL's own bootloader exception —
# the load-bearing exception issue #267 already names and treats as settled,
# not something SPIKE-J re-litigates.
BUILD_TOOLCHAIN_ONLY = {
    "pyinstaller", "pyinstaller-hooks-contrib", "altgraph", "macholib",
    "pefile", "pywin32-ctypes", "setuptools", "pip", "wheel",
}

# A short, SPDX-ish string is trustworthy; a long one is very often the FULL
# license text dumped into the `License` field by an older build backend
# (pandas's METADATA does this, and its text quotes the Python Software
# Foundation's own GPL-compatibility discussion — matching "GPL" there is a
# false positive on prose, not a finding about pandas's license). Classifiers
# are curated, structured, and short by construction, so they are always
# trusted; the free-text field is trusted only when it looks like an
# identifier rather than a document.
_MAX_TRUSTED_FREETEXT_LEN = 120


def _license_strings(dist: im.Distribution) -> list[str]:
    out = []
    meta = dist.metadata
    for field in ("License", "License-Expression"):
        val = meta.get(field)
        if val and len(val) <= _MAX_TRUSTED_FREETEXT_LEN:
            out.append(val)
    for classifier in meta.get_all("Classifier") or []:
        if classifier.startswith("License ::"):
            out.append(classifier)
    return out


def scan_venv(venv_site_packages: Path) -> tuple[list[str], list[str]]:
    """Returns (gpl_offenders, lgpl_notices), each `"name==version: license"`."""
    gpl, lgpl = [], []
    for dist in im.distributions(path=[str(venv_site_packages)]):
        name = dist.metadata.get("Name", "?")
        if name.lower() in BUILD_TOOLCHAIN_ONLY:
            continue
        version = dist.version or "?"
        for lic in _license_strings(dist):
            upper = lic.upper()
            if any(m in upper for m in GPL_MARKERS):
                gpl.append(f"{name}=={version}: {lic}")
                break
        else:
            for lic in _license_strings(dist):
                if any(m in lic.upper() for m in LGPL_MARKERS):
                    lgpl.append(f"{name}=={version}: {lic}")
                    break
    return gpl, lgpl


def scan_binary_tree(dist_dir: Path) -> list[str]:
    """Only a *file* literally named `osmium`/`osmium-tool` is the CLI binary
    addendum L1 means. pyosmium's own package directory is also named
    `osmium/` (it holds `_osmium*.so`, the compiled extension this spike
    actually ships) — matching directories would flag every pyosmium build
    that ever passes, which is not a finding."""
    hits = []
    for name in ("osmium", "osmium.exe", "osmium-tool", "osmium-tool.exe"):
        hits.extend(str(p) for p in dist_dir.rglob(name) if p.is_file())
    return hits


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--venv", required=True, help="build venv root")
    parser.add_argument("--dist", required=True, help="frozen onedir tree root")
    args = parser.parse_args()

    venv = Path(args.venv)
    site_packages_candidates = list(venv.glob("lib/python*/site-packages")) + list(
        venv.glob("Lib/site-packages")
    )
    if not site_packages_candidates:
        print(f"no site-packages found under {venv}", file=sys.stderr)
        return 2

    gpl_all: list[str] = []
    lgpl_all: list[str] = []
    for sp in site_packages_candidates:
        gpl, lgpl = scan_venv(sp)
        gpl_all.extend(gpl)
        lgpl_all.extend(lgpl)

    binary_hits = scan_binary_tree(Path(args.dist))

    if lgpl_all:
        print("LGPL dependencies present (not a failure, recorded for #267):")
        for line in sorted(set(lgpl_all)):
            print(f"  {line}")

    ok = True
    if gpl_all:
        ok = False
        print("FAIL: GPL/AGPL-family dependency in the build venv:", file=sys.stderr)
        for line in sorted(set(gpl_all)):
            print(f"  {line}", file=sys.stderr)
    if binary_hits:
        ok = False
        print("FAIL: GPL-3 osmium-tool binary found in the frozen artifact:", file=sys.stderr)
        for line in binary_hits:
            print(f"  {line}", file=sys.stderr)

    if ok:
        print("PASS: no GPL/AGPL dependency in the venv, no osmium-tool binary in the artifact.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
