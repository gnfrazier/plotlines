"""Unit tests for `plotlines_core.curation.taxonomy` (PRD FR97/FR98)."""

import pytest

from plotlines_core.curation.taxonomy import LAYERS, Qualification, match, weight_for


def test_layers_span_the_osm_taxonomy():
    # FR97's AC: "Layer catalog spans the OSM sightseeing/amenity/natural/
    # historic/leisure/man-made taxonomy".
    assert LAYERS == {"sight", "amenity", "natural", "historic", "leisure", "man_made"}


def test_historic_wildcard_matches_any_value():
    rule = match({"historic": "boundary_stone"})
    assert rule is not None
    assert rule.key == "historic" and rule.is_wildcard


def test_exact_rule_wins_over_wildcard_on_same_key():
    rule = match({"historic": "memorial"})
    assert rule is not None
    assert rule.value == "memorial" and not rule.is_wildcard


def test_unknown_type_does_not_match():
    assert match({"shop": "bakery"}) is None


def test_historic_castle_outranks_boundary_stone():
    # FR98(a)'s seed case, stated directly: "a castle, fort, or archaeological
    # site must outrank a boundary stone or milestone".
    castle = match({"historic": "castle"})
    stone = match({"historic": "boundary_stone"})
    assert weight_for(castle, {"historic": "castle"}) > weight_for(stone, {"historic": "boundary_stone"})


def test_uncataloged_wildcard_value_floors_below_the_wildcard_base_weight():
    rule = match({"historic": "something_never_seeded"})
    weight = weight_for(rule, {"historic": "something_never_seeded"})
    assert weight < rule.base_weight or weight <= 0.3


def test_non_wildcard_rule_ignores_value_weights_table():
    rule = match({"historic": "memorial"})
    assert weight_for(rule, {"historic": "memorial"}) == rule.base_weight


def test_qualification_with_no_gate_is_always_satisfied():
    q = Qualification()
    assert q.satisfied_by({}, None) is True


def test_qualification_requires_any_needs_a_non_empty_value():
    q = Qualification(requires_any=("denotation",))
    assert q.satisfied_by({"denotation": ""}, None) is False
    assert q.satisfied_by({"denotation": "natural_monument"}, None) is True
    assert q.satisfied_by({}, None) is False


def test_qualification_area_threshold():
    q = Qualification(min_area_m2=20_000.0)
    assert q.satisfied_by({}, 10_000.0) is False
    assert q.satisfied_by({}, 20_000.0) is True
    assert q.satisfied_by({}, None) is False


def test_qualification_requires_value_checks_the_value_not_just_presence():
    # SPIKE-A: `denotation=avenue` (a street tree) must NOT satisfy a gate that
    # `denotation=natural_monument` does.
    q = Qualification(requires_value={"denotation": ("natural_monument", "landmark")})
    assert q.satisfied_by({"denotation": "natural_monument"}, None) is True
    assert q.satisfied_by({"denotation": "avenue"}, None) is False
    assert q.satisfied_by({"denotation": ""}, None) is False
    assert q.satisfied_by({}, None) is False


def test_tree_gates_on_denotation_value():
    # The calibrated `natural=tree` rule: only the notable denotation values pass.
    assert match({"natural": "tree"}) is not None  # it has a rule
    rule = match({"natural": "tree"})
    assert rule.qualification.satisfied_by({"natural": "tree", "denotation": "avenue"}, None) is False
    assert rule.qualification.satisfied_by(
        {"natural": "tree", "denotation": "natural_monument"}, None) is True


def test_historic_district_outranks_a_plain_historic_building():
    # SPIKE-A sub-weight addition: a whole conservation area is the strongest
    # thing the `historic=*` wildcard sees.
    wild = match({"historic": "district"})
    assert weight_for(wild, {"historic": "district"}) > weight_for(wild, {"historic": "building"})
    assert weight_for(wild, {"historic": "yes"}) <= 0.1


def test_bridge_needs_a_heritage_signal_not_just_a_name():
    rule = match({"man_made": "bridge"})
    assert rule is not None
    assert rule.qualification.satisfied_by({"man_made": "bridge", "name": "Gould Avenue"}, None) is False
    assert rule.qualification.satisfied_by(
        {"man_made": "bridge", "name": "Colorado Street Bridge", "heritage": "2"}, None) is True


# --- Story C7 (issue #43, FR23) — lodging/campground types -----------------


@pytest.mark.parametrize("value", ["hotel", "hostel", "camp_site", "alpine_hut", "wilderness_hut"])
def test_lodging_types_match_under_the_amenity_layer_with_station_affinity(value):
    rule = match({"tourism": value})
    assert rule is not None
    assert rule.layer == "amenity"
    assert rule.role_affinity == "station"


def test_lodging_types_carry_no_qualification_gate():
    # Unlike street trees or a generic "attraction" pin, lodging is
    # low-density in a trip-sized bbox — every instance is something an
    # Author filtering by type wants to see, so nothing gates it.
    for value in ("hotel", "hostel", "camp_site", "alpine_hut", "wilderness_hut"):
        rule = match({"tourism": value})
        assert rule.qualification.satisfied_by({"tourism": value}, None) is True


def test_lodging_never_collides_with_the_existing_sight_tourism_rows():
    # `tourism=viewpoint`/`museum` are narrative "sight" rows already in the
    # taxonomy — the new lodging rows must not shadow or be shadowed by them.
    viewpoint = match({"tourism": "viewpoint"})
    hotel = match({"tourism": "hotel"})
    assert viewpoint.layer == "sight" and viewpoint.role_affinity == "narrative"
    assert hotel.layer == "amenity" and hotel.role_affinity == "station"
