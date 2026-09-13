"""SPIKE-I leg 3 — the three clip strategies, implemented rather than selected.

The addendum's **L1** is the reason this file is 300 lines instead of a flag:

    "§7.1(3) wants to measure `simple` / `complete_ways` / `smart` strategies.
    Those are osmium-tool concepts. The equivalent behaviour through pyosmium
    has to be implemented, not selected by flag — that is real spike scope the
    document currently prices as a flag comparison."

osmium-tool is GPL-3.0; libosmium and pyosmium are BSD-2-Clause. Nothing here
shells out to an `osmium` binary and there is no such binary in this spike's
environment — the acceptance criterion L1 asks SPIKE-I to carry.

What each strategy has to *mean* was written down in `HARNESS.md` §3 before any
of this was measured, so the comparison is of behaviour and not of names:

    simple          keep ways with >=1 node in the bbox; keep only those of
                    their nodes that are also in the bbox. One pass. Severed
                    ways with holes in their geometry and dangling node refs.
    complete_ways   keep ways with >=1 node in the bbox; keep ALL their nodes,
                    including the ones outside it. Two passes, or one pass plus
                    a back-reference set.
    smart           complete_ways, plus relations whose members are kept, plus
                    the members those relations reference, to a fixpoint.

`service/plotlines_service/mirror_clip.py` already ships `complete_ways`
(`_CompleteWaysSelector`), deliberately, per #262. This module does not replace
it — `shipped_clip` below calls straight into it, so the thing graded against
the parity bands is the code that actually runs on the mirror and not a
lookalike. `simple` and `smart` exist here only to price what the shipped
choice bought and what it left on the table.

**Why `complete_ways` was always the floor, not one of three options.** osmnx's
Overpass query is `(way<filter>(poly:...);>;);out;` and that `>` recurses down
to every member node of every matched way, *including nodes outside the
polygon*. Overpass has been handing us complete ways since the first graph
build. A `simple` clip cannot reach parity against a golden built that way; the
interesting question is not whether it fails but by how much, because that
number is what `complete_ways`'s extra pass is being bought with.
"""

from __future__ import annotations

import os
import resource
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import osmium

SPIKE = Path(__file__).resolve().parent
# Both, and in this order. `complete_ways` calls the shipped
# `plotlines_service.mirror_clip`, which imports `plotlines_core.tiles
# .mirror_state` — so a subprocess that only has `service/` on its path fails at
# import with `No module named 'plotlines_core'` *inside the clip*, which
# surfaces as a clip failure rather than an import failure. `run_clip` spawns
# this file as `__main__`, so the path has to be right here and not only in the
# parent that imports it.
sys.path.insert(0, str(SPIKE.parent.parent / "service"))
sys.path.insert(0, str(SPIKE.parent.parent / "core"))

BBox = tuple[float, float, float, float]

STRATEGIES = ("simple", "complete_ways", "smart")


def _box(bbox: BBox) -> osmium.osm.Box:
    west, south, east, north = bbox
    return osmium.osm.Box(west, south, east, north)


@dataclass(frozen=True)
class ClipMeasurement:
    """One clip, with the numbers B6 grades. `peak_rss_mb` is the delta over
    the process's own high-water mark at entry, not the absolute — the parent
    process has osmnx and pandas resident and charging those to the clip would
    flatter `simple` and `complete_ways` equally while telling us nothing."""

    strategy: str
    bbox: BBox
    source_bytes: int
    output_bytes: int
    wall_s: float
    peak_rss_mb: float
    nodes: int
    ways: int
    relations: int
    #: Ways written whose node references are not all present in the output —
    #: `simple`'s defining cost, and zero by construction for the other two.
    dangling_ways: int

    @property
    def output_fraction(self) -> float:
        return self.output_bytes / self.source_bytes if self.source_bytes else 0.0


# --------------------------------------------------------------------- simple


class _SimpleSelector(osmium.SimpleHandler):
    """osmium-tool's `simple`: a way is kept if any of its nodes is inside the
    box, but only the nodes actually inside the box are written.

    The way is written **unmodified**, so its node reference list still names
    nodes that are not in the output file. That is not a bug in this
    implementation — it is precisely what `simple` does, and why osmium-tool
    documents it as producing a file with incomplete ways. A consumer that
    resolves node locations against this file gets a way with holes in it.
    """

    def __init__(self, writer: osmium.SimpleWriter, box: osmium.osm.Box):
        super().__init__()
        self._writer = writer
        self._box = box
        self._kept_nodes: set[int] = set()
        self.nodes = 0
        self.ways = 0
        self.relations = 0
        self.dangling_ways = 0

    def node(self, n) -> None:
        if n.location.valid() and self._box.contains(n.location):
            self._kept_nodes.add(n.id)
            self._writer.add_node(n)
            self.nodes += 1

    def way(self, w) -> None:
        refs = [nr.ref for nr in w.nodes]
        inside = [
            nr.location.valid() and self._box.contains(nr.location) for nr in w.nodes
        ]
        if not any(inside):
            return
        self._writer.add_way(w)
        self.ways += 1
        if not all(ref in self._kept_nodes for ref in refs):
            self.dangling_ways += 1

    def relation(self, r) -> None:
        # `simple` keeps a relation only if a member is already kept; it never
        # chases the members it does not have.
        if any(m.type == "n" and m.ref in self._kept_nodes for m in r.members):
            self._writer.add_relation(r)
            self.relations += 1


def clip_simple(bbox: BBox, source: Path, dest: Path) -> tuple[int, int, int, int]:
    box = _box(bbox)
    with osmium.SimpleWriter(str(dest), overwrite=True) as writer:
        sel = _SimpleSelector(writer, box)
        sel.apply_file(str(source), locations=True)
    return sel.nodes, sel.ways, sel.relations, sel.dangling_ways


# -------------------------------------------------------------- complete_ways


def clip_complete_ways(bbox: BBox, source: Path, dest: Path) -> tuple[int, int, int, int]:
    """The shipped strategy, called through the shipped code.

    Imported here rather than reimplemented so that what SPIKE-I grades against
    B1-B5 is the module the mirror actually runs. A lookalike in the spike would
    measure the spike.
    """
    from plotlines_service.mirror_clip import _select_and_write

    _select_and_write(bbox, source, dest)
    return _count_output(dest) + (0,)


# ---------------------------------------------------------------------- smart


class _SmartCollector(osmium.SimpleHandler):
    """Pass 1 of `smart`: decide membership, including relation closure.

    `complete_ways` keeps a relation when it directly references something
    already kept, and stops there. `smart` continues: a relation referenced by a
    kept relation is itself kept, and so on to a fixpoint. Route relations are
    the case that matters for Plotlines — a numbered cycle route is commonly a
    relation of relations, and a clip that keeps only the first level loses the
    parent that carries the route's name and `network` tag.
    """

    def __init__(self, box: osmium.osm.Box):
        super().__init__()
        self._box = box
        self.node_ids: set[int] = set()
        self.way_ids: set[int] = set()
        self.relation_ids: set[int] = set()
        #: relation id -> relation ids it references, for the closure pass
        self.relation_refs: dict[int, set[int]] = {}

    def node(self, n) -> None:
        if n.location.valid() and self._box.contains(n.location):
            self.node_ids.add(n.id)

    def way(self, w) -> None:
        if any(nr.location.valid() and self._box.contains(nr.location) for nr in w.nodes):
            self.way_ids.add(w.id)

    def relation(self, r) -> None:
        self.relation_refs[r.id] = {m.ref for m in r.members if m.type == "r"}
        if any(
            (m.type == "w" and m.ref in self.way_ids)
            or (m.type == "n" and m.ref in self.node_ids)
            for m in r.members
        ):
            self.relation_ids.add(r.id)

    def close_relations(self) -> int:
        """Fixpoint over relation->relation references. Returns how many extra
        relations the closure pulled in — the number that says whether `smart`'s
        third pass bought anything at all on this bbox."""
        before = len(self.relation_ids)
        # Invert: parent relations that reference a selected relation.
        changed = True
        while changed:
            changed = False
            for rid, refs in self.relation_refs.items():
                if rid in self.relation_ids:
                    continue
                if refs & self.relation_ids:
                    self.relation_ids.add(rid)
                    changed = True
        return len(self.relation_ids) - before


class _SmartWriter(osmium.SimpleHandler):
    """Pass 2 of `smart`: write the decided membership, ways kept whole."""

    def __init__(self, writer, collector: _SmartCollector):
        super().__init__()
        self._writer = writer
        self._c = collector
        self.nodes = 0
        self.ways = 0
        self.relations = 0

    def node(self, n) -> None:
        if n.id in self._c.node_ids:
            self._writer.add_node(n)
            self.nodes += 1

    def way(self, w) -> None:
        if w.id in self._c.way_ids:
            self._writer.add_way(w)
            self.ways += 1

    def relation(self, r) -> None:
        if r.id in self._c.relation_ids:
            self._writer.add_relation(r)
            self.relations += 1


def clip_smart(bbox: BBox, source: Path, dest: Path) -> tuple[int, int, int, int]:
    box = _box(bbox)
    collector = _SmartCollector(box)
    collector.apply_file(str(source), locations=True)
    extra = collector.close_relations()

    # Ways are written whole, same as complete_ways: BackReferenceWriter pulls
    # in whatever nodes a selected way needs that the box did not already
    # select.
    with osmium.BackReferenceWriter(
        str(dest), str(source), overwrite=True, remove_tags=False
    ) as writer:
        w = _SmartWriter(writer, collector)
        w.apply_file(str(source), locations=True)
    nodes, ways, relations = _count_output(dest)
    return nodes, ways, relations, extra


# ------------------------------------------------------------------- plumbing


class _Counter(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.nodes = self.ways = self.relations = 0

    def node(self, n):
        self.nodes += 1

    def way(self, w):
        self.ways += 1

    def relation(self, r):
        self.relations += 1


def _count_output(path: Path) -> tuple[int, int, int]:
    c = _Counter()
    c.apply_file(str(path))
    return c.nodes, c.ways, c.relations


_CLIPPERS = {
    "simple": clip_simple,
    "complete_ways": clip_complete_ways,
    "smart": clip_smart,
}


def _run_clip_inprocess(strategy: str, bbox: BBox, source: Path,
                        dest: Path) -> ClipMeasurement:
    """One clip, measured against *this* process's own high-water mark.

    Only correct when the process has done nothing else first — which is why
    `run_clip` puts it in a fresh subprocess rather than calling it directly.
    """
    if strategy not in _CLIPPERS:
        raise ValueError(f"unknown strategy {strategy!r}")
    started = time.monotonic()
    nodes, ways, relations, extra = _CLIPPERS[strategy](bbox, source, dest)
    wall = time.monotonic() - started
    # ru_maxrss is KB on Linux and is the peak over the whole process lifetime,
    # so this is the clip's peak only because nothing else has run here.
    peak_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return ClipMeasurement(
        strategy=strategy,
        bbox=bbox,
        source_bytes=source.stat().st_size,
        output_bytes=dest.stat().st_size if dest.exists() else 0,
        wall_s=wall,
        peak_rss_mb=peak_kb / 1024.0,
        nodes=nodes,
        ways=ways,
        relations=relations,
        dangling_ways=extra if strategy == "simple" else 0,
    )


def run_clip(strategy: str, bbox: BBox, source: Path, dest: Path) -> ClipMeasurement:
    """Run one strategy in a **fresh subprocess** and measure it there.

    The subprocess is not isolation theatre — it is the only way this figure is
    honest. `resource.getrusage(...).ru_maxrss` is a process-lifetime high-water
    mark that never decreases, so a second clip in the same process reports the
    *first* clip's peak, and a delta against the previous peak reports roughly
    zero for every clip after the largest. Six sequential clips per cell would
    have produced one real number and five fictions, all of them flattering.

    It also bounds the damage: `complete_ways` over a multi-hundred-MB extract
    holds a large id index, and CPython does not return that to the OS on free.
    In one process the harness would accumulate every clip's peak and eventually
    measure the harness's own fragmentation instead of the clip's cost.
    """
    import json
    import subprocess

    payload = {
        "strategy": strategy, "bbox": list(bbox),
        "source": str(source), "dest": str(dest),
    }
    proc = subprocess.run(
        [sys.executable, str(Path(__file__).resolve()), "--json", json.dumps(payload)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"clip {strategy} failed (rc={proc.returncode}): {proc.stderr[-2000:]}"
        )
    data = json.loads(proc.stdout.strip().splitlines()[-1])
    return ClipMeasurement(
        strategy=data["strategy"], bbox=tuple(data["bbox"]),
        source_bytes=data["source_bytes"], output_bytes=data["output_bytes"],
        wall_s=data["wall_s"], peak_rss_mb=data["peak_rss_mb"],
        nodes=data["nodes"], ways=data["ways"], relations=data["relations"],
        dangling_ways=data["dangling_ways"],
    )


#: Address-space ceiling for a clip subprocess, in GB.
#:
#: `complete_ways` builds a node-location index over the *whole* source extract,
#: and that index is what the strategy costs. On a 94 MB extract it is ~1.9 GB;
#: it grows with the extract, not with the bbox. Without a ceiling a large state
#: extract does not fail, it *swaps* — the box thrashes, the wall-time figure
#: becomes a measurement of the page cache, and the run has to be killed by hand
#: with nothing recorded.
#:
#: A hard `RLIMIT_AS` turns that into a clean, fast `MemoryError` (or SIGKILL)
#: in a child process the harness already isolates, so "this clip does not fit"
#: is *recorded as a result* instead of taking the run down. 10 GB is chosen
#: against the box under measurement (16 GB), not against the Pi — the Pi's own
#: 8 GB is what B6's RSS band is set against, and a clip that needs more than
#: this on a laptop has already failed that band by a wide margin.
CLIP_ADDRESS_SPACE_LIMIT_GB = 10


if __name__ == "__main__":
    import argparse
    import dataclasses
    import json

    ap = argparse.ArgumentParser(description="one clip, measured in isolation")
    ap.add_argument("--json", required=True)
    ap.add_argument("--limit-gb", type=int, default=CLIP_ADDRESS_SPACE_LIMIT_GB)
    ns = ap.parse_args()
    spec = json.loads(ns.json)

    if ns.limit_gb:
        cap = ns.limit_gb * 1024**3
        soft, hard = resource.getrlimit(resource.RLIMIT_AS)
        resource.setrlimit(
            resource.RLIMIT_AS, (cap, cap if hard == resource.RLIM_INFINITY
                                 else min(cap, hard)),
        )
    measurement = _run_clip_inprocess(
        spec["strategy"], tuple(spec["bbox"]),
        Path(spec["source"]), Path(spec["dest"]),
    )
    out = dataclasses.asdict(measurement)
    out["bbox"] = list(out["bbox"])
    print(json.dumps(out))
