"""FR94 — the one bbox-scoped, on-demand cache pattern (issue #152, #273).

`plotlines_core.cache_layout` is the single place tiles, elevation,
candidates and OSM extracts agree on *where* a payload for a trip bbox lives
and *how* that location is named. These pin the two rules FR94 states:
scoped by the trip bbox (FR120), and a separate cache per payload — plus,
for the extract, the pin-above-the-key rule and its sweep (issue #273).
"""

from __future__ import annotations

from pathlib import Path

from plotlines_core.cache_layout import (
    CANDIDATES_DIRNAME,
    ELEVATION_DIRNAME,
    EXTRACTS_DIRNAME,
    TILES_DIRNAME,
    CacheLayout,
    trip_bbox_key,
)

_BBOX = (-82.83, 35.36, -82.14, 35.79)  # Buncombe County, NC — the home region


# -- trip_bbox_key --------------------------------------------------------- #


def test_key_is_deterministic_and_short_hex() -> None:
    k = trip_bbox_key(_BBOX)
    assert k == trip_bbox_key(_BBOX)
    assert len(k) == 16 and all(c in "0123456789abcdef" for c in k)


def test_key_ignores_sub_metre_float_noise() -> None:
    """A re-drawn but visually identical bbox must hit the same cache entry."""
    jittered = tuple(c + 1e-7 for c in _BBOX)
    assert trip_bbox_key(jittered) == trip_bbox_key(_BBOX)


def test_key_separates_deliberately_different_extents() -> None:
    bigger = (_BBOX[0] - 0.5, _BBOX[1], _BBOX[2], _BBOX[3])
    assert trip_bbox_key(bigger) != trip_bbox_key(_BBOX)


def test_key_depends_only_on_the_bbox() -> None:
    """No network type, zoom, or layer selection in the key — FR94 scopes the
    tile and elevation caches by the trip bbox *alone* (FR120)."""
    import inspect

    sig = inspect.signature(trip_bbox_key)
    assert list(sig.parameters) == ["bbox"]


# -- CacheLayout: a separate cache per payload ---------------------------- #


def test_the_four_payload_caches_are_separate_sibling_dirs(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    assert layout.tiles_dir == tmp_path / TILES_DIRNAME
    assert layout.elevation_dir == tmp_path / ELEVATION_DIRNAME
    assert layout.candidates_dir == tmp_path / CANDIDATES_DIRNAME
    assert layout.extracts_dir == tmp_path / EXTRACTS_DIRNAME
    # Four distinct directories — "separate cache" (FR94) is a dir boundary.
    assert (
        len(
            {
                layout.tiles_dir,
                layout.elevation_dir,
                layout.candidates_dir,
                layout.extracts_dir,
            }
        )
        == 4
    )


def test_payload_paths_are_bbox_scoped_under_their_own_cache(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    key = trip_bbox_key(_BBOX)

    assert layout.tile_archive(_BBOX) == tmp_path / TILES_DIRNAME / f"{key}.pmtiles"
    assert layout.elevation_raster(_BBOX) == tmp_path / ELEVATION_DIRNAME / f"{key}.tif"
    assert layout.candidate_set(_BBOX) == tmp_path / CANDIDATES_DIRNAME / f"{key}.json"
    assert (
        layout.osm_extract(_BBOX, "2026-09-01")
        == tmp_path / EXTRACTS_DIRNAME / "2026-09-01" / f"{key}.osm.pbf"
    )


def test_tile_and_elevation_share_one_key_for_the_same_bbox(tmp_path: Path) -> None:
    """Identical pattern (FR94): the tile archive and the DEM for one trip
    bbox carry the same stem, differing only by cache dir and extension."""
    layout = CacheLayout(tmp_path)
    key = trip_bbox_key(_BBOX)
    assert layout.tile_archive(_BBOX).stem == key
    assert layout.elevation_raster(_BBOX).stem == key
    # ".osm.pbf" is a double extension — strip both to compare stems fairly.
    assert layout.osm_extract(_BBOX, "2026-09-01").name == f"{key}.osm.pbf"


def test_ensure_dirs_creates_only_the_payload_caches(tmp_path: Path) -> None:
    root = tmp_path / "app-support"
    layout = CacheLayout(root).ensure_dirs()
    assert layout.tiles_dir.is_dir()
    assert layout.elevation_dir.is_dir()
    assert layout.candidates_dir.is_dir()
    assert layout.extracts_dir.is_dir()
    assert sorted(p.name for p in root.iterdir()) == sorted(
        [TILES_DIRNAME, ELEVATION_DIRNAME, CANDIDATES_DIRNAME, EXTRACTS_DIRNAME]
    )
    # The pin level isn't known at construction time, so ensure_dirs leaves
    # extracts_dir empty rather than guessing at a pin.
    assert list(layout.extracts_dir.iterdir()) == []


# -- osm_extract: pin above the key, not inside it ------------------------- #


def test_osm_extract_pin_is_a_directory_level_above_the_key(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    path = layout.osm_extract(_BBOX, "2026-09-01")
    assert path.parent.name == "2026-09-01"
    assert path.parent.parent == layout.extracts_dir
    assert path.name == f"{trip_bbox_key(_BBOX)}.osm.pbf"


def test_osm_extract_two_pins_for_one_bbox_coexist_without_collision(
    tmp_path: Path,
) -> None:
    layout = CacheLayout(tmp_path)
    old = layout.osm_extract(_BBOX, "2026-08-01")
    new = layout.osm_extract(_BBOX, "2026-09-01")
    assert old != new
    assert old.name == new.name  # same bbox key — only the pin dir differs
    assert old.parent != new.parent

    old.parent.mkdir(parents=True)
    old.write_bytes(b"august extract")
    new.parent.mkdir(parents=True)
    new.write_bytes(b"september extract")

    assert old.read_bytes() == b"august extract"
    assert new.read_bytes() == b"september extract"


def test_trip_bbox_key_is_unaffected_by_the_pin(tmp_path: Path) -> None:
    """The key rule (FR94) holds even for the one payload with a pin axis:
    trip_bbox_key never sees it."""
    layout = CacheLayout(tmp_path)
    key = trip_bbox_key(_BBOX)
    assert layout.osm_extract(_BBOX, "2026-08-01").name == f"{key}.osm.pbf"
    assert layout.osm_extract(_BBOX, "2026-09-01").name == f"{key}.osm.pbf"


# -- sweep_stale_extracts --------------------------------------------------- #


def test_sweep_stale_extracts_removes_other_pins_keeps_current(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    old = layout.osm_extract(_BBOX, "2026-08-01")
    current = layout.osm_extract(_BBOX, "2026-09-01")
    for p in (old, current):
        p.parent.mkdir(parents=True)
        p.write_bytes(b"extract")

    removed = layout.sweep_stale_extracts("2026-09-01")

    assert removed == [layout.extracts_dir / "2026-08-01"]
    assert not old.parent.exists()
    assert current.exists()


def test_sweep_stale_extracts_on_absent_extracts_dir_is_a_no_op(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    assert not layout.extracts_dir.exists()
    assert layout.sweep_stale_extracts("2026-09-01") == []


def test_sweep_stale_extracts_with_only_the_current_pin_removes_nothing(
    tmp_path: Path,
) -> None:
    layout = CacheLayout(tmp_path)
    current = layout.osm_extract(_BBOX, "2026-09-01")
    current.parent.mkdir(parents=True)
    current.write_bytes(b"extract")

    assert layout.sweep_stale_extracts("2026-09-01") == []
    assert current.exists()


def test_str_root_is_accepted_and_normalised(tmp_path: Path) -> None:
    layout = CacheLayout(str(tmp_path))
    assert isinstance(layout.root, Path)
    assert layout.tiles_dir == tmp_path / TILES_DIRNAME


def test_layout_is_frozen(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    try:
        layout.root = tmp_path / "other"  # type: ignore[misc]
    except Exception as exc:  # noqa: BLE001
        assert type(exc).__name__ in {"FrozenInstanceError", "AttributeError"}
    else:  # pragma: no cover
        raise AssertionError("CacheLayout should be immutable")
