"""Issue #202 — wire `solver_profile_from_author` into the compose path.

#200 / PR #201 added the Author-facing → solver `WeightProfile` conversion but
stopped at the primitive: no caller used it, so a saved trip's Author-set weights
never reached the solver. This covers the two halves of the fix:

  * `trips.compose.resolve_author_weights` / `solver_profile_for_day` — the
    most-specific-wins precedence (`Segment.weights` → `Day.weights` →
    `Trip.default_weights`) and the single Author→solver conversion site;
  * `trips.spine.spine_solver_profile` — the compose-mode companion to
    `spine_waypoints` that carries that solver profile into `generate_segment`,
    keeping distance an output (FR118) and `interest` inactive (§7.7);

plus a compose-path integration solve over a small synthetic graph proving a
non-default Author profile actually changes the route (`_weighted_path` is the
same primitive `routing.solve.generate_segment` calls).
"""

from __future__ import annotations

import networkx as nx
import pytest

from plotlines_core.routing.solve import _weighted_path
from plotlines_core.scoring.profile import WeightProfile as SolverWeightProfile
from plotlines_core.trips.compose import (
    resolve_author_weights,
    solver_profile_for_day,
)
from plotlines_core.trips.payload import WeightProfile as AuthorWeightProfile
from plotlines_core.trips.spine import spine_solver_profile


def _author(name: str, **dials) -> AuthorWeightProfile:
    return AuthorWeightProfile(name=name, **dials)


# ---------------------------------------------------------------------------
# resolve_author_weights — most-specific-wins precedence (AC clause 2)
# ---------------------------------------------------------------------------


def test_segment_weights_win_over_day_and_trip():
    seg, day, trip = _author("seg"), _author("day"), _author("trip")
    assert resolve_author_weights(segment=seg, day=day, trip_default=trip) is seg


def test_day_weights_win_when_segment_is_unset():
    day, trip = _author("day"), _author("trip")
    assert resolve_author_weights(segment=None, day=day, trip_default=trip) is day


def test_trip_default_used_when_segment_and_day_are_unset():
    trip = _author("trip")
    assert resolve_author_weights(trip_default=trip) is trip


def test_all_unset_resolves_to_none():
    assert resolve_author_weights() is None


def test_an_unset_level_falls_through_it_does_not_block_a_less_specific_one():
    # Segment unset, Day unset, Trip set — the fall-through reaches the trip
    # default rather than stopping at the first `None`.
    trip = _author("trip only")
    assert resolve_author_weights(segment=None, day=None, trip_default=trip) is trip


# ---------------------------------------------------------------------------
# solver_profile_for_day — resolve + convert in one step (single conversion site)
# ---------------------------------------------------------------------------


def test_none_all_the_way_through_is_the_balanced_solver_default():
    assert solver_profile_for_day() == SolverWeightProfile()


def test_the_resolved_profile_is_run_through_the_author_to_solver_conversion():
    # traffic is Author-facing 0.0-5.0; the solver reads `quiet` as (5.0 - ui) / 5.0.
    result = solver_profile_for_day(trip_default=_author("calm", traffic=1.0))
    assert isinstance(result, SolverWeightProfile)
    assert result.quiet == pytest.approx((5.0 - 1.0) / 5.0)
    assert result.name == "calm"


def test_the_most_specific_profile_is_the_one_converted():
    seg = _author("gravel seg", surface={"gravel": 5.0})
    trip = _author("paved trip", surface={"paved": 5.0})
    result = solver_profile_for_day(segment=seg, day=None, trip_default=trip)
    assert result.surface_gravel == pytest.approx(1.0)   # from the segment
    assert result.surface_paved == pytest.approx(0.0)    # trip default not consulted


# ---------------------------------------------------------------------------
# spine_solver_profile — the compose companion to spine_waypoints
# ---------------------------------------------------------------------------


def test_spine_solver_profile_delegates_to_the_same_precedence_and_conversion():
    day = _author("hilly", climbing=5.0)
    trip = _author("flat", climbing=0.0)
    assert spine_solver_profile(day_weights=day, trip_default_weights=trip) == (
        solver_profile_for_day(day=day, trip_default=trip)
    )


def test_spine_solver_profile_defaults_to_balanced_when_nothing_is_stored():
    assert spine_solver_profile() == SolverWeightProfile()


def test_spine_solver_profile_forces_interest_inactive_in_compose():
    # §7.7 — the salience bias is an explore-mode dial; in compose the anchors are
    # the editorial decision, so a stored `interest` must not reach the solve.
    stored = _author("keen", interest=5.0, climbing=4.0)
    result = spine_solver_profile(trip_default_weights=stored)
    assert result.interest == 0.0
    # the rest of the profile still converts normally
    assert result.peaks == pytest.approx((4.0 - 2.5) / 2.5)


def test_spine_solver_profile_leaves_a_zero_interest_profile_untouched():
    stored = _author("plain", climbing=4.0)
    assert spine_solver_profile(trip_default_weights=stored) == (
        solver_profile_for_day(trip_default=stored)
    )


# ---------------------------------------------------------------------------
# Compose-path integration — a non-default Author profile changes the route
# (AC clause 1). Two parallel A -> B ways: a shorter paved one and a longer
# gravel one. Balanced weights take the paved way on length; a gravel-seeking
# Author profile re-routes the composed passage onto the gravel way.
#
#   A --(paved, 500m)--> P --(paved, 500m)--> B     total 1000m
#   A --(gravel, 600m)-> G --(gravel, 600m)-> B     total 1200m
# ---------------------------------------------------------------------------

_A, _B, _PAVED_MID, _GRAVEL_MID = 1, 2, 3, 4


def _two_surface_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, x=-105.30, y=40.00)
    g.add_node(_B, x=-105.20, y=40.00)
    g.add_node(_PAVED_MID, x=-105.25, y=40.01)
    g.add_node(_GRAVEL_MID, x=-105.25, y=39.99)
    for u, v in ((_A, _PAVED_MID), (_PAVED_MID, _B)):
        g.add_edge(u, v, length=500.0, highway="unclassified", surface="asphalt")
    for u, v in ((_A, _GRAVEL_MID), (_GRAVEL_MID, _B)):
        g.add_edge(u, v, length=600.0, highway="track", surface="gravel")
    return g


def _composed_mid_node(profile: SolverWeightProfile) -> int:
    """The interior node the compose solve routes through, A -> B."""
    path = _weighted_path(_two_surface_graph(), _A, _B, profile)
    assert path[0] == _A and path[-1] == _B      # origin/destination honoured
    return path[1]


def test_default_compose_profile_takes_the_shorter_paved_way():
    assert _composed_mid_node(solver_profile_for_day()) == _PAVED_MID


def test_author_gravel_preference_reroutes_the_composed_passage_onto_gravel():
    author = _author("gravel day", surface={"gravel": 5.0})
    assert _composed_mid_node(solver_profile_for_day(trip_default=author)) == _GRAVEL_MID


def test_segment_weights_override_the_trip_default_in_the_solved_route():
    # Trip default seeks gravel; this segment seeks pavement — the segment wins,
    # and the solved route follows it back onto the paved way.
    gravel_trip = _author("gravel", surface={"gravel": 5.0})
    paved_seg = _author("paved", surface={"paved": 5.0, "gravel": 0.0})
    mid = _composed_mid_node(
        solver_profile_for_day(segment=paved_seg, trip_default=gravel_trip)
    )
    assert mid == _PAVED_MID


def test_compose_wiring_produces_only_a_weight_profile_no_band_or_target():
    # FR118 / §7.7 — the wiring changes only the weight handed to the solver;
    # nothing here introduces a target_distance, a band, or a conflict path.
    author = _author("gravel day", surface={"gravel": 5.0})
    profile = spine_solver_profile(trip_default_weights=author)
    assert isinstance(profile, SolverWeightProfile)
    assert not hasattr(profile, "target_distance")
    assert not hasattr(profile, "bands")
