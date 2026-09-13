"""SPIKE-I path T — a clipped `.osm.pbf` in Overpass's own response shape.

This is the whole transport swap, and it is deliberately small. `graph_from_polygon`
is one download call followed by ten lines of post-processing:

    response_jsons = _overpass._download_overpass_network(poly_buff, network_type, ...)
    G_buff = _create_graph(response_jsons, bidirectional)
    ... truncate / largest_component / simplify / truncate / count_streets_per_node

Everything after the first line is osmnx's, is deterministic, and is *called* by
path T rather than reimplemented. So the swap reduces to: produce the same
`response_json` from local bytes that Overpass would have returned. This module
is that function, and `graphs.py` calls osmnx for the rest.

The element shape `_parse_nodes_paths` actually consumes is minimal — nodes need
`id`/`lat`/`lon`/`tags`, ways need `id`/`nodes`/`tags` — but "minimal" is not the
same as "obvious", so it is reproduced here exactly rather than approximately;
`_convert_node`/`_convert_path` then filter tags down to
`settings.useful_tags_node`/`useful_tags_way` identically on both sides. That
identity is why B5's tag-survival question has a sharp answer for path T: the
pbf carries every tag, Overpass's `out;` returns every tag, and the same osmnx
code filters both.

**The one genuinely reimplemented thing is the way filter**, and `HARNESS.md`
§0.1 flags it as the most likely source of a T-path difference. It is not
transcribed by hand: `_get_network_filter(network_type)` returns Overpass QL and
`parse_overpass_filter` parses *that string* into predicates. A hand-copied
filter would drift from osmnx the first time osmnx changed one, and the drift
would look exactly like a parity finding.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import osmium
from osmnx import _overpass, settings

BBox = tuple[float, float, float, float]


# ------------------------------------------------------- the Overpass QL filter


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
            # its value does not match. Both halves matter — the absent case is
            # why `["bicycle"!~"no"]` does not exclude every untagged way.
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

    Two properties of Overpass's regex matching that this has to preserve, and
    that a casual reimplementation gets wrong in the permissive direction:

    * **Unanchored.** `["highway"!~"motor"]` excludes `motorway`,
      `motorway_link` and `motor`. `re.search`, not `re.fullmatch`.
    * **Case-sensitive** by default — there is no `,i` modifier on any filter
      osmnx builds.

    A worked consequence, because it looks like a bug the first time it is seen
    and is not one: the `bike` filter's `["bicycle"!~"no"]` excludes
    `bicycle=unknown`, because "unknown" contains "no". Overpass does that too.
    Path T reproducing it is parity; path T "fixing" it would be a divergence.
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
    """The predicates for `network_type`, derived from osmnx's own filter string
    rather than copied — so an osmnx upgrade that changes a filter changes this
    too, instead of silently disagreeing with the golden it is compared against."""
    return parse_overpass_filter(_overpass._get_network_filter(network_type))


def way_passes(tags: dict[str, str], clauses: Iterable[Clause]) -> bool:
    return all(c.test(tags) for c in clauses)


# ----------------------------------------------------------------- the pbf read


@dataclass
class ExtractedElements:
    """What a path-T read produced, plus the counters B0 grades."""

    elements: list[dict[str, Any]]
    ways_considered: int
    ways_kept: int
    #: Ways that pass the tag filter and whose geometry crosses the polygon but
    #: which have no *vertex* inside it. Overpass's `(poly:)` keeps these; a
    #: node-membership clip does not. Counted separately because it is the one
    #: structural difference between "what Overpass asked for" and "what the
    #: shipped clip selects", and it is invisible in a node count.
    ways_crossing_without_vertex: int
    nodes_emitted: int


class _WayCollector(osmium.SimpleHandler):
    """Pass 1: which ways pass the filter and touch the polygon, and which nodes
    they need."""

    def __init__(self, clauses, polygon, *, require_vertex_inside: bool):
        super().__init__()
        self._clauses = clauses
        self._polygon = polygon
        self._require_vertex = require_vertex_inside
        self.ways: dict[int, dict[str, Any]] = {}
        self.needed_nodes: set[int] = set()
        self.ways_considered = 0
        self.crossing_without_vertex = 0

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
        vertex_inside = any(self._polygon.covers(_point(x, y)) for x, y in coords)
        crosses = vertex_inside
        if not vertex_inside and len(coords) >= 2:
            from shapely.geometry import LineString

            crosses = LineString(coords).intersects(self._polygon)
            if crosses:
                self.crossing_without_vertex += 1

        keep = vertex_inside if self._require_vertex else crosses
        if not keep:
            return

        refs = [nr.ref for nr in w.nodes]
        self.ways[w.id] = {"type": "way", "id": w.id, "nodes": refs, "tags": tags}
        self.needed_nodes.update(refs)


def _point(x, y):
    from shapely.geometry import Point

    return Point(x, y)


class _NodeCollector(osmium.SimpleHandler):
    """Pass 2: emit every node a kept way references — *all* of them, including
    those outside the polygon.

    This is not a choice. osmnx's query is `(way<filter>(poly:...);>;);out;` and
    the `>` recurses down to every member node of every matched way regardless
    of where it sits. Overpass has been returning complete ways all along, so a
    path-T read that emitted only the nodes inside the box would be comparing a
    truncated graph against a complete one and calling the difference parity.
    """

    def __init__(self, needed: set[int]):
        super().__init__()
        self._needed = needed
        self.nodes: dict[int, dict[str, Any]] = {}

    def node(self, n) -> None:
        if n.id in self._needed and n.location.valid():
            tags = {t.k: t.v for t in n.tags}
            self.nodes[n.id] = {
                "type": "node",
                "id": n.id,
                "lat": n.location.lat,
                "lon": n.location.lon,
                "tags": tags,
            }


def elements_from_pbf(
    pbf: Path,
    polygon,
    network_type: str,
    *,
    require_vertex_inside: bool = True,
) -> ExtractedElements:
    """Read `pbf` and return what Overpass would have returned for `polygon`.

    `require_vertex_inside=True` reproduces what the *shipped clip* selects (a
    way is in if one of its nodes is in the box). `False` reproduces what
    *Overpass* selects (a way is in if its geometry intersects the polygon at
    all, vertex or not). Running both is how the difference between the two gets
    a number instead of an argument — see B0 and `parity.py`.
    """
    clauses = network_clauses(network_type)
    ways = _WayCollector(clauses, polygon, require_vertex_inside=require_vertex_inside)
    ways.apply_file(str(pbf), locations=True)

    nodes = _NodeCollector(ways.needed_nodes)
    nodes.apply_file(str(pbf))

    # Order matters for B2b. osmnx assigns the edge key `k` among parallel edges
    # by insertion order in `_add_paths`, so way iteration order is a property of
    # the transport — exactly the thing B2b is asking about. Overpass returns
    # elements sorted by type then id; a pbf is also stored in id order. Sorting
    # explicitly here means path T is not relying on that coincidence holding.
    elements: list[dict[str, Any]] = []
    elements.extend(nodes.nodes[i] for i in sorted(nodes.nodes))
    elements.extend(ways.ways[i] for i in sorted(ways.ways))

    return ExtractedElements(
        elements=elements,
        ways_considered=ways.ways_considered,
        ways_kept=len(ways.ways),
        ways_crossing_without_vertex=ways.crossing_without_vertex,
        nodes_emitted=len(nodes.nodes),
    )


def response_json(extracted: ExtractedElements) -> dict[str, Any]:
    """Wrap elements in the envelope `_create_graph` consumes. The envelope's
    other keys (`version`, `generator`, `osm3s`) are never read by osmnx's
    parser; they are included so a dumped fixture is recognisable as what it is
    rather than a bare list."""
    return {
        "version": 0.6,
        "generator": "plotlines SPIKE-I path T (local extract, no network)",
        "elements": extracted.elements,
    }


def useful_tag_settings_snapshot() -> dict[str, list[str]]:
    """What osmnx will keep off each element, at the moment of the call.

    Recorded into the results because it is the *shared* half of B5: both the
    golden and path T are filtered by these lists, so a tag missing from both is
    a `PLOTLINES_WAY_TAGS` bug and not a transport bug, and the write-up should
    not be able to confuse the two.
    """
    return {
        "useful_tags_way": list(settings.useful_tags_way),
        "useful_tags_node": list(settings.useful_tags_node),
    }
