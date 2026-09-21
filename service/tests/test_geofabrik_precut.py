"""`geofabrik_pull.py --precut-wnc-corridor` — issue #375 (Phase 1 of epic
#264, docs/Plotlines_OSM_Acquisition_Review.md §6.7).

`/clip`'s wall time scales with the size of the pinned region extract it
has to scan, not the trip bbox (measured on the live Pi: 627-640s against a
60s outer band, #375's own measurement). Geofabrik publishes no sub-state
cuts for the states this mirror pins, so `precut_region` produces a smaller
pinned extract locally, once, by reusing `mirror_clip.clip_bbox` — the same
algorithm `/clip` runs per request — against already-pulled full-state
extracts.

Loaded by file path, same as `test_geofabrik_pull.py`, since
`deploy/mirror/geofabrik_pull.py` is deployed standalone. Unlike that file's
tests, these exercise real pyosmium behaviour against tiny synthetic
`.osm.pbf` fixtures (`mirror_clip_fixtures.py`), never a real Geofabrik
download or a network mock — `precut_region` never touches the network
itself, only already-pulled files.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

from mirror_clip_fixtures import build_mirror_tree, node, way, write_pbf

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[2] / "deploy" / "mirror" / "geofabrik_pull.py"
)


def _load_geofabrik_pull():
    spec = importlib.util.spec_from_file_location("geofabrik_pull", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["geofabrik_pull"] = module
    spec.loader.exec_module(module)
    return module


gp = _load_geofabrik_pull()

_CORRIDOR_BBOX = (-83.0, 35.0, -81.9, 35.5)


def _two_region_mirror(tmp_path: Path) -> Path:
    """Two already-"pulled" extracts, the same border-way shape
    `test_mirror_clip.py::TestTwoExtractSpan` uses — real overlap, a real
    shared border way, not a contrived edge case."""
    west_region = write_pbf(
        tmp_path / "west.osm.pbf",
        nodes=[node(1, -82.5, 35.2), node(2, -82.35, 35.25)],
        ways=[way(10, [1, 2], tags={"highway": "path"})],
        box=(-83.0, 35.0, -82.35, 35.5),
    )
    east_region = write_pbf(
        tmp_path / "east.osm.pbf",
        nodes=[
            node(1, -82.5, 35.2),
            node(2, -82.35, 35.25),
            node(3, -82.2, 35.3, {"amenity": "drinking_water"}),
        ],
        ways=[way(10, [1, 2], tags={"highway": "path"})],
        box=(-82.35, 35.0, -81.9, 35.5),
    )
    return build_mirror_tree(
        tmp_path / "mirror", regions={"west-region": west_region, "east-region": east_region}
    )


def test_precut_pins_a_smaller_extract_and_removes_the_sources_by_default(
    tmp_path: Path,
) -> None:
    mirror = _two_region_mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")

    result = gp.precut_region(
        root=mirror, pinned_date="2026-09-01", state=state,
        dest_region="wnc-corridor", source_regions=["west-region", "east-region"],
        bbox=_CORRIDOR_BBOX,
    )

    assert result.action == "precut"
    dest_path = mirror / "osm" / "geofabrik" / "2026-09-01" / "wnc-corridor.osm.pbf"
    assert dest_path.exists()
    assert dest_path.stat().st_size > 0

    regions = state["geofabrik"]["regions"]
    assert set(regions) == {"wnc-corridor"}  # sources replaced, per the default
    entry = regions["wnc-corridor"]
    assert entry["precut_from"] == ["west-region", "east-region"]
    assert entry["precut_bbox"] == list(_CORRIDOR_BBOX)
    assert entry["md5"] == result.detail


def test_precut_sets_checked_at_so_the_pin_does_not_read_permanently_stale(
    tmp_path: Path,
) -> None:
    """#471: the precut path wrote `pulled_at` but never `checked_at`, and
    `mirror_state.geofabrik_health`'s `_pull_health` reads only
    `checked_at` for age — the same gap the two non-precut pull paths
    (`pull_region`, `pull_index`) already close by setting it themselves.
    A missing `checked_at` reads as `age = None`, and `stale = age is None
    or age > max_age_days` treats that as stale, so a freshly-precut
    region — the WNC corridor, which every real pin bump produces per the
    release checklist — reported `capabilities.mirror.stale = true`
    forever regardless of how recently it was actually pulled."""
    from datetime import datetime, timezone

    from plotlines_core.tiles.mirror_state import geofabrik_health

    mirror = _two_region_mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")

    gp.precut_region(
        root=mirror, pinned_date="2026-09-01", state=state,
        dest_region="wnc-corridor", source_regions=["west-region", "east-region"],
        bbox=_CORRIDOR_BBOX,
    )

    entry = state["geofabrik"]["regions"]["wnc-corridor"]
    assert entry["checked_at"] is not None

    health = geofabrik_health(state, now=datetime.now(timezone.utc))
    assert health["regions"]["wnc-corridor"]["stale"] is False
    assert health["stale"] is False


def test_precut_keeps_sources_when_asked(tmp_path: Path) -> None:
    mirror = _two_region_mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")

    gp.precut_region(
        root=mirror, pinned_date="2026-09-01", state=state,
        dest_region="wnc-corridor", source_regions=["west-region", "east-region"],
        bbox=_CORRIDOR_BBOX, replace_sources=False,
    )

    regions = state["geofabrik"]["regions"]
    assert set(regions) == {"west-region", "east-region", "wnc-corridor"}


def test_precut_result_matches_clipping_the_sources_directly(tmp_path: Path) -> None:
    """The precut is not a new algorithm — it must produce exactly what
    `clip_bbox` against the un-cut sources already produces, since that's
    the whole justification for reusing it rather than a bespoke cut."""
    import osmium

    from plotlines_service.mirror_clip import clip_bbox

    mirror = _two_region_mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")
    direct = clip_bbox(_CORRIDOR_BBOX, root=mirror, dest=tmp_path / "direct.osm.pbf")

    gp.precut_region(
        root=mirror, pinned_date="2026-09-01", state=state,
        dest_region="wnc-corridor", source_regions=["west-region", "east-region"],
        bbox=_CORRIDOR_BBOX,
    )
    precut_path = mirror / "osm" / "geofabrik" / "2026-09-01" / "wnc-corridor.osm.pbf"

    def _node_ids(path: Path) -> set[int]:
        seen: set[int] = set()
        osmium.apply(str(path), type("_C", (osmium.SimpleHandler,), {
            "node": lambda self, n: seen.add(n.id)
        })())
        return seen

    assert _node_ids(precut_path) == _node_ids(direct.output_path)


def test_precut_raises_if_a_declared_source_was_never_pulled(tmp_path: Path) -> None:
    mirror = _two_region_mirror(tmp_path)
    state = gp.load_state(mirror / "MIRROR_STATE.json")

    with pytest.raises(SystemExit, match="not pulled yet"):
        gp.precut_region(
            root=mirror, pinned_date="2026-09-01", state=state,
            dest_region="wnc-corridor",
            source_regions=["west-region", "never-pulled-region"],
            bbox=_CORRIDOR_BBOX,
        )


def test_precut_raises_if_actual_coverage_disagrees_with_declared_sources(
    tmp_path: Path,
) -> None:
    """A third, undeclared region whose header box also overlaps the
    corridor bbox must not be silently folded into the precut — that would
    make `replace_sources` guess wrong about what to remove."""
    mirror = _two_region_mirror(tmp_path)
    extra = write_pbf(
        tmp_path / "extra.osm.pbf",
        nodes=[node(1, -82.5, 35.2)],
        box=(-83.0, 35.0, -82.35, 35.5),  # overlaps _CORRIDOR_BBOX too
    )
    dest_dir = mirror / "osm" / "geofabrik" / "2026-09-01"
    (dest_dir / "extra-region.osm.pbf").write_bytes(extra.read_bytes())
    state = gp.load_state(mirror / "MIRROR_STATE.json")
    state["geofabrik"]["regions"]["extra-region"] = {
        "pulled_at": "2026-09-01T00:00:00Z", "md5": "deadbeef",
    }
    gp.save_state(mirror / "MIRROR_STATE.json", state)  # clip_bbox reads the mirror from disk

    with pytest.raises(SystemExit, match="not the declared"):
        gp.precut_region(
            root=mirror, pinned_date="2026-09-01", state=state,
            dest_region="wnc-corridor",
            source_regions=["west-region", "east-region"],  # missing extra-region
            bbox=_CORRIDOR_BBOX,
        )


def test_run_applies_precut_only_after_every_pull_succeeds(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    mirror = _two_region_mirror(tmp_path)

    def _fake_pull_region(*, region, root, pinned_date, state, **kwargs):
        return gp.PullResult(region, "failed", "network unreachable")

    monkeypatch.setattr(gp, "pull_region", _fake_pull_region)
    precut_calls: list[str] = []
    monkeypatch.setattr(
        gp, "precut_region",
        lambda **kwargs: precut_calls.append(kwargs["dest_region"])
        or gp.PullResult(kwargs["dest_region"], "precut", ""),
    )

    gp.run(
        ["west-region", "east-region"], root=mirror, pinned_date="2026-09-01",
        precut={"dest_region": "wnc-corridor", "bbox": _CORRIDOR_BBOX, "replace_sources": True},
    )

    assert precut_calls == []  # every pull "failed" above — precut must not run
