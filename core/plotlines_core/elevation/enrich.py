"""Elevation enrichment — the graph-annotation half of the elevation seam
(PRD FR89, ARCH §6.1 ``enrich_elevation``, SPIKE-18).

Acquisition (:mod:`plotlines_core.elevation.interface`) and reading
(:mod:`plotlines_core.elevation.sampler`) put an elevation value behind every
coordinate. This module is what writes those values onto the routing graph:

* **every node** gets an ``elevation`` attribute (metres), and
* **every edge** ``(u, v)`` gets ``elev_gain = max(0.0, elev[v] - elev[u])`` —
  the climb from ``u`` to ``v`` only, never a negative number (FR89). The
  descending direction of the same street is a *separate* directed edge in the
  ``MultiDiGraph`` and carries its own ``elev_gain`` of ``0.0``.

Enrichment is a planning-time step (FR121: it gates only elevation-dependent
metrics, nothing else) and it never raises. Two void cases, per FR88 as amended
by #473 (ARCH D68):

* **A gap inside the raster** — a node on nodata or outside the raster's bounds
  — takes the mean of its graph neighbours' elevations, spreading outward from
  covered nodes one hop at a time, so a void node sits between the real values
  around it rather than dropping to sea level. Only a connected component with
  no covered node at all falls back to ``0.0``.
* **No source at all** — no sampler, or a degraded one — writes **no**
  ``elevation`` and **no** ``elev_gain``, and strips any left from an earlier
  pass. FR89's "every node / every edge" holds whenever a raster resolved; with
  none, elevation is absent, never a fabricated flat graph. Every reader already
  treats a missing attribute as "no elevation" (``scoring.metrics`` skips the
  climb, ``graph.loader._elevations`` returns ``None``).
"""

from __future__ import annotations

from dataclasses import dataclass

import networkx as nx
import numpy as np

from plotlines_core.elevation.interface import BBox, ElevationResolver
from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.elevation.void import VOID_FILL

#: Edge attribute written by :func:`enrich_elevation`. Positive-only climb over
#: the edge, in metres (FR89).
ELEV_GAIN_KEY = "elev_gain"

#: Node attribute written by :func:`enrich_elevation`, in metres.
ELEVATION_KEY = "elevation"


@dataclass(frozen=True)
class EnrichmentReport:
    """What one :func:`enrich_elevation` pass touched. Handy for a ``/health``
    progress line; not required by FR89's acceptance criteria.

    ``void_nodes`` counts nodes whose own read was a gap and were filled from
    their neighbours; ``degraded`` means no source resolved and nothing was
    annotated."""

    nodes_annotated: int
    edges_annotated: int
    void_nodes: int
    degraded: bool


def enrich_elevation(
    graph: nx.MultiDiGraph, sampler: ElevationSampler | None
) -> nx.MultiDiGraph:
    """Annotate every node with ``elevation`` and every edge with ``elev_gain``.

    ``elev_gain`` is ``max(0.0, elev[v] - elev[u])`` — positive gain only
    (FR89). The graph is mutated in place *and* returned, matching the ARCH
    §6.1 ``enrich_elevation(graph, ...) -> graph`` shape and letting callers
    chain it.

    Never raises. A gap is filled from the graph neighbours; with no source
    (``sampler`` is ``None`` or degraded) the graph comes back with elevation
    absent rather than flat.
    """
    node_ids = list(graph.nodes)

    if sampler is None or sampler.degraded:
        # A degraded sampler logged `unreadable_raster` when it failed to open.
        for n in node_ids:
            graph.nodes[n].pop(ELEVATION_KEY, None)
        for u, v, key in graph.edges(keys=True):
            graph.edges[u, v, key].pop(ELEV_GAIN_KEY, None)
        graph.graph.pop("_pl_node_elev", None)
        graph.graph["_pl_elev_enrichment"] = EnrichmentReport(
            nodes_annotated=0, edges_annotated=0, void_nodes=0, degraded=True,
        )
        return graph

    if node_ids:
        coords = [
            (
                float(graph.nodes[n].get("y", 0.0) or 0.0),
                float(graph.nodes[n].get("x", 0.0) or 0.0),
            )
            for n in node_ids
        ]
        elevations = sampler.read(coords)
    else:
        elevations = np.empty(0, dtype="float64")

    elev_by_node = {n: float(e) for n, e in zip(node_ids, elevations)}
    void_nodes = _fill_graph_gaps(graph, elev_by_node)
    for n, val in elev_by_node.items():
        graph.nodes[n][ELEVATION_KEY] = val

    edges_annotated = 0
    for u, v, key in graph.edges(keys=True):
        gain = elev_by_node[v] - elev_by_node[u]
        graph.edges[u, v, key][ELEV_GAIN_KEY] = max(0.0, gain)
        edges_annotated += 1

    # The loader caches node elevations on the graph for repeated snapping
    # (`graph.loader._elevations`); refresh it so a lookup after enrichment
    # does not return a stale array or `None`.
    if node_ids:
        graph.graph["_pl_node_elev"] = np.asarray(
            [elev_by_node[n] for n in node_ids], dtype="float64"
        )

    report = EnrichmentReport(
        nodes_annotated=len(node_ids),
        edges_annotated=edges_annotated,
        void_nodes=void_nodes,
        degraded=False,
    )
    graph.graph["_pl_elev_enrichment"] = report
    return graph


def _fill_graph_gaps(graph: nx.MultiDiGraph, elev_by_node: dict) -> int:
    """Fill every NaN in ``elev_by_node`` from the graph's adjacency, in place.

    The graph analogue of :func:`~plotlines_core.elevation.void.interpolate_voids`:
    node ids carry no spatial order, so "the nearest finite samples" are the
    node's neighbours. Wavefront by hop — each round sets a void node touching
    an already-known node to the mean of its known neighbours, using only the
    previous round's values, so the result does not depend on iteration order.
    A component with no known node at all falls back to
    :data:`~plotlines_core.elevation.void.VOID_FILL`. Returns the void count.
    """
    pending = {n for n, e in elev_by_node.items() if not np.isfinite(e)}
    count = len(pending)
    while pending:
        resolved = {}
        for n in pending:
            known = [
                elev_by_node[m] for m in set(nx.all_neighbors(graph, n))
                if m not in pending
            ]
            if known:
                resolved[n] = float(np.mean(known))
        if not resolved:
            break
        elev_by_node.update(resolved)
        pending.difference_update(resolved)
    for n in pending:
        elev_by_node[n] = VOID_FILL
    return count


def enrich_from_resolver(
    graph: nx.MultiDiGraph, resolver: ElevationResolver, bbox: BBox
) -> nx.MultiDiGraph:
    """Resolve ``bbox`` through ``resolver`` and enrich ``graph`` from the
    result. A convenience wrapper — when no source covers the bbox the resolver
    hands back ``None`` rather than raising (FR88), and the graph comes back
    with elevation absent (#473)."""
    return enrich_elevation(graph, resolver.sampler_for(bbox))
