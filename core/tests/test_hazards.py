"""Story C11 — hazard and technical-crux warnings (PRD FR27, FR115).

Covers the model half of C11's acceptance criteria:

  * a hazard/crux marker attaches to a route, a transit leg, a day, or an
    anchor, with a severity, a safety note and required-gear callouts;
  * severity is a closed enum, enforced in the model, not just the schema;
  * `trips.hazards.collect_hazards` is the single traversal every hazard
    surface reads (map, elevation, itinerary, cue sheet, sync alert);
  * high-severity markers raise a distinct Character alert on sync
    (`sync_alerts`), ordered deterministically worst-first;
  * a hazard carries no reveal field and cannot be hidden by any Author
    (FR115) — there is nothing on the object to set.
"""

import json
from pathlib import Path

import pytest

from plotlines_core.content.anchor import Anchor, Role
from plotlines_core.trips.hazards import (
    ALERTING_SEVERITIES,
    HAZARD_SEVERITIES,
    collect_hazards,
    has_sync_alerts,
    sync_alerts,
)
from plotlines_core.trips.payload import Day, Hazard, RouteMetrics, Segment, Trip

_SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json")
    .read_text()
)


# --- fixtures ---------------------------------------------------------------


def _segment(seg_id: str, *, distance_m: float = 5_000.0,
             hazards: list[Hazard] | None = None) -> Segment:
    return Segment(
        id=seg_id, mode="cycling", shape="point_to_point",
        start=[0.0, 0.0], end=[0.1, 0.1],
        metrics=RouteMetrics(distance_m=distance_m),
        hazards=hazards or [],
    )


def _trip(days: list[Day], anchors: list[Anchor] | None = None) -> Trip:
    return Trip(title="Test trip", days=days, anchors=anchors or [])


# --- the model: severity is a closed enum, enforced here ------------------


def test_severity_ladder_is_a_closed_enum_worst_last():
    assert HAZARD_SEVERITIES == ("caution", "high", "mandatory_reroute")
    assert ALERTING_SEVERITIES == ("high", "mandatory_reroute")


def test_hazard_rejects_a_severity_outside_the_enum():
    with pytest.raises(ValueError, match="severity"):
        Hazard(severity="extreme")


@pytest.mark.parametrize("severity", HAZARD_SEVERITIES)
def test_every_named_severity_constructs(severity):
    assert Hazard(severity=severity).severity == severity


def test_is_alerting_is_high_and_above_only():
    assert not Hazard(severity="caution").is_alerting
    assert Hazard(severity="high").is_alerting
    assert Hazard(severity="mandatory_reroute").is_alerting


# --- the model: what a hazard attaches to --------------------------------


def test_hazard_pins_to_an_anchor_a_node_or_a_point_but_not_two():
    Hazard(severity="high", anchor_id="anchor-1")
    Hazard(severity="high", node_id="node-1")
    Hazard(severity="high", coord=[-105.2, 40.0], distance_along_m=1_200.0)
    with pytest.raises(ValueError, match="mutually exclusive"):
        Hazard(severity="high", anchor_id="anchor-1", node_id="node-1")


def test_hazard_carries_severity_safety_note_and_gear():
    hazard = Hazard(
        severity="mandatory_reroute",
        title="Washed-out bridge at Elk Creek",
        safety_note="Ford is impassable above 2 m gauge. Use the FS-19 detour.",
        required_gear=["helmet", "throw bag"],
    )
    d = hazard.to_dict()
    assert d["severity"] == "mandatory_reroute"
    assert d["safety_note"].startswith("Ford is impassable")
    assert d["required_gear"] == ["helmet", "throw bag"]


def test_hazard_has_no_reveal_field_fr115():
    """FR115 — the model enforces "always visible" by giving an Author no
    place to say otherwise: there is no reveal key on the wire shape."""
    assert "reveal" not in Hazard(severity="high").to_dict()
    assert "reveal" not in _SCHEMA["$defs"]["hazard"]["properties"]


def test_emitted_dict_keys_match_the_schema():
    allowed = set(_SCHEMA["$defs"]["hazard"]["properties"])
    emitted = set(Hazard(severity="high", anchor_id="a1").to_dict())
    assert emitted <= allowed, emitted - allowed
    assert "anchor_id" in allowed


# --- collect_hazards: one traversal, with placement ---------------------


def test_collect_walks_days_then_segments_in_order():
    trip = _trip([
        Day(index=1, hazards=[Hazard(severity="caution", title="Loose gravel")],
            segments=[
                _segment("s1", hazards=[Hazard(severity="high", title="Cattle guard")]),
                _segment("s2", hazards=[Hazard(severity="caution", title="Blind bend")]),
            ]),
        Day(index=2, segments=[_segment("s3")]),
    ])
    located = collect_hazards(trip)
    assert [(lh.day_index, lh.scope, lh.hazard.title) for lh in located] == [
        (1, "day", "Loose gravel"),
        (1, "passage", "Cattle guard"),
        (1, "passage", "Blind bend"),
    ]
    assert located[1].segment_id == "s1"


def test_collect_resolves_anchor_scope_and_title():
    anchor = Anchor(id="anchor-x", coord=[-105.2, 40.0], title="The narrows",
                    roles=[Role(kind="narrative")])
    trip = _trip(
        [Day(index=1, segments=[
            _segment("s1", hazards=[Hazard(severity="high", anchor_id="anchor-x",
                                           title="Class IV rapid")]),
        ])],
        anchors=[anchor],
    )
    (lh,) = collect_hazards(trip)
    assert lh.scope == "anchor"
    assert lh.anchor_id == "anchor-x"
    assert lh.anchor_title == "The narrows"
    assert lh.segment_id == "s1"  # still records which passage's list carried it


def test_collect_anchor_scope_survives_an_unknown_anchor():
    trip = _trip([Day(index=1, hazards=[
        Hazard(severity="high", anchor_id="ghost", title="Rockfall zone"),
    ])])
    (lh,) = collect_hazards(trip)
    assert lh.scope == "anchor" and lh.anchor_title is None


# --- sync_alerts: the distinct Character alert on sync -----------------


def test_sync_alerts_only_carries_high_severity_and_above():
    trip = _trip([Day(index=1, segments=[_segment("s1", hazards=[
        Hazard(severity="caution", title="Puddle"),
        Hazard(severity="high", title="Cattle guard"),
        Hazard(severity="mandatory_reroute", title="Bridge out"),
    ])])])
    titles = [a.title for a in sync_alerts(trip)]
    assert titles == ["Bridge out", "Cattle guard"]
    assert "Puddle" not in titles


def test_sync_alerts_order_is_worst_first_then_day_then_distance():
    trip = _trip([
        Day(index=1, segments=[_segment("s1", hazards=[
            Hazard(severity="high", title="D1 far", distance_along_m=9_000.0),
            Hazard(severity="high", title="D1 near", distance_along_m=1_000.0),
            Hazard(severity="mandatory_reroute", title="D1 reroute",
                   distance_along_m=5_000.0),
        ])]),
        Day(index=2, segments=[_segment("s2", hazards=[
            Hazard(severity="high", title="D2 hazard", distance_along_m=500.0),
        ])]),
    ])
    assert [a.title for a in sync_alerts(trip)] == [
        "D1 reroute", "D1 near", "D1 far", "D2 hazard",
    ]


def test_sync_alerts_is_deterministic_across_runs():
    trip = _trip([Day(index=1, segments=[_segment("s1", hazards=[
        Hazard(severity="high", title="Bee", id="h-b"),
        Hazard(severity="high", title="Ant", id="h-a"),
    ])])])
    assert [a.to_dict() for a in sync_alerts(trip)] == [
        a.to_dict() for a in sync_alerts(trip)
    ]


def test_sync_alert_carries_safety_note_gear_and_placement():
    trip = _trip([Day(index=3, segments=[_segment("s9", hazards=[
        Hazard(severity="mandatory_reroute", title="Weir",
               safety_note="Portage river-left. Do not run.",
               required_gear=["PFD"], distance_along_m=4_321.0,
               coord=[-105.1, 40.1]),
    ])])])
    (alert,) = sync_alerts(trip)
    d = alert.to_dict()
    assert d["day_index"] == 3
    assert d["segment_id"] == "s9"
    assert d["scope"] == "passage"
    assert d["safety_note"] == "Portage river-left. Do not run."
    assert d["required_gear"] == ["PFD"]
    assert d["distance_along_m"] == 4321.0
    assert d["coord"] == [-105.1, 40.1]


def test_has_sync_alerts_is_the_cheap_precheck():
    quiet = _trip([Day(index=1, segments=[_segment("s1", hazards=[
        Hazard(severity="caution", title="Puddle"),
    ])])])
    loud = _trip([Day(index=1, hazards=[Hazard(severity="high", title="Ice")])])
    assert not has_sync_alerts(quiet)
    assert has_sync_alerts(loud)
    assert sync_alerts(quiet) == []


def test_a_trip_with_no_hazards_has_no_alerts():
    trip = _trip([Day(index=1, segments=[_segment("s1")])])
    assert collect_hazards(trip) == []
    assert sync_alerts(trip) == []
    assert not has_sync_alerts(trip)
