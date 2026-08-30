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
metrics, nothing else) and it never raises — the sampler resolves every void to
``0.0`` (FR88), and a degraded sampler simply annotates a flat graph. That keeps
FR89's "every node / every edge" guarantee true even with no raster on disk.
"""

from __future__ import annotations

from dataclasses import dataclass

import networkx as nx
import numpy as np

from plotlines_core.elevation.interface import BBox, ElevationResolver
from plotlines_core.elevation.sampler import ElevationSampler

#: Edge attribute written by :func:`enrich_elevation`. Positive-only climb over
#: the edge, in metres (FR89).
ELEV_GAIN_KEY = "elev_gain"

#: Node attribute written by :func:`enrich_elevation`, in metres.
ELEVATION_KEY = "elevation"


@dataclass(frozen=True)
class EnrichmentReport:
    """What one :func:`enrich_elevation` pass touched. Handy for a ``/health``
    progress line; not required by FR89's acceptance criteria."""

    nodes_annotated: int
    edges_annotated: int
    void_nodes: int
    degraded: bool


def enrich_elevation(
    graph: nx.MultiDiGraph, sampler: ElevationSampler
) -> nx.MultiDiGraph:
    """Annotate every node with ``elevation`` and every edge with ``elev_gain``.

    ``elev_gain`` is ``max(0.0, elev[v] - elev[u])`` — positive gain only
    (FR89). The graph is mutated in place *and* returned, matching the ARCH
    §6.1 ``enrich_elevation(graph, ...) -> graph`` shape and letting callers
    chain it.

    Never raises: the sampler fills every void with ``0.0`` (FR88), so a graph
    with no DEM behind it comes back fully annotated and flat rather than
    partly annotated.
    """
    node_ids = list(graph.nodes)
    if node_ids:
        coords = [
            (
                float(graph.nodes[n].get("y", 0.0) or 0.0),
                float(graph.nodes[n].get("x", 0.0) or 0.0),
            )
            for n in node_ids
        ]
        elevations = sampler.sample(coords)
    else:
        elevations = np.empty(0, dtype="float64")

    elev_by_node: dict = {}
    for n, e in zip(node_ids, elevations):
        val = float(e)
        graph.nodes[n][ELEVATION_KEY] = val
        elev_by_node[n] = val

    # `0.0` is the void fill (VOID_FILL) everywhere in this module, so a
    # genuine sea-level node reads as a void here too — a harmless imprecision
    # in the report line, never in the annotation itself.
    void_nodes = int(np.count_nonzero(elevations == 0.0)) if len(elevations) else 0

    edges_annotated = 0
    for u, v, key in graph.edges(keys=True):
        gain = elev_by_node.get(v, 0.0) - elev_by_node.get(u, 0.0)
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
        degraded=sampler.degraded,
    )
    graph.graph["_pl_elev_enrichment"] = report
    return graph


def enrich_from_resolver(
    graph: nx.MultiDiGraph, resolver: ElevationResolver, bbox: BBox
) -> nx.MultiDiGraph:
    """Resolve ``bbox`` through ``resolver`` and enrich ``graph`` from the
    result. A convenience wrapper — the resolver hands back a degraded (flat)
    sampler rather than raising when no source covers the bbox (FR88)."""
    return enrich_elevation(graph, resolver.sampler_for(bbox))
