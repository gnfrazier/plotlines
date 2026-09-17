"""Build an osmnx graph from a local, already-clipped `.osm.pbf` — issue
#275 (Phase 3.3 of epic #272; docs/Plotlines_OSM_Acquisition_Review.md §1,
§2, §8(4); PRD FR1). Promoted from `spikes/SPIKE-I/elements.py` and
`spikes/SPIKE-I/graphs.py`'s `_graph_from_elements`, which measured this
approach at exact parity against a live-Overpass golden on every cell of the
matrix (node/edge sets, edge-key stability, largest SCC, per-edge geometry,
tag survival — `spikes/SPIKE-I/results/RESULTS.md` §1).

**The whole trick, and why it is safe.** `ox.graph_from_polygon` is one
Overpass download call followed by a fixed, deterministic post-processing
pipeline (buffer -> truncate -> largest_component -> simplify -> truncate ->
largest_component -> street-count). Swap only the download call for a local
read of the same *Overpass response shape* and the rest of osmnx's own code
runs unchanged — which is the "transport swap, not a rewrite" framing this
issue's own body uses. `graph_from_pbf` below is that swap: it reads
`pbf_path` (the mirror's `/clip` output, already scoped to `bbox` by
`_CompleteWaysSelector` in `service.plotlines_service.mirror_clip`), filters
its ways exactly the way Overpass would for `network_type` (`network_clauses`,
derived from osmnx's own filter string rather than hand-copied), wraps the
surviving elements in Overpass's `{"elements": [...]}` envelope, and calls
osmnx's own `_create_graph` plus the identical buffer/truncate/simplify tail
`graph_from_polygon` runs.

**Why the shipped `/clip` (raw bbox, no buffer) is sufficient.** SPIKE-I's
clause I-9 predicted the 500 m buffer `graph_from_polygon` queries around a
requested polygon would be load-bearing — a raw-bbox clip would clip a road
short of where the buffered Overpass query would have reached, and the
prediction was wrong: `complete_ways` (`mirror_clip._CompleteWaysSelector`)
keeps a selected way **whole**, so a raw-bbox clip already reaches past its
own edge by up to a full way's length, further than 500 m in every cell
measured. Both the buffered and the raw arm reached exact parity. So this
module still selects elements against the *buffered* polygon (matching what
`graph_from_polygon` actually queries, and what SPIKE-I measured), but the
source bytes it reads are the plain, unbuffered `/clip` result — no second,
buffered clip request is needed, and `graph.extract_fetch` never asks for one.

**What this module is not.** It does not fetch or cache anything — `pbf_path`
must already exist on disk (`graph.extract_fetch.ensure_extract`, issue #274,
puts it at `CacheLayout.osm_extract(bbox, pin)`). It does not touch the
network, and it raises nothing Overpass-shaped: a caller with an empty result
gets a graph with zero nodes, exactly as `_create_graph` would from an empty
Overpass response — `graph.regions.ensure_graph` is what translates that into
`NoRoutableWaysError` (issue #248's existing, finished-sentence contract),
the same way it already does for the Overpass path.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import networkx as nx
import osmium
from osmnx import graph as oxgraph
from osmnx import projection, settings, stats, truncate
from osmnx import _errors, _overpass
from shapely.geometry import Point, Polygon, box

BBox = tuple[float, float, float, float]


# --------------------------------------------------------------------------
# The Overpass QL way filter, reproduced rather than hand-copied
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Clause:
    """One `["k"...]` clause of an Overpass way filter."""

    key: str
    #: "exists" | "not_matches" | "matches" | "equals" | "not_equals"
    op: str
    value: str | None = None

    def test(self, tags: dict[str, str]) -> bool:
        present = self.key in tags
        if self.op == "exists":
            return present
        if self.op == "not_matches":
            # Overpass `[k!~"v"]`: true when the key is ABSENT, or present and
            # its value does not match — both halves matter (a way with no
            # `bicycle` tag at all is not excluded by `["bicycle"!~"no"]`).
            return (not present) or re.search(self.value, tags[self.key]) is None
        if self.op == "matches":
            return present and re.search(self.value, tags[self.key]) is not None
        if self.op == "equals":
            return present and tags[self.key] == self.value
        if self.op == "not_equals":
            return (not present) or tags[self.key] != self.value
        raise ValueError(f"unhandled op {self.op!r}")


_CLAUSE_RE = re.compile(r'\["(?P<key>[^"]+)"(?:(?P<op>!~|~|!=|=)"(?P<value>[^"]*)")?\]')


def parse_overpass_filter(way_filter: str) -> tuple[Clause, ...]:
    """Parse an Overpass QL way filter into predicates.

    Two properties of Overpass's regex matching that a casual reimplementation
    gets wrong in the permissive direction, and that this preserves by
    construction (it uses the same `re.search`, not `re.fullmatch`, with no
    case-insensitive flag): the match is **unanchored** (`["highway"!~"motor"]`
    excludes `motorway`, `motorway_link`, and `motor`) and **case-sensitive**.
    """
    clauses = []
    for m in _CLAUSE_RE.finditer(way_filter):
        op_raw, value = m.group("op"), m.group("value")
        op = {
            None: "exists", "!~": "not_matches", "~": "matches",
            "=": "equals", "!=": "not_equals",
        }[op_raw]
        clauses.append(Clause(key=m.group("key"), op=op, value=value))
    if not clauses:
        raise ValueError(f"no clauses parsed from {way_filter!r}")
    return tuple(clauses)


def network_clauses(network_type: str) -> tuple[Clause, ...]:
    """The predicates for `network_type`, derived from osmnx's own filter
    string (`_overpass._get_network_filter`) rather than a hand-copied one —
    an osmnx upgrade that changes a filter changes this too, instead of
    silently building a graph to a filter osmnx no longer uses. This is also
    where SPIKE-E's known `drive` defect (dropping `highway=track` and
    `highway=service` before a way reaches the graph) is reproduced rather
    than accidentally fixed: parity with a known defect is parity, and
    fixing it is SPIKE-E's issue (#171) to own, not this module's."""
    return parse_overpass_filter(_overpass._get_network_filter(network_type))


def way_passes(tags: dict[str, str], clauses: Iterable[Clause]) -> bool:
    return all(c.test(tags) for c in clauses)


# --------------------------------------------------------------------------
# bbox <-> polygon helpers, matching what `graph_from_polygon` itself queries
# --------------------------------------------------------------------------


def bbox_polygon(bbox: BBox) -> Polygon:
    """`bbox` as a shapely Polygon, in the codebase's own (west, south, east,
    north) order — identical in effect to `osmnx.utils_geo.bbox_to_poly`."""
    west, south, east, north = bbox
    return box(west, south, east, north)


def buffered_polygon(bbox: BBox) -> Polygon:
    """The polygon `ox.graph_from_polygon` actually queries against: `bbox`
    projected, buffered by 500 m, and unprojected — never the bare bbox. A
    local read has to select elements against the same buffered polygon
    `graph_from_polygon` would have queried, or it is answering a narrower
    question than the golden it was measured against
    (`spikes/SPIKE-I/graphs.py::_graph_from_elements`'s docstring)."""
    poly = bbox_polygon(bbox)
    poly_proj, crs_utm = projection.project_geometry(poly)
    poly_proj_buff = poly_proj.buffer(500)
    poly_buff, _ = projection.project_geometry(poly_proj_buff, crs=crs_utm, to_latlong=True)
    return poly_buff


# --------------------------------------------------------------------------
# pbf -> Overpass-shaped elements
# --------------------------------------------------------------------------


@dataclass
class ExtractedElements:
    elements: list[dict[str, Any]]
    ways_considered: int
    ways_kept: int
    nodes_emitted: int


class _WayCollector(osmium.SimpleHandler):
    """Pass 1: which ways pass `network_type`'s filter and touch `polygon`
    (the buffered polygon), and which nodes they need. A way is kept if it
    has at least one vertex inside `polygon` — the same "complete ways"
    membership test `mirror_clip._CompleteWaysSelector` used to produce
    `pbf_path` in the first place, so this pass and the clip that fed it
    agree on what "in" means."""

    def __init__(self, clauses: tuple[Clause, ...], polygon: Polygon):
        super().__init__()
        self._clauses = clauses
        self._polygon = polygon
        self.ways: dict[int, dict[str, Any]] = {}
        self.needed_nodes: set[int] = set()
        self.ways_considered = 0

    def way(self, w) -> None:
        tags = {t.k: t.v for t in w.tags}
        if "highway" not in tags:
            return
        self.ways_considered += 1
        if not way_passes(tags, self._clauses):
            return

        coords = [
            (nr.location.lon, nr.location.lat) for nr in w.nodes if nr.location.valid()
        ]
        if not coords:
            return
        if not any(self._polygon.covers(Point(x, y)) for x, y in coords):
            return

        refs = [nr.ref for nr in w.nodes]
        self.ways[w.id] = {"type": "way", "id": w.id, "nodes": refs, "tags": tags}
        self.needed_nodes.update(refs)


class _NodeCollector(osmium.SimpleHandler):
    """Pass 2: emit every node a kept way references, including nodes outside
    `polygon` — osmnx's own query (`(way<filter>(poly:...);>;);out;`)
    recurses to every member node of every matched way regardless of where it
    sits, so a local read that only emitted in-polygon nodes would be
    comparing a truncated graph to a complete one."""

    def __init__(self, needed: set[int]):
        super().__init__()
        self._needed = needed
        self.nodes: dict[int, dict[str, Any]] = {}

    def node(self, n) -> None:
        if n.id in self._needed and n.location.valid():
            tags = {t.k: t.v for t in n.tags}
            self.nodes[n.id] = {
                "type": "node", "id": n.id,
                "lat": n.location.lat, "lon": n.location.lon,
                "tags": tags,
            }


def elements_from_pbf(pbf_path: Path, polygon: Polygon, network_type: str) -> ExtractedElements:
    """Read `pbf_path` and return what Overpass would have returned for
    `network_type` against `polygon` (the *buffered* polygon — see
    `buffered_polygon`)."""
    clauses = network_clauses(network_type)
    ways = _WayCollector(clauses, polygon)
    ways.apply_file(str(pbf_path), locations=True)

    nodes = _NodeCollector(ways.needed_nodes)
    nodes.apply_file(str(pbf_path))

    # Order matters: osmnx assigns the edge key `k` among parallel edges by
    # insertion order in `_add_paths`. Overpass returns elements sorted by
    # type then id, and a pbf is stored in id order — sorted explicitly here
    # so this does not lean on that coincidence holding.
    elements: list[dict[str, Any]] = []
    elements.extend(nodes.nodes[i] for i in sorted(nodes.nodes))
    elements.extend(ways.ways[i] for i in sorted(ways.ways))

    return ExtractedElements(
        elements=elements,
        ways_considered=ways.ways_considered,
        ways_kept=len(ways.ways),
        nodes_emitted=len(nodes.nodes),
    )


def response_json(extracted: ExtractedElements) -> dict[str, Any]:
    """Wrap `extracted.elements` in the envelope `_create_graph` consumes.
    The other envelope keys are never read by osmnx's parser; they are
    included so a dumped payload is recognisable as what it is."""
    return {
        "version": 0.6,
        "generator": "plotlines local extract (mirror clip, no network) — issue #275",
        "elements": extracted.elements,
    }


# --------------------------------------------------------------------------
# elements -> graph, replicating `ox.graph_from_polygon`'s own tail exactly
# --------------------------------------------------------------------------


def _graph_from_elements(
    elements_json: dict[str, Any],
    polygon_buffered: Polygon,
    polygon: Polygon,
    network_type: str,
) -> nx.MultiDiGraph:
    """`osmnx.graph.graph_from_polygon`, with its one download line replaced
    by `[elements_json]` and everything else transcribed in osmnx's own
    order — see this module's docstring for why that is the whole point."""
    bidirectional = network_type in settings.bidirectional_network_types
    try:
        G_buff = oxgraph._create_graph([elements_json], bidirectional)
    except _errors.InsufficientResponseError:
        # osmnx's own reaction to zero elements for the live Overpass path
        # (`graph.regions.ensure_graph`'s `except ...InsufficientResponseError`
        # arm) — reproduced here rather than let it escape, so a caller can
        # treat "an empty local extract" and "an empty Overpass response" the
        # same way: a true, honest answer about this bbox/mode, not a crash.
        return nx.MultiDiGraph()
    G_buff = truncate.truncate_graph_polygon(G_buff, polygon_buffered, truncate_by_edge=False)
    G_buff = truncate.largest_component(G_buff, strongly=False)
    # `simplify=False` here on purpose — `graph.regions._download_region_graph`
    # simplifies by hand afterward, with `node_attrs_include=["barrier"]`,
    # which `graph_from_polygon`'s own `simplify=True` path has no way to
    # request (issue #206). Matching that ordering is what keeps a barrier
    # node that is not also a junction from being collapsed into edge
    # geometry — and its tag lost — before it can be folded onto an edge.

    G = truncate.truncate_graph_polygon(G_buff, polygon, truncate_by_edge=False)
    G = truncate.largest_component(G, strongly=False)

    spn = stats.count_streets_per_node(G_buff, nodes=G.nodes)
    nx.set_node_attributes(G, values=spn, name="street_count")
    return G


def graph_from_pbf(pbf_path: Path, bbox: BBox, network_type: str) -> nx.MultiDiGraph:
    """The whole local-extract transport: `pbf_path` -> a `MultiDiGraph`
    finished to exactly the same shape `graph.regions._download_region_graph`
    returns for the Overpass transport (simplify not yet applied — the
    caller runs #206's simplify/fold-barriers/largest-component tail, the
    same as it does after the Overpass call).

    A graph with zero nodes is a true, honest answer for an empty extract or
    an extract with nothing passing `network_type`'s filter — the caller
    (`graph.regions.ensure_graph`) is what translates that into
    `NoRoutableWaysError`, mirroring the Overpass path's own
    `InsufficientResponseError` handling.
    """
    poly_buff = buffered_polygon(bbox)
    poly = bbox_polygon(bbox)
    extracted = elements_from_pbf(pbf_path, poly_buff, network_type)
    rj = response_json(extracted)
    return _graph_from_elements(rj, poly_buff, poly, network_type)
