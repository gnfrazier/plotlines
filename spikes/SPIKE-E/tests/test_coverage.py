"""The denominators. Every published percentage is a fraction of one of these, so the
de-duplication and eligibility rules are worth more tests than the arithmetic."""

from __future__ import annotations

import coverage as cov
from regions import MIN_ELIGIBLE_WAYS, band_for


def edge(u, v, osmid, length=100.0, **tags):
    return (u, v, {"osmid": osmid, "length": length, **tags})


def test_a_two_way_road_counts_once():
    """Both directions of one way are one road. Counting edges would double every
    two-way street and quietly weight the answer toward town."""
    ways = cov.collect([edge(1, 2, 10), edge(2, 1, 10)], "network")
    assert ways.count == 1
    assert ways.km == 0.1


def test_distinct_ways_between_the_same_nodes_are_distinct():
    ways = cov.collect([edge(1, 2, 10), edge(1, 2, 11)], "network")
    assert ways.count == 2


def test_tracktype_is_only_eligible_on_tracks():
    ways = cov.collect([
        edge(1, 2, 10, highway="track", tracktype="grade3"),
        edge(2, 3, 11, highway="unclassified"),
        edge(3, 4, 12, highway="residential"),
    ], "network")
    signals = cov.signal_coverage(ways)
    assert signals["tracktype"]["eligible_ways"] == 1
    assert signals["tracktype"]["pct_ways"] == 100.0
    # ...while `surface` is eligible everywhere and reads 0 here.
    assert signals["surface"]["eligible_ways"] == 3
    assert signals["surface"]["pct_ways"] == 0.0


def test_km_and_way_percentages_separate():
    """One 40 km untagged road and one 100 m tagged spur: half the ways, 0.2% of the
    kilometres. Reporting only the first would be flattering and useless."""
    ways = cov.collect([
        edge(1, 2, 10, length=40_000.0),
        edge(2, 3, 11, length=100.0, surface="gravel"),
    ], "route")
    surface = cov.signal_coverage(ways)["surface"]
    assert surface["pct_ways"] == 50.0
    assert surface["pct_km"] < 1.0


def test_any_signal_ignores_motor_vehicle():
    """`motor_vehicle` is an access tag; counting it as condition coverage would let
    a legality tag vouch for a road nobody has surveyed."""
    ways = cov.collect([edge(1, 2, 10, motor_vehicle="destination")], "route")
    assert cov.any_signal_coverage(ways)["pct_ways"] == 0.0
    ways = cov.collect([edge(1, 2, 10, highway="track")], "route")
    assert cov.any_signal_coverage(ways)["pct_ways"] == 100.0


def test_track_prevalence_is_reported_separately_from_coverage():
    ways = cov.collect([
        edge(1, 2, 10, highway="track", length=1000.0),
        edge(2, 3, 11, highway="unclassified", length=3000.0),
    ], "network")
    assert "track" not in cov.signal_coverage(ways)
    assert cov.prevalence(ways)["pct_km"] == 25.0


def test_a_thin_sample_reports_na_not_absent():
    assert band_for(0.0, MIN_ELIGIBLE_WAYS - 1) == "n/a"
    assert band_for(0.0, MIN_ELIGIBLE_WAYS) == "absent"
    assert band_for(25.0, 100) == "opportunistic"
    assert band_for(80.0, 100) == "read"


def test_list_valued_tags_are_read():
    ways = cov.collect([edge(1, 2, [10, 11], surface=["gravel", "dirt"])], "route")
    assert cov.signal_coverage(ways)["surface"]["pct_ways"] == 100.0
