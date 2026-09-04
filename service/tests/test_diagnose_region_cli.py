"""Issue #232 — the standalone `python -m plotlines_service.diagnose_region`
diagnostic: runs the real acquisition path for one bbox, times it, and on
failure prints the full traceback. Exit code reflects the outcome.
"""

from __future__ import annotations

from pathlib import Path

import networkx as nx
import pytest

from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import LoadedGraph
from plotlines_service import diagnose_region


def _fake_loaded(*_a, **_k) -> LoadedGraph:
    g = nx.MultiDiGraph()
    g.add_node(1, y=35.5, x=-82.5)
    g.add_node(2, y=35.6, x=-82.4)
    g.add_edge(1, 2, length=100.0)
    return LoadedGraph(graph=g, source="x", load_seconds=0.0)


def test_ok_path_reports_counts_and_exits_zero(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        lambda *a, **k: tmp_path / "graph.graphml")
    monkeypatch.setattr(diagnose_region, "load_graphml", _fake_loaded)

    rc = diagnose_region.main(
        ["--cache-dir", str(tmp_path), "--bbox", "-82.83", "35.36", "-82.14", "35.79"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "RESULT: OK" in out
    assert "2 nodes, 1 edges" in out


def test_build_failure_prints_traceback_and_exits_one(tmp_path, monkeypatch, capsys):
    def boom(*_a, **_k):
        raise RuntimeError("simplify_graph blew up")

    monkeypatch.setattr(region_lib, "ensure_graph", boom)
    rc = diagnose_region.main(["--cache-dir", str(tmp_path),
                               "--bbox", "-82.83", "35.36", "-82.14", "35.79"])
    out = capsys.readouterr().out
    assert rc == 1
    assert "RESULT: build FAILED" in out
    assert "RuntimeError: simplify_graph blew up" in out
    assert "Traceback (most recent call last)" in out


def test_overpass_unavailable_exits_three(tmp_path, monkeypatch, capsys):
    def unavailable(*_a, **_k):
        raise region_lib.OverpassUnavailable("Couldn't reach the map-data service.")

    monkeypatch.setattr(region_lib, "ensure_graph", unavailable)
    rc = diagnose_region.main(["--cache-dir", str(tmp_path),
                               "--bbox", "-82.83", "35.36", "-82.14", "35.79"])
    out = capsys.readouterr().out
    assert rc == 3
    assert "OverpassUnavailable" in out


def test_bad_bbox_is_rejected(tmp_path):
    with pytest.raises(SystemExit):
        diagnose_region.main(["--cache-dir", str(tmp_path), "--bbox", "1,2,3"])


def test_cli_stamps_the_plotlines_user_agent(tmp_path, monkeypatch, capsys):
    """Issue #241 — `diagnose_region` bypasses `create_app`, so it must set
    the contactable UA itself before `ensure_graph` reaches Overpass."""
    import osmnx as ox

    from plotlines_core.osm_identity import osm_user_agent
    from plotlines_service.version import VERSION

    ox.settings.http_user_agent = "OSMnx Python package (https://github.com/gboeing/osmnx)"
    monkeypatch.setattr(region_lib, "ensure_graph",
                        lambda *a, **k: tmp_path / "graph.graphml")
    monkeypatch.setattr(diagnose_region, "load_graphml", _fake_loaded)

    rc = diagnose_region.main(
        ["--cache-dir", str(tmp_path), "--bbox", "-82.83", "35.36", "-82.14", "35.79"])

    assert rc == 0
    assert ox.settings.http_user_agent == osm_user_agent(VERSION)
    assert ox.settings.http_referer == osm_user_agent(VERSION)
    assert f"user-agent: {osm_user_agent(VERSION)}" in capsys.readouterr().out


def test_cli_points_the_osm_response_cache_inside_the_cache_dir(tmp_path, monkeypatch):
    """Issue #242 — same reasoning as the UA: `diagnose_region` bypasses
    `create_app`, so it configures osmnx's response cache itself rather than
    relying on `ensure_graph`'s internal call, and never writes to `./cache`
    in the CWD."""
    import osmnx as ox

    ox.settings.cache_folder = "./cache"
    monkeypatch.setattr(region_lib, "ensure_graph",
                        lambda *a, **k: tmp_path / "graph.graphml")
    monkeypatch.setattr(diagnose_region, "load_graphml", _fake_loaded)

    rc = diagnose_region.main(
        ["--cache-dir", str(tmp_path), "--bbox", "-82.83", "35.36", "-82.14", "35.79"])

    assert rc == 0
    assert ox.settings.cache_folder == str(tmp_path / "overpass")
