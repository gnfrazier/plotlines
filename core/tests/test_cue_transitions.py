"""FR12 / B3 — a transition reaches the Character's cue sheet with the Author's
instructions attached, and is never thinned away.

`trips/cues.py` had no unit coverage at all (SPIKE-21's harness measured it on
real regions; nothing pinned its behaviour). Scoped here to the transition path
B3 depends on rather than to the whole module: a cue sheet that drops the
put-in instruction is the specific failure this story has to make impossible.

The `Route` is built directly instead of through `route_polyline(graph, walk)` —
these assertions are about node projection and cue text, not about graph
traversal, and a synthetic straight line makes the distances exact.
"""

import math

from plotlines_core.trips.cues import (
    Cue, CueSettings, Route, _merge, hazard_cues, node_cues,
)
from plotlines_core.trips.payload import Node

#: A straight 1 km line east along 40°N, in 100 m steps.
_STEP_DEG = 100.0 / (math.cos(math.radians(40.0)) * math.pi * 6_371_000.0 / 180.0)


def _route() -> Route:
    coords = [[-105.30 + _STEP_DEG * i, 40.0] for i in range(11)]
    return Route(coords=coords, cumulative_m=[100.0 * i for i in range(11)], edges=[])


def _transition(**kwargs) -> Node:
    return Node(kind="transition", coord=[-105.30 + _STEP_DEG * 5, 40.0], **kwargs)


def test_a_transition_node_is_cued_as_a_mode_change():
    cues, stats = node_cues(_route(), [_transition()], CueSettings())

    assert stats["emitted"] == 1
    assert cues[0].kind == "transition"
    assert cues[0].instruction == "Mode change"
    assert cues[0].distance_along_m == 500.0


def test_the_author_instructions_ride_out_on_the_cue():
    """FR12's whole point: the Character is told where to stash the gear."""
    node = _transition(title="Put-in at Lyons",
                       instructions="Stash the bikes behind the outhouse.")

    cues, _ = node_cues(_route(), [node], CueSettings())

    assert cues[0].instruction == (
        "Mode change: Put-in at Lyons — Stash the bikes behind the outhouse."
    )
    assert cues[0].ref_id == node.id


def test_only_the_first_line_of_a_multi_line_instruction_reaches_the_cue():
    """A cue-sheet row is a glance, not a page — the whole note stays on the
    node for any surface with room for it."""
    node = _transition(instructions="Put in below the bridge.\nNot the ramp upstream.")

    cues, _ = node_cues(_route(), [node], CueSettings())

    assert cues[0].instruction == "Mode change — Put in below the bridge."
    assert "Not the ramp" not in cues[0].instruction


def test_a_transition_placed_off_the_route_is_recorded_not_silently_dropped():
    """"A node the Author placed and the sheet does not mention is a support
    question later" — so the count is returned rather than logged."""
    far = Node(kind="transition", coord=[-105.30, 41.0], instructions="Put in here.")

    cues, stats = node_cues(_route(), [far], CueSettings())

    assert cues == []
    assert stats["off_route"] == 1
    assert stats["considered"] == 1


def test_a_transition_cue_survives_the_density_merge_beside_a_turn():
    """`_SAFETY_CRITICAL` — the merge thins derived turns and surface changes,
    never the Author's own transitions. A cue sheet that drops the mode change
    because a junction happened to be nearby is the failure this guards."""
    cues = [
        Cue(sequence=0, distance_along_m=500.0, kind="turn", instruction="Turn left"),
        Cue(sequence=0, distance_along_m=502.0, kind="transition",
            instruction="Mode change — put in below the bridge"),
    ]

    merged, _ = _merge(cues, CueSettings())

    kinds = [c.kind for c in merged]
    assert "transition" in kinds


def test_a_transition_never_outranks_a_hazard():
    """Priority order, unchanged by B3: hazards lead. A transition is important;
    a weir is survival."""
    route = _route()
    cues = [
        Cue(sequence=0, distance_along_m=500.0, kind="transition", instruction="Mode change"),
        *hazard_cues(route, [_Hazard()], CueSettings()),
    ]

    merged, _ = _merge(cues, CueSettings())

    assert merged[0].kind == "hazard"


class _Hazard:
    """The minimal shape `hazard_cues` reads — this module takes duck-typed
    payload objects, not a fixed class."""

    id = "hz1"
    distance_along_m = 500.0
    coord = None
    severity = "high"
    title = "Weir"
    safety_note = "Portage river left."
