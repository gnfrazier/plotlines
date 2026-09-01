"""The adapters, against the real committed responses in `raw/`.

Both feeds are spec-conformant WZDx and they differ in ways that decide the
spike's answer, so those differences are pinned here rather than asserted once
in prose: if a publisher changes shape, this fails and the write-up is known
to be out of date.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path

import pytest

import normalize

RAW = Path(__file__).resolve().parents[1] / "raw"


def _doc(name: str) -> dict:
    path = RAW / f"{name}.json.gz"
    if not path.exists():  # pragma: no cover — a fresh clone before a run
        pytest.skip(f"{path.name} not captured yet; run run_spike.py")
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def test_wisconsin_declares_a_licence_and_new_york_does_not():
    """The registration gate (D45) turns on exactly this field."""
    assert normalize.wzdx_licence_id(_doc("wzdx-wi")) == \
        "https://creativecommons.org/publicdomain/zero/1.0/"
    assert normalize.wzdx_licence_id(_doc("wzdx-ny")) == ""


def test_one_adapter_reads_both_publishers_with_no_branch():
    wi = normalize.wzdx_events(_doc("wzdx-wi"), "wzdx-wi")
    ny = normalize.wzdx_events(_doc("wzdx-ny"), "wzdx-ny")
    assert len(wi) > 4_000 and len(ny) > 5_000
    assert all(e.id and e.road_names for e in wi[:50])
    assert all(e.id for e in ny[:50])


def test_the_two_publishers_disagree_about_geometry_shape():
    """Wisconsin publishes shapes; New York publishes locations. Both are
    conformant, and the difference is worth 12.9% recall — RESULTS §3."""
    wi = normalize.wzdx_events(_doc("wzdx-wi"), "wzdx-wi")
    ny = normalize.wzdx_events(_doc("wzdx-ny"), "wzdx-ny")
    assert {e.geometry_kind for e in wi} == {"line"}
    assert {e.geometry_kind for e in ny} == {"point"}


def test_an_unrecognised_impact_normalises_to_unknown_never_to_none():
    """FR14's rule made mechanical: "no signal" must never render as "clear"."""
    doc = {"features": [{"id": "x", "properties": {
        "core_details": {"event_type": "work-zone"},
        "vehicle_impact": "some-impact-nobody-has-seen-before"}}]}
    event = normalize.wzdx_events(doc, "test")[0]
    assert event.impact == "unknown"
    assert event.impact != "none"


def test_nws_alerts_carry_no_road_identity_and_often_no_geometry():
    doc = _doc("nws-alerts-wi")
    events = normalize.nws_events(doc, "nws")
    assert events, "the WI alert feed was empty when captured"
    assert all(e.road_names == () for e in events)
    # Every alert with no geometry of its own points at zones that must be
    # fetched one by one — the N+1 that makes this the proxy question's source.
    refs = normalize.nws_zone_refs(doc)
    assert len(refs) >= len([e for e in events if not e.locatable])


def test_subsecond_timestamps_from_both_publishers_parse():
    """WZDx publishers emit 7-digit fractional seconds, which
    `datetime.fromisoformat` rejects on some versions."""
    assert normalize._iso("2026-09-01T13:11:38.2911663+00:00") is not None
    assert normalize._iso("2026-06-29T14:53:25Z") is not None
    assert normalize._iso("") is None
    assert normalize._iso("not a date") is None
