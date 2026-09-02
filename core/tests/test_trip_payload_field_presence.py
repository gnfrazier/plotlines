"""Every populated field survives `to_dict()` — the trip payload's shape gate.

#235 B1. `payload.py` reported 95% line coverage, but a mutation run killed only
7 of 25 mutants: nearly every survivor was the `[...] or None` idiom in a
`to_dict`. Flipping `or` to `and` turns

    "hazards": [h.to_dict() for h in self.hazards] or None

into `... and None`, i.e. **the field silently vanishes from the emitted
payload**, and the whole suite still passed. Hazards dropping out of a trip
payload is the shape of failure this module should be loudest about.

The tests are executable but unasserted precisely because nothing ever compared
the emitted dict against the fields that went in. So that is what this does: a
fully-populated instance of every payload dataclass, then one assertion per
field that its key is present and non-null on the way out. Line coverage was
never the problem; this is the missing oracle.

`payload.py` is the source of truth for the client contract (ARCH D28), so the
same file also pins the round-trip through `plotlines_core.trips.payload`'s
`Trip.to_dict` against `docs/schemas/trip_payload.schema.json`'s property names.
"""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import pytest

from plotlines_core.trips import payload as P

_SCHEMA_PATH = (Path(__file__).resolve().parents[2] / "docs" / "schemas"
                / "trip_payload.schema.json")


# ── fully-populated instances ────────────────────────────────────────────
#
# Every optional field set to something distinguishable. A default anywhere here
# would silently exempt that field from the presence check below, so these are
# deliberately exhaustive rather than minimal.


def _weight_profile() -> P.WeightProfile:
    return P.WeightProfile(name="custom", climbing=1.0, traffic=2.5,
                           surface={"paved": 1.0, "gravel": 2.0},
                           interest=1.5, terrain_technicality=0.5)


def _route_metrics(distance_m: float = 1000.0) -> P.RouteMetrics:
    return P.RouteMetrics(
        distance_m=distance_m, climb_m=100.0, descent_m=90.0, traffic=0.2,
        unpaved_frac=0.3, scenic_frac=0.4, salience=0.5, max_grade=0.08,
        overlap_frac=0.1, overlap_near_frac=0.05, overlap_far_frac=0.02,
        edge_count=42, moving_time_s=3600.0, elapsed_time_s=4000.0,
        pace_source="declared",
    )


def _elevation() -> P.Elevation:
    return P.Elevation(ascent_m=100.0, descent_m=90.0, min_m=1500.0, max_m=1900.0,
                       samples=[1500.0, 1700.0, 1900.0], void_samples=1,
                       source="gedtm30")


def _media() -> P.MediaRef:
    return P.MediaRef(kind="image", path="media/a.jpg", id="m1", caption="c",
                      bytes=2048, duration_s=0.0)


def _narration() -> P.Narration:
    return P.Narration(trigger_distance_m=120.0, media_id="m1", text="Look left.")


def _scheduled() -> P.ScheduledWindow:
    return P.ScheduledWindow(opens_at="09:00", closes_at="17:00",
                             timezone="America/Denver", detail="summer only")


def _line_string() -> P.LineString:
    return P.LineString(coordinates=[[-105.30, 40.0], [-105.20, 40.05]],
                        source="solver")


def _node() -> P.Node:
    return P.Node(
        kind="poi", coord=[-105.28, 40.02], id="n1", distance_along_m=250.0,
        title="Overlook", note="Worth the stop.", media=[_media()],
        amenities=["water", "toilets"], poi_type="viewpoint", arc_stage="rising",
        narration=_narration(), instructions="Bear left.", scheduled=_scheduled(),
    )


def _hazard() -> P.Hazard:
    return P.Hazard(
        severity="high", id="hz1", title="Weir", safety_note="Portage river left.",
        required_gear=["helmet"], coord=[-105.29, 40.03], distance_along_m=500.0,
        # `node_id` and `anchor_id` are mutually exclusive by construction — a
        # hazard is anchored to one thing, not both — so "fully populated" here
        # means one of them. See `_EXCLUSIVE_WITH` below.
        anchor_id="a1",
    )


def _portage() -> P.Portage:
    return P.Portage(geometry=_line_string(), id="p1", exit_bank="river_left",
                     distance_m=120.0, surface="gravel", elevation_change_m=4.0,
                     mandatory=True, note="carry past the weir")


def _alternate() -> P.Alternate:
    return P.Alternate(
        kind="variant", geometry=_line_string(), id="alt1", intent="branch",
        label="Gravel variant", metrics=_route_metrics(500.0), elevation=_elevation(),
        diverges_at_m=200.0, rejoins_at_m=800.0, note="drier in spring",
        anchor_ids=["a1"], narration=_narration(), reveal="always_visible",
    )


def _solve() -> P.SolveProvenance:
    return P.SolveProvenance(engine_version="0.0.1", graph_region="abc123",
                             solve_ms=12.5, solver_calls=3,
                             solved_at="2026-09-02T00:00:00Z", closed=True,
                             hit_via=True, stale=False)


def _cue() -> P.Cue:
    return P.Cue(sequence=1, distance_along_m=100.0, kind="turn", id="c1",
                 instruction="Turn left onto Main", modifier="left",
                 bearing_deg=270.0, ref_id="n1", segment_id="s1", retrace=True)


def _cue_sheet() -> P.CueSheet:
    return P.CueSheet(generated_at="2026-09-02T00:00:00Z", cues=[_cue()],
                      generator="plotlines-core", segment_ids=["s1"],
                      geometry_digest="dg1")


def _limit_breach() -> P.LimitBreach:
    return P.LimitBreach(mode="cycling", bound="max", limit_m=90000.0,
                         realised_m=95000.0, day_id="d1")


def _roll_up() -> P.RollUp:
    return P.RollUp(total=_route_metrics(), by_mode={"cycling": _route_metrics()},
                    limit_breaches=[_limit_breach()])


def _segment() -> P.Segment:
    return P.Segment(
        mode="cycling", shape="point_to_point", id="s1", title="Morning climb",
        start=[-105.30, 40.00], end=[-105.20, 40.05], via=[[-105.25, 40.02]],
        target_distance=P.TargetDistance(value_m=20000.0, min_m=18000.0,
                                         max_m=22000.0, advisory=True),
        bands=[P.Band(attribute="climb_m", minimum=200.0, maximum=600.0,
                      source="author")],
        violations=[P.Violation(attribute="climb_m", realised=150.0, shortfall=-50.0)],
        weights=_weight_profile(), geometry=_line_string(), metrics=_route_metrics(),
        elevation=_elevation(), nodes=[_node()], alternates=[_alternate()],
        hazards=[_hazard()], portages=[_portage()], solve=_solve(),
        arc_stage="rising", note="Passage note.", media=[_media()],
    )


def _transition() -> P.Transition:
    return P.Transition(from_segment_id="s1", to_segment_id="s2", id="t1",
                        from_mode="cycling", to_mode="paddling", node=_node(),
                        gap_m=40.0, gap_warning=True)


def _day() -> P.Day:
    return P.Day(
        index=1, kind="riding", id="d1", roles=["driver"], date="2026-09-02",
        title="Day one", note="Day note.", media=[_media()],
        location=[-105.26, 40.02], segments=[_segment()],
        transitions=[_transition()], nodes=[_node()], hazards=[_hazard()],
        limits={"cycling": {"min_m": 10000.0, "max_m": 90000.0}},
        weights=_weight_profile(), metrics=_roll_up(), cue_sheet=_cue_sheet(),
    )


def _trip() -> P.Trip:
    return P.Trip(
        title="Test trip", id="trip-1",
        created_at="2026-09-01T00:00:00Z", updated_at="2026-09-02T00:00:00Z",
        duration={"days": 2, "nights": 1},
        default_weights=_weight_profile(),
        day_limits={"cycling": {"min_m": 10000.0, "max_m": 90000.0}},
        days=[_day()],
        anchors=[],  # `content.anchor.Anchor` — covered by test_content_anchor.py
        metrics=_roll_up(),
        provenance=P.Provenance(
            produced_by="plotlines-core", app_version="0.0.1",
            sidecar_version="0.0.1",
            attribution=[P.Attribution(source="osm", licence="ODbL",
                                       credit="\u00a9 OpenStreetMap contributors",
                                       url="https://osm.org/copyright")],
        ),
    )


#: Every payload dataclass that carries a `to_dict`, with a fully-populated
#: instance. `Trip` is handled separately \u2014 its `to_dict` prunes and nests.
_POPULATED = {
    P.WeightProfile: _weight_profile(),
    P.Band: P.Band(attribute="climb_m", minimum=1.0, maximum=2.0, source="author"),
    P.Violation: P.Violation(attribute="climb_m", realised=1.0, shortfall=-1.0),
    P.TargetDistance: P.TargetDistance(value_m=1.0, min_m=0.5, max_m=1.5,
                                       advisory=True),
    P.RouteMetrics: _route_metrics(),
    P.Elevation: _elevation(),
    P.MediaRef: _media(),
    P.Narration: _narration(),
    P.ScheduledWindow: _scheduled(),
    P.Node: _node(),
    P.Hazard: _hazard(),
    P.LineString: _line_string(),
    P.Portage: _portage(),
    P.Alternate: _alternate(),
    P.SolveProvenance: _solve(),
    P.Cue: _cue(),
    P.CueSheet: _cue_sheet(),
    P.LimitBreach: _limit_breach(),
    P.RollUp: _roll_up(),
    P.Segment: _segment(),
    P.Transition: _transition(),
    P.Day: _day(),
    P.Attribution: P.Attribution(source="osm", licence="ODbL", credit="c",
                                 url="https://osm.org"),
    P.Provenance: P.Provenance(produced_by="p", app_version="1",
                               sidecar_version="1",
                               attribution=[P.Attribution(source="osm",
                                                          licence="ODbL",
                                                          credit="c")]),
}


#: Fields a fully-populated instance legitimately cannot set, because the
#: dataclass refuses to hold them alongside the sibling we did set. Skipped by
#: the presence check with the sibling that stands in for them.
_EXCLUSIVE_WITH = {
    (P.Hazard, "node_id"): "anchor_id",
}

#: Dataclass field -> emitted key, where they differ.
_RENAMED = {
    # The schema spells a band's bounds `min`/`max` (`$defs/band`); the
    # dataclass avoids shadowing the builtins.
    (P.Band, "minimum"): "min",
    (P.Band, "maximum"): "max",
    # `cue_sheet.derived_from` is an object holding both of these.
    (P.CueSheet, "segment_ids"): "derived_from",
    (P.CueSheet, "geometry_digest"): "derived_from",
}


def _cases():
    for cls, instance in _POPULATED.items():
        for f in dataclasses.fields(cls):
            yield pytest.param(cls, instance, f.name, id=f"{cls.__name__}.{f.name}")


@pytest.mark.parametrize("cls,instance,field_name", list(_cases()))
def test_a_populated_field_reaches_the_emitted_payload(cls, instance, field_name):
    """One assertion per field: it was set, so it must come out.

    This is what the `or None` mutants walked past. `[...] or None` is the
    correct idiom — an empty list should be absent, not `[]` — but nothing was
    checking the populated half of it.
    """
    if (cls, field_name) in _EXCLUSIVE_WITH:
        pytest.skip(
            f"{cls.__name__}.{field_name} cannot be set alongside "
            f"{_EXCLUSIVE_WITH[(cls, field_name)]!r}; the sibling covers the path"
        )

    emitted = instance.to_dict()
    key = _RENAMED.get((cls, field_name), field_name)

    assert key in emitted, (
        f"{cls.__name__}.{field_name} was populated but {key!r} is missing from "
        f"to_dict() — a consumer would never see it"
    )
    assert emitted[key] is not None, (
        f"{cls.__name__}.{field_name} was populated but emitted as null"
    )


@pytest.mark.parametrize("cls,instance", [(c, i) for c, i in _POPULATED.items()])
def test_a_populated_collection_is_not_emitted_empty(cls, instance):
    """The other half of the same failure: a list that arrives as `[]` when it
    had members is as broken as one that vanishes."""
    emitted = instance.to_dict()
    for f in dataclasses.fields(cls):
        value = getattr(instance, f.name)
        if isinstance(value, (list, dict)) and value:
            out = emitted.get(_RENAMED.get((cls, f.name), f.name))
            assert out, f"{cls.__name__}.{f.name} had {len(value)} member(s), emitted {out!r}"


# ── the same rule for `Trip`, whose to_dict prunes and nests ─────────────


def test_every_populated_trip_field_survives_to_dict():
    emitted = _trip().to_dict()
    for key in ("schema_version", "id", "title", "created_at", "updated_at",
                "duration", "defaults", "days", "metrics", "provenance"):
        assert key in emitted and emitted[key] is not None, f"trip.{key} vanished"

    assert emitted["defaults"]["weights"] is not None
    assert emitted["defaults"]["day_limits"] == {
        "cycling": {"min_m": 10000.0, "max_m": 90000.0}
    }


def test_a_days_segments_transitions_nodes_and_hazards_all_reach_the_payload():
    """The specific `Day.to_dict` mutants that survived. Hazards first: a day's
    hazard list silently becoming absent is a safety surface disappearing."""
    day = _day().to_dict()
    assert len(day["hazards"]) == 1
    assert len(day["segments"]) == 1
    assert len(day["transitions"]) == 1
    assert len(day["nodes"]) == 1
    assert day["limits"] == {"cycling": {"min_m": 10000.0, "max_m": 90000.0}}


def test_a_segments_hazards_bands_violations_and_nodes_all_reach_the_payload():
    seg = _segment().to_dict()
    assert len(seg["hazards"]) == 1
    assert len(seg["bands"]) == 1
    assert len(seg["violations"]) == 1
    assert len(seg["nodes"]) == 1
    assert len(seg["alternates"]) == 1
    assert len(seg["portages"]) == 1
    assert seg["via"] == [[-105.25, 40.02]]


def test_a_hazard_survives_the_whole_way_to_the_serialised_trip():
    """End to end, because that is the level a consumer sees: the weir the
    Author marked is still in the JSON bytes."""
    blob = json.loads(_trip().to_json())
    hazards = blob["days"][0]["segments"][0]["hazards"]
    assert [h["title"] for h in hazards] == ["Weir"]
    assert hazards[0]["safety_note"] == "Portage river left."


# ── empty stays absent — the idiom's intended half ──────────────────────


def test_an_empty_collection_is_omitted_rather_than_emitted_as_an_empty_list():
    """`or None` exists so an untouched trip does not carry a dozen empty
    arrays. Pinning this keeps a future "fix" from making absence and emptiness
    indistinguishable in the other direction."""
    bare = P.Segment(id="s", mode="cycling", shape="loop", start=[0.0, 0.0])
    emitted = bare.to_dict()
    for key in ("via", "bands", "violations", "nodes", "alternates", "hazards",
                "portages", "media"):
        assert emitted[key] is None, f"empty {key} should be null, got {emitted[key]!r}"


def test_the_trip_root_prunes_its_nulls_entirely():
    """`Trip.to_dict` prunes rather than emitting nulls, so absence really is
    absence at the top level."""
    emitted = P.Trip(title="Bare", id="t", created_at="x", updated_at="y").to_dict()
    assert "metrics" not in emitted
    assert "provenance" not in emitted
    assert emitted["title"] == "Bare"


# ── the emitted shape agrees with the schema's vocabulary ───────────────


def _schema_defs() -> dict:
    return json.loads(_SCHEMA_PATH.read_text())


@pytest.mark.skipif(not _SCHEMA_PATH.exists(), reason="schema not in this checkout")
@pytest.mark.parametrize("cls,def_name", [
    (P.WeightProfile, "weight_profile"), (P.Band, "band"), (P.Violation, "violation"),
    (P.TargetDistance, "target_distance"), (P.RouteMetrics, "route_metrics"),
    (P.Elevation, "elevation"), (P.MediaRef, "media_ref"), (P.Narration, "narration"),
    (P.ScheduledWindow, "scheduled_window"), (P.Node, "node"), (P.Hazard, "hazard"),
    (P.LineString, "line_string"), (P.Portage, "portage"), (P.Alternate, "alternate"),
    (P.SolveProvenance, "solve_provenance"), (P.Cue, "cue"), (P.CueSheet, "cue_sheet"),
    (P.RollUp, "roll_up"), (P.Segment, "segment"), (P.Transition, "transition"),
    (P.Day, "day"), (P.Provenance, "provenance"),
])
def test_a_populated_instance_emits_only_keys_the_schema_declares(cls, def_name):
    """ARCH D28: where `payload.py` and the schema disagree, the schema wins —
    so an emitted key the schema has never heard of is a defect in this module.
    Most of these `$defs` are `additionalProperties: false`, which makes an
    undeclared key a hard validation failure downstream."""
    schema = _schema_defs()
    declared = set((schema["$defs"][def_name].get("properties") or {}).keys())
    emitted = set(_POPULATED[cls].to_dict().keys())

    assert emitted <= declared, (
        f"{cls.__name__}.to_dict emits {sorted(emitted - declared)}, which "
        f"$defs/{def_name} does not declare"
    )


@pytest.mark.skipif(not _SCHEMA_PATH.exists(), reason="schema not in this checkout")
def test_the_trip_root_emits_only_keys_the_schema_declares():
    schema = _schema_defs()
    declared = set((schema.get("properties") or {}).keys())
    assert set(_trip().to_dict().keys()) <= declared


@pytest.mark.skipif(not _SCHEMA_PATH.exists(), reason="schema not in this checkout")
def test_every_required_key_is_emitted_by_a_populated_instance():
    schema = _schema_defs()
    for cls, def_name in [(P.Band, "band"), (P.Violation, "violation"),
                          (P.Node, "node"), (P.Hazard, "hazard"),
                          (P.Segment, "segment"), (P.Day, "day"),
                          (P.Cue, "cue"), (P.CueSheet, "cue_sheet")]:
        required = set(schema["$defs"][def_name].get("required") or [])
        emitted = {k: v for k, v in _POPULATED[cls].to_dict().items() if v is not None}
        assert required <= set(emitted), (
            f"{cls.__name__}.to_dict omits required {sorted(required - set(emitted))}"
        )


# ── RouteMetrics.merged — the roll-up arithmetic ────────────────────────


def test_merging_sums_the_additive_terms():
    """`add()` mutated to zero a component and the suite still passed."""
    merged = _route_metrics(1000.0).merged(_route_metrics(3000.0))

    assert merged.distance_m == 4000.0
    assert merged.climb_m == 200.0
    assert merged.descent_m == 180.0
    assert merged.edge_count == 84
    assert merged.moving_time_s == 7200.0
    assert merged.elapsed_time_s == 8000.0


def test_merging_length_weights_the_fractional_terms():
    """"A 2 km connector at 90% traffic and a 60 km day at 5% do not average to
    47.5%" — the classic roll-up bug the docstring names."""
    short = P.RouteMetrics(distance_m=2000.0, traffic=0.9)
    long = P.RouteMetrics(distance_m=60000.0, traffic=0.05)

    merged = short.merged(long)

    expected = (0.9 * 2000.0 + 0.05 * 60000.0) / 62000.0
    assert merged.traffic == pytest.approx(expected)
    assert merged.traffic < 0.1, "an unweighted mean would land near 0.475"


def test_a_component_present_on_only_one_side_is_not_dropped_or_zeroed():
    """`(a or 0.0)` is there so one side's `None` does not poison the blend —
    mutating it to `and` zeroed the side that *did* have a value."""
    with_value = P.RouteMetrics(distance_m=1000.0, scenic_frac=0.8, edge_count=10)
    without = P.RouteMetrics(distance_m=1000.0)

    merged = with_value.merged(without)

    assert merged.scenic_frac == pytest.approx(0.4)  # 0.8 over half the distance
    assert merged.edge_count == 10


def test_a_component_absent_on_both_sides_stays_absent():
    """None means "not measured" and must not become a confident 0.0."""
    merged = P.RouteMetrics(distance_m=1.0).merged(P.RouteMetrics(distance_m=1.0))
    assert merged.traffic is None
    assert merged.edge_count is None
    assert merged.max_grade is None


def test_max_grade_takes_the_steeper_of_the_two():
    merged = (P.RouteMetrics(distance_m=1.0, max_grade=0.04)
              .merged(P.RouteMetrics(distance_m=1.0, max_grade=0.11)))
    assert merged.max_grade == 0.11


def test_max_grade_survives_when_only_one_side_measured_it():
    """`is None and is None` is the guard for "neither side measured it". Read
    as `or`, one unmeasured side would erase a real steepest grade — the number
    a Character uses to decide whether the day is rideable."""
    assert (P.RouteMetrics(distance_m=1.0, max_grade=0.11)
            .merged(P.RouteMetrics(distance_m=1.0)).max_grade == 0.11)
    assert (P.RouteMetrics(distance_m=1.0)
            .merged(P.RouteMetrics(distance_m=1.0, max_grade=0.11)).max_grade == 0.11)


def test_the_pace_source_of_the_first_measured_side_carries_the_merge():
    """`a or b` — the left side wins when it has one, and the right stands in
    when it does not. Read as `and`, a merge would report the *second* side's
    provenance while carrying the first's numbers, or drop it entirely."""
    assert P.RouteMetrics(distance_m=1.0, pace_source="declared").merged(
        P.RouteMetrics(distance_m=1.0, pace_source="fallback")).pace_source == "declared"
    assert P.RouteMetrics(distance_m=1.0).merged(
        P.RouteMetrics(distance_m=1.0, pace_source="fallback")).pace_source == "fallback"
    assert P.RouteMetrics(distance_m=1.0).merged(
        P.RouteMetrics(distance_m=1.0)).pace_source is None


def test_merging_two_zero_length_sets_does_not_divide_by_zero():
    merged = P.RouteMetrics(distance_m=0.0, traffic=0.5).merged(
        P.RouteMetrics(distance_m=0.0, traffic=0.1))
    assert merged.distance_m == 0.0
    assert merged.traffic == 0.0
