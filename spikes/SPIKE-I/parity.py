"""SPIKE-I — compare two graphs against the pre-registered bands.

Nothing in this module decides anything. It produces the numbers `bands.py`
grades, and it is deliberately incapable of softening one: every comparison
returns counts and distributions, never a verdict, and the differences
themselves are kept so the write-up can enumerate them rather than round them.

Two choices here are load-bearing and were fixed in `HARNESS.md` before the run.

**Edge identity is `(u, v, frozenset(osmid))`, not `(u, v, k)`.** After
simplification an osmnx edge carries the set of OSM way ids it was built from,
and *that* is the edge's identity in any sense the product cares about — the key
`k` is an artefact of insertion order among parallel edges. Using `k` as part of
the identity would make B2b unmeasurable: every re-keyed edge would score as a
missing edge plus an extra edge, and B2a would absorb the finding B2b exists to
isolate.

**A difference is a failure unless it is *shown* to be snapshot drift.** With the
attic control in place both sides describe the same database instant, so nothing
can be drift and `attribute_differences` will correctly attribute nothing. That
is the intended outcome, not a broken check — the machinery exists for the
fallback path, where the two snapshots genuinely differ and each differing
element has to be looked up and explained. Unattributed always counts against
the band.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from typing import Any, Iterable

import networkx as nx
import requests

OSM_API = "https://api.openstreetmap.org/api/0.6"
UA = "plotlines-spike-I/0.1 (+https://github.com/gnfrazier/plotlines)"

#: How many differing elements will be looked up individually before the run
#: stops asking and reports the remainder as unchecked. A parity run that
#: produces thousands of differences has already failed its band; hammering the
#: OSM API to characterise the failure would be impolite and would not change
#: the verdict. Reported honestly as `not_checked` rather than folded into
#: either column.
ATTRIBUTION_CAP = 250


def _osmid_set(data: dict[str, Any]) -> frozenset[int]:
    raw = data.get("osmid")
    if raw is None:
        return frozenset()
    if isinstance(raw, (list, tuple, set)):
        return frozenset(int(x) for x in raw)
    return frozenset({int(raw)})


def edge_index(g: nx.MultiDiGraph) -> dict[tuple[int, int, frozenset[int]], dict]:
    """Edges keyed by identity, carrying their osmnx key and length.

    Parallel edges between the same `(u, v)` built from the *same* way set are
    vanishingly rare but not impossible (a way that doubles back), so the last
    one wins and the count of collisions is reported by `compare_graphs` rather
    than silently dropped.
    """
    out: dict[tuple[int, int, frozenset[int]], dict] = {}
    collisions = 0
    for u, v, k, data in g.edges(keys=True, data=True):
        ident = (u, v, _osmid_set(data))
        if ident in out:
            collisions += 1
        out[ident] = {"k": k, "length": data.get("length"), "data": data}
    out["__collisions__"] = collisions  # type: ignore[index]
    return out


def _uv_edge_counts(g: nx.MultiDiGraph) -> dict[tuple[int, int], int]:
    counts: dict[tuple[int, int], int] = {}
    for u, v, _k in g.edges(keys=True):
        counts[(u, v)] = counts.get((u, v), 0) + 1
    return counts


@dataclass
class Comparison:
    """Everything B1-B4 needs, plus the raw differences for the write-up."""

    golden_nodes: int
    local_nodes: int
    nodes_only_golden: list[int]
    nodes_only_local: list[int]

    golden_edges: int
    local_edges: int
    edges_only_golden: list[tuple[int, int, list[int]]]
    edges_only_local: list[tuple[int, int, list[int]]]
    edge_collisions: int

    common_edges: int
    edges_same_key: int
    rekeyed_on_single_edge_uv: int

    golden_scc: int
    local_scc: int
    golden_scc_ratio: float
    local_scc_ratio: float

    length_deltas: list[float] = field(default_factory=list)

    #: B0, made observable. Overpass's verdict on a way is not something we can
    #: ask it for directly, but it is entailed by the answer: a way the golden
    #: graph is built from is a way Overpass kept. So a way id present in the
    #: golden and absent from the local is a **false reject** by the local
    #: filter — SPIKE-E's defect shape — and the reverse is a false accept.
    #: Derived rather than asserted, because a hardcoded zero here would be the
    #: spike grading its own homework.
    ways_only_golden: list[int] = field(default_factory=list)
    ways_only_local: list[int] = field(default_factory=list)

    @property
    def edge_key_stability(self) -> float:
        return self.edges_same_key / self.common_edges if self.common_edges else 1.0

    def length_percentiles(self) -> dict[str, float]:
        if not self.length_deltas:
            return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "n": 0}
        d = sorted(self.length_deltas)
        def pct(p: float) -> float:
            if len(d) == 1:
                return d[0]
            idx = min(len(d) - 1, int(round(p * (len(d) - 1))))
            return d[idx]
        return {
            "p50": pct(0.50), "p95": pct(0.95), "p99": pct(0.99),
            "max": d[-1], "mean": statistics.fmean(d), "n": len(d),
        }

    def to_dict(self) -> dict[str, Any]:
        return {
            "nodes": {
                "golden": self.golden_nodes, "local": self.local_nodes,
                "only_golden": len(self.nodes_only_golden),
                "only_local": len(self.nodes_only_local),
                "sample_only_golden": self.nodes_only_golden[:20],
                "sample_only_local": self.nodes_only_local[:20],
            },
            "edges": {
                "golden": self.golden_edges, "local": self.local_edges,
                "only_golden": len(self.edges_only_golden),
                "only_local": len(self.edges_only_local),
                "collisions": self.edge_collisions,
                "sample_only_golden": self.edges_only_golden[:20],
                "sample_only_local": self.edges_only_local[:20],
            },
            "edge_keys": {
                "common": self.common_edges,
                "same_key": self.edges_same_key,
                "stability": self.edge_key_stability,
                "rekeyed_on_single_edge_uv": self.rekeyed_on_single_edge_uv,
            },
            "scc": {
                "golden": self.golden_scc, "local": self.local_scc,
                "golden_ratio": self.golden_scc_ratio,
                "local_ratio": self.local_scc_ratio,
            },
            "length_delta_m": self.length_percentiles(),
            "way_filter": {
                "false_rejects": len(self.ways_only_golden),
                "false_accepts": len(self.ways_only_local),
                "sample_false_rejects": self.ways_only_golden[:20],
                "sample_false_accepts": self.ways_only_local[:20],
            },
        }


def compare_graphs(golden: nx.MultiDiGraph, local: nx.MultiDiGraph) -> Comparison:
    gn, ln = set(golden.nodes), set(local.nodes)
    gi, li = edge_index(golden), edge_index(local)
    g_collisions = gi.pop("__collisions__")  # type: ignore[arg-type]
    l_collisions = li.pop("__collisions__")  # type: ignore[arg-type]

    g_keys, l_keys = set(gi), set(li)
    common = g_keys & l_keys

    g_uv = _uv_edge_counts(golden)
    same_key = 0
    rekeyed_single = 0
    deltas: list[float] = []
    for ident in common:
        if gi[ident]["k"] == li[ident]["k"]:
            same_key += 1
        elif g_uv.get((ident[0], ident[1]), 0) <= 1:
            # `k` moved on a (u, v) that has exactly one edge. That cannot be
            # insertion order among parallel edges, which is the only mechanism
            # B2b's RECALIBRATE row tolerates.
            rekeyed_single += 1
        gl, ll = gi[ident]["length"], li[ident]["length"]
        if gl is not None and ll is not None:
            deltas.append(abs(float(gl) - float(ll)))

    def scc(g):
        if not g.number_of_nodes():
            return 0
        return len(max(nx.strongly_connected_components(g), key=len))

    g_scc, l_scc = scc(golden), scc(local)

    def way_ids(g) -> set[int]:
        out: set[int] = set()
        for _u, _v, _k, data in g.edges(keys=True, data=True):
            out |= _osmid_set(data)
        return out

    gw, lw = way_ids(golden), way_ids(local)

    return Comparison(
        golden_nodes=len(gn), local_nodes=len(ln),
        nodes_only_golden=sorted(gn - ln), nodes_only_local=sorted(ln - gn),
        golden_edges=len(g_keys), local_edges=len(l_keys),
        edges_only_golden=[(u, v, sorted(o)) for u, v, o in sorted(g_keys - l_keys)],
        edges_only_local=[(u, v, sorted(o)) for u, v, o in sorted(l_keys - g_keys)],
        edge_collisions=g_collisions + l_collisions,
        common_edges=len(common), edges_same_key=same_key,
        rekeyed_on_single_edge_uv=rekeyed_single,
        golden_scc=g_scc, local_scc=l_scc,
        golden_scc_ratio=g_scc / len(gn) if gn else 0.0,
        local_scc_ratio=l_scc / len(ln) if ln else 0.0,
        length_deltas=deltas,
        ways_only_golden=sorted(gw - lw),
        ways_only_local=sorted(lw - gw),
    )


# ------------------------------------------------------- snapshot attribution


@dataclass
class Attribution:
    attributed: int
    unattributed: int
    not_checked: int
    detail: list[dict[str, Any]] = field(default_factory=list)


def attribute_differences(
    node_ids: Iterable[int],
    t0: str | None,
    t1: str | None,
    *,
    session: requests.Session | None = None,
    cap: int = ATTRIBUTION_CAP,
) -> Attribution:
    """Explain each differing node as an OSM edit between the two snapshots.

    Returns `attributed` only for elements with a version whose timestamp falls
    strictly between `t0` and `t1`. With the attic control both timestamps are
    the same instant, the window is empty, and nothing can be attributed —
    which is the correct and intended behaviour, because under that control a
    difference *cannot* be drift.

    `t0`/`t1` of `None` means the run had no snapshot control at all; every
    difference is then unattributed by definition rather than waved through.
    """
    ids = list(node_ids)
    if not ids or t0 is None or t1 is None or t0 == t1:
        return Attribution(attributed=0, unattributed=len(ids), not_checked=0)

    lo, hi = sorted([t0, t1])
    s = session or requests.Session()
    s.headers.update({"User-Agent": UA})

    attributed = unattributed = 0
    detail: list[dict[str, Any]] = []
    checked = ids[:cap]
    for nid in checked:
        try:
            r = s.get(f"{OSM_API}/node/{nid}/history.json", timeout=30)
        except requests.RequestException as exc:  # pragma: no cover - network
            detail.append({"id": nid, "error": str(exc)})
            unattributed += 1
            continue
        if r.status_code != 200:
            detail.append({"id": nid, "status": r.status_code})
            unattributed += 1
            continue
        versions = r.json().get("elements", [])
        in_window = [v for v in versions if lo < v.get("timestamp", "") < hi]
        if in_window:
            attributed += 1
            detail.append({"id": nid, "versions_in_window": len(in_window)})
        else:
            unattributed += 1
    return Attribution(
        attributed=attributed,
        unattributed=unattributed,
        not_checked=max(0, len(ids) - len(checked)),
        detail=detail[:50],
    )
