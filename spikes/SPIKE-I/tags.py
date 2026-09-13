"""SPIKE-I leg 2 (B5) — tag survival, asserted on the bytes.

The issue is explicit about why this leg is not a formality:

    "This is the **#206** class of defect — a rule keyed on an un-downloaded tag
    goes silently inert on every real graph, and SPIKE-E found it live. Assert on
    the bytes, not on the loader's promise."

So the count that matters is taken by reading the clipped `.osm.pbf` directly
with pyosmium — not through osmnx, not through pyrosm, not through anything that
could be the thing that is broken. A loader that drops `motor_vehicle` reports
zero `motor_vehicle` ways and is perfectly self-consistent while doing it.

Three assertion points, because a tag can be lost at three different places and
only one of them is visible in the graph:

    bytes   source extract (restricted to the bbox) -> clip. Loss here is the
            clip dropping tags, which `remove_tags=False` on the
            BackReferenceWriter is supposed to prevent — and which nothing
            currently tests against a real multi-hundred-MB extract.
    graph   golden edges carrying the tag vs local edges carrying it. Loss here
            is the transport or the filter, not the clip.
    fold    `barrier` specifically. It is tagged on the *node* in OSM and
            `routing/access.py` reads it off the *edge*, so
            `fold_node_barriers` has to move it — after simplification, which
            is told to retain barrier nodes as endpoints. Three ways to lose it
            and only one of them looks like a missing tag.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import networkx as nx
import osmium

import bands

BBox = tuple[float, float, float, float]


class _TagCounter(osmium.SimpleHandler):
    """Count ways carrying each watched tag, optionally restricted to a bbox.

    The bbox restriction uses the same "any node inside" rule the shipped clip
    selects with, so `source-within-bbox` and `clip` are counted by the same
    definition and a difference between them is a real loss rather than a
    definitional one.
    """

    def __init__(self, way_tags: tuple[str, ...], node_tags: tuple[str, ...],
                 box: osmium.osm.Box | None):
        super().__init__()
        self._way_tags = way_tags
        self._node_tags = node_tags
        self._box = box
        self.way_counts: dict[str, int] = {t: 0 for t in way_tags}
        self.node_counts: dict[str, int] = {t: 0 for t in node_tags}
        self.ways = 0
        self.nodes = 0
        self.highway_ways = 0

    def _in_box(self, loc) -> bool:
        return self._box is None or (loc.valid() and self._box.contains(loc))

    def node(self, n) -> None:
        if not self._in_box(n.location):
            return
        self.nodes += 1
        tags = {t.k: t.v for t in n.tags}
        for t in self._node_tags:
            if t in tags:
                self.node_counts[t] += 1

    def way(self, w) -> None:
        if self._box is not None and not any(
            nr.location.valid() and self._box.contains(nr.location) for nr in w.nodes
        ):
            return
        self.ways += 1
        tags = {t.k: t.v for t in w.tags}
        if "highway" in tags:
            self.highway_ways += 1
        for t in self._way_tags:
            if t in tags:
                self.way_counts[t] += 1


def count_tags_in_pbf(
    pbf: Path, *, bbox: BBox | None = None,
    way_tags: tuple[str, ...] = bands.ZERO_TOLERANCE_WAY_TAGS,
    node_tags: tuple[str, ...] = bands.ZERO_TOLERANCE_NODE_TAGS,
) -> dict[str, Any]:
    """Per-tag element counts, straight off the pbf. Point 1 of the three."""
    box = None
    if bbox is not None:
        west, south, east, north = bbox
        box = osmium.osm.Box(west, south, east, north)
    counter = _TagCounter(way_tags, node_tags, box)
    counter.apply_file(str(pbf), locations=bbox is not None)
    return {
        "ways": counter.ways,
        "highway_ways": counter.highway_ways,
        "nodes": counter.nodes,
        "way_tag_counts": dict(counter.way_counts),
        "node_tag_counts": dict(counter.node_counts),
    }


def count_tags_in_graph(
    g: nx.MultiDiGraph,
    *,
    way_tags: tuple[str, ...] = bands.ZERO_TOLERANCE_WAY_TAGS,
    node_tags: tuple[str, ...] = bands.ZERO_TOLERANCE_NODE_TAGS,
) -> dict[str, Any]:
    """Per-tag edge/node counts on a built graph. Points 2 and 3.

    `barrier` is counted on edges, which is where `routing/access.py` reads it,
    *and* on nodes, which is where OSM puts it — the gap between the two is
    `fold_node_barriers`' entire job, so reporting only one of them would hide a
    fold that silently did nothing.
    """
    edge_counts = {t: 0 for t in way_tags}
    edge_barrier = 0
    for _u, _v, _k, data in g.edges(keys=True, data=True):
        for t in way_tags:
            if data.get(t) not in (None, ""):
                edge_counts[t] += 1
        if data.get("barrier") not in (None, ""):
            edge_barrier += 1

    node_counts = {t: 0 for t in node_tags}
    for _n, data in g.nodes(data=True):
        for t in node_tags:
            if data.get(t) not in (None, ""):
                node_counts[t] += 1

    return {
        "edges": g.number_of_edges(),
        "nodes": g.number_of_nodes(),
        "edge_tag_counts": edge_counts,
        "node_tag_counts": node_counts,
        "edges_with_folded_barrier": edge_barrier,
    }


@dataclass
class TagSurvival:
    """B5's verdict inputs. `losses` is what `bands.veto_reasons` reads."""

    bytes_source: dict[str, Any]
    bytes_clip: dict[str, Any]
    graph_golden: dict[str, Any]
    graph_local: dict[str, Any]
    losses: dict[str, int] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "bytes_source_in_bbox": self.bytes_source,
            "bytes_clip": self.bytes_clip,
            "graph_golden": self.graph_golden,
            "graph_local": self.graph_local,
            "losses": self.losses,
            "notes": self.notes,
        }


def assess_survival(
    bytes_source: dict[str, Any],
    bytes_clip: dict[str, Any],
    graph_golden: dict[str, Any],
    graph_local: dict[str, Any],
) -> TagSurvival:
    """Roll the three points up into B5's zero-tolerance verdict.

    A loss is recorded when the local side carries *fewer* elements with a tag
    than the golden side does. The reverse — local carrying more — is not a
    loss and is recorded as a note: it means the clip admitted ways the Overpass
    filter excluded, which B0 and B1 grade. Conflating the two directions here
    would let a filter bug cancel out a tag bug.
    """
    losses: dict[str, int] = {}
    notes: list[str] = []

    for tag in bands.ZERO_TOLERANCE_WAY_TAGS:
        src = bytes_source["way_tag_counts"].get(tag, 0)
        clip = bytes_clip["way_tag_counts"].get(tag, 0)
        if clip < src:
            losses[f"bytes:{tag}"] = src - clip
        elif clip > src:
            notes.append(
                f"bytes:{tag}: clip has {clip} vs {src} in source-within-bbox — "
                f"expected, the clip keeps ways whole and so reaches past the box"
            )

        gold = graph_golden["edge_tag_counts"].get(tag, 0)
        loc = graph_local["edge_tag_counts"].get(tag, 0)
        if loc < gold:
            losses[f"graph:{tag}"] = gold - loc
        elif loc > gold:
            notes.append(f"graph:{tag}: local {loc} vs golden {gold}")

    src_b = bytes_source["node_tag_counts"].get("barrier", 0)
    clip_b = bytes_clip["node_tag_counts"].get("barrier", 0)
    if clip_b < src_b:
        losses["bytes:barrier"] = src_b - clip_b

    gold_fold = graph_golden["edges_with_folded_barrier"]
    loc_fold = graph_local["edges_with_folded_barrier"]
    if loc_fold < gold_fold:
        losses["fold:barrier"] = gold_fold - loc_fold
    if gold_fold == 0 and src_b > 0:
        # The golden itself folded nothing while the area demonstrably has
        # barrier nodes. That is #206's exact failure re-appearing on the
        # *golden* side, and it would make the local side's zero look like
        # parity. Never silently pass it.
        notes.append(
            f"fold:barrier: golden folded 0 edges but the source has {src_b} "
            f"barrier node(s) in bbox — check node_attrs_include ordering (#206)"
        )

    return TagSurvival(
        bytes_source=bytes_source, bytes_clip=bytes_clip,
        graph_golden=graph_golden, graph_local=graph_local,
        losses=losses, notes=notes,
    )
