"""Read the `THIRD_PARTY_LICENSES` bundle back at runtime — issue #267.

`generate.write_bundle` writes this same record format at freeze time; this
module is the reader half, so `web/about.py` can surface a software-notices
section distinct from FR101's data-attribution list (addendum L5, item 5).

The bundle is a **static build artifact**, not something produced by the
interpreter running it — a source checkout or an unfrozen test run has no
bundle to find, and that is expected, not an error. `load_software_notices`
returns an empty list in that case; callers that care whether a frozen build
actually shipped one read `bundle_found` off the same lookup instead of
inferring it from an empty list (an environment with zero third-party
packages is not a real case, but "bundle absent" and "bundle present but
empty" should never be conflated).
"""

from __future__ import annotations

import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

#: The line that opens one record. Chosen to be a prefix no licence text is
#: remotely likely to start a line with, so a naive line-by-line split is
#: reliable in both directions (see `generate.render_bundle`).
RECORD_MARKER = "### NOTICE "

BUNDLE_FILENAME = "THIRD_PARTY_LICENSES"


@dataclass(frozen=True)
class SoftwareNotice:
    """One third-party package's licence notice."""

    name: str
    version: str
    licence_id: str
    text: str

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "version": self.version,
            "licence": self.licence_id,
            "text": self.text,
        }


def _parse_header(rest: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in shlex.split(rest):
        if "=" in token:
            key, value = token.split("=", 1)
            fields[key] = value
    return fields


def parse_third_party_licenses(raw: str) -> list[SoftwareNotice]:
    """Parse the bundle text `generate.render_bundle` produces.

    Unknown content before the first record (the file's own header comment)
    is discarded. A record with no recognisable ``name=`` field is skipped
    rather than raising — a partially-written or hand-damaged bundle should
    degrade to "fewer notices shown", never a crash on the About surface.
    """
    notices: list[SoftwareNotice] = []
    name: str | None = None
    version = licence_id = ""
    body: list[str] = []

    def flush() -> None:
        if name:
            notices.append(SoftwareNotice(
                name=name, version=version, licence_id=licence_id,
                text="\n".join(body).strip(),
            ))

    for line in raw.splitlines():
        if line.startswith(RECORD_MARKER):
            flush()
            fields = _parse_header(line[len(RECORD_MARKER):])
            name = fields.get("name", "")
            version = fields.get("version", "")
            licence_id = fields.get("licence", "")
            body = []
        elif name is not None:
            body.append(line)
    flush()
    return notices


def _candidate_paths() -> list[Path]:
    """Every place the bundle might live, mirroring
    `plotlines_service.version.read_version`'s probe order: PyInstaller's
    unpacked data dir first, then beside the executable (Nuitka and any
    other freezer). Unlike `version.lock`, there is deliberately **no**
    source-checkout fallback — the bundle is generated at freeze time and
    never committed, so "not found" outside a frozen build is the correct,
    expected answer, not a missing case to paper over.
    """
    paths: list[Path] = []
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        paths.append(Path(meipass) / BUNDLE_FILENAME)
    try:
        paths.append(Path(sys.executable).resolve().parent / BUNDLE_FILENAME)
    except OSError:
        pass
    return paths


def load_software_notices(
    paths: list[Path] | None = None,
) -> tuple[list[SoftwareNotice], bool]:
    """The notices from the first readable bundle, and whether one was found.

    ``paths`` overrides the default freeze-time search order — used by tests
    and by anything that wants to point at a specific built artifact rather
    than the running interpreter's own location.
    """
    for path in (paths if paths is not None else _candidate_paths()):
        try:
            raw = path.read_text(encoding="utf-8")
        except OSError:
            continue
        return parse_third_party_licenses(raw), True
    return [], False
