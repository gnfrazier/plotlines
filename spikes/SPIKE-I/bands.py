"""SPIKE-I — the bands, declared before the first byte is clipped.

This is the machine-readable half of `HARNESS.md`, and it exists for the same
reason SPIKE-13's `bands.py` does: a threshold written in prose can be read
generously after the numbers arrive, and one written as a function cannot.
`run.py` grades a completed run against `classify()` and exits non-zero on a
fail.

The addendum's **G5** is the whole reason this file is committed before
`probe.py` is first executed:

    "A spike this consequential should pre-register what counts as parity
    (exact node/edge sets? +/-x% on largest-SCC size? identical
    PLOTLINES_WAY_TAGS survival with zero tolerance?), in the house style the
    other spikes use. Otherwise 'close enough' gets decided after the numbers
    are visible."

Three verdict bands, and the middle one is the one that matters because it is
the one §8 and #276 are written against:

    PARITY       Phase 3's transport swap is safe as written. SPIKE-A's golden
                 candidate sets and SPIKE-G's ~2,800-marker ceiling do not need
                 re-earning against the new data path.
    RECALIBRATE  §8 stands, but the swap is not *done* until #276 re-runs
                 SPIKE-A, SPIKE-G and SPIKE-21's cue derivation against it, and
                 A23/A23a are re-answered with the clip's numbers.
    RESCOPE      Phase 3 does not happen as written; §12's answers reopen —
                 Q1-C against its D fallback, and Q6's arithmetic against a
                 transport that costs more than the one it replaces.

Two of the checks are **vetoes** and sit outside the rollup: B0 (way-filter
agreement) and B5 (tag survival). They are not degrees of parity. A filter that
drops a real way, or a tag that does not survive the clip, is a defect that
ships and *reports success* — SPIKE-E's `drive` finding and #206 are both
exactly that shape, and preventing a third is what this spike is for.

Per-cell, never rolled up: every band is evaluated per
`(region x network_type x path)` and is met only if it is met in every cell.
SPIKE-13's rule — an overall figure can never launder one bad host — is the
same rule here with regions in place of mail providers. A half-percent node
difference spread evenly over three regions is noise; the same half-percent
concentrated in one is a different trip.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class Band(str, Enum):
    PARITY = "parity"
    RECALIBRATE = "recalibrate"
    RESCOPE = "rescope"


class Path(str, Enum):
    """The two swaps §11.1 conflates. See HARNESS.md §0."""

    #: clipped .osm.pbf -> Overpass-shaped elements -> osmnx's own
    #: `_create_graph` and the identical post-download pipeline. The bytes
    #: change and the way-filter is reimplemented; nothing else does.
    TRANSPORT = "transport"
    #: clipped .osm.pbf -> pyrosm -> graph. A different implementation of the
    #: same idea, which is the risk §11.1 actually names.
    REIMPLEMENTATION = "reimplementation"


# --- the pre-registered numbers -------------------------------------------------
#
# Rationale for each lives in HARNESS.md next to the band, so a later reader can
# argue with the number and not merely with the verdict. The short form:
#
#  B1/B2a 0.5%   — a ceiling on the aggregate unattributed difference. Any cell
#      spending more than a tenth of it gets its differences enumerated
#      individually in the write-up rather than reported as a percentage.
#  B2b 100%      — edge key `k` is a function of way *iteration order*, which is
#      a property of the transport. If it moves at all, the deliverable is a
#      GRAPH_RULESET_VERSION bump in Phase 3, not a tolerance: the on-disk graph
#      cache key is (bbox, network_type, ruleset) and does not include the
#      transport, so an Overpass-era graph.graphml and a Phase 3 build would
#      resolve against each other with no error and no cache miss.
#  B3 1.0%       — the strongly-connected component is the graph that actually
#      routes, and it is the metric a single severed way moves first (§11.7).
#      Asymmetric: *smaller* by >1% in any one cell is RESCOPE regardless of the
#      aggregate, because real road has fallen out of the routable set.
#  B4 1 mm       — not a tight band, the honest one. A pbf stores coordinates as
#      nanodegree integers at granularity 100 (exactly 1e-7 deg) and Overpass
#      JSON emits 7 decimal places: the same numbers. `length` is computed by the
#      same `distance.add_edge_lengths` call on both sides. Any delta is a
#      float-formatting artefact; above a millimetre means a node moved.
#  B6 20 s/60 s  — the clip is strictly upstream of a *measured* 36.7-116.6 s
#      graph build, inside FR120's declare-the-extent moment and reported through
#      FR121's channel. 20 s disappears into that wait; 60 s is visible but
#      survivable; past it the clip is its own readiness stage.
#  B6 1.5 GB RSS — the Pi 5 has 8 GB and also serves the static tree. A clip
#      needing 3 GB is one concurrent request away from being the mirror's
#      availability story, which is §11.3's warning.

#: B1 node set / B2a edge set: max unattributed symmetric difference, as a
#: fraction of the golden count, for RECALIBRATE. PARITY requires zero.
MAX_UNATTRIBUTED_SET_DIFF = 0.005

#: B2b: fraction of common edges that must keep their osmnx key `k`.
MIN_EDGE_KEY_STABILITY_PARITY = 1.0
MIN_EDGE_KEY_STABILITY_RECALIBRATE = 0.999

#: B3: max |delta| in largest-SCC size, as a fraction of golden SCC size.
MAX_SCC_DELTA = 0.010
#: B3: max |delta| in the SCC/total ratio, in percentage *points*.
MAX_SCC_RATIO_DELTA_POINTS = 1.0

#: B4: per-edge length delta, metres.
MAX_EDGE_LENGTH_DELTA_PARITY_M = 0.001
MAX_EDGE_LENGTH_DELTA_P99_RECALIBRATE_M = 0.5
MAX_EDGE_LENGTH_DELTA_MAX_RECALIBRATE_M = 5.0

#: B6: server-side clip cost, measured through the real `/clip` endpoint on the
#: mirror (addendum 2c). Figures taken anywhere else do not count toward the band.
MAX_CLIP_P95_S_PARITY = 20.0
MAX_CLIP_P95_S_RECALIBRATE = 60.0
MAX_CLIP_PEAK_RSS_MB_PARITY = 1536.0
MAX_CLIP_PEAK_RSS_MB_RECALIBRATE = 3072.0
MAX_CLIP_OUTPUT_FRACTION_PARITY = 0.02
MAX_CLIP_OUTPUT_FRACTION_RECALIBRATE = 0.05

#: B9: the Q1-D trigger. Fraction of a realistic offline bbox-edit distribution
#: that must be servable from the clip the client already holds for Q1-C to
#: stand. The distribution itself is fixed in HARNESS.md §4 before the run:
#: shrink (0.5-0.95 about the centre), nudge (0-25% of span), grow (1.05-2.0),
#: equal weight — equal because nothing measured tells us the real mix, and
#: saying so is the point of fixing it now.
MIN_OFFLINE_SERVABLE_FRACTION = 0.90

#: The fifteen tags B5 admits no losses on: `PLOTLINES_WAY_TAGS` plus the node
#: tag `barrier`. Mirrored here rather than imported so the pre-registration is
#: self-contained and cannot drift if the product constant is edited later; the
#: spike's own test asserts the two lists still agree, which is the failure a
#: later reader wants to see rather than a silently narrowed band.
ZERO_TOLERANCE_WAY_TAGS = (
    "surface", "tracktype", "smoothness", "maxspeed", "lanes", "bicycle",
    "foot", "canoe", "motor_vehicle", "motorcar", "4wd_only", "ford",
    "waterway", "oneway:bicycle", "climbing:access",
)
ZERO_TOLERANCE_NODE_TAGS = ("barrier",)


@dataclass(frozen=True)
class CellResult:
    """One `(region x network_type x path)` cell of the parity matrix."""

    region: str
    network_type: str
    path: Path

    # B0 — way-filter agreement against Overpass's observable verdict.
    filter_false_accepts: int
    filter_false_rejects: int

    # B1 / B2a — set differences, already partitioned into snapshot-attributed
    # (an OSM version between the two snapshots explains it) and not. §1's rule:
    # a difference is a failure unless it is *shown* to be drift.
    golden_nodes: int
    unattributed_node_diff: int
    golden_edges: int
    unattributed_edge_diff: int

    # B2b
    edge_key_stability: float
    rekeyed_on_single_edge_uv: int

    # B3
    golden_scc: int
    local_scc: int
    golden_scc_ratio: float
    local_scc_ratio: float

    # B4 — a distribution, never a mean.
    length_delta_p99_m: float
    length_delta_max_m: float

    # B5 — per-tag losses across all three assertion points (bytes, graph,
    # fold). Any entry at all is a veto.
    tag_losses: dict[str, int] = field(default_factory=dict)

    @property
    def node_diff_fraction(self) -> float:
        return self.unattributed_node_diff / self.golden_nodes if self.golden_nodes else 0.0

    @property
    def edge_diff_fraction(self) -> float:
        return self.unattributed_edge_diff / self.golden_edges if self.golden_edges else 0.0

    @property
    def scc_delta_fraction(self) -> float:
        if not self.golden_scc:
            return 0.0
        return abs(self.local_scc - self.golden_scc) / self.golden_scc

    @property
    def scc_shrank_beyond_band(self) -> bool:
        """B3's asymmetric clause: a *smaller* SCC is real road falling out of
        the routable set, which silently shortens routes. A larger one means the
        clip admitted ways the filter excluded — also a bug, but a loud one."""
        if not self.golden_scc:
            return False
        return (self.golden_scc - self.local_scc) / self.golden_scc > MAX_SCC_DELTA


@dataclass(frozen=True)
class ClipResult:
    """B6/B7 — measured server-side, through the real `/clip` endpoint."""

    bbox_key: str
    measured_on_mirror: bool
    p95_wall_s: float
    peak_rss_mb: float
    output_fraction: float


def veto_reasons(cells: tuple[CellResult, ...]) -> list[str]:
    """B0 and B5 — the two checks that are not degrees of parity.

    Kept out of `classify`'s band ladder deliberately. A way-filter that drops a
    real trailhead, or a `PLOTLINES_WAY_TAGS` entry that does not survive the
    clip, produces a graph that is wrong and *reports success*. SPIKE-E's `drive`
    download filter and #206's inert access tags are both that shape; a
    percentage band would let a third one through.
    """
    out: list[str] = []
    for c in cells:
        where = f"{c.region}/{c.network_type}/{c.path.value}"
        if c.filter_false_rejects:
            out.append(
                f"B0 {where}: {c.filter_false_rejects} way(s) the Python filter "
                f"rejected and Overpass kept — SPIKE-E's defect shape"
            )
        if c.filter_false_accepts:
            out.append(
                f"B0 {where}: {c.filter_false_accepts} way(s) the Python filter "
                f"kept and Overpass rejected"
            )
        for tag, lost in sorted(c.tag_losses.items()):
            if lost:
                out.append(f"B5 {where}: tag {tag!r} lost on {lost} element(s) — #206 shape")
    return out


def _cell_band(c: CellResult) -> Band:
    """Grade one cell on B1-B4. B0/B5 are vetoes and are not graded here."""
    parity = (
        c.unattributed_node_diff == 0
        and c.unattributed_edge_diff == 0
        and c.edge_key_stability >= MIN_EDGE_KEY_STABILITY_PARITY
        and c.golden_scc == c.local_scc
        and c.length_delta_max_m <= MAX_EDGE_LENGTH_DELTA_PARITY_M
    )
    if parity:
        return Band.PARITY

    # B3's asymmetry: a shrunken SCC is RESCOPE in *any* single cell, regardless
    # of what the aggregate says, because the aggregate is where a severed
    # network hides.
    if c.scc_shrank_beyond_band:
        return Band.RESCOPE
    if c.rekeyed_on_single_edge_uv:
        # `k` moved on a (u, v) that has only one edge — that is not iteration
        # order, it is something else, and we do not know what.
        return Band.RESCOPE

    recalibrate = (
        c.node_diff_fraction <= MAX_UNATTRIBUTED_SET_DIFF
        and c.edge_diff_fraction <= MAX_UNATTRIBUTED_SET_DIFF
        and c.edge_key_stability >= MIN_EDGE_KEY_STABILITY_RECALIBRATE
        and c.scc_delta_fraction <= MAX_SCC_DELTA
        and abs(c.local_scc_ratio - c.golden_scc_ratio) * 100.0 <= MAX_SCC_RATIO_DELTA_POINTS
        and c.length_delta_p99_m <= MAX_EDGE_LENGTH_DELTA_P99_RECALIBRATE_M
        and c.length_delta_max_m <= MAX_EDGE_LENGTH_DELTA_MAX_RECALIBRATE_M
    )
    return Band.RECALIBRATE if recalibrate else Band.RESCOPE


def clip_band(r: ClipResult) -> Band:
    """B6. A figure not taken on the mirror cannot reach PARITY — addendum 2c
    makes server-side measurement the condition on which Q1-C is decidable, so a
    dev-box number is reported and explicitly does not count toward the band."""
    if (
        r.measured_on_mirror
        and r.p95_wall_s <= MAX_CLIP_P95_S_PARITY
        and r.peak_rss_mb <= MAX_CLIP_PEAK_RSS_MB_PARITY
        and r.output_fraction <= MAX_CLIP_OUTPUT_FRACTION_PARITY
    ):
        return Band.PARITY
    if (
        r.p95_wall_s <= MAX_CLIP_P95_S_RECALIBRATE
        and r.peak_rss_mb <= MAX_CLIP_PEAK_RSS_MB_RECALIBRATE
        and r.output_fraction <= MAX_CLIP_OUTPUT_FRACTION_RECALIBRATE
    ):
        return Band.RECALIBRATE
    return Band.RESCOPE


_ORDER = {Band.PARITY: 0, Band.RECALIBRATE: 1, Band.RESCOPE: 2}


def classify(cells: tuple[CellResult, ...], clips: tuple[ClipResult, ...] = ()) -> Band:
    """The run's verdict. Worst cell wins; a veto is RESCOPE outright.

    `path` is deliberately *not* special-cased. If TRANSPORT passes and
    REIMPLEMENTATION fails, this returns RESCOPE and the write-up says why —
    the finding is then "parity is a property of which swap you choose", and §8
    gets a named implementation rather than a warning. Encoding a preference for
    one path here would be deciding the answer in the pre-registration.
    """
    if veto_reasons(cells):
        return Band.RESCOPE
    worst = Band.PARITY
    for band in [_cell_band(c) for c in cells] + [clip_band(r) for r in clips]:
        if _ORDER[band] > _ORDER[worst]:
            worst = band
    return worst


def unmet_reasons(cells: tuple[CellResult, ...], clips: tuple[ClipResult, ...] = ()) -> list[str]:
    """Human-readable list of why the run did not reach PARITY — for the writeup."""
    out = veto_reasons(cells)
    for c in cells:
        where = f"{c.region}/{c.network_type}/{c.path.value}"
        if c.unattributed_node_diff:
            out.append(
                f"B1 {where}: {c.unattributed_node_diff} unattributed node(s) "
                f"({c.node_diff_fraction:.3%} of {c.golden_nodes:,})"
            )
        if c.unattributed_edge_diff:
            out.append(
                f"B2a {where}: {c.unattributed_edge_diff} unattributed edge(s) "
                f"({c.edge_diff_fraction:.3%} of {c.golden_edges:,})"
            )
        if c.edge_key_stability < MIN_EDGE_KEY_STABILITY_PARITY:
            out.append(f"B2b {where}: edge key stability {c.edge_key_stability:.4%}")
        if c.rekeyed_on_single_edge_uv:
            out.append(
                f"B2b {where}: {c.rekeyed_on_single_edge_uv} re-key(s) on a (u, v) "
                f"with a single edge — not iteration order"
            )
        if c.golden_scc != c.local_scc:
            out.append(
                f"B3 {where}: SCC {c.local_scc:,} vs golden {c.golden_scc:,} "
                f"({c.scc_delta_fraction:.3%}"
                f"{', SHRANK past band' if c.scc_shrank_beyond_band else ''})"
            )
        if c.length_delta_max_m > MAX_EDGE_LENGTH_DELTA_PARITY_M:
            out.append(
                f"B4 {where}: length delta p99 {c.length_delta_p99_m:.4g} m, "
                f"max {c.length_delta_max_m:.4g} m"
            )
    for r in clips:
        if not r.measured_on_mirror:
            out.append(
                f"B6 {r.bbox_key}: not measured on the mirror — cannot reach PARITY "
                f"(addendum 2c)"
            )
        if r.p95_wall_s > MAX_CLIP_P95_S_PARITY:
            out.append(f"B6 {r.bbox_key}: p95 wall {r.p95_wall_s:.1f}s")
        if r.peak_rss_mb > MAX_CLIP_PEAK_RSS_MB_PARITY:
            out.append(f"B6 {r.bbox_key}: peak RSS {r.peak_rss_mb:.0f} MB")
        if r.output_fraction > MAX_CLIP_OUTPUT_FRACTION_PARITY:
            out.append(f"B6 {r.bbox_key}: output {r.output_fraction:.2%} of extract")
    return out
