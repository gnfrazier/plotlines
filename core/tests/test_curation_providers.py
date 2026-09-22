"""Unit tests for `plotlines_core.curation.providers` (ARCH §14.2, D40).

Exercises the pure geometry-conversion helpers, never a live Overpass call —
`OsmLayerProvider.fetch` itself is a thin network wrapper around these, the
same split `graph/loader.py` uses to keep geometry math independently
testable from the disk/network read that feeds it.
"""

import time

import osmium
import osmnx as ox
import pytest
import requests
from osmium.osm import mutable
from shapely.geometry import Point, Polygon

from plotlines_core import osm_identity
from plotlines_core.cache_layout import CacheLayout
from plotlines_core.curation.providers import (
    BBox, CandidateFetchUnavailable, OsmLayerProvider, SharedOsmFetch,
    feature_from_geometry, osm_tags_for,
)

# Issue #275 (Phase 3.3) — local-clip fixtures, same discipline
# `test_graph_regions.py` uses: a bbox distinct from the other tests' so a
# clip seeded here can never be picked up by an unrelated Overpass-path test.
_CLIP_BBOX = (-105.31, 39.99, -105.27, 40.03)
_CLIP_PIN = "2026-09-01"


def _write_clip(cache_dir, *, nodes=(), bbox=_CLIP_BBOX, pin=_CLIP_PIN):
    path = CacheLayout(cache_dir).osm_extract(bbox, pin)
    path.parent.mkdir(parents=True, exist_ok=True)
    with osmium.SimpleWriter(str(path)) as writer:
        for n in nodes:
            writer.add_node(n)
    return path


def _clip_node(id_: int, lon: float, lat: float, tags: dict[str, str] | None = None):
    return mutable.Node(id=id_, location=(lon, lat), tags=tags or {})


def test_osm_tags_for_wildcard_layer_asks_for_the_whole_key():
    tags = osm_tags_for({"historic"})
    assert tags["historic"] is True


def test_osm_tags_for_non_wildcard_layer_asks_for_specific_values():
    tags = osm_tags_for({"natural", "leisure"})
    assert "natural" in tags and "leisure" in tags
    assert "tree" in tags["natural"] or "peak" in tags["natural"] or "spring" in tags["natural"]
    assert tags["natural"] is not True


def test_osm_tags_for_excludes_layers_not_requested():
    tags = osm_tags_for({"natural"})
    assert "historic" not in tags and "amenity" not in tags


def test_osm_tags_for_empty_layer_set_is_empty():
    assert osm_tags_for(set()) == {}


def test_feature_from_geometry_point_has_no_area():
    feature = feature_from_geometry("n1", Point(-105.27, 40.02), {"natural": "peak"})
    assert feature is not None
    assert feature.coord == (-105.27, 40.02)
    assert feature.area_m2 is None


def test_feature_from_geometry_polygon_gets_an_approximate_area():
    # A roughly 200m x 200m square near Boulder, CO (~40N) in degrees.
    d = 0.0018
    poly = Polygon([(-105.27, 40.02), (-105.27 + d, 40.02),
                     (-105.27 + d, 40.02 + d), (-105.27, 40.02 + d)])
    feature = feature_from_geometry("w1", poly, {"leisure": "park", "name": "Test Park"})
    assert feature is not None
    assert feature.area_m2 is not None
    assert feature.area_m2 > 10_000  # order-of-magnitude sanity, not exact


def test_feature_from_geometry_none_is_dropped():
    assert feature_from_geometry("x", None, {}) is None


def test_feature_from_geometry_uses_centroid_for_polygon_coord():
    d = 0.002
    poly = Polygon([(0, 0), (d, 0), (d, d), (0, d)])
    feature = feature_from_geometry("w1", poly, {})
    assert feature is not None
    assert abs(feature.coord[0] - d / 2) < 1e-9
    assert abs(feature.coord[1] - d / 2) < 1e-9


def test_fetch_stamps_the_plotlines_user_agent_before_querying(monkeypatch):
    """Issue #241 / review §3.4: the candidate path must not query Overpass
    as osmnx's stock UA either. `fetch` applies the contactable identity
    before its first `features_from_bbox` call — asserted here because
    `fetch` is otherwise the one thin network wrapper this file skips.
    """
    saved_ua = ox.settings.http_user_agent
    monkeypatch.setattr(ox.settings, "http_user_agent",
                        "OSMnx Python package (https://github.com/gboeing/osmnx)")

    seen: dict[str, str] = {}

    def fake_features_from_bbox(*_args, **_kwargs):
        import geopandas as gpd

        seen["ua"] = ox.settings.http_user_agent
        return gpd.GeoDataFrame({"geometry": []})

    monkeypatch.setattr(ox, "features_from_bbox", fake_features_from_bbox)
    try:
        OsmLayerProvider().fetch(BBox(0.0, 0.0, 0.01, 0.01), {"historic"})
    finally:
        ox.settings.http_user_agent = saved_ua

    assert seen["ua"].startswith("Plotlines/")
    assert "gboeing" not in seen["ua"]


# --------------------------------------------------------------------------- #
# Issue #250 / Phase 0.10 — the candidate path's accepted single-endpoint,
# no-failover Overpass posture still owes an honest error surface.
# --------------------------------------------------------------------------- #

def test_fetch_returns_no_candidates_on_a_true_empty_response(monkeypatch):
    """A `200 OK` with zero elements is a true answer about this bbox/layer —
    no such feature here — not an outage, mirroring #248's
    `NoRoutableWaysError` distinction on the graph path. `fetch` must return
    an empty list, not raise."""
    def fake_features_from_bbox(*_args, **_kwargs):
        raise ox._errors.InsufficientResponseError("Overpass returned no results")

    monkeypatch.setattr(ox, "features_from_bbox", fake_features_from_bbox)

    assert OsmLayerProvider().fetch(BBox(0.0, 0.0, 0.01, 0.01), {"historic"}) == []


def test_fetch_raises_candidate_fetch_unavailable_on_a_transport_failure(monkeypatch):
    """A refused/reset/timed-out connection must not leak a raw
    `requests.exceptions.ConnectionError` repr — the pre-#250 behaviour this
    guards against — but come back as a finished, user-facing sentence."""
    def fake_features_from_bbox(*_args, **_kwargs):
        raise requests.exceptions.ConnectionError("Connection refused")

    monkeypatch.setattr(ox, "features_from_bbox", fake_features_from_bbox)

    with pytest.raises(CandidateFetchUnavailable) as excinfo:
        OsmLayerProvider().fetch(BBox(0.0, 0.0, 0.01, 0.01), {"historic"})
    assert "Connection refused" not in str(excinfo.value)
    assert str(excinfo.value)  # a real sentence, not an empty/blank message


def test_fetch_raises_candidate_fetch_unavailable_on_a_bad_response_status(monkeypatch):
    """`ox._errors.ResponseStatusCodeError` (a mirror answering e.g. `502` with
    an unparseable body) is the failure #232 found escaping the graph path's
    retry/failover loop because it subclasses `ValueError`, not
    `RequestException`. The candidate path must not let it through as a raw
    repr either."""
    def fake_features_from_bbox(*_args, **_kwargs):
        raise ox._errors.ResponseStatusCodeError("502 Bad Gateway")

    monkeypatch.setattr(ox, "features_from_bbox", fake_features_from_bbox)

    with pytest.raises(CandidateFetchUnavailable) as excinfo:
        OsmLayerProvider().fetch(BBox(0.0, 0.0, 0.01, 0.01), {"historic"})
    assert "502 Bad Gateway" not in str(excinfo.value)
    assert str(excinfo.value)


# --------------------------------------------------------------------------- #
# Issue #490 — `OSM_SETTINGS_LOCK` used to be held (by whichever side got
# there first) for the length of a whole Overpass attempt, and the other
# side's `overpass_settings()` call waited for it with no bound of its own.
# A region build holding the lock therefore left a concurrent `/candidates`
# fetch blocked for as long as the build's own attempt took — unbounded if
# osmnx got stuck inside it (#488's DNS-with-no-timeout finding, ARCH A23a's
# unbounded recursive pause).
# --------------------------------------------------------------------------- #


def test_fetch_raises_candidate_fetch_unavailable_when_the_lock_is_held_too_long(
    monkeypatch,
):
    """`fetch` must give up waiting for `OSM_SETTINGS_LOCK` after
    `OVERPASS_LOCK_TIMEOUT_S` rather than block on it indefinitely behind a
    region build (or anything else) that holds it.

    Regression: against the pre-#490 `with OSM_SETTINGS_LOCK:` this test
    would hang forever, since nothing in that call ever released the lock
    within the test's lifetime.
    """
    monkeypatch.setattr(osm_identity, "OVERPASS_LOCK_TIMEOUT_S", 0.2)

    with osm_identity.OSM_SETTINGS_LOCK:  # stands in for a concurrent build
        started = time.monotonic()
        with pytest.raises(CandidateFetchUnavailable) as excinfo:
            OsmLayerProvider().fetch(BBox(0.0, 0.0, 0.01, 0.01), {"historic"})
        elapsed = time.monotonic() - started

    assert elapsed < 2.0, f"fetch waited {elapsed:.2f}s on an already-held lock"
    assert str(excinfo.value)  # a finished sentence, not a raw repr


# --------------------------------------------------------------------------
# Issue #275 (Phase 3.3) — reading candidates from a local mirror clip
# --------------------------------------------------------------------------


def test_fetch_reads_from_a_local_clip_without_touching_overpass(tmp_path):
    def _blocked(*_a, **_k):
        raise AssertionError("fetch must not touch Overpass when a local clip is cached")

    layout = CacheLayout(tmp_path)
    _write_clip(
        tmp_path,
        nodes=[
            _clip_node(1, -105.29, 40.00, {"natural": "peak", "name": "Test Peak"}),
            _clip_node(2, -105.28, 40.01, {"amenity": "drinking_water"}),
        ],
    )

    saved = ox.features_from_bbox
    ox.features_from_bbox = _blocked
    try:
        provider = OsmLayerProvider(cache_layout=layout)
        feats = provider.fetch(BBox(*_CLIP_BBOX), {"natural"})
    finally:
        ox.features_from_bbox = saved

    assert len(feats) == 1
    assert feats[0].tags["natural"] == "peak"
    assert feats[0].tags["name"] == "Test Peak"


def test_fetch_local_clip_empty_result_is_an_empty_list_not_an_error(tmp_path):
    layout = CacheLayout(tmp_path)
    _write_clip(tmp_path, nodes=[_clip_node(1, -105.29, 40.00, {"amenity": "bench"})])

    provider = OsmLayerProvider(cache_layout=layout)
    assert provider.fetch(BBox(*_CLIP_BBOX), {"natural"}) == []


def test_fetch_falls_back_to_overpass_when_no_local_clip_is_cached(tmp_path, monkeypatch):
    """A `cache_layout` with nothing fetched yet for this bbox — the
    pre-#275 Overpass transport still runs, unchanged."""
    import geopandas as gpd

    seen: dict[str, bool] = {}

    def fake_features_from_bbox(*_args, **_kwargs):
        seen["called"] = True
        return gpd.GeoDataFrame({"geometry": []})

    monkeypatch.setattr(ox, "features_from_bbox", fake_features_from_bbox)

    layout = CacheLayout(tmp_path)  # nothing written under layout.extracts_dir
    provider = OsmLayerProvider(cache_layout=layout)
    assert provider.fetch(BBox(*_CLIP_BBOX), {"natural"}) == []
    assert seen.get("called") is True


def test_shared_osm_fetch_default_engine_reads_the_cache_layout_it_was_given(tmp_path):
    """`SharedOsmFetch()`'s default-constructed engine gets the same
    `cache_layout` — this is what lets the registry path (`registry
    .build_default_registry` -> `builtin_osm_providers`) read a mirror clip
    with no extra wiring at the call site."""
    def _blocked(*_a, **_k):
        raise AssertionError("must not touch Overpass when a local clip is cached")

    layout = CacheLayout(tmp_path)
    _write_clip(tmp_path, nodes=[_clip_node(1, -105.29, 40.00, {"natural": "peak"})])

    saved = ox.features_from_bbox
    ox.features_from_bbox = _blocked
    try:
        shared = SharedOsmFetch(cache_layout=layout)
        feats = shared.features_for(BBox(*_CLIP_BBOX), {"natural"})
    finally:
        ox.features_from_bbox = saved

    assert len(feats) == 1
