"""The on-disk candidate cache — issue #243, Phase 0.3 of the OSM
acquisition plan (review §5.3), ARCH A23's first mitigation, FR94.

`SharedOsmFetch` gained an L2 tier: the raw OSM extract for a bbox is
persisted to `CacheLayout.candidate_set(bbox)` and re-read on a hit, so a
second `/candidates` call in a *fresh process* (the M12 watchdog restarts
the sidecar precisely when a heavy build saturates it) does no Overpass
request. The file carries the `(layer_set_version, ruleset_version)` half of
ARCH §4.2's cache key in its contents; a mismatch on either is a miss.
"""

from __future__ import annotations

import json

import pytest

from plotlines_core.cache_layout import CacheLayout, trip_bbox_key
from plotlines_core.curation import providers as providers_mod
from plotlines_core.curation.notability import RawFeature
from plotlines_core.curation.providers import (
    LAYER_SET_VERSION,
    BBox,
    SharedOsmFetch,
    builtin_osm_providers,
)
from plotlines_core.curation.taxonomy import LAYERS

_BBOX = BBox(-82.10, 35.90, -81.78, 36.12)
_KEY = (_BBOX.west, _BBOX.south, _BBOX.east, _BBOX.north)


class _CountingEngine:
    """Records every `fetch` so a disk hit (zero calls) is assertable."""

    licence = "ODbL"

    def __init__(self, features: list[RawFeature]) -> None:
        self._features = features
        self.calls: list[frozenset[str]] = []

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        self.calls.append(frozenset(layers))
        return list(self._features)


def _features() -> list[RawFeature]:
    return [
        RawFeature(id="n/1", coord=(-81.95, 36.00),
                   tags={"historic": "castle", "name": "Keep"}),
        RawFeature(id="n/2", coord=(-81.92, 36.02),
                   tags={"natural": "peak", "name": "Knob"}),
        RawFeature(id="w/3", coord=(-81.90, 36.01),
                   tags={"leisure": "park", "name": "Common"},
                   area_m2=48000.0,
                   geometry=((-81.91, 36.00), (-81.89, 36.00),
                             (-81.89, 36.02), (-81.91, 36.00))),
    ]


def test_extract_is_persisted_under_the_cachelayout_root_and_nowhere_else(tmp_path):
    layout = CacheLayout(tmp_path)
    SharedOsmFetch(_CountingEngine(_features()), cache_layout=layout).features_for(
        _BBOX, set(LAYERS))

    entry = layout.candidate_set(_KEY)
    assert entry.exists()
    assert entry == tmp_path / "candidates" / f"{trip_bbox_key(_KEY)}.json"
    # nothing written outside the candidates sub-dir
    assert [p.name for p in tmp_path.iterdir()] == ["candidates"]
    assert [p.name for p in (tmp_path / "candidates").iterdir()] == [entry.name]


def test_a_fresh_sharedfetch_reads_the_disk_cache_without_an_overpass_call(tmp_path):
    layout = CacheLayout(tmp_path)
    first = _CountingEngine(_features())
    SharedOsmFetch(first, cache_layout=layout).features_for(_BBOX, set(LAYERS))
    assert len(first.calls) == 1

    # A new instance == a new process: empty L1 dict, new engine that would
    # raise if it were consulted.
    second = _CountingEngine([])
    got = SharedOsmFetch(second, cache_layout=layout).features_for(_BBOX, set(LAYERS))

    assert second.calls == []
    assert [f.id for f in got] == ["n/1", "n/2", "w/3"]


def test_disk_round_trip_preserves_area_and_geometry(tmp_path):
    layout = CacheLayout(tmp_path)
    SharedOsmFetch(_CountingEngine(_features()), cache_layout=layout).features_for(
        _BBOX, set(LAYERS))

    got = SharedOsmFetch(_CountingEngine([]), cache_layout=layout).features_for(
        _BBOX, set(LAYERS))
    park = next(f for f in got if f.id == "w/3")

    assert park.area_m2 == 48000.0
    assert park.geometry == ((-81.91, 36.00), (-81.89, 36.00),
                             (-81.89, 36.02), (-81.91, 36.00))
    assert all(isinstance(c, tuple) for f in got for c in [f.coord])


def test_a_ruleset_version_change_invalidates_the_entry(tmp_path, monkeypatch):
    layout = CacheLayout(tmp_path)
    SharedOsmFetch(_CountingEngine(_features()), cache_layout=layout).features_for(
        _BBOX, set(LAYERS))

    # An Author bumps RULESET_VERSION (a filter change → every salience score
    # moves). The stale file must not be served.
    monkeypatch.setattr(providers_mod, "RULESET_VERSION", "99.0.0")
    rebuilt = _CountingEngine(_features())
    SharedOsmFetch(rebuilt, cache_layout=layout).features_for(_BBOX, set(LAYERS))

    assert len(rebuilt.calls) == 1


def test_a_layer_set_version_change_invalidates_the_entry(tmp_path, monkeypatch):
    layout = CacheLayout(tmp_path)
    SharedOsmFetch(_CountingEngine(_features()), cache_layout=layout).features_for(
        _BBOX, set(LAYERS))

    monkeypatch.setattr(providers_mod, "LAYER_SET_VERSION", "deadbeefcafe")
    rebuilt = _CountingEngine(_features())
    SharedOsmFetch(rebuilt, cache_layout=layout).features_for(_BBOX, set(LAYERS))

    assert len(rebuilt.calls) == 1


def test_the_persisted_file_records_both_versions(tmp_path):
    layout = CacheLayout(tmp_path)
    SharedOsmFetch(_CountingEngine(_features()), cache_layout=layout).features_for(
        _BBOX, set(LAYERS))

    doc = json.loads(layout.candidate_set(_KEY).read_text())
    assert doc["layer_set_version"] == LAYER_SET_VERSION
    assert doc["ruleset_version"] == "1.2.0"
    assert doc["bbox"] == list(_KEY)
    assert {f["id"] for f in doc["features"]} == {"n/1", "n/2", "w/3"}


def test_a_corrupt_file_is_ignored_and_rebuilt(tmp_path):
    layout = CacheLayout(tmp_path)
    entry = layout.candidate_set(_KEY)
    entry.parent.mkdir(parents=True, exist_ok=True)
    entry.write_text("{not json")

    engine = _CountingEngine(_features())
    got = SharedOsmFetch(engine, cache_layout=layout).features_for(_BBOX, set(LAYERS))

    assert len(engine.calls) == 1
    assert [f.id for f in got] == ["n/1", "n/2", "w/3"]
    # the rebuild overwrote the corrupt file with a valid one
    assert json.loads(entry.read_text())["ruleset_version"] == "1.2.0"


def test_without_a_cache_layout_the_behaviour_is_l1_only(tmp_path):
    """Regression guard: the no-`cache_layout` path is exactly the pre-#243
    in-process-only one — a new instance re-queries, and nothing touches
    disk."""
    a = _CountingEngine(_features())
    SharedOsmFetch(a).features_for(_BBOX, set(LAYERS))
    b = _CountingEngine(_features())
    SharedOsmFetch(b).features_for(_BBOX, set(LAYERS))

    assert len(a.calls) == 1 and len(b.calls) == 1
    assert not any(tmp_path.iterdir())


def test_l1_dict_still_fronts_the_disk_read(tmp_path):
    layout = CacheLayout(tmp_path)
    engine = _CountingEngine(_features())
    shared = SharedOsmFetch(engine, cache_layout=layout)

    shared.features_for(_BBOX, set(LAYERS))
    entry = layout.candidate_set(_KEY)
    entry.unlink()  # remove the disk tier; L1 must still answer

    again = shared.features_for(_BBOX, set(LAYERS))
    assert [f.id for f in again] == ["n/1", "n/2", "w/3"]
    assert len(engine.calls) == 1
    assert not entry.exists()  # served from L1, no rewrite


def test_builtin_osm_providers_threads_the_cache_layout(tmp_path):
    layout = CacheLayout(tmp_path)
    engine = _CountingEngine(_features())
    providers = builtin_osm_providers(engine, cache_layout=layout)
    for provider in providers.values():
        provider.fetch_candidates(_BBOX)
    assert len(engine.calls) == 1  # six siblings, one fetch

    # a fresh set of providers over the same layout: disk hit, no fetch
    engine2 = _CountingEngine([])
    providers2 = builtin_osm_providers(engine2, cache_layout=layout)
    for provider in providers2.values():
        provider.fetch_candidates(_BBOX)
    assert engine2.calls == []
