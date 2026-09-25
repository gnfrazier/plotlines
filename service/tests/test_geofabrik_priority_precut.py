"""`geofabrik_pull.py --precut-priority-regions` — issue #530, the OSM
counterpart to #453's basemap prewarm.

The grid (`priority_cells`) is pure bbox arithmetic and is tested without
pyosmium. The per-cell precut (`precut_cells`) runs the real
`mirror_clip.clip_bbox` against tiny synthetic `.osm.pbf` fixtures
(`mirror_clip_fixtures.py`), never a real Geofabrik download, the same
posture as `test_geofabrik_precut.py`.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import osmium
import pytest

from mirror_clip_fixtures import build_mirror_tree, node, way, write_pbf

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT_PATH = _REPO / "deploy" / "mirror" / "geofabrik_pull.py"


def _load_geofabrik_pull():
    spec = importlib.util.spec_from_file_location("geofabrik_pull", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["geofabrik_pull"] = module
    spec.loader.exec_module(module)
    return module


gp = _load_geofabrik_pull()


def _boxes_overlap(a, b) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


# --------------------------------------------------------------------------
# The source table stays pinned to the areas it serves
# --------------------------------------------------------------------------


def test_every_priority_area_has_geofabrik_sources_listed() -> None:
    sys.path.insert(0, str(_REPO / "deploy" / "elevation"))
    from priority_regions import build_priority_candidates

    keys = {c.region_key for c in build_priority_candidates()}
    assert keys <= set(gp.PRIORITY_REGION_SOURCES)


def test_the_wnc_corridor_bbox_matches_plotlines_core() -> None:
    from plotlines_core.tiles.mirror import WNC_CORRIDOR_BBOX, WNC_CORRIDOR_REGION_NAME

    assert gp.WNC_CORRIDOR_BBOX == WNC_CORRIDOR_BBOX
    assert gp.WNC_CORRIDOR_KEY == WNC_CORRIDOR_REGION_NAME


def test_every_listed_source_is_a_valid_leaf_region_path() -> None:
    for sources in gp.PRIORITY_REGION_SOURCES.values():
        for region in sources:
            assert gp._validate_region(region) == region
            # Leaf regions only: never the California parent file when its
            # norcal/socal halves are listed.
            assert region != "north-america/us/california"


# --------------------------------------------------------------------------
# priority_cells — the grid
# --------------------------------------------------------------------------

_SOURCES = {"a": ("region/a",), "b": ("region/b",), "c": ("region/c",)}


def test_an_area_inside_one_square_is_one_cell_clamped_to_the_area() -> None:
    cells = gp.priority_cells([("a", (-82.5, 35.2, -82.1, 35.7))], sources=_SOURCES)

    assert cells == [gp.PrecutCell("priority-w084-n34", (-82.5, 35.2, -82.1, 35.7),
                                   ("region/a",))]


def test_an_area_crossing_grid_lines_is_split_into_non_overlapping_cells() -> None:
    cells = gp.priority_cells([("a", (-83.0, 35.0, -81.0, 37.0))], sources=_SOURCES)

    assert [c.name for c in cells] == [
        "priority-w084-n34", "priority-w084-n36", "priority-w082-n34", "priority-w082-n36",
    ]
    assert [c.bbox for c in cells] == [
        (-83.0, 35.0, -82.0, 36.0), (-83.0, 36.0, -82.0, 37.0),
        (-82.0, 35.0, -81.0, 36.0), (-82.0, 36.0, -81.0, 37.0),
    ]


def test_overlapping_areas_share_one_cell_with_both_areas_sources() -> None:
    cells = gp.priority_cells(
        [("a", (-83.0, 35.0, -82.5, 35.5)), ("b", (-82.8, 35.3, -82.2, 35.9))],
        sources=_SOURCES,
    )

    assert len(cells) == 1
    assert cells[0].bbox == (-83.0, 35.0, -82.2, 35.9)
    assert cells[0].source_regions == ("region/a", "region/b")


def test_an_area_that_only_touches_a_grid_line_adds_no_cell_beyond_it() -> None:
    cells = gp.priority_cells([("a", (-84.0, 34.0, -82.0, 36.0))], sources=_SOURCES)

    assert [c.name for c in cells] == ["priority-w084-n34"]


def test_the_real_priority_grid_never_overlaps_and_covers_every_area() -> None:
    sys.path.insert(0, str(_REPO / "deploy" / "elevation"))
    from priority_regions import build_priority_candidates

    areas = [(gp.WNC_CORRIDOR_KEY, gp.WNC_CORRIDOR_BBOX)]
    areas += [(c.region_key, c.bbox) for c in build_priority_candidates()]
    cells = gp.priority_cells(areas)

    for i, a in enumerate(cells):
        for b in cells[i + 1:]:
            assert not _boxes_overlap(a.bbox, b.bbox), (a.name, b.name)
    # Every corner-ish interior point of every area lands in some cell.
    for _key, (w, s, e, n) in areas:
        for x in (w + 1e-6, (w + e) / 2, e - 1e-6):
            for y in (s + 1e-6, (s + n) / 2, n - 1e-6):
                assert any(c.bbox[0] <= x <= c.bbox[2] and c.bbox[1] <= y <= c.bbox[3]
                           for c in cells), (x, y)
    # Every name is unique and a valid region path, so it can be pinned.
    assert len({c.name for c in cells}) == len(cells)
    for cell in cells:
        gp._validate_region(cell.name)


def test_an_area_without_listed_sources_is_refused() -> None:
    with pytest.raises(ValueError, match="PRIORITY_REGION_SOURCES"):
        gp.priority_cells([("nowhere", (0.0, 0.0, 1.0, 1.0))], sources=_SOURCES)


# --------------------------------------------------------------------------
# precut_cells — the per-cell clip
# --------------------------------------------------------------------------

_PIN = "2026-09-01"


def _mirror(tmp_path: Path) -> Path:
    """Two pulled sources meeting at -82.35, a border way in both, plus an
    already-pinned `wnc-corridor` and an unrelated region the cells must
    neither draw from nor unregister."""
    west = write_pbf(
        tmp_path / "west.osm.pbf",
        nodes=[node(1, -82.5, 35.2), node(2, -82.35, 35.25)],
        ways=[way(10, [1, 2], tags={"highway": "path"})],
        box=(-83.0, 35.0, -82.35, 35.5),
    )
    east = write_pbf(
        tmp_path / "east.osm.pbf",
        nodes=[node(1, -82.5, 35.2), node(2, -82.35, 35.25),
               node(3, -82.2, 35.3, {"amenity": "drinking_water"})],
        ways=[way(10, [1, 2], tags={"highway": "path"})],
        box=(-82.35, 35.0, -81.9, 35.5),
    )
    corridor = write_pbf(tmp_path / "corridor.osm.pbf",
                         nodes=[node(99, -82.4, 35.3)], box=(-83.0, 35.0, -81.9, 35.5))
    other = write_pbf(tmp_path / "other.osm.pbf",
                      nodes=[node(50, -82.3, 35.2)], box=(-83.0, 35.0, -81.9, 35.5))
    return build_mirror_tree(tmp_path / "mirror", pinned_date=_PIN, regions={
        "west-region": west, "east-region": east,
        "wnc-corridor": corridor, "other-region": other,
    })


def _node_ids(path: Path) -> set[int]:
    seen: set[int] = set()
    osmium.apply(str(path), type("_C", (osmium.SimpleHandler,), {
        "node": lambda self, n: seen.add(n.id)
    })())
    return seen


def _header_box(path: Path):
    reader = osmium.io.Reader(str(path))
    try:
        box = reader.header().box()
    finally:
        reader.close()
    return (round(box.bottom_left.lon, 5), round(box.bottom_left.lat, 5),
            round(box.top_right.lon, 5), round(box.top_right.lat, 5))


_CELL = gp.PrecutCell("priority-w084-n34", (-83.0, 35.0, -81.9, 35.5),
                      ("east-region", "west-region"))
_EMPTY_CELL = gp.PrecutCell("priority-w082-n36", (-81.9, 36.0, -81.0, 36.4),
                            ("east-region",))


def test_precut_cells_pins_each_cell_from_only_its_own_sources(tmp_path: Path) -> None:
    mirror = _mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")

    results = gp.precut_cells(root=mirror, pinned_date=_PIN, state=state, cells=[_CELL],
                              supersedes=("wnc-corridor",))

    assert [(r.region, r.action) for r in results] == [("priority-w084-n34", "precut")]
    dest = mirror / "osm" / "geofabrik" / _PIN / "priority-w084-n34.osm.pbf"
    # The west/east data, merged across the border way, and nothing from
    # the corridor (99) or the unrelated region (50) that overlap it on the
    # live mirror.
    assert _node_ids(dest) == {1, 2, 3}
    # The cell's own box is its header, so /clip excludes it cheaply for a
    # trip bbox elsewhere.
    assert _header_box(dest) == _CELL.bbox

    regions = state["geofabrik"]["regions"]
    assert set(regions) == {"priority-w084-n34", "other-region"}
    entry = regions["priority-w084-n34"]
    assert sorted(entry["precut_from"]) == ["east-region", "west-region"]
    assert entry["precut_bbox"] == list(_CELL.bbox)
    assert entry["md5"] == results[0].detail
    assert entry["checked_at"] is not None
    # Unregistered, not deleted.
    assert (mirror / "osm" / "geofabrik" / _PIN / "wnc-corridor.osm.pbf").exists()
    assert (mirror / "osm" / "geofabrik" / _PIN / "west-region.osm.pbf").exists()
    # No scratch tree left behind in the live pin directory.
    assert not list((mirror / "osm" / "geofabrik" / _PIN).glob(".precut-*"))


def test_a_cell_with_nothing_in_it_is_skipped_and_its_old_entry_removed(
    tmp_path: Path,
) -> None:
    mirror = _mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")
    state["geofabrik"]["regions"]["priority-w082-n36"] = {"md5": "from-an-earlier-run"}

    results = gp.precut_cells(root=mirror, pinned_date=_PIN, state=state,
                              cells=[_EMPTY_CELL], replace_sources=False)

    assert [r.action for r in results] == ["skipped_empty"]
    assert "priority-w082-n36" not in state["geofabrik"]["regions"]
    assert not (mirror / "osm" / "geofabrik" / _PIN / "priority-w082-n36.osm.pbf").exists()


def test_keep_sources_leaves_every_existing_registration_alone(tmp_path: Path) -> None:
    mirror = _mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")

    gp.precut_cells(root=mirror, pinned_date=_PIN, state=state, cells=[_CELL],
                    replace_sources=False)

    assert set(state["geofabrik"]["regions"]) == {
        "west-region", "east-region", "wnc-corridor", "other-region", "priority-w084-n34",
    }


def test_precut_cells_refuses_a_source_that_was_never_pulled(tmp_path: Path) -> None:
    mirror = _mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")
    cell = gp.PrecutCell("priority-w084-n34", _CELL.bbox, ("never-pulled",))

    with pytest.raises(SystemExit, match="not pulled yet"):
        gp.precut_cells(root=mirror, pinned_date=_PIN, state=state, cells=[cell])


def test_run_precuts_cells_only_after_every_pull_succeeds(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    mirror = _mirror(tmp_path)
    monkeypatch.setattr(gp, "pull_region",
                        lambda **kw: gp.PullResult(kw["region"], "failed", "offline"))
    calls: list[object] = []
    monkeypatch.setattr(gp, "precut_cells", lambda **kw: calls.append(kw) or [])

    gp.run(["west-region"], root=mirror, pinned_date=_PIN,
           priority_precut={"cells": [_CELL], "replace_sources": True, "supersedes": ()})

    assert calls == []


def test_a_rerun_replaces_a_pinned_cell_in_place(tmp_path: Path) -> None:
    mirror = _mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")
    gp.precut_cells(root=mirror, pinned_date=_PIN, state=state, cells=[_CELL],
                    replace_sources=False)
    first = state["geofabrik"]["regions"]["priority-w084-n34"]["md5"]

    gp.precut_cells(root=mirror, pinned_date=_PIN, state=state, cells=[_CELL],
                    replace_sources=False)

    assert state["geofabrik"]["regions"]["priority-w084-n34"]["md5"] == first


# --------------------------------------------------------------------------
# The CLI
# --------------------------------------------------------------------------


def test_dry_run_prints_the_plan_and_makes_no_call(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
) -> None:
    monkeypatch.setattr(gp, "run", lambda *a, **kw: pytest.fail("dry run must not run"))

    assert gp.main(["--precut-priority-regions", "--priority-regions", "yellowstone",
                    "--dry-run"]) == 0

    out = capsys.readouterr().out
    assert "priority-w112-n44" in out
    assert "north-america/us/wyoming" in out
    # The corridor is always in the plan.
    assert "north-america/us/tennessee" in out


def test_the_priority_run_defaults_to_the_mirrors_current_pin(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    mirror = _mirror(tmp_path)
    seen: dict = {}
    monkeypatch.setattr(gp, "run", lambda regions, **kw: seen.update(kw, regions=regions) or [])

    assert gp.main(["--root", str(mirror), "--precut-priority-regions",
                    "--priority-regions", "bwcaw"]) == 0

    assert seen["pinned_date"] == _PIN
    assert "north-america/canada/ontario" in seen["regions"]
    assert seen["request_spacing"].total_seconds() == 120
    assert seen["priority_precut"]["supersedes"] == ("wnc-corridor",)
    assert json.loads((mirror / "MIRROR_STATE.json").read_text())  # untouched, still valid


@pytest.mark.parametrize("extra", [["--region", "north-america/us/ohio"],
                                   ["--precut-wnc-corridor"]])
def test_the_priority_run_refuses_flags_it_replaces(extra: list[str]) -> None:
    with pytest.raises(SystemExit):
        gp.main(["--precut-priority-regions", *extra])


def test_a_plain_run_still_requires_a_region() -> None:
    with pytest.raises(SystemExit):
        gp.main([])
