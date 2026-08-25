"""Joining candidate salience onto the graph (FR5, FR98 — Story A4).

`curation.notability.score_notability` and the routing graph are computed
independently (ARCH §7.1's boundary, D36 — candidates live in a regenerable
bbox-scoped cache, never in the graph). `annotate_interest` is the one place
that joins them: it writes each edge's nearby candidates' highest salience
onto its data as `interest_salience`, which `scoring.profile.edge_cost`
reads back for the `interest` weight (FR5). Nothing else in `routing/`
needs to know a candidate exists.

This is deliberately a proximity join, not a per-edge tag read — a
candidate is a point (a monument, a viewpoint), not a way, so there is no
tag on the edge itself to read the way `surface`/`highway` are read for the
other weights.
"""

from __future__ import annotations

from typing import Iterable, Protocol

import networkx as nx

from plotlines_core.graph.loader import OutsideGraphExtent, nearest_node, nodes_within

#: How far a candidate's salience reaches along the graph, in metres. Large
#: enough that a rider passing a block away from a viewpoint still counts as
#: "passing" it, small enough that it never bridges two genuinely distant
#: places into one blob.
DEFAULT_INTEREST_RADIUS_M = 150.0


class Salient(Protocol):
    """The two fields `annotate_interest` needs off a candidate — matches
    `curation.notability.Candidate` structurally without importing it, so
    `routing/` stays free to accept a plain stand-in in tests."""

    coord: tuple[float, float]  # (lon, lat), same convention as Candidate
    salience: float


def annotate_interest(
    graph: nx.MultiDiGraph,
    candidates: Iterable[Salient],
    *,
    radius_m: float = DEFAULT_INTEREST_RADIUS_M,
) -> nx.MultiDiGraph:
    """Write `interest_salience` onto every edge within `radius_m` of a candidate.

    An edge near several candidates takes the highest salience among them —
    FR5 biases toward *quality*, so one castle nearby must not be diluted by
    also being near three boundary stones (FR98's own wildcard-sub-weighting
    is exactly this reasoning applied to a single feature's tags; this is
    applying it across features). An edge near nothing notable carries no key
    at all, not a `0.0` — `edge_cost` treats absence and zero the same way,
    but leaving the key off makes "this edge was never assessed" and "this
    edge was assessed as unremarkable" the same true statement, since salience
    is never negative.

    Mutates `graph` in place and returns it, matching `enrich_elevation`'s
    shape (ARCH §7.1) — a graph is prepared once against a candidate set,
    then routed against many times as the Author tunes weights and bands. A
    candidate whose nearest routable node is farther than `radius_m` away
    never reaches an edge: it exists (a monument on an island, a viewpoint
    off any mapped trail) but nothing here can route past it.
    """
    node_salience: dict[int, float] = {}
    for candidate in candidates:
        if candidate.salience <= 0.0:
            continue
        lon, lat = candidate.coord
        try:
            node = nearest_node(graph, lat, lon, max_snap_m=radius_m)
        except OutsideGraphExtent:
            continue
        for n in nodes_within(graph, node, radius_m):
            if candidate.salience > node_salience.get(n, 0.0):
                node_salience[n] = candidate.salience

    for u, v, data in graph.edges(data=True):
        score = max(node_salience.get(u, 0.0), node_salience.get(v, 0.0))
        if score:
            data["interest_salience"] = score
        elif "interest_salience" in data:
            # A second annotation pass (a different candidate set, e.g. the
            # live layer set changed) must not leave a stale score behind on
            # an edge nothing nearby qualifies for any more.
            del data["interest_salience"]
    return graph
