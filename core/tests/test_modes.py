"""Unit tests for `plotlines_core.multimodal.modes` — B1 (FR10, FR130).

Three things are under test, in the order B1's AC states them:

  * the traversal list is FR10's eight, driving included, and the schema enum
    cannot drift from it;
  * station activities (FR109 / O4) appear nowhere in a travel-mode list —
    punchlist §2.6's fail signal, as an assertion;
  * FR130's extension path really is configuration: a mode this codebase has
    never heard of routes and scores through the existing single scorer with
    no new code, given only a `WeightProfile` and its domain parameters.
"""

import json
from pathlib import Path

import networkx as nx
import pytest

from plotlines_core.multimodal.modes import (
    EXTENDED,
    FIRST_CLASS,
    STATION_ACTIVITIES,
    TRANSPORT_NOTE_MODES,
    TRAVERSAL_MODES,
    TraversalMode,
    access_mode_for,
    all_mode_keys,
    base_speed_kmh,
    extended_modes,
    first_class_modes,
    is_station_activity,
    is_traversal_mode,
    mode_label,
    network_type_for,
    traversal_mode,
    weights_for,
)
from plotlines_core.routing import access
from plotlines_core.scoring.profile import WeightProfile, edge_cost

_SCHEMA = Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json"


# --- FR10: the traversal list --------------------------------------------


def test_the_traversal_list_is_fr10s_eight_modes():
    assert set(TRAVERSAL_MODES) == {
        "cycling",
        "hiking",
        "paddling",
        "cross_country_skiing",
        "packrafting",
        "riverboarding",
        "mountain_biking",
        "driving",
    }


def test_driving_is_a_traversal_mode_not_a_note():
    """Punchlist §2.11's fail signal: "driving is absent from the traversal-mode
    list; or a drive to the trailhead produces a note rather than a route"."""
    assert is_traversal_mode("driving")
    assert "driving" not in TRANSPORT_NOTE_MODES
    assert TRAVERSAL_MODES["driving"].network_type == "drive"


def test_transit_is_a_note_mode_and_never_a_traversal_one():
    """FR29's other half — train, shuttle and flight legs are authored notes."""
    assert not is_traversal_mode("transit")
    assert "transit" in TRANSPORT_NOTE_MODES
    assert base_speed_kmh("transit") is None


def test_cycling_hiking_and_paddling_are_the_first_class_modes():
    assert first_class_modes() == ["cycling", "hiking", "paddling"]
    assert set(extended_modes()) == set(TRAVERSAL_MODES) - {"cycling", "hiking", "paddling"}
    for key in first_class_modes():
        assert TRAVERSAL_MODES[key].tier == FIRST_CLASS
    for key in extended_modes():
        assert TRAVERSAL_MODES[key].tier == EXTENDED


def test_every_mode_carries_its_domain_parameters():
    """FR130 — "a new `WeightProfile` entry and its domain parameters". A row
    missing one of them is a mode the engine cannot actually run."""
    for key, mode in TRAVERSAL_MODES.items():
        assert mode.key == key
        assert isinstance(mode.weights, WeightProfile)
        assert mode.network_type
        assert mode.medium in {"land", "water", "snow"}
        assert mode.base_speed_kmh > 0.0
        assert mode.label and mode.label != key


def test_lookups_fall_through_for_an_unknown_mode_rather_than_raising():
    """FR144 — an Author may create a passage in an undeclared mode, and a
    plugin may declare one this build has never heard of."""
    assert traversal_mode("teleportation") is None
    assert weights_for("teleportation") == WeightProfile()
    assert network_type_for("teleportation") == "bike"
    assert base_speed_kmh("teleportation") is None
    assert mode_label("teleportation") == "teleportation"
    # `access` falls through to the mode itself, so `routing.access` treats an
    # unknown mode exactly as it did before this registry existed.
    assert access_mode_for("teleportation") == "teleportation"


# --- the schema enum mirrors the registry --------------------------------


def test_the_schema_travel_mode_enum_matches_the_registry():
    schema = json.loads(_SCHEMA.read_text())
    assert schema["$defs"]["travel_mode"]["enum"] == all_mode_keys()


# --- FR109 / O4: stations are not modes ----------------------------------


@pytest.mark.parametrize("activity", ["climbing", "canyoneering", "jumaring"])
def test_station_activities_never_appear_as_travel_modes(activity):
    """Punchlist §2.6's fail signal, verbatim: "climbing or canyoneering
    appears anywhere in a *travel mode* list"."""
    assert is_station_activity(activity)
    assert activity not in TRAVERSAL_MODES
    assert activity not in TRANSPORT_NOTE_MODES
    assert activity not in all_mode_keys()


def test_the_schema_enum_carries_no_station_activity():
    schema = json.loads(_SCHEMA.read_text())
    assert not STATION_ACTIVITIES & set(schema["$defs"]["travel_mode"]["enum"])


# --- FR130: legality is aliased, not duplicated --------------------------


def test_aliased_modes_resolve_to_an_existing_constraints_row():
    """Mountain biking is legally cycling, packrafting legally paddling,
    cross-country skiing legally foot travel — one rule set each side, no
    second constraints table."""
    assert access.constraints_for("mountain_biking") is access.MODE_CONSTRAINTS["cycling"]
    assert access.constraints_for("packrafting") is access.MODE_CONSTRAINTS["paddling"]
    assert access.constraints_for("riverboarding") is access.MODE_CONSTRAINTS["paddling"]
    assert access.constraints_for("cross_country_skiing") is access.MODE_CONSTRAINTS["hiking"]


def test_an_aliased_mode_inherits_the_hard_exclusion_it_should():
    """`bicycle=no` closes a way to a mountain bike as surely as to a tourer —
    without `mountain_biking` appearing anywhere in `MODE_CONSTRAINTS`."""
    assert "mountain_biking" not in access.MODE_CONSTRAINTS
    verdict = access.evaluate_edge({"highway": "path", "bicycle": "no"}, "mountain_biking")
    assert not verdict.passable
    assert verdict.reason == "bicycle=no"


def test_driving_has_its_own_row_and_honours_motor_vehicle_access():
    verdict = access.evaluate_edge({"highway": "track", "motor_vehicle": "no"}, "driving")
    assert not verdict.passable
    assert verdict.reason == "motor_vehicle=no"
    # A ford is a hard stop for a car, unlike on foot.
    assert not access.evaluate_edge({"highway": "track", "ford": "yes"}, "driving").passable
    assert access.evaluate_edge({"highway": "path", "ford": "yes"}, "hiking").passable


def test_a_gate_on_a_forest_road_is_surfaced_for_driving_never_deleted():
    """FR29a's rule applied to legality: the driving leg exists precisely
    because the last mile is rough — name the obstacle, don't silently remove
    the only road in."""
    verdict = access.evaluate_edge({"highway": "track", "barrier": "gate"}, "driving")
    assert verdict.passable
    assert "barrier=gate" in verdict.flags


def test_the_mode_graph_cache_is_shared_by_modes_with_one_rule_set():
    graph = nx.MultiDiGraph()
    graph.add_edge(1, 2, highway="path", length=10.0)
    filtered = access.mode_legal_graph(graph, "cycling")
    assert access.mode_legal_graph(graph, "mountain_biking") is filtered


def test_an_unknown_mode_still_routes_unconstrained():
    graph = nx.MultiDiGraph()
    graph.add_edge(1, 2, highway="path", bicycle="no", length=10.0)
    assert access.mode_legal_graph(graph, "teleportation") is graph


# --- FR130: a new mode is configuration, not a scorer --------------------


def test_adding_a_mode_needs_only_a_profile_and_domain_parameters():
    """FR130's claim, exercised end to end: a mode this codebase has never
    heard of is a registry row, and the one shared scoring function consumes
    its profile with no branch on the mode at all."""
    registry = {
        **TRAVERSAL_MODES,
        "snowshoeing": TraversalMode(
            key="snowshoeing",
            label="Snowshoe",
            tier=EXTENDED,
            medium="snow",
            weights=WeightProfile(name="snowshoeing", quiet=1.0, directness=0.2),
            network_type="walk",
            access_mode="hiking",
            base_speed_kmh=3.0,
        ),
    }

    assert is_traversal_mode("snowshoeing", registry)
    assert mode_label("snowshoeing", registry) == "Snowshoe"
    assert base_speed_kmh("snowshoeing", registry) == 3.0
    # It inherits foot legality without a `MODE_CONSTRAINTS` row of its own.
    assert access_mode_for("snowshoeing", registry) == "hiking"

    # And the one scorer prices an edge under it, exactly as for any other
    # profile — no `if mode == ...` anywhere in the call.
    edge = {"highway": "residential", "length": 100.0, "maxspeed": "60"}
    quiet_cost = edge_cost(edge, weights_for("snowshoeing", registry))
    indifferent_cost = edge_cost(edge, WeightProfile(name="flat", quiet=0.0, directness=0.2))
    assert quiet_cost > indifferent_cost


def test_a_modes_profile_is_a_real_scoring_input_not_decoration():
    """Mountain biking's registry row seeks singletrack outright and avoids
    pavement (FR4's bipolar dials); that has to show up as a cheaper trail
    edge and a dearer paved one under the shared scorer."""
    trail = {"highway": "path", "length": 100.0}
    road = {"highway": "residential", "surface": "asphalt", "length": 100.0}
    mtb = weights_for("mountain_biking")
    plain = weights_for("cycling")
    assert edge_cost(trail, mtb) < edge_cost(trail, plain)
    assert edge_cost(road, mtb) > edge_cost(road, plain)
