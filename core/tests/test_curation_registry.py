"""`LayerRegistry` — per-layer readiness and subtract-not-abort extraction.
Stories N2/N5; ARCH §8.3 (B1), D45/D48; SPIKE-D #159, SPIKE-H #160.
"""

from __future__ import annotations

import time

import pytest

from plotlines_core.curation.notability import Candidate, RawFeature, score_with_taxonomy
from plotlines_core.curation.providers import (
    FAILED,
    LOADING,
    READY,
    BBox,
    CandidateFetchUnavailable,
    LayerLicence,
    LayerLoadState,
)
from plotlines_core.curation.registry import LayerRegistry, build_default_registry
from plotlines_core.curation.taxonomy import LAYERS, TypeRule

_BBOX = BBox(-82.10, 35.90, -81.78, 36.12)

_PLUGIN_TAXONOMY = (
    TypeRule(layer="battlefields", key="site_type", value="battlefield",
             base_weight=0.8, role_affinity="narrative"),
)
_GOOD_LICENCE = LayerLicence(id="CC-BY-4.0", attribution="Test County GIS")


class FakePlugin:
    """A §14.2 `LayerProvider` whose readiness and fetch behaviour are
    scripted. `load_states` is consumed one value per `load_state()` call,
    repeating the last; `raise_on_fetch` makes `fetch_candidates` throw."""

    def __init__(self, *, licence: LayerLicence = _GOOD_LICENCE,
                 load_states: list[LayerLoadState] | None = None,
                 features: list[RawFeature] | None = None,
                 raise_on_fetch: Exception | None = None) -> None:
        self._licence = licence
        self._states = list(load_states or [LayerLoadState(READY)])
        self._features = features or [
            RawFeature(id="bf/1", coord=(-81.95, 36.0),
                       tags={"site_type": "battlefield", "name": "Test Ridge"}),
        ]
        self._raise = raise_on_fetch

    @property
    def licence(self) -> LayerLicence:
        return self._licence

    @property
    def taxonomy(self):
        return _PLUGIN_TAXONOMY

    def fetch_candidates(self, bbox: BBox) -> list[Candidate]:
        if self._raise is not None:
            raise self._raise
        return score_with_taxonomy(self._features, self.taxonomy,
                                   live_layers={"battlefields"})

    def load_state(self) -> LayerLoadState:
        state = self._states[0]
        if len(self._states) > 1:
            self._states.pop(0)
        return state


class FakeOsmEngine:
    licence = "ODbL"

    def __init__(self, features: list[RawFeature]) -> None:
        self._features = features

    def fetch(self, bbox, layers) -> list[RawFeature]:
        return list(self._features)


def _osm_engine() -> FakeOsmEngine:
    return FakeOsmEngine([
        RawFeature(id="n/1", coord=(-81.95, 36.0), tags={"historic": "castle", "name": "Keep"}),
        RawFeature(id="n/2", coord=(-81.92, 36.02), tags={"amenity": "drinking_water"}),
    ])


def _registry_with_builtins() -> LayerRegistry:
    from plotlines_core.curation.providers import builtin_osm_providers

    reg = LayerRegistry()
    reg.register_builtins(builtin_osm_providers(_osm_engine()))
    return reg


# --------------------------------------------------------------------------- #
# built-in layers
# --------------------------------------------------------------------------- #

def test_builtins_are_ready_immediately():
    reg = _registry_with_builtins()
    per = reg.per_layer()
    assert set(per) == set(LAYERS)
    assert all(state == "ready" for state in per.values())
    assert reg.capability()["ready"] is True


def test_capability_ready_is_any_not_all():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields",
                        FakePlugin(load_states=[LayerLoadState(state=LOADING)]))
    # one layer loading, six ready -> capability is still ready (`any`)
    assert reg.per_layer()["battlefields"] == "loading"
    assert reg.capability()["ready"] is True


# --------------------------------------------------------------------------- #
# licence gate (D45)
# --------------------------------------------------------------------------- #

def test_plugin_with_unsatisfiable_licence_is_failed_at_registration():
    reg = _registry_with_builtins()
    reg.register_plugin("markers", FakePlugin(licence=LayerLicence()))
    assert reg.per_layer()["markers"] == "failed:licence_unsatisfiable"
    assert "markers" not in reg.ready_layers()


def test_a_failed_licence_layer_is_never_queried():
    reg = _registry_with_builtins()

    class Exploding(FakePlugin):
        def fetch_candidates(self, bbox):  # pragma: no cover
            raise AssertionError("an unlicensed provider must never be queried")

    reg.register_plugin("markers", Exploding(licence=LayerLicence()))
    cands, errors = reg.fetch_candidates_all(_BBOX, {"markers"})
    assert cands == []
    assert errors["markers"].startswith("failed:licence_unsatisfiable")


# --------------------------------------------------------------------------- #
# per-layer load state (D48, N2)
# --------------------------------------------------------------------------- #

def test_load_state_ready_makes_the_layer_usable():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(load_states=[LayerLoadState(READY)]))
    assert reg.per_layer()["battlefields"] == "ready"
    assert "battlefields" in reg.ready_layers()


def test_load_state_failed_names_the_reason():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(
        load_states=[LayerLoadState(state=FAILED, reason="upstream 404")]))
    assert reg.per_layer()["battlefields"] == "failed:upstream 404"


def test_a_loading_layer_settles_to_ready_in_the_background():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(load_states=[
        LayerLoadState(state=LOADING, reason="fetching", progress=0.3),
        LayerLoadState(state=LOADING, reason="fetching", progress=0.7),
        LayerLoadState(READY),
    ]))
    assert reg.per_layer()["battlefields"] == "loading"
    deadline = time.monotonic() + 5.0
    while reg.per_layer()["battlefields"] != "ready":
        if time.monotonic() > deadline:  # pragma: no cover
            raise AssertionError(f"never settled: {reg.per_layer_detail()['battlefields']}")
        time.sleep(0.05)
    assert reg.per_layer()["battlefields"] == "ready"


def test_loading_detail_reports_progress_not_a_fixed_eta():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(load_states=[
        LayerLoadState(state=LOADING, reason="fetching dataset", progress=0.42),
    ] * 50))
    detail = reg.per_layer_detail()["battlefields"]
    assert detail["state"] == "loading"
    assert detail["progress"] == 0.42
    assert "elapsed_s" in detail
    assert "eta_s" not in detail  # FR121 — never a fixed figure


def test_a_broken_load_state_is_a_failed_layer_not_a_crash():
    reg = _registry_with_builtins()

    class BrokenState(FakePlugin):
        def load_state(self):
            raise RuntimeError("boom")

    reg.register_plugin("battlefields", BrokenState())
    assert reg.per_layer()["battlefields"].startswith("failed:RuntimeError")


# --------------------------------------------------------------------------- #
# subtract-not-abort extraction (N2's headline clause)
# --------------------------------------------------------------------------- #

def test_fetch_serves_good_layers_when_one_layer_fails():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(
        raise_on_fetch=TimeoutError("upstream crag API timed out")))

    layers = set(LAYERS) | {"battlefields"}
    cands, errors = reg.fetch_candidates_all(_BBOX, layers)

    assert cands  # built-in candidates still came back
    assert "battlefields" in errors
    assert "TimeoutError" in errors["battlefields"]
    assert set(errors) == {"battlefields"}  # nothing else was harmed


def test_a_layer_that_raises_at_fetch_is_marked_failed_afterwards():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(
        raise_on_fetch=TimeoutError("down")))
    reg.fetch_candidates_all(_BBOX, {"battlefields"})
    assert reg.per_layer()["battlefields"].startswith("failed:TimeoutError")


def test_candidate_fetch_unavailable_surfaces_a_finished_sentence_not_a_repr():
    """Issue #250: the candidate path's accepted single-endpoint Overpass
    posture still owes an honest error surface — a `CandidateFetchUnavailable`
    must read like #248's `OverpassUnavailable` on the routing path, not the
    generic `f"{type(exc).__name__}: {exc}"` raw-repr fallback every other
    provider exception gets."""
    message = "the map-data service didn't answer for this layer — try again."
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin(
        raise_on_fetch=CandidateFetchUnavailable(message)))

    cands, errors = reg.fetch_candidates_all(_BBOX, {"battlefields"})

    assert errors["battlefields"] == f"{FAILED}:{message}"
    assert "CandidateFetchUnavailable" not in errors["battlefields"]
    assert reg.per_layer()["battlefields"] == f"{FAILED}:{message}"


def test_fetch_names_an_unknown_layer_without_aborting():
    reg = _registry_with_builtins()
    cands, errors = reg.fetch_candidates_all(_BBOX, {"historic", "not_a_layer"})
    assert cands
    assert errors == {"not_a_layer": "unknown_layer"}


def test_fetch_reports_a_not_ready_layer_as_its_state():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields",
                        FakePlugin(load_states=[LayerLoadState(state=LOADING)] * 50))
    cands, errors = reg.fetch_candidates_all(_BBOX, {"historic", "battlefields"})
    assert cands
    assert errors == {"battlefields": "loading"}


def test_fetch_candidates_all_ranks_merged_results_by_salience():
    reg = _registry_with_builtins()
    reg.register_plugin("battlefields", FakePlugin())
    cands, _ = reg.fetch_candidates_all(_BBOX, set(LAYERS) | {"battlefields"})
    saliences = [c.salience for c in cands]
    assert saliences == sorted(saliences, reverse=True)


def test_build_default_registry_registers_the_six_builtins_without_network():
    reg = build_default_registry(osm_engine=_osm_engine(), discover_plugins=False)
    assert set(reg.ready_layers()) == set(LAYERS)
