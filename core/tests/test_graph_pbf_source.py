"""Unit tests for `plotlines_core.graph.pbf_source` — issue #275 (Phase 3.3
of epic #272). Promoted from `spikes/SPIKE-I/elements.py` /
`spikes/SPIKE-I/graphs.py`, which measured this approach at exact parity
against a live-Overpass golden (`spikes/SPIKE-I/results/RESULTS.md` §1); these
tests exercise the module's own mechanics — the way filter, complete-ways
node pull-through, and the drive/track exclusion SPIKE-E found — rather than
re-running that calibration.
"""

from __future__ import annotations

import osmium
import pytest
from osmium.osm import mutable

from plotlines_core.graph import pbf_source as P


def _node(id_: int, lon: float, lat: float, tags: dict[str, str] | None = None):
    return mutable.Node(id=id_, location=(lon, lat), tags=tags or {})


def _way(id_: int, node_ids: list[int], tags: dict[str, str] | None = None):
    return mutable.Way(id=id_, nodes=node_ids, tags=tags or {})


def _write_pbf(path, *, nodes=(), ways=()):
    path.parent.mkdir(parents=True, exist_ok=True)
    with osmium.SimpleWriter(str(path)) as writer:
        for n in nodes:
            writer.add_node(n)
        for w in ways:
            writer.add_way(w)
    return path


# --------------------------------------------------------------------------
# The Overpass QL filter parser
# --------------------------------------------------------------------------


def test_parse_overpass_filter_exists_clause():
    clauses = P.parse_overpass_filter('["highway"]')
    assert len(clauses) == 1
    assert clauses[0].op == "exists"
    assert clauses[0].test({"highway": "residential"})
    assert not clauses[0].test({})


def test_parse_overpass_filter_not_matches_is_permissive_on_an_absent_key():
    # `["bicycle"!~"no"]` must NOT exclude a way with no `bicycle` tag at
    # all — both halves of Overpass's semantics matter here (module docstring).
    clauses = P.parse_overpass_filter('["bicycle"!~"no"]')
    assert clauses[0].test({})  # absent key passes
    assert not clauses[0].test({"bicycle": "no"})
    assert clauses[0].test({"bicycle": "yes"})


def test_parse_overpass_filter_not_matches_is_unanchored():
    # The worked consequence the module docstring calls out: "unknown"
    # contains "no", so `["bicycle"!~"no"]` excludes it too.
    clauses = P.parse_overpass_filter('["bicycle"!~"no"]')
    assert not clauses[0].test({"bicycle": "unknown"})


def test_network_clauses_bike_matches_osmnxs_own_filter_string():
    from osmnx import _overpass

    clauses = P.network_clauses("bike")
    assert clauses == P.parse_overpass_filter(_overpass._get_network_filter("bike"))


# --------------------------------------------------------------------------
# elements_from_pbf — complete-ways membership and node pull-through
# --------------------------------------------------------------------------


def test_elements_from_pbf_keeps_a_way_with_a_vertex_inside_the_polygon(tmp_path):
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(1, 0.0, 0.0), _node(2, 0.001, 0.001)],
        ways=[_way(10, [1, 2], {"highway": "residential"})],
    )
    polygon = P.bbox_polygon((-0.01, -0.01, 0.01, 0.01))

    extracted = P.elements_from_pbf(pbf, polygon, "all")

    assert extracted.ways_kept == 1
    assert extracted.nodes_emitted == 2


def test_elements_from_pbf_pulls_in_a_referenced_node_outside_the_polygon(tmp_path):
    # Node 2 sits well outside the small polygon below; the way is kept
    # because node 1 is inside, and node 2 must still be emitted — this is
    # the "complete ways" behaviour `mirror_clip._CompleteWaysSelector`
    # already applies to the clip this module reads.
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(1, 0.0, 0.0), _node(2, 5.0, 5.0)],
        ways=[_way(10, [1, 2], {"highway": "residential"})],
    )
    polygon = P.bbox_polygon((-0.01, -0.01, 0.01, 0.01))

    extracted = P.elements_from_pbf(pbf, polygon, "all")

    assert extracted.ways_kept == 1
    assert extracted.nodes_emitted == 2  # node 2 pulled in despite being outside


def test_elements_from_pbf_drops_a_way_entirely_outside_the_polygon(tmp_path):
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(1, 5.0, 5.0), _node(2, 5.001, 5.001)],
        ways=[_way(10, [1, 2], {"highway": "residential"})],
    )
    polygon = P.bbox_polygon((-0.01, -0.01, 0.01, 0.01))

    extracted = P.elements_from_pbf(pbf, polygon, "all")

    assert extracted.ways_kept == 0
    assert extracted.nodes_emitted == 0


def test_elements_from_pbf_ignores_a_way_that_fails_the_network_type_filter(tmp_path):
    # `highway=footway` is excluded from `bike`'s own filter.
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(1, 0.0, 0.0), _node(2, 0.001, 0.001)],
        ways=[_way(10, [1, 2], {"highway": "footway"})],
    )
    polygon = P.bbox_polygon((-0.01, -0.01, 0.01, 0.01))

    extracted = P.elements_from_pbf(pbf, polygon, "bike")

    assert extracted.ways_considered == 1
    assert extracted.ways_kept == 0


def test_elements_from_pbf_ignores_a_way_with_no_highway_tag(tmp_path):
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(1, 0.0, 0.0), _node(2, 0.001, 0.001)],
        ways=[_way(10, [1, 2], {"waterway": "stream"})],
    )
    polygon = P.bbox_polygon((-0.01, -0.01, 0.01, 0.01))

    extracted = P.elements_from_pbf(pbf, polygon, "all")

    assert extracted.ways_considered == 0
    assert extracted.ways_kept == 0


# --------------------------------------------------------------------------
# graph_from_pbf — the whole transport, end to end
# --------------------------------------------------------------------------


def test_graph_from_pbf_builds_a_routable_graph(tmp_path):
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(1, -105.29, 40.00), _node(2, -105.28, 40.01),
               _node(3, -105.27, 40.02)],
        ways=[_way(10, [1, 2, 3], {"highway": "residential"})],
    )
    bbox = (-105.31, 39.99, -105.27, 40.03)

    graph = P.graph_from_pbf(pbf, bbox, "all")

    assert graph.number_of_nodes() == 3
    assert graph.number_of_edges() > 0


def test_graph_from_pbf_empty_extract_returns_a_null_graph(tmp_path):
    pbf = _write_pbf(tmp_path / "clip.osm.pbf", nodes=[_node(1, -105.29, 40.00)])
    bbox = (-105.31, 39.99, -105.27, 40.03)

    graph = P.graph_from_pbf(pbf, bbox, "bike")

    assert graph.number_of_nodes() == 0


def test_graph_from_pbf_drive_drops_track_reproducing_spike_e(tmp_path):
    pbf = _write_pbf(
        tmp_path / "clip.osm.pbf",
        nodes=[_node(n, -105.30 + n * 0.001, 40.00) for n in range(1, 5)],
        ways=[
            _way(10, [1, 2], {"highway": "residential"}),
            _way(11, [3, 4], {"highway": "track"}),
        ],
    )
    bbox = (-105.31, 39.99, -105.27, 40.03)

    graph = P.graph_from_pbf(pbf, bbox, "drive")

    highways = {data.get("highway") for *_uv, data in graph.edges(data=True)}
    assert "residential" in highways
    assert "track" not in highways
