"""SPIKE-I leg 6 (B9) — the Q1-D trigger, measured rather than argued.

§6.7 names exactly one thing that would force the D fallback:

    "Q1-D stays reachable. The pinned region extracts remain served as plain
    immutable files, so 'pull a state extract deliberately for a trip you know
    is coming' is a configuration decision later and not a rebuild. **Offline
    bbox *editing* is the case that would force D; that is a measurement, not a
    guess, and SPIKE-I is where it gets made.**"

The measurement has a shape the review does not spell out, and getting the shape
right is most of the work.

**What the client actually holds is not the clip.** Q1-C's whole point was to
remove the client-side native dependency — the client never receives a region
extract, and after Phase 3 it has no pyosmium either, so it *cannot* re-clip a
`.osm.pbf` at all. Asking "can the client re-clip offline" answers no for every
edit and tells us nothing. What the client holds is the **built graph**, cached
by `ensure_graph` at `region.graph_path(cache_dir)` as GraphML. Re-serving an
edited bbox offline therefore means **truncating the held graph**, which is pure
osmnx/networkx and needs no native code.

So B9 asks two things, and both are measurable:

1. **Coverage.** For a realistic distribution of edits to a bbox, what fraction
   lands inside what the held graph already covers?
2. **Fidelity.** For the edits that do land inside, is the graph you get by
   truncating the held one the same graph you would have got by clipping and
   building fresh? An offline edit that silently returns a *worse* graph is
   worse than one that fails — it is B7's undetectable-split failure mode
   wearing different clothes.

The edit distribution is fixed in `HARNESS.md` §4 before the run — shrink
(0.5–0.95 about the centre), nudge (0–25% of span), grow (1.05–2.0), equal
weight — and equal weight is an assumption, stated as one, because nothing
measured tells us the real mix.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Any

BBox = tuple[float, float, float, float]

#: Fixed before the run. Changing it after the numbers are visible would be
#: exactly the post-hoc fit the pre-registration exists to prevent.
EDIT_SEED = 265
EDITS_PER_SHAPE = 200

SHRINK_RANGE = (0.50, 0.95)
NUDGE_RANGE = (0.0, 0.25)
GROW_RANGE = (1.05, 2.00)


def _scale(bbox: BBox, factor: float) -> BBox:
    west, south, east, north = bbox
    cx, cy = (west + east) / 2.0, (south + north) / 2.0
    hw, hh = (east - west) / 2.0 * factor, (north - south) / 2.0 * factor
    return (cx - hw, cy - hh, cx + hw, cy + hh)


def _translate(bbox: BBox, fx: float, fy: float) -> BBox:
    west, south, east, north = bbox
    dx, dy = (east - west) * fx, (north - south) * fy
    return (west + dx, south + dy, east + dx, north + dy)


def generate_edits(bbox: BBox, *, seed: int = EDIT_SEED,
                   n: int = EDITS_PER_SHAPE) -> list[tuple[str, BBox]]:
    """The edit distribution, deterministically. Same seed, same edits, so a
    re-run of this spike grades against the same bboxes rather than a fresh
    sample that happens to be kinder."""
    rng = random.Random(seed)
    edits: list[tuple[str, BBox]] = []
    for _ in range(n):
        edits.append(("shrink", _scale(bbox, rng.uniform(*SHRINK_RANGE))))
    for _ in range(n):
        mag = rng.uniform(*NUDGE_RANGE)
        ang = rng.uniform(0, 2 * 3.141592653589793)
        import math
        edits.append(("nudge", _translate(bbox, mag * math.cos(ang),
                                          mag * math.sin(ang))))
    for _ in range(n):
        edits.append(("grow", _scale(bbox, rng.uniform(*GROW_RANGE))))
    return edits


def _contains(outer: BBox, inner: BBox) -> bool:
    ow, os_, oe, on = outer
    iw, is_, ie, inn = inner
    return ow <= iw and os_ <= is_ and oe >= ie and on >= inn


@dataclass
class OfflineResult:
    held_bbox: BBox
    #: What the held graph actually covers — the *buffered* box the clip was
    #: taken at, not the trip bbox. The 500 m buffer is real coverage and
    #: ignoring it would understate what offline editing can serve.
    held_coverage: BBox
    per_shape: dict[str, dict[str, Any]]
    servable_fraction: float
    fidelity: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "held_bbox": list(self.held_bbox),
            "held_coverage": list(self.held_coverage),
            "per_shape": self.per_shape,
            "servable_fraction": self.servable_fraction,
            "fidelity": self.fidelity,
            "distribution": {
                "shrink": list(SHRINK_RANGE),
                "nudge": list(NUDGE_RANGE),
                "grow": list(GROW_RANGE),
                "per_shape_n": EDITS_PER_SHAPE,
                "seed": EDIT_SEED,
                "weighting": "equal — an assumption, stated as one (HARNESS.md §4)",
            },
        }


def measure_coverage(held_bbox: BBox, held_coverage: BBox) -> tuple[dict, float]:
    """Leg 1: what fraction of the edit distribution lands inside coverage."""
    edits = generate_edits(held_bbox)
    per_shape: dict[str, dict[str, Any]] = {}
    for shape in ("shrink", "nudge", "grow"):
        these = [b for s, b in edits if s == shape]
        inside = [b for b in these if _contains(held_coverage, b)]
        per_shape[shape] = {
            "n": len(these),
            "servable": len(inside),
            "fraction": len(inside) / len(these) if these else 0.0,
        }
    total = sum(v["n"] for v in per_shape.values())
    servable = sum(v["servable"] for v in per_shape.values())
    return per_shape, (servable / total if total else 0.0)


def truncate_held(graph, bbox: BBox):
    """Serve an edited bbox from the held graph — the only offline move the
    client can make, since Q1-C left it with no native clip dependency.

    `truncate_graph_polygon` then `largest_component(strongly=True)` is the tail
    of `_download_region_graph`, so what comes out is the same *shape* of object
    the routing code expects. Whether it is the same *graph* is leg 2.
    """
    import networkx as nx
    import osmnx as ox
    from shapely.geometry import box

    west, south, east, north = bbox
    g = ox.truncate.truncate_graph_polygon(graph.copy(), box(west, south, east, north))
    if g.number_of_nodes() == 0:
        return g
    return ox.truncate.largest_component(g, strongly=True)
