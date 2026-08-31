"""Punch list §2A.4 / ARCH risk A18 — `solver_profile_from_author`, the one
function turning a stored Author-facing `trips.payload.WeightProfile` (0.0–5.0,
FR2–FR5) into the solver's internal `scoring.profile.WeightProfile` (0.0–1.0, and
−1..1 for the bipolar dials).

The conversion is specified twice — here and in `client/lib/domain/weight_profile.dart`
(`peaksFromClimbing` / `quietFromTraffic` / `surfaceWeightsFromAuthor` /
`interestFromAuthor`) — and the two must not drift, so the parity block below pins the
exact per-field formulas the Dart doc comments state.
"""

from __future__ import annotations

import pytest

from plotlines_core.scoring.profile import (
    WeightProfile,
    edge_cost,
    solver_profile_from_author,
)
from plotlines_core.trips.payload import WeightProfile as AuthorWeightProfile


# ---------------------------------------------------------------------------
# Unset inputs fall through to solver defaults, never an invented 0.0
# ---------------------------------------------------------------------------


def test_none_maps_to_the_default_solver_profile():
    assert solver_profile_from_author(None) == WeightProfile()


def test_author_profile_with_no_dials_set_is_all_defaults_plus_its_name():
    result = solver_profile_from_author(AuthorWeightProfile(name="untouched"))
    assert result == WeightProfile(name="untouched")
    # The dials with no Author-facing source stay at their solver defaults.
    assert (result.scenic, result.directness) == (0.5, 0.5)
    # And the ones that do have a source, but were left unset, are defaulted too —
    # not forced to a converted 0.0 (which for `quiet` would be 1.0, not the default).
    assert (result.peaks, result.quiet, result.interest) == (0.0, 0.5, 0.0)
    assert (result.surface_paved, result.surface_gravel, result.surface_singletrack) == (
        0.0,
        0.0,
        0.0,
    )


def test_name_is_carried_through():
    assert solver_profile_from_author(AuthorWeightProfile(name="my theme")).name == "my theme"


# ---------------------------------------------------------------------------
# Per-field formulas — the values the Dart doc comments name explicitly
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "climbing, peaks",
    [(0.0, -1.0), (1.25, -0.5), (2.5, 0.0), (3.75, 0.5), (5.0, 1.0)],
)
def test_climbing_maps_to_bipolar_peaks(climbing, peaks):
    result = solver_profile_from_author(AuthorWeightProfile(name="x", climbing=climbing))
    assert result.peaks == pytest.approx(peaks)


@pytest.mark.parametrize(
    "traffic, quiet",
    [(0.0, 1.0), (1.25, 0.75), (2.5, 0.5), (3.75, 0.25), (5.0, 0.0)],
)
def test_traffic_tolerance_inverts_to_quiet_aversion(traffic, quiet):
    # FR3: `traffic` is a tolerance for cars, `quiet` is aversion strength — low
    # tolerance must become *high* aversion, so this is an inversion not a scaling.
    result = solver_profile_from_author(AuthorWeightProfile(name="x", traffic=traffic))
    assert result.quiet == pytest.approx(quiet)


@pytest.mark.parametrize(
    "interest, expected",
    [(0.0, 0.0), (1.0, 0.2), (2.5, 0.5), (5.0, 1.0)],
)
def test_interest_maps_unipolar(interest, expected):
    result = solver_profile_from_author(AuthorWeightProfile(name="x", interest=interest))
    assert result.interest == pytest.approx(expected)


@pytest.mark.parametrize("ui, weight", [(0.0, -1.0), (2.5, 0.0), (5.0, 1.0)])
def test_each_surface_class_maps_bipolar_and_independently(ui, weight):
    result = solver_profile_from_author(
        AuthorWeightProfile(name="x", surface={"gravel": ui})
    )
    assert result.surface_gravel == pytest.approx(weight)
    # Classes not named stay indifferent, not converted.
    assert result.surface_paved == 0.0
    assert result.surface_singletrack == 0.0


def test_all_three_surface_classes_at_once():
    result = solver_profile_from_author(
        AuthorWeightProfile(
            name="x", surface={"paved": 0.0, "gravel": 5.0, "singletrack": 2.5}
        )
    )
    assert (result.surface_paved, result.surface_gravel, result.surface_singletrack) == (
        pytest.approx(-1.0),
        pytest.approx(1.0),
        pytest.approx(0.0),
    )


# ---------------------------------------------------------------------------
# Parity with weight_profile.dart — the exact formulas its doc comments state
# ---------------------------------------------------------------------------

_UI_SWEEP = [0.0, 0.4, 1.0, 2.5, 3.3, 4.0, 5.0]


@pytest.mark.parametrize("ui", _UI_SWEEP)
def test_parity_with_dart_formulas(ui):
    result = solver_profile_from_author(
        AuthorWeightProfile(
            name="x",
            climbing=ui,
            traffic=ui,
            interest=ui,
            surface={"paved": ui, "gravel": ui, "singletrack": ui},
        )
    )
    assert result.peaks == pytest.approx((ui - 2.5) / 2.5)  # peaksFromClimbing
    assert result.quiet == pytest.approx((5.0 - ui) / 5.0)  # quietFromTraffic
    assert result.interest == pytest.approx(ui / 5.0)       # interestFromAuthor
    for got in (result.surface_paved, result.surface_gravel, result.surface_singletrack):
        assert got == pytest.approx((ui - 2.5) / 2.5)       # surfaceWeightsFromAuthor


# ---------------------------------------------------------------------------
# terrain_technicality is an Author declaration, not a solver weight (§7.3)
# ---------------------------------------------------------------------------


def test_terrain_technicality_is_not_mapped():
    with_tt = solver_profile_from_author(
        AuthorWeightProfile(name="x", climbing=4.0, terrain_technicality=5.0)
    )
    without_tt = solver_profile_from_author(
        AuthorWeightProfile(name="x", climbing=4.0)
    )
    assert with_tt == without_tt
    assert not hasattr(with_tt, "terrain_technicality")


# ---------------------------------------------------------------------------
# Bad inputs are rejected with a message that names the Author-facing field
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("field, value", [("climbing", 5.1), ("traffic", -0.1), ("interest", 6.0)])
def test_out_of_range_scalar_is_rejected(field, value):
    with pytest.raises(ValueError, match=field):
        solver_profile_from_author(AuthorWeightProfile(name="x", **{field: value}))


def test_out_of_range_surface_value_names_the_class():
    with pytest.raises(ValueError, match=r"surface\[gravel\]"):
        solver_profile_from_author(AuthorWeightProfile(name="x", surface={"gravel": 9.0}))


def test_unknown_surface_class_is_rejected():
    with pytest.raises(ValueError, match="unknown surface class"):
        solver_profile_from_author(
            AuthorWeightProfile(name="x", surface={"cobblestone": 3.0})
        )


def test_error_message_names_fr4s_legal_classes():
    with pytest.raises(ValueError, match="paved, gravel, singletrack"):
        solver_profile_from_author(AuthorWeightProfile(name="x", surface={"mud": 1.0}))


# ---------------------------------------------------------------------------
# The result is a usable solver profile end to end
# ---------------------------------------------------------------------------


def test_result_passes_weightprofile_post_init_at_the_extremes():
    # Every dial at an extreme of the Author-facing scale — the derived profile must
    # still sit inside `WeightProfile.__post_init__`'s bounds.
    result = solver_profile_from_author(
        AuthorWeightProfile(
            name="extreme",
            climbing=5.0,
            traffic=0.0,
            interest=5.0,
            surface={"paved": 0.0, "gravel": 5.0, "singletrack": 0.0},
        )
    )
    assert isinstance(result, WeightProfile)
    assert result.peaks == pytest.approx(1.0)
    assert result.surface_gravel == pytest.approx(1.0)


def test_result_drives_edge_cost_without_error():
    profile = solver_profile_from_author(
        AuthorWeightProfile(name="x", climbing=4.0, traffic=1.0, surface={"gravel": 4.0})
    )
    edge = {"length": 100.0, "highway": "track", "surface": "gravel", "grade_abs": 0.08}
    cost = edge_cost(edge, profile)
    assert cost > 0.0


def test_a_realistic_authored_profile_maps_field_for_field():
    author = AuthorWeightProfile(
        name="gravel grinder",
        climbing=3.5,
        traffic=1.0,
        surface={"gravel": 4.5, "paved": 1.0},
        interest=2.0,
    )
    result = solver_profile_from_author(author)
    assert result == WeightProfile(
        name="gravel grinder",
        peaks=(3.5 - 2.5) / 2.5,
        quiet=(5.0 - 1.0) / 5.0,
        surface_gravel=(4.5 - 2.5) / 2.5,
        surface_paved=(1.0 - 2.5) / 2.5,
        interest=2.0 / 5.0,
    )
