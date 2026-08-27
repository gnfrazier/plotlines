"""Unit tests for `plotlines_core.curation.colocate` (PRD FR102-FR105a, N4/N4a).

The ranking function, corridor treatment and cap were tuned by SPIKE-B
(issue #169); these lock the behaviour those decisions produced.
"""

from dataclasses import replace

from plotlines_core.curation.colocate import (
    analyze_colocation, analyze_colocation_full, by_corridor_proximity,
    diff_runs, reviewable_cap, DEFAULTS,
)
from plotlines_core.curation.notability import Candidate
from plotlines_core.curation.providers import BBox

BOX = BBox(-1.0, -1.0, 1.0, 1.0)
# ~ metres-per-degree near the equator, for placing points a known distance apart
_M_PER_DEG = 111_320.0


def cand(cid, lon, lat, salience=0.6, affinity="narrative", tags=None, title=None):
    return Candidate(id=cid, coord=(lon, lat), layer=affinity, salience=salience,
                     role_affinity=affinity, tags=tags or {"tourism": "viewpoint"},
                     title=title)


def at(lon0, lat0, dx_m=0.0, dy_m=0.0):
    return (lon0 + dx_m / _M_PER_DEG, lat0 + dy_m / _M_PER_DEG)


# --- clustering -------------------------------------------------------------- #

def test_three_near_features_make_one_proposal():
    p0 = (0.0, 0.0)
    cands = [cand("a", *p0),
             cand("b", *at(*p0, 30, 0)),
             cand("c", *at(*p0, 0, 30))]
    props = analyze_colocation(cands, BOX)
    assert len(props) == 1
    assert {m.candidate_id for m in props[0].members} == {"a", "b", "c"}


def test_isolated_feature_is_not_a_proposal():
    cands = [cand("a", 0.0, 0.0),
             cand("b", *at(0.0, 0.0, 5000, 0))]   # 5 km away
    assert analyze_colocation(cands, BOX) == []


def test_diameter_ceiling_splits_a_long_chain():
    # five points 120 m apart in a line span ~480 m — one single-linkage blob,
    # but complete linkage at 160 m must break it into several proposals.
    p0 = (0.0, 0.0)
    cands = [cand(str(i), *at(*p0, 120 * i, 0)) for i in range(5)]
    props = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100))
    assert len(props) >= 2
    for p in props:
        assert p.extent_m <= DEFAULTS.max_diameter_m


def test_candidates_outside_bbox_are_ignored():
    cands = [cand("in1", 0.0, 0.0), cand("in2", *at(0.0, 0.0, 20, 0)),
             cand("out1", 5.0, 5.0), cand("out2", *at(5.0, 5.0, 20, 0))]
    props = analyze_colocation(cands, BOX)
    assert len(props) == 1
    assert all(m.candidate_id.startswith("in") for m in props[0].members)


# --- affinity union (FR105 / D47) ----------------------------------------- #

def test_narrative_only_cluster_reads_as_narrative():
    cands = [cand("a", 0.0, 0.0, affinity="narrative"),
             cand("b", *at(0.0, 0.0, 25, 0), affinity="narrative")]
    p = analyze_colocation(cands, BOX)[0]
    assert p.kind == "narrative"
    assert p.role_affinities == ("narrative",)


def test_provision_only_cluster_reads_as_provision():
    cands = [cand("a", 0.0, 0.0, affinity="provision"),
             cand("b", *at(0.0, 0.0, 25, 0), affinity="provision")]
    p = analyze_colocation(cands, BOX)[0]
    assert p.kind == "provision"
    assert p.role_affinities == ("provision",)


def test_mixed_cluster_proposes_the_union():
    cands = [cand("mon", 0.0, 0.0, affinity="narrative", salience=0.8),
             cand("wc", *at(0.0, 0.0, 20, 0), affinity="provision"),
             cand("water", *at(0.0, 0.0, 0, 20), affinity="provision")]
    p = analyze_colocation(cands, BOX)[0]
    assert p.kind == "narrative+provision"
    assert p.role_affinities == ("narrative", "provision")


def test_plugin_station_affinity_participates_with_no_core_change():
    # a plugin type the core has never heard of, declaring `station`.
    cands = [cand("crag", 0.0, 0.0, affinity="station",
                  tags={"type": "crag"}, title="North Buttress"),
             cand("water", *at(0.0, 0.0, 25, 0), affinity="provision")]
    p = analyze_colocation(cands, BOX)[0]
    assert "station" in p.role_affinities
    assert p.kind.endswith("+station")


def test_station_only_cluster_does_not_double_its_kind():
    cands = [cand("c1", 0.0, 0.0, affinity="station", tags={"type": "crag"}),
             cand("c2", *at(0.0, 0.0, 25, 0), affinity="station", tags={"type": "crag"})]
    p = analyze_colocation(cands, BOX)[0]
    assert p.kind == "station"
    assert p.role_affinities == ("station",)


# --- ranking: salience x tightness -------------------------------------- #

def test_more_notable_cluster_outranks_less_notable_at_equal_tightness():
    p0, p1 = (0.0, 0.0), (0.5, 0.5)
    cands = [
        cand("hi1", *p0, salience=0.9), cand("hi2", *at(*p0, 25, 0), salience=0.9),
        cand("lo1", *p1, salience=0.3), cand("lo2", *at(*p1, 25, 0), salience=0.3),
    ]
    props = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100))
    assert props[0].members[0].candidate_id.startswith("hi")


def test_tighter_cluster_outranks_looser_at_equal_salience():
    tight0 = (0.0, 0.0)
    loose0 = (0.5, 0.5)
    cands = [
        cand("t1", *tight0, salience=0.6), cand("t2", *at(*tight0, 15, 0), salience=0.6),
        cand("l1", *loose0, salience=0.6), cand("l2", *at(*loose0, 150, 0), salience=0.6),
    ]
    props = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100))
    assert props[0].members[0].candidate_id.startswith("t")


# --- corridor proximity (Q12): filter + resort, not the default rank ---- #

def _two_clusters_one_on_route():
    near0 = (0.0, 0.0)
    far0 = (0.0, 0.5)                      # ~55 km north
    route = [(-0.5, 0.0), (0.5, 0.0)]     # runs east-west through y=0
    cands = [
        cand("near1", *near0, salience=0.6), cand("near2", *at(*near0, 20, 0), salience=0.6),
        cand("far1", *far0, salience=0.9), cand("far2", *at(*far0, 20, 0), salience=0.9),
    ]
    return cands, route


def test_route_does_not_change_the_default_rank():
    cands, route = _two_clusters_one_on_route()
    no_route = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100))
    with_route = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100), route=route)
    assert [p.id for p in no_route] == [p.id for p in with_route]
    # the far, more-notable cluster still ranks first by salience x tightness
    assert with_route[0].members[0].candidate_id.startswith("far")


def test_distance_to_route_is_populated_only_when_a_route_is_given():
    cands, route = _two_clusters_one_on_route()
    assert all(p.distance_to_route_m is None
               for p in analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100)))
    withr = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100), route=route)
    assert all(p.distance_to_route_m is not None for p in withr)
    near = next(p for p in withr if p.members[0].candidate_id.startswith("near"))
    assert near.distance_to_route_m < 100


def test_corridor_resort_pulls_the_on_route_cluster_up():
    cands, route = _two_clusters_one_on_route()
    props = analyze_colocation(cands, BOX, replace(DEFAULTS, cap_floor=100), route=route)
    assert props[0].members[0].candidate_id.startswith("far")     # default: far wins
    resorted = by_corridor_proximity(props)
    assert resorted[0].members[0].candidate_id.startswith("near")  # resort: near wins


# --- cap (FR105a / N4a) ------------------------------------------------- #

def test_cap_is_the_floor_with_no_route():
    assert reviewable_cap(DEFAULTS) == DEFAULTS.cap_floor


def test_cap_grows_with_route_length():
    short = [(0.0, 0.0), (0.1, 0.0)]      # ~11 km
    long = [(0.0, 0.0), (2.0, 0.0)]       # ~222 km
    assert reviewable_cap(DEFAULTS, long) > reviewable_cap(DEFAULTS, short) > DEFAULTS.cap_floor


def test_full_returns_the_beyond_count_and_never_truncates_silently():
    p0 = (0.0, 0.0)
    # 40 well-separated pairs -> 40 proposals, cap 5
    cands = []
    for i in range(40):
        c0 = at(*p0, 0, 400 * i)
        cands += [cand(f"{i}a", *c0), cand(f"{i}b", *at(*c0, 20, 0))]
    params = replace(DEFAULTS, cap_floor=5)
    shown, beyond = analyze_colocation_full(cands, BOX, params)
    assert len(shown) == 5
    assert beyond == 35
    assert len(shown) + beyond == 40


# --- rejection memory + re-run (FR110 / N4a) --------------------------- #

def test_a_rejected_member_set_is_not_re_proposed():
    p0 = (0.0, 0.0)
    cands = [cand("a", *p0), cand("b", *at(*p0, 25, 0)), cand("c", *at(*p0, 0, 25))]
    first = analyze_colocation(cands, BOX)
    assert len(first) == 1
    again = analyze_colocation(cands, BOX, rejected=[first[0].member_key])
    assert again == []


def test_rejection_survives_an_unrelated_new_candidate_elsewhere():
    p0, p1 = (0.0, 0.0), (0.7, 0.7)
    base = [cand("a", *p0), cand("b", *at(*p0, 25, 0))]
    rej = analyze_colocation(base, BOX)[0].member_key
    later = base + [cand("x", *p1), cand("y", *at(*p1, 25, 0))]
    props = analyze_colocation(later, BOX, rejected=[rej])
    assert all(m.candidate_id not in ("a", "b") for p in props for m in p.members)
    assert len(props) == 1  # only the new, un-rejected cluster


def test_diff_runs_marks_new_and_carried_over():
    p0, p1 = (0.0, 0.0), (0.5, 0.5)
    run1_cands = [cand("a", *p0), cand("b", *at(*p0, 25, 0))]
    run1 = analyze_colocation(run1_cands, BOX)
    run2_cands = run1_cands + [cand("x", *p1), cand("y", *at(*p1, 25, 0))]
    run2 = analyze_colocation(run2_cands, BOX, replace(DEFAULTS, cap_floor=100))
    marked = diff_runs(run1, run2)
    by_first = {p.members[0].candidate_id: p for p in marked}
    assert by_first["a"].is_new is False
    assert by_first["x"].is_new is True


def test_proposal_id_is_stable_across_runs():
    p0 = (0.0, 0.0)
    cands = [cand("a", *p0), cand("b", *at(*p0, 25, 0))]
    id1 = analyze_colocation(cands, BOX)[0].id
    id2 = analyze_colocation(list(reversed(cands)), BOX)[0].id
    assert id1 == id2
