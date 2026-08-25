"""FR9 (Story A6) — naming a conflict and offering relaxations, end to end
through `diagnose.py`'s own control flow rather than a re-implementation of
it.

`test_band_search.py` already exercises `diagnose` end to end against a real
graph for the two easy cases (feasible, and a single unattainable band).
SPIKE-02's own suite proved the harder cases — a genuine two-band
*combination* conflict, the O(n) deletion filter narrowing three bands down
to the two that actually bind, and a via-node implicated as the true cause —
but only as a spike script against real regions (`spikes/SPIKE-02/run.py`,
never promoted into `core/tests`), and only the honest boundary and cost
findings from it are asserted anywhere in CI.

Reproducing those scenarios against a *real* graph is what the spike had to
do (see its own commentary on how fiddly a small synthetic grid is to coax
into a genuine "reachable alone, not together" conflict). This file takes
the other approach: `diagnose()` only ever talks to the graph through
`search_bands`, so monkeypatching that one seam turns every branch of its
control flow — the attainable-alone pre-check, the deletion filter, the
via-node fallback probe — into something a fake, table-driven oracle can
drive directly and deterministically, at unit-test speed. What is *not*
retested here: whether an offered relaxation actually re-solves. That needs
value-sensitive search behaviour a metric-keyed fake cannot honestly
provide, and `test_band_search.py`'s
`test_diagnose_names_an_unattainable_salience_band_and_offers_a_relaxation`
already covers it against the real grid.
"""

from __future__ import annotations

import plotlines_core.routing.diagnose as diagnose_mod
from plotlines_core.routing.diagnose import diagnose
from plotlines_core.routing.search import Attempt, SearchResult
from plotlines_core.scoring.bands import Band, BandSet
from plotlines_core.scoring.metrics import RouteMetrics
from plotlines_core.scoring.profile import WeightProfile

_START = (40.0, -105.0)
_TARGET_M = 20_000.0


def _metrics(**overrides) -> RouteMetrics:
    # `distance_m` defaults to exactly `_TARGET_M` so every fake attempt below
    # satisfies FR8/A8's now-mandatory default distance band (`diagnose`'s own
    # `ensure_distance_band`, applied to every `bands` set this file drives
    # through it) without having to say so at each call site.
    base = dict(distance_m=_TARGET_M, climb_m=100.0, descent_m=100.0, traffic=0.2,
                unpaved_frac=0.0, scenic_frac=0.1, max_grade=0.05, overlap_frac=0.0,
                edge_count=10)
    base.update(overrides)
    return RouteMetrics(**base)


class _FakeLoop:
    """Stands in for `Attempt.loop` — only `Attempt.to_dict()` (via
    `Diagnosis.best_effort`) ever touches it, and only for `.summary()`."""

    def summary(self) -> dict:
        return {}


def _attempt(name: str, **metric_overrides) -> Attempt:
    return Attempt(profile=WeightProfile(name=name), metrics=_metrics(**metric_overrides),
                   penalty=0.0, loop=_FakeLoop())


def _result(feasible: bool, attempts: tuple[Attempt, ...] = (), envelope=None) -> SearchResult:
    return SearchResult(feasible=feasible, best=(attempts[0] if attempts else None),
                        bands=BandSet.of(), solves=1, elapsed_ms=1.0,
                        envelope=envelope or {}, attempts=list(attempts))


def _fake_search_bands(table: dict):
    """`diagnose()`'s only seam onto the graph. Keyed by the metric names in
    the requested band set plus whether a via-node was carried — the two
    things every one of `diagnose()`'s internal calls varies on — never by
    the band's min/max, so this cannot honestly answer "does a relaxed band
    now route" (see the module docstring).

    FR8/A8: `diagnose()` now folds a default `distance_m` band into every
    `bands` set it builds (`ensure_distance_band`), so every real call this
    fake stands in for carries one whether a scenario cares about distance or
    not. `_metrics()`'s `distance_m` defaults to exactly `_TARGET_M`, trivially
    inside that band for every fake attempt below, so its presence never
    changes which outcome a scenario maps to — `distance_m` is stripped from
    the key here rather than threaded through every table below, the same way
    this fake already ignores anything not deliberately varied per scenario.
    """

    def fake(graph, start, target_m, bands, *, via=None, budget=30, keep_attempts=False):
        key = (frozenset(b.metric for b in bands if b.metric != "distance_m"), via is not None)
        return table[key]

    return fake


def test_combination_conflict_names_both_bands_and_offers_working_relaxations(monkeypatch):
    """SPIKE-02's classic case: climbing and low traffic are each reachable
    on their own (one attempt reaches each alone), but no attempt reaches
    both — the honest verdict is "combination," naming both, each with a
    relaxation stating what it costs on the other band."""
    climb = Band("climb_m", minimum=280.0)
    traffic = Band("traffic", maximum=0.14)
    bands = BandSet.of(climb, traffic)

    attempt_flat = _attempt("flat", climb_m=200.0, traffic=0.10)      # meets traffic, not climb
    attempt_climby = _attempt("climby", climb_m=300.0, traffic=0.25)  # meets climb, not traffic
    full = _result(False, attempts=(attempt_flat, attempt_climby),
                   envelope={"climb_m": (100.0, 300.0), "traffic": (0.10, 0.30)})

    monkeypatch.setattr(diagnose_mod, "search_bands", _fake_search_bands({
        (frozenset({"climb_m", "traffic"}), True): full,
        # FR8/A8: `bands` now carries a third (auto-injected) `distance_m`
        # band, so the O(n) deletion filter runs one more probe than a
        # two-band conflict alone would need — dropping either climb or
        # traffic still leaves the other plus distance satisfiable (both
        # attempts default `distance_m` to `_TARGET_M`), so each stays in
        # the conflict; distance itself drops out via the `full` entry above.
        (frozenset({"traffic"}), True): _result(True),
        (frozenset({"climb_m"}), True): _result(True),
    }))

    result = diagnose(object(), _START, _TARGET_M, bands, via=[(40.1, -105.1)])

    assert result.feasible is False
    assert result.kind == "combination"
    assert {b.metric for b in result.conflict} == {"climb_m", "traffic"}
    # the honesty boundary (SPIKE-02 §5): search failure is worded as "not
    # found," never as a claim of proof.
    assert "no route was found" in result.explanation
    assert "impossible" not in result.explanation.lower()

    by_metric = {r.band.metric: r for r in result.relaxations}
    assert set(by_metric) == {"climb_m", "traffic"}
    for relaxation in by_metric.values():
        assert relaxation.trade_off  # A6's AC: every relaxation states its trade-off


def test_unattainable_band_is_never_reported_as_a_combination(monkeypatch):
    """A band nothing here reaches at any weights is a fact about the
    terrain, not a fight between constraints — reporting it as "combination"
    would send an Author to loosen a setting that was never the problem
    (SPIKE-02 §1)."""
    climb = Band("climb_m", minimum=280.0)
    slack_traffic = Band("traffic", maximum=0.90)  # comfortably reachable
    bands = BandSet.of(climb, slack_traffic)

    only_attempt = _attempt("balanced", climb_m=40.0, traffic=0.3)
    full = _result(False, attempts=(only_attempt,), envelope={"climb_m": (10.0, 40.0)})
    solo_climb_infeasible = _result(False, attempts=(only_attempt,))

    monkeypatch.setattr(diagnose_mod, "search_bands", _fake_search_bands({
        (frozenset({"climb_m", "traffic"}), False): full,
        (frozenset({"climb_m"}), False): solo_climb_infeasible,
    }))

    result = diagnose(object(), _START, _TARGET_M, bands)

    assert result.kind == "unattainable"
    assert [b.metric for b in result.conflict] == ["climb_m"]  # the slack band is never blamed


def test_three_band_deletion_filter_drops_the_non_binding_band(monkeypatch):
    """Three bands go in; the deletion filter (O(n) probes, not the 2^n
    subset sweep) must discover that dropping `scenic_frac` alone still
    fails, while dropping either of the other two fixes it — so scenic was
    never part of the conflict, and naming it would send the Author to loosen
    something that binds nothing (SPIKE-02's `three_way` scenario)."""
    climb = Band("climb_m", minimum=260.0)
    traffic = Band("traffic", maximum=0.15)
    scenic = Band("scenic_frac", minimum=0.45)
    bands = BandSet.of(climb, traffic, scenic)

    a_climby = _attempt("climby", climb_m=300.0, traffic=0.25, scenic_frac=0.10)
    a_quiet = _attempt("quiet", climb_m=100.0, traffic=0.05, scenic_frac=0.10)
    a_scenic = _attempt("scenic", climb_m=100.0, traffic=0.05, scenic_frac=0.60)
    full = _result(False, attempts=(a_climby, a_quiet, a_scenic),
                   envelope={"climb_m": (100.0, 300.0), "traffic": (0.05, 0.25),
                             "scenic_frac": (0.10, 0.60)})

    monkeypatch.setattr(diagnose_mod, "search_bands", _fake_search_bands({
        (frozenset({"climb_m", "traffic", "scenic_frac"}), False): full,
        # deletion-filter probes, each dropping one band from the original three:
        (frozenset({"traffic", "scenic_frac"}), False): _result(True),   # infeasible w/o climb? no -> keep climb
        (frozenset({"climb_m", "scenic_frac"}), False): _result(True),   # infeasible w/o traffic? no -> keep traffic
        (frozenset({"climb_m", "traffic"}), False): _result(False),      # infeasible w/o scenic too -> drop scenic
    }))

    result = diagnose(object(), _START, _TARGET_M, bands)

    assert result.kind == "combination"
    assert {b.metric for b in result.conflict} == {"climb_m", "traffic"}
    assert "scenic" not in result.explanation.lower()
    assert {r.band.metric for r in result.relaxations} == {"climb_m", "traffic"}


def test_via_node_implicated_when_dropping_it_makes_the_band_reachable(monkeypatch):
    """A via-node is a constraint too (SPIKE-01 §4, SPIKE-02 §6 item 5): when
    the same band set routes fine without it, blaming the terrain is wrong —
    the useful offer is dropping the via-node, not widening the band."""
    climb = Band("climb_m", minimum=500.0)
    bands = BandSet.of(climb)
    via = [(40.1, -105.1)]

    attempt = _attempt("balanced", climb_m=50.0)
    full = _result(False, attempts=(attempt,), envelope={"climb_m": (10.0, 50.0)})
    without_via_feasible = _result(True)

    monkeypatch.setattr(diagnose_mod, "search_bands", _fake_search_bands({
        (frozenset({"climb_m"}), True): full,                    # with the via-node (full + solo)
        (frozenset({"climb_m"}), False): without_via_feasible,   # the no-via fallback probe
    }))

    result = diagnose(object(), _START, _TARGET_M, bands, via=via)

    assert result.feasible is False
    assert result.kind == "combination"
    assert result.via_implicated is True
    assert result.via_relaxation is not None
    assert result.via_relaxation["action"] == "drop_via_nodes"
    assert result.via_relaxation["verified_routes"] is True


def test_default_distance_band_can_itself_be_named_as_the_unattainable_constraint(monkeypatch):
    """FR8/A8: distance is banded by default even when the Author never set
    one on it — and like any other band, if nothing reachable here lands
    inside it, `diagnose` must name *that* rather than silently let the
    search trade distance away to satisfy everything else, which is exactly
    the failure SPIKE-03 measured (up to +14.8% unannounced drift) and the
    default band exists to catch. Uses a bespoke fake (not
    `_fake_search_bands`, which deliberately strips `distance_m` from its
    key since every other scenario in this file never varies it) because
    this scenario is specifically about `distance_m` varying."""
    climb = Band("climb_m", minimum=50.0)  # trivially attainable — never the culprit
    bands = BandSet.of(climb)  # the Author set no distance_m band at all

    drifted = _attempt("balanced", climb_m=100.0, distance_m=_TARGET_M * 1.30)
    full = _result(False, attempts=(drifted,),
                   envelope={"climb_m": (50.0, 150.0),
                             "distance_m": (_TARGET_M * 1.25, _TARGET_M * 1.35)})

    def fake(graph, start, target_m, requested, *, via=None, budget=30, keep_attempts=False):
        key = frozenset(b.metric for b in requested)
        if key == {"climb_m", "distance_m"}:
            return full
        if key == {"climb_m"}:
            return _result(True, attempts=(drifted,))          # climb alone: attainable
        if key == {"distance_m"}:
            return _result(False, attempts=(drifted,))         # distance alone: unattainable here
        raise AssertionError(f"unexpected band request: {sorted(key)}")

    monkeypatch.setattr(diagnose_mod, "search_bands", fake)

    result = diagnose(object(), _START, _TARGET_M, bands)

    assert result.feasible is False
    assert result.kind == "unattainable"
    assert [b.metric for b in result.conflict] == ["distance_m"]
    assert result.relaxations and result.relaxations[0].band.metric == "distance_m"


def test_diagnose_never_raises_and_always_returns_an_explanation(monkeypatch):
    """A6's AC: never a raw error, never a silent drop. Every branch —
    feasible, unattainable, and combination — must leave `explanation`
    non-empty; a caller (the sidecar's `/segments/diagnose` job) has nothing
    else to show the Author."""
    band = Band("traffic", maximum=0.2)
    bands = BandSet.of(band)
    feasible_attempt = _attempt("balanced", traffic=0.1)

    monkeypatch.setattr(diagnose_mod, "search_bands", _fake_search_bands({
        (frozenset({"traffic"}), False): _result(True, attempts=(feasible_attempt,)),
    }))

    result = diagnose(object(), _START, _TARGET_M, bands)

    assert result.feasible is True
    assert result.kind == "none"
    assert result.explanation
