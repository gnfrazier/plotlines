"""Unit tests for `plotlines_core.curation.notability` (PRD FR98/FR99)."""

from plotlines_core.curation.notability import RawFeature, score_notability
from plotlines_core.curation.taxonomy import LAYERS


def test_every_candidate_carries_a_salience_score():
    features = [RawFeature(id="1", coord=(-105.27, 40.02), tags={"historic": "castle"})]
    candidates = score_notability(features, live_layers=LAYERS)
    assert len(candidates) == 1
    assert 0.0 <= candidates[0].salience <= 1.0


def test_historic_wildcard_ranks_castle_above_boundary_stone():
    features = [
        RawFeature(id="a", coord=(0, 0), tags={"historic": "boundary_stone"}),
        RawFeature(id="b", coord=(0, 0), tags={"historic": "castle"}),
    ]
    candidates = score_notability(features, live_layers=LAYERS)
    by_id = {c.id: c for c in candidates}
    assert by_id["b"].salience > by_id["a"].salience


def test_results_are_ranked_highest_salience_first():
    features = [
        RawFeature(id="low", coord=(0, 0), tags={"historic": "milestone"}),
        RawFeature(id="high", coord=(0, 0), tags={"historic": "castle"}),
        RawFeature(id="mid", coord=(0, 0), tags={"historic": "ruins"}),
    ]
    candidates = score_notability(features, live_layers=LAYERS)
    assert [c.id for c in candidates] == ["high", "mid", "low"]


def test_unqualified_tree_is_filtered_out_not_scored_low():
    # FR98(b): natural=tree needs `denotation` before it is displayable at all.
    features = [RawFeature(id="1", coord=(0, 0), tags={"natural": "tree"})]
    assert score_notability(features, live_layers=LAYERS) == []


def test_qualified_tree_with_denotation_is_a_candidate():
    features = [RawFeature(id="1", coord=(0, 0),
                            tags={"natural": "tree", "denotation": "natural_monument"})]
    candidates = score_notability(features, live_layers=LAYERS)
    assert len(candidates) == 1
    assert candidates[0].layer == "natural"


def test_park_qualifies_by_name_even_when_small():
    features = [RawFeature(id="1", coord=(0, 0),
                            tags={"leisure": "park", "name": "Chautauqua Park"},
                            area_m2=500.0)]
    candidates = score_notability(features, live_layers=LAYERS)
    assert len(candidates) == 1


def test_park_qualifies_by_area_even_when_unnamed():
    features = [RawFeature(id="1", coord=(0, 0), tags={"leisure": "park"}, area_m2=25_000.0)]
    candidates = score_notability(features, live_layers=LAYERS)
    assert len(candidates) == 1


def test_unnamed_small_park_is_filtered_out():
    features = [RawFeature(id="1", coord=(0, 0), tags={"leisure": "park"}, area_m2=500.0)]
    assert score_notability(features, live_layers=LAYERS) == []


def test_unnamed_attraction_is_filtered_out():
    features = [RawFeature(id="1", coord=(0, 0), tags={"tourism": "attraction"})]
    assert score_notability(features, live_layers=LAYERS) == []


def test_named_attraction_is_a_candidate():
    features = [RawFeature(id="1", coord=(0, 0),
                            tags={"tourism": "attraction", "name": "Big Rock"})]
    candidates = score_notability(features, live_layers=LAYERS)
    assert candidates[0].title == "Big Rock"


def test_silo_without_name_or_heritage_signal_is_filtered_out():
    features = [RawFeature(id="1", coord=(0, 0), tags={"man_made": "silo"})]
    assert score_notability(features, live_layers=LAYERS) == []


def test_silo_with_heritage_signal_is_a_candidate():
    features = [RawFeature(id="1", coord=(0, 0), tags={"man_made": "silo", "heritage": "4"})]
    assert len(score_notability(features, live_layers=LAYERS)) == 1


def test_feature_whose_layer_is_not_live_is_excluded():
    features = [RawFeature(id="1", coord=(0, 0), tags={"natural": "peak"})]
    assert score_notability(features, live_layers={"amenity"}) == []
    assert len(score_notability(features, live_layers={"natural"})) == 1


def test_unrecognized_type_never_becomes_a_candidate():
    features = [RawFeature(id="1", coord=(0, 0), tags={"shop": "bakery"})]
    assert score_notability(features, live_layers=LAYERS) == []


def test_candidate_carries_role_affinity_for_later_colocation_use():
    features = [RawFeature(id="1", coord=(0, 0), tags={"amenity": "drinking_water"})]
    candidates = score_notability(features, live_layers=LAYERS)
    assert candidates[0].role_affinity == "provision"
