"""Provision-layer coverage — PRD FR104, ARCH Q16.

FR104 proposes co-located utility features as candidate rest stops /
provisions, with "toilet + drinking water + shelter" and "café + restroom +
bike repair station" as its two worked clusters. Before the Q16 mapping
pass the taxonomy carried `drinking_water` and `shelter` only, so neither
cluster could be computed. These tests pin that the contributing amenities
now all resolve to `provision`-affinity rules and reach the candidate set.
"""

import pytest

from plotlines_core.curation.notability import RawFeature, score_notability
from plotlines_core.curation.providers import osm_tags_for
from plotlines_core.curation.taxonomy import LAYERS, match

# The amenities each of FR104's two worked clusters is built from.
_TOILET_WATER_SHELTER = ("toilets", "drinking_water", "shelter")
_CAFE_RESTROOM_BIKE_REPAIR = ("cafe", "toilets", "bicycle_repair_station")

_ALL_PROVISION_AMENITIES = (
    "toilets", "drinking_water", "water_point", "shower", "shelter",
    "cafe", "restaurant", "fast_food", "pharmacy",
    "bicycle_repair_station", "compressed_air",
)


@pytest.mark.parametrize("value", _ALL_PROVISION_AMENITIES)
def test_each_provision_amenity_is_in_the_taxonomy(value):
    rule = match({"amenity": value})
    assert rule is not None, f"amenity={value} is not mapped"
    assert rule.role_affinity == "provision"
    assert rule.layer == "amenity"


@pytest.mark.parametrize(
    "cluster",
    [_TOILET_WATER_SHELTER, _CAFE_RESTROOM_BIKE_REPAIR],
    ids=["toilet+water+shelter", "cafe+restroom+bike_repair"],
)
def test_fr104_worked_cluster_is_expressible(cluster):
    # Every contributing amenity resolves, and to the same affinity, so a
    # co-location engine (Leg 2.5) proposing the union of affinities present
    # gets a clean `provision` proposal (ARCH D47) rather than a partial one.
    affinities = set()
    for value in cluster:
        rule = match({"amenity": value})
        assert rule is not None, f"FR104 cluster needs amenity={value}, taxonomy has no rule"
        affinities.add(rule.role_affinity)
    assert affinities == {"provision"}


@pytest.mark.parametrize("value", _ALL_PROVISION_AMENITIES)
def test_provision_amenity_scores_as_a_candidate_on_a_rest_day(value):
    # "amenity" is live on a rest day (config/layer_defaults.json); a
    # provision amenity with no over-trigger gate should score, not filter.
    features = [RawFeature(id="1", coord=(-82.55, 35.6), tags={"amenity": value})]
    candidates = score_notability(features, live_layers={"amenity"})
    assert len(candidates) == 1
    assert candidates[0].role_affinity == "provision"
    assert 0.0 <= candidates[0].salience <= 1.0


def test_provision_amenities_are_not_live_on_a_route_day():
    # The Frodo principle is a rest-day concern; "amenity" is not in the
    # route-day default live set, so these never clutter a riding day.
    features = [RawFeature(id="1", coord=(0, 0), tags={"amenity": "toilets"})]
    assert score_notability(features, live_layers={"sight", "historic", "natural"}) == []


def test_osm_provider_requests_the_provision_amenities_from_overpass():
    tags = osm_tags_for({"amenity"})
    assert "amenity" in tags
    requested = set(tags["amenity"])
    missing = [v for v in _ALL_PROVISION_AMENITIES if v not in requested]
    assert not missing, f"osm_tags_for would not fetch: {missing}"


def test_existing_non_amenity_layers_are_unaffected():
    # A regression guard for the mapping pass: adding amenity rows must not
    # perturb what another layer asks Overpass for.
    assert osm_tags_for({"historic"}) == {"historic": True}


def test_full_catalog_still_spans_exactly_the_six_layers():
    assert LAYERS == {"sight", "amenity", "natural", "historic", "leisure", "man_made"}
