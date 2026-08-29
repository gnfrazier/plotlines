"""Co-location analysis — PRD FR102-FR105a, ARCH §4.4, story N4/N4a.

Stage 3 of the authoring pipeline. Takes the notability-scored `Candidate`s a
bbox produced (Stage 1) and finds **spatial clusters across heterogeneous
layers**, scoring each by combined salience and tightness and proposing a role
set from the affinities its members declare (ARCH D47).

This runs as a **named Author action over a fixed bbox** (FR102) — never
ambiently over a moving viewport — so it is cheap to cache alongside the
candidates it reads (ARCH §8.2). It never writes canon (ARCH P10): a
`ClusterProposal` is something the Author reviews and promotes or rejects, not
an anchor.

The ranking function, the corridor-proximity treatment, and the reviewable cap
were tuned by **SPIKE-B** (issue #169, 2026-08-27) against the Blue Ridge
Parkway corridor (Asheville-Boone, NC — ~8,800 km2) and PRD §5.4a's worked
review pass. See `spikes/SPIKE-B/results/RESULTS.md`. The three findings that
shaped this module:

  1. **Cost is not a concern at bbox scale.** ~4,700 candidates over an
     8,800 km2 multi-day bbox cluster in well under a tenth of a second at a
     few MB; the grid index makes it near-linear in candidate count. The
     cacheable-endpoint mitigation is more than enough — the analysis does not
     need bounding.
  2. **Corridor proximity is a filter and a resort axis, not part of the
     default rank (Q12 answered "no, it does not dominate").** Folding an
     `exp(-d/decay)` factor into the score buried genuinely major sights that
     sit a few km off the drawn line under tight roadside viewpoint pairs.
     The default sort stays salience x tightness (as N4a's own text says);
     `by_corridor_proximity` is the opt-in resorted view, and the corridor
     *filter* is the caller dropping proposals past a distance threshold.
  3. **The cap is a floor of 30 plus 0.5 per corridor-km** when a route
     exists — proposals run ~1 per 18 km2, so an unbounded 20,000 km2 bbox
     yields ~1,100. Always returned with the count beyond it (N4a), never a
     silent truncation.
"""

from __future__ import annotations

import hashlib
import heapq
import math
from dataclasses import dataclass
from typing import Iterable, Sequence

from .notability import Candidate
from .providers import BBox

_EARTH_R_M = 6_371_000.0


# --------------------------------------------------------------------------- #
# Parameters (SPIKE-B tuned; ARCH §4.4 "radius bands, min salience, cap")
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class ColocationParams:
    """Every knob the ranking function reads. Defaults are SPIKE-B's tuned
    values; they are here rather than inline so a later region can adjust them
    without a code change (the same discipline as the notability ruleset)."""

    #: A cluster is "one stop" — a place the Author would park once and walk
    #: around — so **every pair of its members lies within this** (complete
    #: linkage, not single). SPIKE-B finding: single linkage at any radius
    #: chains a town's amenities into one 100-member blob; a diameter ceiling
    #: is what keeps a proposal to a walkable stop and splits a main street
    #: into the few real clusters on it.
    max_diameter_m: float = 160.0

    #: Distance scale for the tightness score. A cluster whose members sit
    #: this far (RMS) from their centroid scores tightness 0.5.
    tightness_scale_m: float = 90.0

    #: Tightness never drives the score below this fraction of the
    #: salience-only score — a very notable cluster that happens to be loose
    #: is still worth surfacing. SPIKE-B: 0.6 pushed s=1.0 clusters below
    #: tight s=0.85 pairs; 0.72 lets tightness re-order without overturning
    #: a real salience gap.
    tightness_floor: float = 0.72

    #: Candidates below this salience are ignored when *forming* clusters —
    #: they neither seed nor join. 0.0 = every candidate participates; the
    #: bulk-reject-below-threshold action (N4a) is a review-time filter, not
    #: this. SPIKE-B leaves it at 0.0 and lets ranking + cap do the work.
    min_member_salience: float = 0.0

    #: A formed cluster whose rank score is below this is dropped before the
    #: cap is applied — removes 2-member all-noise pairs (two benches, a
    #: bench and a waste basket) that are co-located but propose nothing.
    min_cluster_score: float = 0.12

    #: Decay scale for the *optional* `by_corridor_proximity` resort (N4a's
    #: "resortable by distance-from-route"). Not applied to the default rank —
    #: SPIKE-B found folding it in buries major off-route sights. 2500 m: a
    #: cluster 2.5 km off the line keeps ~37% weight in that resorted view.
    corridor_decay_m: float = 2500.0

    #: The reviewable cap (FR105a). Floor plus an allowance per km of route
    #: when one exists (a longer tour legitimately has more to review, and it
    #: grows with corridor km ~1D, not bbox area ~2D). SPIKE-B: proposals run
    #: ~1 per 18 km2, so a 20,000 km2 bbox yields ~1,100 — the cap is not
    #: optional. 30 + 0.5/route-km: §5.4a's ~40 fits the floor; a 250 km tour
    #: caps at ~155, the rest shown as "+N beyond", never truncated.
    cap_floor: int = 30
    cap_per_route_km: float = 0.5


DEFAULTS = ColocationParams()


# --------------------------------------------------------------------------- #
# Result types
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class ClusterMember:
    """One candidate inside a proposal, carried through so the Author can
    judge the proposal rather than trust it (FR103/FR104, N4a)."""

    candidate_id: str
    layer: str
    type: str          # the resolved "key=value" of the candidate's tags
    title: str | None
    salience: float
    role_affinity: str


@dataclass(frozen=True)
class ClusterProposal:
    """A reviewable object (N4a), not a map pin. Renders as a card carrying a
    generated name, its members, the suggested role set with the affinity that
    produced it, extent + tightness, and distance-from-route where one exists.
    """

    id: str
    name: str
    kind: str                       # "narrative" | "provision" | "narrative+provision" (+"+station")
    role_affinities: tuple[str, ...]  # FR105 affinity union, sorted
    members: tuple[ClusterMember, ...]
    centroid: tuple[float, float]   # (lon, lat)
    extent_m: float                 # radius of the smallest enclosing circle-ish (max dist to centroid)
    tightness: float                # 0..1, higher = more compact
    salience_score: float           # 0..1, noisy-OR of member saliences
    rank_score: float               # what the list is sorted by
    distance_to_route_m: float | None = None
    is_new: bool = True             # set false by `diff_runs` when seen in a prior run

    @property
    def member_key(self) -> frozenset[str]:
        return frozenset(m.candidate_id for m in self.members)


# --------------------------------------------------------------------------- #
# Geometry helpers (equirectangular; fine at cluster scale — same call the
# providers seam already makes for area, ARCH §14.2)
# --------------------------------------------------------------------------- #

def _local_xy(lon: float, lat: float, lat0: float) -> tuple[float, float]:
    k = math.pi / 180.0 * _EARTH_R_M
    return (lon * k * math.cos(math.radians(lat0)), lat * k)


def _dist_m(a: tuple[float, float], b: tuple[float, float], lat0: float) -> float:
    ax, ay = _local_xy(a[0], a[1], lat0)
    bx, by = _local_xy(b[0], b[1], lat0)
    return math.hypot(ax - bx, ay - by)


def _point_seg_dist_m(p, a, b, lat0: float) -> float:
    px, py = _local_xy(p[0], p[1], lat0)
    ax, ay = _local_xy(a[0], a[1], lat0)
    bx, by = _local_xy(b[0], b[1], lat0)
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _dist_to_polyline_m(p, route: Sequence[tuple[float, float]], lat0: float) -> float:
    return min(_point_seg_dist_m(p, route[i], route[i + 1], lat0)
              for i in range(len(route) - 1))


# --------------------------------------------------------------------------- #
# Clustering — grid pre-pass for connected components, then complete-linkage
# agglomeration inside each so every cluster's diameter <= max_diameter_m.
# --------------------------------------------------------------------------- #

class _UF:
    def __init__(self, n: int) -> None:
        self.p = list(range(n))

    def find(self, x: int) -> int:
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[ra] = rb


def _components(pts_xy: list[tuple[float, float]], radius_m: float) -> list[list[int]]:
    """Connected components under "within radius_m", via a grid of cell size
    radius_m so each point only checks its 9 neighbouring cells. This is only
    a *coarse* pass — it caps how many points the O(k^2) complete-linkage step
    below ever sees at once — so it stays near-linear in len(pts)."""
    if not pts_xy:
        return []
    uf = _UF(len(pts_xy))
    cell = radius_m
    grid: dict[tuple[int, int], list[int]] = {}
    for i, (x, y) in enumerate(pts_xy):
        grid.setdefault((int(x // cell), int(y // cell)), []).append(i)
    r2 = radius_m * radius_m
    for (cx, cy), members in grid.items():
        neigh: list[int] = []
        for gx in (cx - 1, cx, cx + 1):
            for gy in (cy - 1, cy, cy + 1):
                neigh.extend(grid.get((gx, gy), ()))
        for i in members:
            xi, yi = pts_xy[i]
            for j in neigh:
                if j <= i:
                    continue
                xj, yj = pts_xy[j]
                if (xi - xj) ** 2 + (yi - yj) ** 2 <= r2:
                    uf.union(i, j)
    comps: dict[int, list[int]] = {}
    for i in range(len(pts_xy)):
        comps.setdefault(uf.find(i), []).append(i)
    return list(comps.values())


#: Above this many points in one connected component, grid-split the component
#: before complete-linkage rather than run the O(k^2 log k) agglomeration on
#: the whole thing. A 160 m-connected blob of this many candidates is ~1 per
#: 100 m2 — denser than any real place — so the split only ever bites on
#: synthetic stress inputs, and even then loses at most a boundary merge.
_SPLIT_CAP = 400


def _complete_link(idxs: list[int], pts_xy: list[tuple[float, float]],
                   max_diam: float) -> list[list[int]]:
    """Heap-driven greedy complete-linkage agglomeration of one component:
    start every point as its own cluster, repeatedly merge the closest pair
    whose complete-linkage distance (the max pairwise distance across the two,
    which for clusters both already within max_diam *is* the merged diameter)
    stays <= max_diam, stop when no such pair remains. Guarantees every
    returned cluster's members are all mutually within max_diam — so a
    continuous main street splits into the handful of walkable stops on it,
    not one blob.

    Lazy heap of pair distances + Lance-Williams update
    (D(A+B, X) = max(D(A,X), D(B,X))) → O(k^2 log k) in the component size."""
    k = len(idxs)
    if k <= 1:
        return [idxs] if idxs else []

    active: dict[int, list[int]] = {c: [idxs[c]] for c in range(k)}
    link: dict[int, dict[int, float]] = {c: {} for c in range(k)}
    heap: list[tuple[float, int, int]] = []
    for a in range(k):
        xa, ya = pts_xy[idxs[a]]
        for b in range(a + 1, k):
            xb, yb = pts_xy[idxs[b]]
            dab = math.hypot(xa - xb, ya - yb)
            link[a][b] = link[b][a] = dab
            if dab <= max_diam:
                heap.append((dab, a, b))
    heapq.heapify(heap)

    while heap:
        d, a, b = heapq.heappop(heap)
        if a not in active or b not in active:
            continue
        if link[a].get(b) != d:      # stale entry, superseded by a merge
            continue
        if d > max_diam:
            break
        active[a].extend(active.pop(b))
        lb = link.pop(b)
        for c in list(active):
            if c == a:
                continue
            m = link[a].get(c, 0.0)
            other = lb.get(c, 0.0)
            if other > m:
                m = other
            link[a][c] = link[c][a] = m
            link[c].pop(b, None)
            if m <= max_diam:
                heapq.heappush(heap, (m, min(a, c), max(a, c)))
    return list(active.values())


def _grid_split(comp: list[int], pts_xy: list[tuple[float, float]],
                cell: float) -> list[list[int]]:
    buckets: dict[tuple[int, int], list[int]] = {}
    for i in comp:
        x, y = pts_xy[i]
        buckets.setdefault((int(x // cell), int(y // cell)), []).append(i)
    return list(buckets.values())


def _cluster_indices(pts_xy: list[tuple[float, float]],
                     max_diameter_m: float) -> list[list[int]]:
    out: list[list[int]] = []
    for comp in _components(pts_xy, max_diameter_m):
        if len(comp) < 2:
            continue
        groups = ([comp] if len(comp) <= _SPLIT_CAP
                  else _grid_split(comp, pts_xy, max_diameter_m))
        for g in groups:
            if len(g) < 2:
                continue
            out.extend(cl for cl in _complete_link(g, pts_xy, max_diameter_m)
                       if len(cl) >= 2)
    return out


# --------------------------------------------------------------------------- #
# Scoring
# --------------------------------------------------------------------------- #

def _noisy_or(values: Iterable[float]) -> float:
    prod = 1.0
    for v in values:
        prod *= (1.0 - max(0.0, min(1.0, v)))
    return 1.0 - prod


def _kind_and_roles(affinities: set[str]) -> tuple[str, tuple[str, ...]]:
    roles = tuple(sorted(affinities))
    has_n = "narrative" in affinities
    has_p = "provision" in affinities
    if has_n and has_p:
        base = "narrative+provision"
    elif has_p:
        base = "provision"
    elif has_n:
        base = "narrative"
    else:
        # no narrative/provision member — a station-only (or unknown-affinity)
        # cluster; its kind is just its role list joined.
        return "+".join(roles) if roles else "narrative", roles
    if "station" in affinities:
        base = base + "+station"
    return base, roles


def _proposal_id(member_ids: Iterable[str]) -> str:
    h = hashlib.sha1("\x1f".join(sorted(member_ids)).encode()).hexdigest()
    return f"cl_{h[:16]}"


# --------------------------------------------------------------------------- #
# Public entry point
# --------------------------------------------------------------------------- #

def analyze_colocation(
    candidates: Sequence[Candidate],
    bbox: BBox,
    params: ColocationParams = DEFAULTS,
    *,
    route: Sequence[tuple[float, float]] | None = None,
    rejected: Iterable[frozenset[str]] = (),
) -> list[ClusterProposal]:
    """Cluster `candidates` within `bbox` and return ranked `ClusterProposal`s.

    `route`, when given, is a lon/lat polyline; every proposal gets a
    `distance_to_route_m` for the N4a corridor filter and the
    `by_corridor_proximity` resort — the default rank stays salience x
    tightness (SPIKE-B / Q12). `rejected` is the set of member-id sets the
    Author has already dismissed for this trip (ARCH §4.4 "a small rejection set");
    a fresh cluster whose membership substantially matches one is dropped, so
    a re-run does not re-propose it (FR110, N4a).

    The return is the ranked list already **capped** (see `reviewable_cap`);
    `analyze_colocation_full` returns the uncapped list plus the beyond-count
    for the "+N more" the UI must show instead of truncating silently (N4a).
    """
    capped, _ = analyze_colocation_full(
        candidates, bbox, params, route=route, rejected=rejected)
    return capped


def analyze_colocation_full(
    candidates: Sequence[Candidate],
    bbox: BBox,
    params: ColocationParams = DEFAULTS,
    *,
    route: Sequence[tuple[float, float]] | None = None,
    rejected: Iterable[frozenset[str]] = (),
) -> tuple[list[ClusterProposal], int]:
    """`(capped_proposals, n_beyond_cap)` — the form N4a's dense state needs."""
    in_box = [
        c for c in candidates
        if bbox.west <= c.coord[0] <= bbox.east
        and bbox.south <= c.coord[1] <= bbox.north
        and c.salience >= params.min_member_salience
    ]
    if len(in_box) < 2:
        return [], 0

    lat0 = (bbox.south + bbox.north) / 2
    pts_xy = [_local_xy(c.coord[0], c.coord[1], lat0) for c in in_box]
    rejected_sets = [frozenset(r) for r in rejected]

    proposals: list[ClusterProposal] = []
    for idxs in _cluster_indices(pts_xy, params.max_diameter_m):
        if len(idxs) < 2:
            continue
        members = [in_box[i] for i in idxs]
        mxy = [pts_xy[i] for i in idxs]
        cx = sum(x for x, _ in mxy) / len(mxy)
        cy = sum(y for _, y in mxy) / len(mxy)
        dists = [math.hypot(x - cx, y - cy) for x, y in mxy]
        rms = math.sqrt(sum(d * d for d in dists) / len(dists))
        extent = max(dists)
        tightness = 1.0 / (1.0 + rms / params.tightness_scale_m)

        # Combined salience: noisy-OR of the members. A cluster is at least as
        # notable as its best member and rises with diminishing returns as
        # more notable features join it. SPIKE-B: this is the "combined
        # salience" of FR102/FR105a; its *discrimination* is bounded by the
        # notability weights feeding it, and in mountain terrain those are
        # near-flat (`tourism=viewpoint` 0.7, `natural=peak` 0.55) — which is
        # why SPIKE-A's deferred prominence sub-scaling is the next step, not
        # a cleverer aggregation here.
        sal = _noisy_or(m.salience for m in members)
        tight_mult = params.tightness_floor + (1.0 - params.tightness_floor) * tightness
        score = sal * tight_mult

        centroid_lonlat = (
            sum(m2.coord[0] for m2 in (in_box[i] for i in idxs)) / len(idxs),
            sum(m2.coord[1] for m2 in (in_box[i] for i in idxs)) / len(idxs),
        )
        # SPIKE-B / Q12: distance-to-route is carried for display, the N4a
        # corridor *filter*, and the "resort by distance-from-route" action
        # (`by_corridor_proximity`) — but it does NOT fold into the default
        # rank. Decaying the score by proximity buried genuinely major sights
        # that sit a few km off the drawn line; N4a's own spec keeps the
        # default sort at salience x tightness and makes corridor a resort axis.
        dist_route = None
        if route and len(route) >= 2:
            dist_route = _dist_to_polyline_m(centroid_lonlat, route, lat0)

        if score < params.min_cluster_score:
            continue

        member_ids = [m.id for m in members]
        if _is_rejected(frozenset(member_ids), rejected_sets):
            continue

        affinities = {m.role_affinity for m in members}
        kind, roles = _kind_and_roles(affinities)
        cm = tuple(
            ClusterMember(
                candidate_id=m.id, layer=m.layer,
                type=_type_of(m), title=m.title,
                salience=round(m.salience, 4), role_affinity=m.role_affinity,
            )
            for m in sorted(members, key=lambda m: -m.salience)
        )
        proposals.append(ClusterProposal(
            id=_proposal_id(member_ids),
            name=_name_for(cm),
            kind=kind,
            role_affinities=roles,
            members=cm,
            centroid=centroid_lonlat,
            extent_m=round(extent, 1),
            tightness=round(tightness, 4),
            salience_score=round(sal, 4),
            rank_score=round(score, 6),
            distance_to_route_m=None if dist_route is None else round(dist_route, 1),
        ))

    proposals.sort(key=lambda p: (-p.rank_score, p.id))
    cap = reviewable_cap(params, route)
    return proposals[:cap], max(0, len(proposals) - cap)


def reviewable_cap(params: ColocationParams,
                   route: Sequence[tuple[float, float]] | None = None) -> int:
    """FR105a's cap. A floor of `cap_floor`, plus `cap_per_route_km` per km of
    route when one exists — a 250 km tour legitimately has more to get through
    than a day ride, but the growth is tied to corridor km (~1D) not bbox area
    (~2D, which is what would otherwise blow the count up). SPIKE-B: 30 +
    0.5/km puts a ~250 km tour at a ~155 cap and the §5.4a 30 km trip box at
    30. The count beyond the cap is always returned (N4a — never truncate
    silently)."""
    if not route or len(route) < 2:
        return params.cap_floor
    km = _polyline_len_km(route)
    return params.cap_floor + int(round(params.cap_per_route_km * km))


def by_corridor_proximity(
    proposals: Sequence[ClusterProposal],
    params: ColocationParams = DEFAULTS,
) -> list[ClusterProposal]:
    """N4a's "resortable by distance-from-route" — the Author's opt-in view
    that pulls corridor-adjacent proposals up. Multiplies each proposal's
    rank score by exp(-distance_to_route_m / corridor_decay_m) and re-sorts.
    A proposal with no `distance_to_route_m` (no route was given) is left
    where it is. This is a *view*, not the default order."""
    def key(p: ClusterProposal) -> tuple[float, str]:
        d = p.distance_to_route_m
        if d is None:
            return (-p.rank_score, p.id)
        return (-(p.rank_score * math.exp(-d / params.corridor_decay_m)), p.id)
    return sorted(proposals, key=key)


def diff_runs(previous: Sequence[ClusterProposal],
              current: Sequence[ClusterProposal]) -> list[ClusterProposal]:
    """N4a: 'running the analysis again marks which proposals are new since the
    last run.' Returns `current` with `is_new` set from whether an
    equivalent proposal (same member set, allowing one added/removed member)
    was in `previous`."""
    return mark_new_against(current, [p.member_key for p in previous])


def mark_new_against(
    current: Sequence[ClusterProposal],
    previous_member_keys: Iterable[frozenset[str]],
) -> list[ClusterProposal]:
    """`diff_runs`, but taking just the prior run's member-id sets rather
    than whole `ClusterProposal`s — the form a stateless endpoint has, since
    the client persists only the small sets (ARCH §4.4), not the proposals.
    A proposal whose membership matches a prior one (Jaccard ≥ 0.6, i.e. up
    to one member added or removed) is `is_new=False`."""
    prev = [frozenset(k) for k in previous_member_keys]
    out: list[ClusterProposal] = []
    for p in current:
        seen = any(_jaccard(p.member_key, k) >= 0.6 for k in prev)
        out.append(_replace_is_new(p, not seen))
    return out


# --------------------------------------------------------------------------- #
# internals
# --------------------------------------------------------------------------- #

def _type_of(c: Candidate) -> str:
    for key in ("historic", "tourism", "amenity", "natural", "leisure",
                "man_made", "type"):
        if key in c.tags:
            return f"{key}={c.tags[key]}"
    return c.layer


def _name_for(members: Sequence[ClusterMember]) -> str:
    for m in members:  # already sorted by -salience
        if m.title:
            return m.title
    top = members[0]
    return top.type.split("=")[-1].replace("_", " ").title()


def _is_rejected(members: frozenset[str],
                 rejected_sets: Sequence[frozenset[str]]) -> bool:
    return any(_jaccard(members, r) >= 0.6 for r in rejected_sets)


def _jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a and not b:
        return 1.0
    return len(a & b) / len(a | b)


def _polyline_len_km(route: Sequence[tuple[float, float]]) -> float:
    lat0 = sum(p[1] for p in route) / len(route)
    total = 0.0
    for i in range(len(route) - 1):
        total += _dist_m(route[i], route[i + 1], lat0)
    return total / 1000.0


def _replace_is_new(p: ClusterProposal, is_new: bool) -> ClusterProposal:
    return ClusterProposal(
        id=p.id, name=p.name, kind=p.kind, role_affinities=p.role_affinities,
        members=p.members, centroid=p.centroid, extent_m=p.extent_m,
        tightness=p.tightness, salience_score=p.salience_score,
        rank_score=p.rank_score, distance_to_route_m=p.distance_to_route_m,
        is_new=is_new,
    )
