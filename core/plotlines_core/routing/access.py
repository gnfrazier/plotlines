"""Mode-legal routability (FR128, Story A11, issue #29) — ARCH §7.9.

v1.0 specified no passability guarantee anywhere in 96 requirements, though the OSM
attribute mapping always carried a routability-constraint column (`docs/osm_reference.md`).
This module is where that column becomes engine behaviour: **a tag that determines
whether a way may legally or physically be traversed in a given mode is a routability
constraint, and is honoured as one** (FR128's governing rule).

Three treatments, never conflated:

  * **Hard exclusion** (`bicycle=no`, `foot=no`, `canoe=no`/`private`/`permit`,
    `bicycle=use_sidepath`, `bicycle=destination`, an unpassable ford, a hard waterway
    obstacle) — the edge is removed from the mode's graph entirely. A penalty large
    enough to avoid an edge is not the same as an edge that cannot be used (ARCH §7.9);
    this runs before scoring, not as a cost.
  * **Surfaced constraint** (`bicycle=dismount`, a barrier with no access override, a
    ford a mode *can* cross) — still routable, but flagged on the resolved path so a
    route response can name it rather than silently rolling through it.
  * **Permission** (`oneway:bicycle=no`) — a contraflow edge the base graph may not
    carry is added back for the mode that is allowed to use it.

This is a *legality* model, entirely separate from `scoring.profile`'s traffic-stress
model (ARCH §7.9's closing note) — a road being quiet and a road being legal are
different questions.

**Model simplification, stated once:** OSM tags a barrier on the *node* where it sits,
but this codebase's graph abstraction (`scoring.profile.features` and everywhere else
in `routing/`) only ever reads way tags off the *edge* dict — nodes carry just
`y`/`x`/`elevation`. `evaluate_edge` follows that same convention: `barrier`, `ford`,
`waterway`, and `climbing:access` are read as edge-level tags. A real extraction
pipeline that keeps node-level barrier tags separate would fold them onto the
incident edge before reaching this module; that folding is graph-construction's job,
not this one's.

`climbing:access` is not wired into any solver here — climbing is a station activity,
not a traversal mode (FR130), and the anchor/station object model that would hold
"a station is authored here" does not exist yet (`content/anchor.py`'s own note: station
activity is "reserved for later stories, not guessed ahead of time"). `climbing_access_closed`
is the governing-rule predicate FR128's climbing bullet needs, ready for that station
model to call once it exists.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import networkx as nx

# ---------------------------------------------------------------------------
# Tag reading. OSM tags arrive as a bare string or, after way-merging during
# simplification, a list of strings that disagreed across the merged ways
# (the real Boulder fixture has `bicycle=['dismount', 'designated']`) — every
# value in the list is a fact about some part of the merged way, so a hard
# exclusion or a surfaced constraint must check the whole list, never just
# the first element the way `scoring.profile._first` does for soft scoring.
# ---------------------------------------------------------------------------


def _values(data: dict, key: str) -> list[str]:
    """Every value tagged under `key`, lower-cased. `[]` when untagged."""
    raw = data.get(key)
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(v).lower() for v in raw]
    return [str(raw).lower()]


def _effective_access_values(data: dict, mode_key: str | None) -> list[str]:
    """The access values that actually govern this edge for one mode.

    OSM's access hierarchy: a mode-specific tag (`bicycle=*`) overrides the
    generic `access=*` tag outright rather than merging with it — an
    `access=private, bicycle=yes` way is open to bikes, full stop. Falls back
    to `access=*` only when the mode has no opinion of its own.
    """
    if mode_key:
        specific = _values(data, mode_key)
        if specific:
            return specific
    return _values(data, "access")


# ---------------------------------------------------------------------------
# Per-mode constraint configuration. FR128 names cycling, hiking (foot), and
# paddling (canoe) as the seed set shipping first — "not a closed list": a
# new traversal mode is a new `ModeConstraints` entry, exactly the extension
# path FR130 already established for `WeightProfile`.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ModeConstraints:
    """One mode's routability rules — data, not a branch of code (M1's own
    "themes are data" rule, applied to legality instead of preference)."""

    mode: str
    #: The OSM key carrying this mode's own access opinion (`bicycle`, `foot`,
    #: `canoe`), or `None` for a mode with no dedicated access tag.
    access_key: str | None
    #: Values of `access_key` that remove the edge outright.
    excluded_values: frozenset[str]
    #: Values of the *generic* `access=*` tag that remove the edge, used only
    #: when `access_key` itself is silent on this edge.
    generic_excluded_values: frozenset[str]
    #: Values of `access_key` that stay routable but must be surfaced.
    surfaced_values: frozenset[str]
    #: Whether `ford=yes`/`stepping_stones` is even a question for this mode.
    applies_to_fords: bool
    #: True: a tagged ford stays routable, flagged. False: it excludes the edge.
    ford_passable: bool
    #: True: `waterway=weir`/`lock_gate`/`waterfall`/`hazard` excludes the edge.
    blocks_waterway_obstacles: bool
    #: True: `oneway:bicycle=no` earns this mode a contraflow edge the base
    #: graph doesn't carry.
    honours_contraflow: bool


#: Ford values recognised as a crossing at all (FR128 / osm_reference.md).
_FORD_VALUES = frozenset({"yes", "stepping_stones"})

#: `waterway=*` values that are hard obstacles, not merely notable features
#: (FR128 / FR15 — a mapped hazard may prompt an Author-drawn portage, but the
#: engine never claims a portage route it does not have, so the edge is
#: simply removed here).
_WATERWAY_HARD_OBSTACLES = frozenset({"weir", "lock_gate", "waterfall", "hazard"})

#: Barrier treatment with no access-tag override present, per mode. "pass":
#: routable, no flag. "penalty": routable, flagged as a surfaced constraint.
#: "exclude" never appears here — an unconditional exclusion belongs in
#: `excluded_values` instead; a barrier's default is always provisional on
#: there being no explicit access grant/denial to check first.
_BARRIER_DEFAULTS: dict[str, dict[str, str]] = {
    # cycle_barrier: "forcing a slow-down or dismount" (osm_reference.md) —
    # routable, but materially different from clear road.
    "cycling": {"cycle_barrier": "penalty", "bollard": "pass", "gate": "penalty"},
    # A cycle-specific chicane is not a pedestrian obstacle; a gate still is.
    "hiking": {"cycle_barrier": "pass", "bollard": "pass", "gate": "penalty"},
    # Barriers belong to the road/path graph this module's simplification
    # reads tags from — meaningless on a waterway.
    "paddling": {},
}


MODE_CONSTRAINTS: dict[str, ModeConstraints] = {
    "cycling": ModeConstraints(
        mode="cycling",
        access_key="bicycle",
        # FR128: use_sidepath/destination are compulsory-redirect and
        # area-restricted access respectively — the architecture's own
        # table (§7.9) lists both as hard exclusions alongside bicycle=no,
        # not as a softer "prefer the sidepath" bias.
        excluded_values=frozenset({"no", "use_sidepath", "destination"}),
        generic_excluded_values=frozenset({"no", "private"}),
        surfaced_values=frozenset({"dismount"}),
        applies_to_fords=True,
        ford_passable=False,
        blocks_waterway_obstacles=False,
        honours_contraflow=True,
    ),
    "hiking": ModeConstraints(
        mode="hiking",
        access_key="foot",
        excluded_values=frozenset({"no"}),
        generic_excluded_values=frozenset({"no", "private"}),
        surfaced_values=frozenset(),
        applies_to_fords=True,
        ford_passable=True,
        blocks_waterway_obstacles=False,
        honours_contraflow=False,
    ),
    "paddling": ModeConstraints(
        mode="paddling",
        access_key="canoe",
        excluded_values=frozenset({"no", "private", "permit"}),
        generic_excluded_values=frozenset({"no", "private"}),
        surfaced_values=frozenset(),
        applies_to_fords=False,
        ford_passable=True,
        blocks_waterway_obstacles=True,
        honours_contraflow=False,
    ),
}


@dataclass(frozen=True)
class EdgeVerdict:
    """One edge's routability for one mode."""

    passable: bool
    #: Surfaced-constraint labels ("bicycle=dismount", "ford=yes", ...),
    #: empty when the edge is ordinary or excluded outright.
    flags: frozenset[str] = field(default_factory=frozenset)
    #: Set only when `passable` is False — the tag that excluded it, for A6.
    reason: str | None = None


def _barrier_treatment(barrier: str, data: dict, constraints: ModeConstraints) -> str:
    """pass / penalty / exclude for one barrier, per its own access value.

    "Its own" is this module's documented simplification (module docstring):
    whatever access tag is on the edge is treated as governing the barrier
    sitting on it, since the graph carries no separate node-tag channel.
    """
    override = _effective_access_values(data, constraints.access_key)
    if override:
        if any(v in constraints.excluded_values or v in constraints.generic_excluded_values
               for v in override):
            return "exclude"
        return "pass"  # an explicit yes/designated/permissive grant overrides caution
    return _BARRIER_DEFAULTS.get(constraints.mode, {}).get(barrier, "pass")


def evaluate_edge(data: dict, mode: str) -> EdgeVerdict:
    """One edge's routability for `mode`. An unknown mode is unconstrained —
    this module's seed set (FR128) is not a closed list, and a mode this
    table has no opinion on should route exactly as it did before A11."""
    constraints = MODE_CONSTRAINTS.get(mode)
    if constraints is None:
        return EdgeVerdict(True)

    flags: set[str] = set()

    mode_tagged = bool(constraints.access_key and _values(data, constraints.access_key))
    values = _effective_access_values(data, constraints.access_key)
    excluded = constraints.excluded_values if mode_tagged else constraints.generic_excluded_values
    tag_name = constraints.access_key if mode_tagged else "access"
    for value in values:
        if value in excluded:
            return EdgeVerdict(False, reason=f"{tag_name}={value}")
    if mode_tagged:
        for value in values:
            if value in constraints.surfaced_values:
                flags.add(f"{constraints.access_key}={value}")

    for barrier in _values(data, "barrier"):
        treatment = _barrier_treatment(barrier, data, constraints)
        if treatment == "exclude":
            return EdgeVerdict(False, reason=f"barrier={barrier}")
        if treatment == "penalty":
            flags.add(f"barrier={barrier}")

    if constraints.applies_to_fords:
        for ford in _values(data, "ford"):
            if ford in _FORD_VALUES:
                if not constraints.ford_passable:
                    return EdgeVerdict(False, reason=f"ford={ford}")
                flags.add(f"ford={ford}")

    if constraints.blocks_waterway_obstacles:
        for waterway in _values(data, "waterway"):
            if waterway in _WATERWAY_HARD_OBSTACLES:
                return EdgeVerdict(False, reason=f"waterway={waterway}")

    return EdgeVerdict(True, frozenset(flags))


def _add_contraflow_edges(graph: nx.MultiDiGraph) -> None:
    """FR128's contraflow permission: `oneway:bicycle=no` licenses travel
    against a one-way street's mapped direction. If the base graph already
    carries no reverse edge (a genuinely one-directional way in the source
    data — see module tests), add one so the mode can use it; the copied
    attribute dict means it costs and reports identically to the forward
    edge, which is the honest read of "the same road, ridden the other way."
    """
    additions: list[tuple[int, int, dict]] = []
    for u, v, data in graph.edges(data=True):
        if "no" not in _values(data, "oneway:bicycle"):
            continue
        if graph.has_edge(v, u):
            continue
        additions.append((v, u, dict(data)))
    for v, u, data in additions:
        graph.add_edge(v, u, **data)


def mode_legal_graph(graph: nx.MultiDiGraph, mode: str) -> nx.MultiDiGraph:
    """The graph filtered to what `mode` may legally and physically use.

    Hard exclusions are removed as edges here, at graph-build time, never left
    as a scoring penalty (ARCH §7.9) — an edge Dijkstra can still choose,
    however expensively, is not the same guarantee as an edge that does not
    exist. Surfaced constraints are tagged onto the edge dict
    (`_pl_access_flags`) so a resolved path can report them
    (`flags_along_walk`) rather than silently rolling through.

    Cached per mode on the source graph's own `.graph` dict: `search.py`'s
    band search calls this dozens of times per request, and filtering a
    region-sized graph is not a per-Dijkstra-relaxation-scale operation.
    Returns `graph` itself, unfiltered, for a mode this module has no
    constraints for.
    """
    constraints = MODE_CONSTRAINTS.get(mode)
    if constraints is None:
        return graph

    cache: dict[str, nx.MultiDiGraph] = graph.graph.setdefault("_pl_mode_graph_cache", {})
    cached = cache.get(mode)
    if cached is not None:
        return cached

    filtered = graph.copy()
    doomed: list[tuple[int, int, int]] = []
    for u, v, k, data in filtered.edges(keys=True, data=True):
        verdict = evaluate_edge(data, mode)
        if not verdict.passable:
            doomed.append((u, v, k))
        elif verdict.flags:
            data["_pl_access_flags"] = sorted(verdict.flags)
    for u, v, k in doomed:
        filtered.remove_edge(u, v, k)

    if constraints.honours_contraflow:
        _add_contraflow_edges(filtered)

    cache[mode] = filtered
    return filtered


def flags_along_walk(walk: list[tuple[int, int, dict]]) -> list[dict]:
    """Surfaced constraints hit along a resolved walk, in path order — A11's
    "surfaced explicitly rather than silently routed through," applied to
    whatever shape (`generate_loop`/`generate_out_and_back`/`generate_segment`)
    produced the walk."""
    out = []
    for u, v, data in walk:
        flags = data.get("_pl_access_flags")
        if flags:
            out.append({"from": u, "to": v, "flags": list(flags)})
    return out


# ---------------------------------------------------------------------------
# Climbing access — a station-activity concern (FR130), not a traversal-mode
# one. See module docstring: no anchor/station model exists yet to call this
# from; it is the governing-rule predicate FR128's climbing bullet needs.
# ---------------------------------------------------------------------------

#: `climbing:access=*` values documented as closures in osm_reference.md
#: ("legal/seasonal access restrictions, e.g. raptor-nesting closures").
_CLIMBING_CLOSED_VALUES = frozenset({"no", "private", "closed", "permit"})


def climbing_access_closed(data: dict) -> bool:
    """Whether `climbing:access=*` marks this site closed. Untagged is not
    closed — absence is a fact about the map, never guessed into a value
    (the same rule `scoring.profile.surface_bucket` states for surface)."""
    return any(v in _CLIMBING_CLOSED_VALUES for v in _values(data, "climbing:access"))
