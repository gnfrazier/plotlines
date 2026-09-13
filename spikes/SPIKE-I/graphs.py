"""SPIKE-I — the three graph builds under comparison.

One golden and two locals, and the only difference between the golden and path T
is where the bytes came from.

    golden   `_download_region_graph(region)` from `core/plotlines_core/graph/
             regions.py` — the shipped function, unmodified, pointed at Overpass
             with an attic date so it describes the extract's own instant.
    path T   the same post-download pipeline, called line for line, fed elements
             that `elements.py` read out of a clipped `.osm.pbf`.
    path R   pyrosm builds the graph itself; the pipeline is not involved.

`_download_region_graph` is, in full:

    graph = ox.graph_from_bbox(bbox, network_type=..., simplify=False)
    graph = ox.simplify_graph(graph, node_attrs_include=["barrier"])
    fold_node_barriers(graph)
    return ox.truncate.largest_component(graph, strongly=True)

The `simplify=False` then simplify-by-hand is #206's fix: osmnx 2.x gives no way
to pass `node_attrs_include` through `graph_from_bbox`, so a barrier node that is
not also a junction would be collapsed into edge geometry — and its tag lost —
before `fold_node_barriers` could reach it. Path T must reproduce that ordering
exactly or B5's barrier assertion measures the harness instead of the transport.

`_graph_from_elements` below is `osmnx.graph.graph_from_polygon` with its one
download line replaced and nothing else touched. It is transcribed rather than
monkey-patched deliberately: a `mock.patch` on `_download_overpass_network` would
produce the same graph while hiding *which* steps path T inherits, and the
inheritance is the finding.
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import networkx as nx
import osmnx as ox
from osmnx import graph as oxgraph
from osmnx import settings, simplification, stats, truncate

SPIKE = Path(__file__).resolve().parent
sys.path.insert(0, str(SPIKE.parent.parent / "core"))

from plotlines_core.graph.regions import (  # noqa: E402
    PLOTLINES_NODE_TAGS,
    PLOTLINES_WAY_TAGS,
    Region,
    fold_node_barriers,
)

import elements as E  # noqa: E402
import regions as R  # noqa: E402


@dataclass
class BuildResult:
    graph: nx.MultiDiGraph
    wall_s: float
    #: Counters from the read, for B0. Empty for the golden, which has no
    #: local filter to grade.
    read: dict[str, Any]


# ------------------------------------------------------------------ the golden


def set_attic_date(timestamp: str | None) -> None:
    """Pin every subsequent Overpass query to a database instant.

    `HARNESS.md` §1: a golden built today against an extract pinned on another
    day differs on every id that changed in between, and none of that is a
    parity difference. `timestamp` is read out of the clip's own pbf header
    (`osmosis_replication_timestamp`), so both sides describe the same snapshot
    and exact set identity becomes a legitimate thing to require.

    Passing `None` restores osmnx's default and is what the control check uses
    to prove the dated query is not being silently ignored — a `[date:]` that
    Overpass dropped on the floor would make every band permissive in the
    direction that produces a pass.
    """
    if timestamp is None:
        settings.overpass_settings = "[out:json][timeout:{timeout}]{maxsize}"
    else:
        settings.overpass_settings = (
            '[out:json][timeout:{timeout}]{maxsize}[date:"' + timestamp + '"]'
        )


def build_golden(cell: R.Cell) -> BuildResult:
    """The shipped `_download_region_graph`, called — not reimplemented.

    Imported lazily so that `set_attic_date` has already run against the same
    `ox.settings` module this function will use.
    """
    from plotlines_core.graph.regions import _download_region_graph

    region = Region(key=cell.key, bbox=cell.bbox, network_type=cell.network_type)
    started = time.monotonic()
    graph = _download_region_graph(region)
    return BuildResult(graph=graph, wall_s=time.monotonic() - started, read={})


# -------------------------------------------------------------------- path T


def _graph_from_elements(
    response_json: dict[str, Any],
    polygon_buffered,
    polygon,
    network_type: str,
    *,
    simplify: bool,
    retain_all: bool = False,
    truncate_by_edge: bool = False,
) -> nx.MultiDiGraph:
    """`osmnx.graph.graph_from_polygon`, with the download replaced.

    Every line below this docstring is osmnx's, in osmnx's order — the only
    edit is that `_download_overpass_network(...)` becomes `[response_json]`,
    and that the two polygons osmnx derives internally are passed in instead
    (the caller builds `polygon_buffered` with osmnx's own projection code).

    Both polygons matter, and the buffer is the one that is easy to drop.
    `graph_from_polygon` queries a polygon buffered by 500 m, keeps the largest
    component and simplifies *on the buffered graph*, and only then truncates to
    the polygon the caller actually asked for. Simplification and component
    selection therefore see road that reaches past the bbox edge. Feeding
    elements selected against the unbuffered box into this function produces a
    graph that is genuinely different at its boundary — and the difference would
    read as a parity failure rather than as the harness bug it would be.
    """
    bidirectional = network_type in settings.bidirectional_network_types
    G_buff = oxgraph._create_graph([response_json], bidirectional)
    G_buff = truncate.truncate_graph_polygon(
        G_buff, polygon_buffered, truncate_by_edge=truncate_by_edge
    )
    if not retain_all:
        G_buff = truncate.largest_component(G_buff, strongly=False)
    if simplify:
        G_buff = simplification.simplify_graph(G_buff)

    G = truncate.truncate_graph_polygon(
        G_buff, polygon, truncate_by_edge=truncate_by_edge
    )
    if not retain_all:
        G = truncate.largest_component(G, strongly=False)

    spn = stats.count_streets_per_node(G_buff, nodes=G.nodes)
    nx.set_node_attributes(G, values=spn, name="street_count")
    return G


def build_path_t(cell: R.Cell, clip_pbf: Path, *, require_vertex_inside: bool = True) -> BuildResult:
    """Clipped pbf -> Overpass-shaped elements -> osmnx's own pipeline.

    The tail after `_graph_from_elements` is `_download_region_graph`'s tail,
    character for character, including #206's simplify-then-fold ordering.
    """
    started = time.monotonic()
    buffered = R.buffered_polygon(cell.bbox)
    unbuffered = R.bbox_polygon(cell.bbox)

    extracted = E.elements_from_pbf(
        clip_pbf, buffered, cell.network_type,
        require_vertex_inside=require_vertex_inside,
    )
    rj = E.response_json(extracted)
    graph = _graph_from_elements(
        rj, buffered, unbuffered, cell.network_type, simplify=False
    )

    graph = ox.simplify_graph(graph, node_attrs_include=["barrier"])
    folded = fold_node_barriers(graph)
    graph = ox.truncate.largest_component(graph, strongly=True)

    return BuildResult(
        graph=graph,
        wall_s=time.monotonic() - started,
        read={
            "ways_considered": extracted.ways_considered,
            "ways_kept": extracted.ways_kept,
            "ways_crossing_without_vertex": extracted.ways_crossing_without_vertex,
            "nodes_emitted": extracted.nodes_emitted,
            "barrier_nodes_folded": folded,
            "require_vertex_inside": require_vertex_inside,
        },
    )


# -------------------------------------------------------------------- path R


#: pyrosm's own network-type names against osmnx's. They are not the same
#: vocabulary and the mapping is lossy in both directions — which is itself part
#: of what B0/B1 are measuring, so the lossiness is recorded here rather than
#: smoothed over. pyrosm has no `bike`-equivalent that excludes `bicycle=no`,
#: and no `drive` that reproduces osmnx's service-road exclusions.
PYROSM_NETWORK_TYPE = {
    "bike": "cycling",
    "drive": "driving",
    "walk": "walking",
}


def build_path_r(cell: R.Cell, clip_pbf: Path) -> BuildResult:
    """pyrosm builds the graph itself. §11.1's actual risk, measured.

    Returned as an osmnx-shaped `MultiDiGraph` so the same comparison code runs
    against it — but note what that conversion cannot do: pyrosm's node ids are
    OSM node ids (so B1 is comparable) while its *edges* are its own segments
    with its own geometry and its own length computation (so B2/B4 are comparing
    two different implementations' outputs, which is the point).
    """
    from pyrosm import OSM

    started = time.monotonic()
    osm = OSM(str(clip_pbf))
    nt = PYROSM_NETWORK_TYPE.get(cell.network_type, cell.network_type)
    nodes, edges = osm.get_network(network_type=nt, nodes=True)
    graph = osm.to_graph(nodes, edges, graph_type="networkx", retain_all=True)

    # Same tail as the other two, so any difference is pyrosm's and not the
    # pipeline's absence.
    graph = ox.truncate.largest_component(graph, strongly=True)
    return BuildResult(
        graph=graph,
        wall_s=time.monotonic() - started,
        read={"pyrosm_network_type": nt, "edges_rows": int(len(edges))},
    )


# ------------------------------------------------------------------- utilities


def graph_summary(g: nx.MultiDiGraph) -> dict[str, Any]:
    scc = max(nx.strongly_connected_components(g), key=len) if g.number_of_nodes() else set()
    return {
        "nodes": g.number_of_nodes(),
        "edges": g.number_of_edges(),
        "largest_scc": len(scc),
        "scc_ratio": len(scc) / g.number_of_nodes() if g.number_of_nodes() else 0.0,
    }


def way_tag_settings() -> dict[str, Any]:
    return {
        "plotlines_way_tags": list(PLOTLINES_WAY_TAGS),
        "plotlines_node_tags": list(PLOTLINES_NODE_TAGS),
        **E.useful_tag_settings_snapshot(),
    }
