"""Issue #574 — a loop or out-and-back whose target distance reaches past the
trip area failed with `OutsideGraphExtent`, which the client showed as "This
area doesn't have routable data" (Pi QA of #522: Greensboro, first Generate).

The synthesised shaping points — the loop's anchor ring, the out-and-back's
searched turnaround — are artefacts of hitting a target distance, not places
the Author named. Under a profile with no climbing bias they snapped through
`nearest_node`'s 3 km wrong-region guard; under one with a bias they did not.
They now always snap to the nearest node in the graph, so the solve returns
its closest achievable shape (FR8's envelope). Points the Author placed keep
the guard.
"""

from __future__ import annotations

import pytest

from plotlines_core.graph.loader import OutsideGraphExtent
from plotlines_core.routing.loops import generate_loop, generate_out_and_back
from plotlines_core.scoring.profile import WeightProfile

from test_via_anchor_loop import _CENTER, _grid_graph

_FLAT = WeightProfile("balanced")  # peaks == 0: the guarded path

#: The lattice is 1.2 km across; a 60 km target puts the shaping ring ~9 km
#: out, far past the 3 km guard.
_FAR_TARGET_M = 60_000.0


def test_a_loop_whose_shaping_ring_leaves_the_graph_still_solves():
    loop = generate_loop(_grid_graph(), _CENTER, _FAR_TARGET_M, _FLAT)
    assert loop.closed is True
    assert loop.metrics.distance_m > 0
    # Best effort, honestly short of the target — not a pretend compliance.
    assert loop.metrics.distance_m < _FAR_TARGET_M


def test_an_out_and_back_whose_turnaround_leaves_the_graph_still_solves():
    loop = generate_out_and_back(_grid_graph(), _CENTER, _FLAT, target_m=_FAR_TARGET_M)
    assert loop.metrics.distance_m > 0


def test_a_start_the_author_placed_outside_the_graph_still_raises():
    far = (_CENTER[0] + 0.5, _CENTER[1])  # ~55 km north
    with pytest.raises(OutsideGraphExtent):
        generate_loop(_grid_graph(), far, 2400.0, _FLAT)
