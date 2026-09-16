"""Generate the `THIRD_PARTY_LICENSES` bundle at freeze time — issue #267,
addendum L5.

`packaging/build_sidecar.sh` runs `write_bundle` (via the build venv's own
interpreter, in which `plotlines_core` is already installed editable
alongside PyInstaller) against **that venv's** installed distributions —
i.e. exactly what the frozen sidecar's dependency closure was built from —
and writes the result next to the binary, then bundles it in via
`--add-data` / `--include-data-files` so `licensing.software_notices` can
read it back at runtime. Regenerated on every build; never hand-maintained,
so a dependency bump cannot leave it stale (that is the whole point of the
issue — data credits are mechanical and release-gated, software notices
were not).
"""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from importlib import metadata
from pathlib import Path

from .software_notices import RECORD_MARKER, SoftwareNotice

#: PyInstaller's own licence is GPL-2.0-or-later, but ships a bootloader
#: exception permitting the bootloader to be linked into and distributed as
#: part of a non-free program (commercial included). That exception is the
#: entire reason plotlines-sidecar can ship as a single frozen binary at
#: all — without it, embedding PyInstaller's bootloader would make the
#: whole binary a GPL derivative work (addendum L5). Recorded explicitly
#: here, ahead of PyInstaller's own licence text, rather than left to
#: institutional memory. No other dependency in this bundle carries a GPL
#: exception it relies on; if one ever does, it earns an entry here too.
_RATIONALE_BY_NAME: dict[str, str] = {
    "pyinstaller": (
        "Why this exception matters to Plotlines: PyInstaller's bootloader "
        "is the native stub that unpacks and launches the frozen Python "
        "interpreter inside plotlines-sidecar. Its licence below is "
        "GPL-2.0-or-later, but the \"Bootloader Exception\" clause it "
        "carries grants unlimited permission to link or embed the compiled "
        "bootloader into other programs, non-free and commercial ones "
        "included, and to distribute the combination without the GPL's "
        "restrictions extending to it. Without that exception, shipping "
        "plotlines-sidecar as one frozen binary would make the whole "
        "artifact a GPL derivative work. Full licence text, exception "
        "included, follows."
    ),
}

#: Only licence files that live in a distribution's own `dist-info` are
#: collected — never an unrelated vendored notice deep in a package's data
#: tree (rasterio ships GDAL's own `LICENSE.TXT` under
#: `rasterio/gdal_data/`, which is GDAL's obligation to *its* consumers, not
#: something Plotlines is a party to by depending on rasterio).
_LICENCE_FILENAME = re.compile(r"(licen[cs]e|copying|notice)", re.IGNORECASE)


def _is_editable_local(dist: metadata.Distribution) -> bool:
    """True for `pip install -e` installs of our own `core`/`service`
    packages — not third-party, and excluded from the bundle."""
    try:
        raw = dist.read_text("direct_url.json")
    except Exception:
        return False
    if not raw:
        return False
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return False
    return bool(data.get("dir_info", {}).get("editable"))


def _licence_id(dist: metadata.Distribution) -> str:
    md = dist.metadata
    expr = md.get("License-Expression")
    if expr:
        return expr.strip()
    classifiers = [c for c in (md.get_all("Classifier") or []) if c.startswith("License ::")]
    if classifiers:
        ids = [c.rsplit("::", 1)[-1].strip() for c in classifiers]
        return "; ".join(dict.fromkeys(ids))
    lic = md.get("License")
    if lic and len(lic) <= 100 and "\n" not in lic:
        return lic.strip()
    return "unknown (see notice text)"


def _licence_text(dist: metadata.Distribution) -> str:
    parts: list[str] = []
    seen: set[str] = set()
    for f in dist.files or []:
        fpath = str(f)
        if "dist-info" not in fpath or not _LICENCE_FILENAME.search(f.name):
            continue
        if fpath in seen:
            continue
        seen.add(fpath)
        try:
            content = dist.read_text(fpath)
        except Exception:
            content = None
        if content is None:
            try:
                content = Path(dist.locate_file(f)).read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
        parts.append(content.strip())
    if parts:
        return "\n\n".join(parts)
    lic = dist.metadata.get("License")
    if lic and len(lic) > 100:
        # Some distributions inline the full text into the METADATA `License`
        # field instead of shipping a separate file.
        return lic.strip()
    return "No licence text shipped by this distribution; recorded identifier only."


def discover_distributions() -> list[SoftwareNotice]:
    """Every third-party distribution installed in the running interpreter's
    environment — run this with the build venv's own python so it reflects
    exactly what the frozen sidecar was built from."""
    seen_names: set[str] = set()
    out: list[SoftwareNotice] = []
    dists = sorted(metadata.distributions(), key=lambda d: d.metadata["Name"].lower())
    for dist in dists:
        name = dist.metadata["Name"]
        if name.lower() in seen_names or _is_editable_local(dist):
            continue
        seen_names.add(name.lower())
        text = _licence_text(dist)
        rationale = _RATIONALE_BY_NAME.get(name.lower())
        if rationale:
            text = rationale + "\n\n" + text
        out.append(SoftwareNotice(
            name=name, version=dist.version, licence_id=_licence_id(dist), text=text,
        ))
    return out


def render_bundle(notices: list[SoftwareNotice]) -> str:
    generated = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lines = [
        "Plotlines third-party software notices",
        f"Generated {generated} by packaging/generate_third_party_licenses.py "
        "— regenerated on every sidecar build; do not hand-edit.",
        "",
        "Every third-party Python package installed in the frozen sidecar's "
        "build environment, with the licence text each distribution ships. "
        "See the PyInstaller entry for the bootloader exception this "
        "distribution model relies on.",
        "",
    ]
    for n in notices:
        lines.append(f'{RECORD_MARKER}name="{n.name}" version="{n.version}" licence="{n.licence_id}"')
        lines.append(f"{n.name} {n.version} — {n.licence_id}")
        lines.append("-" * 72)
        lines.append("")
        lines.append(n.text)
        lines.append("")
    return "\n".join(lines)


def write_bundle(output_path: str | Path, *, require_pyinstaller: bool = True) -> int:
    """Write the bundle to `output_path`. Raises rather than writing a
    bundle that would be missing or stale in a way that matters (addendum
    L5, item 6 — "fail the build if the bundle is missing or stale"):

    - no third-party distributions found at all (wrong/empty environment)
    - `require_pyinstaller` and PyInstaller itself is absent, which would
      silently drop the one entry whose GPL exception this whole issue
      exists to write down
    """
    notices = discover_distributions()
    if not notices:
        raise RuntimeError(
            "no third-party distributions found in this environment — "
            "refusing to write an empty THIRD_PARTY_LICENSES bundle"
        )
    if require_pyinstaller and not any(n.name.lower() == "pyinstaller" for n in notices):
        raise RuntimeError(
            "pyinstaller not found in this environment — its bootloader "
            "exception must be recorded whenever the sidecar is frozen "
            "with it (issue #267, addendum L5)"
        )
    Path(output_path).write_text(render_bundle(notices), encoding="utf-8")
    return len(notices)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="path to write THIRD_PARTY_LICENSES to")
    parser.add_argument(
        "--no-require-pyinstaller", action="store_true",
        help="skip the PyInstaller-must-be-present check (non-PyInstaller freeze targets)",
    )
    args = parser.parse_args()
    count = write_bundle(args.output, require_pyinstaller=not args.no_require_pyinstaller)
    print(f"wrote {args.output} ({count} third-party packages)")


if __name__ == "__main__":
    main()
