"""Unit tests for `plotlines_core.graph.regions` (issue #154) — the bbox ->
graph acquisition pipeline promoted from `spikes/shared/regions.py`.

`ensure_graph` makes a live Overpass call when the cache misses; every test
that would miss the cache monkeypatches `ox.graph_from_bbox` with a tiny
synthetic graph instead of touching the network.
"""

from __future__ import annotations

import networkx as nx
import osmnx as ox
import pytest

from plotlines_core.graph import regions

_BBOX = (-105.30, 39.99, -105.25, 40.03)  # SPIKE-00's Boulder fixture bbox


def _fake_graph(*_args, **_kwargs) -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.28)
    g.add_node(2, y=40.01, x=-105.27)
    g.add_edge(1, 2, length=100.0)
    g.add_edge(2, 1, length=100.0)
    g.graph["crs"] = "epsg:4326"
    return g


def test_region_key_is_stable_for_the_same_bbox():
    a = regions.region_key(_BBOX, "bike")
    b = regions.region_key(_BBOX, "bike")
    assert a == b


def test_region_key_differs_for_a_different_bbox():
    other = (-82.83, 35.36, -82.14, 35.79)  # Buncombe County
    assert regions.region_key(_BBOX, "bike") != regions.region_key(other, "bike")


def test_region_key_differs_for_a_different_network_type():
    assert regions.region_key(_BBOX, "bike") != regions.region_key(_BBOX, "walk")


def test_region_key_differs_across_ruleset_versions():
    assert (regions.region_key(_BBOX, "bike", ruleset_version=1)
            != regions.region_key(_BBOX, "bike", ruleset_version=2))


def test_region_key_ignores_float_noise_below_a_centimetre():
    west, south, east, north = _BBOX
    noisy = (west + 1e-9, south, east, north)
    assert regions.region_key(_BBOX, "bike") == regions.region_key(noisy, "bike")


def test_region_for_derives_the_matching_key():
    region = regions.region_for(_BBOX, "bike")
    assert region.key == regions.region_key(_BBOX, "bike")
    assert region.bbox == _BBOX


def test_region_centre_is_the_bbox_midpoint():
    region = regions.region_for((-1.0, -1.0, 1.0, 1.0))
    assert region.centre == (0.0, 0.0)


def test_ensure_graph_builds_and_caches(tmp_path, monkeypatch):
    monkeypatch.setattr(ox, "graph_from_bbox", _fake_graph)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "bike")
    path = regions.ensure_graph(region, tmp_path)

    assert path == region.graph_path(tmp_path)
    assert path.exists()
    reloaded = ox.io.load_graphml(path)
    assert reloaded.number_of_nodes() == 2


def test_ensure_graph_reuses_the_cache_without_hitting_the_network(tmp_path, monkeypatch):
    calls = {"n": 0}

    def counting_fake_graph(*args, **kwargs):
        calls["n"] += 1
        return _fake_graph(*args, **kwargs)

    monkeypatch.setattr(ox, "graph_from_bbox", counting_fake_graph)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "bike")
    regions.ensure_graph(region, tmp_path)
    regions.ensure_graph(region, tmp_path)

    assert calls["n"] == 1


def test_ensure_graph_force_rebuilds(tmp_path, monkeypatch):
    calls = {"n": 0}

    def counting_fake_graph(*args, **kwargs):
        calls["n"] += 1
        return _fake_graph(*args, **kwargs)

    monkeypatch.setattr(ox, "graph_from_bbox", counting_fake_graph)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "bike")
    regions.ensure_graph(region, tmp_path)
    regions.ensure_graph(region, tmp_path, force=True)

    assert calls["n"] == 2


def test_useful_tags_way_carries_the_surface_extension():
    # FR4's surface weight is inert without this (module import time side
    # effect — spikes/shared/regions.py:47-56's finding).
    for tag in ("surface", "tracktype", "smoothness", "maxspeed", "lanes", "bicycle"):
        assert tag in ox.settings.useful_tags_way


def test_configure_overpass_cache_points_at_the_given_dir(tmp_path):
    regions.configure_overpass_cache(tmp_path)
    assert ox.settings.cache_folder == str(tmp_path / "overpass")
