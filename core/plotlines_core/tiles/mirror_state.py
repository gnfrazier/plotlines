"""Mirror staleness monitor and the OSM-snapshot pin format for
`Provenance`/`Attribution` — issue #260 (Phase 1.6 of epic #264;
docs/Plotlines_OSM_Acquisition_Review.md §6.6, addendum Q2/L7).

§11.3 names the cost the mirror takes on: "we become the availability."
Today an Overpass outage is loud and someone else's problem; a mirror pin
that silently stopped advancing three months ago looks identical to a
working one. Q2's decision (adopted 2026-09-03) keeps the pin cadence itself
simple — monthly, one named owner, a release-checklist item — and builds the
monitor regardless, because it is nearly free: `MIRROR_STATE.json` already
carries every timestamp this module needs (`deploy/mirror/geofabrik_pull.py`
and `deploy/mirror/copy_basemap_standin.sh` write it), so staleness is a
pure read, not new acquisition.

`mirror_health()` is what `GET /health` surfaces (service/plotlines_service/
app.py) — a stale pin is loud on the client's existing capability channel
rather than something someone has to remember to SSH in and check.

`geofabrik_attribution_fields()` is L7's other half: the *format* of the pin
a trip payload owes (`trips/payload.py`'s `Attribution(source, licence,
credit, url)`), decided here so Phase 3's payload write (the extract path,
epic #264 Phase 3; addendum L7) and this monitor agree on it without a
second source of truth. This module deliberately returns a plain `dict`
rather than importing `plotlines_core.trips` and constructing the dataclass
itself — `tiles` stays a lower layer than `trips`, and Phase 3 builds
`Attribution(**geofabrik_attribution_fields(state, region))` on its own.
"""

from __future__ import annotations

import json
import re
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

from ..curation.providers import OSM_LICENCE
from ..osm_identity import osm_user_agent
from .mirror import MIRROR_HOST

#: Q2's decision: the pin bumps monthly. The staleness threshold is the
#: cadence plus a grace window wide enough that a bump landing a few days
#: late (a weekend, travel) does not read as broken — only a genuinely
#: stalled cron does. Not itself the cadence; `--min-interval-hours` in
#: `geofabrik_pull.py` is that.
MAX_PIN_AGE_DAYS = 45.0

#: `copy_basemap_standin.sh`'s `BUILD_ID` / `geofabrik_pull.py`'s
#: `--pinned-date` both start with an eight-digit or ISO date
#: (`20250101-wnc`, `2026-09-01`) — this reads either without caring which.
_LEADING_DATE_RE = re.compile(r"^(\d{4})-?(\d{2})-?(\d{2})")


def _parse_pin_date(value: str | None) -> date | None:
    if not value:
        return None
    m = _LEADING_DATE_RE.match(value)
    if not m:
        return None
    year, month, day = (int(g) for g in m.groups())
    try:
        return date(year, month, day)
    except ValueError:
        return None


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def _age_days(then: date | datetime | None, now: datetime) -> float | None:
    if then is None:
        return None
    if isinstance(then, date) and not isinstance(then, datetime):
        then = datetime(then.year, then.month, then.day, tzinfo=timezone.utc)
    return (now - then).total_seconds() / 86400.0


def load_mirror_state(source: str | Path, *, timeout_s: float = 5.0) -> dict:
    """Read `MIRROR_STATE.json` from a local path or the mirror's own
    http(s) URL.

    Unlike `deploy/mirror/geofabrik_pull.py` — a standalone script deployed
    without the rest of the repo, which duplicates the UA literal for that
    reason — this runs inside `plotlines_core` and identifies itself via
    `osm_identity.osm_user_agent()` like every other outbound request the
    library makes, even though `MIRROR_HOST` is Plotlines-controlled
    infrastructure, not a third party owed the politeness Overpass is.
    """
    text: str
    source_str = str(source)
    if isinstance(source, Path) or not source_str.startswith(("http://", "https://")):
        text = Path(source).read_text()
    else:
        req = urllib.request.Request(
            source_str, headers={"User-Agent": osm_user_agent()})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            text = resp.read().decode("utf-8")
    return json.loads(text)


def basemap_health(state: dict, *, now: datetime,
                    max_age_days: float = MAX_PIN_AGE_DAYS) -> dict:
    """Staleness of `state["basemap"]` (`copy_basemap_standin.sh`, #257).
    There is no per-pull `checked_at` here — the basemap copy is a manual
    step, not a polled sync — so age is read off the build id's own leading
    date, the same literal `mirror.py`'s `PROTOMAPS_BASEMAP_BUILD` is."""
    basemap = state.get("basemap") or {}
    build_id = basemap.get("build_id")
    build_date = _parse_pin_date(build_id)
    age = _age_days(build_date, now)
    return {
        "build_id": build_id,
        "age_days": None if age is None else round(age, 1),
        "stale": age is None or age > max_age_days,
    }


def _pull_health(entry: dict, *, now: datetime, max_age_days: float) -> dict:
    """Shared shape for a Geofabrik region entry or the `index` entry —
    both are written by the same at-most-daily/conditional/backs-off pull
    (`geofabrik_pull.py`), and both carry `checked_at` (the last time the
    upstream was successfully reached at all, changed or not) and
    `last_failure`/`consecutive_failures` (so a stalled cron is visible in
    the file itself, not only inferred from silence)."""
    checked_at = _parse_iso(entry.get("checked_at"))
    age = _age_days(checked_at, now)
    return {
        "checked_at": entry.get("checked_at"),
        "age_days": None if age is None else round(age, 1),
        "stale": age is None or age > max_age_days,
        "consecutive_failures": entry.get("consecutive_failures", 0),
        "last_failure": entry.get("last_failure"),
    }


def geofabrik_health(state: dict, *, now: datetime,
                      max_age_days: float = MAX_PIN_AGE_DAYS) -> dict:
    """Staleness of `state["geofabrik"]` — every bootstrapped region plus
    the `index-v1.json` pull, if either has ever been attempted. A mirror
    with no regions pulled yet (a fresh `build_tree.sh` skeleton) reports
    `stale: True` — there being nothing to serve is exactly the state
    §11.3 wants loud rather than indistinguishable from "up to date"."""
    geofabrik = state.get("geofabrik") or {}
    regions = {
        name: _pull_health(entry, now=now, max_age_days=max_age_days)
        for name, entry in (geofabrik.get("regions") or {}).items()
    }
    index_entry = geofabrik.get("index") or {}
    index_health = (
        _pull_health(index_entry, now=now, max_age_days=max_age_days)
        if index_entry.get("checked_at") else None
    )
    stale = (
        not regions
        or any(r["stale"] for r in regions.values())
        or (index_health is not None and index_health["stale"])
    )
    return {
        "pinned_date": geofabrik.get("pinned_date"),
        "regions": regions,
        "index": index_health,
        "stale": stale,
    }


def mirror_health(state: dict, *, now: datetime | None = None,
                   max_age_days: float = MAX_PIN_AGE_DAYS) -> dict:
    """The `/health` staleness summary — §11.3's "we become the
    availability" monitor, built regardless of the pin cadence chosen (Q2:
    B's cadence + C's monitoring)."""
    now = now or datetime.now(timezone.utc)
    basemap = basemap_health(state, now=now, max_age_days=max_age_days)
    geofabrik = geofabrik_health(state, now=now, max_age_days=max_age_days)
    return {
        "configured": True,
        "checked_at": now.isoformat().replace("+00:00", "Z"),
        "max_age_days": max_age_days,
        "basemap": basemap,
        "geofabrik": geofabrik,
        "stale": basemap["stale"] or geofabrik["stale"],
    }


#: `/health`'s answer when no `--mirror-state-url` was given at all — a
#: sidecar not yet pointed at any mirror (before #261, or a dev box with
#: none configured) reports this rather than a stale-looking `configured:
#: True` for state it was never told to read.
MIRROR_NOT_CONFIGURED: dict = {"configured": False}


def geofabrik_pin_credit(pinned_date: str | None) -> str:
    """L7's credit-line format: **"contains OSM data, snapshot
    <date>"** — a stronger notice than a bare "© OpenStreetMap contributors"
    line, because it states *which build* a trip was made from. A cue sheet
    or exported itinerary carrying this line lets a reader tell a fresh trip
    from one built off a stale pin, which a bare credit cannot."""
    if not pinned_date:
        return "contains OSM data (mirror snapshot date unknown)"
    return f"contains OSM data, snapshot {pinned_date}"


def geofabrik_attribution_fields(state: dict, region: str) -> dict:
    """Everything `trips/payload.py`'s `Attribution(source, licence, credit,
    url)` needs for the Geofabrik extract a trip's routing graph and
    candidates were built from, keyed off `state["geofabrik"]`.

    L7: "the pin's on-disk format is specified for Provenance/Attribution
    consumption" — this is that specification, plus the implementation, so
    Phase 3's payload write (the extract path) has nothing left to decide
    beyond calling `Attribution(**geofabrik_attribution_fields(state,
    region))` once a trip's bbox resolves to `region`.
    """
    geofabrik = state.get("geofabrik") or {}
    pinned_date = geofabrik.get("pinned_date")
    return {
        "source": f"geofabrik:{region}",
        "licence": OSM_LICENCE.id,
        "credit": geofabrik_pin_credit(pinned_date),
        "url": (
            f"https://{MIRROR_HOST}/osm/geofabrik/{pinned_date}/{region}.osm.pbf"
            if pinned_date else None
        ),
    }
