"""FR94 — the one bbox-scoped, on-demand cache pattern (issue #152).

`plotlines_core.cache_layout` is the single place tiles, elevation and
candidates agree on *where* a payload for a trip bbox lives and *how* that
location is named. These pin the two rules FR94 states: scoped by the trip
bbox (FR120), and a separate cache per payload.
"""

from __future__ import annotations

from pathlib import Path

from plotlines_core.cache_layout import (
    CANDIDATES_DIRNAME,
    ELEVATION_DIRNAME,
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


def test_the_three_payload_caches_are_separate_sibling_dirs(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    assert layout.tiles_dir == tmp_path / TILES_DIRNAME
    assert layout.elevation_dir == tmp_path / ELEVATION_DIRNAME
    assert layout.candidates_dir == tmp_path / CANDIDATES_DIRNAME
    # Three distinct directories — "separate cache" (FR94) is a dir boundary.
    assert len({layout.tiles_dir, layout.elevation_dir, layout.candidates_dir}) == 3


def test_payload_paths_are_bbox_scoped_under_their_own_cache(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    key = trip_bbox_key(_BBOX)

    assert layout.tile_archive(_BBOX) == tmp_path / TILES_DIRNAME / f"{key}.pmtiles"
    assert layout.elevation_raster(_BBOX) == tmp_path / ELEVATION_DIRNAME / f"{key}.tif"
    assert layout.candidate_set(_BBOX) == tmp_path / CANDIDATES_DIRNAME / f"{key}.json"


def test_tile_and_elevation_share_one_key_for_the_same_bbox(tmp_path: Path) -> None:
    """Identical pattern (FR94): the tile archive and the DEM for one trip
    bbox carry the same stem, differing only by cache dir and extension."""
    layout = CacheLayout(tmp_path)
    assert (
        layout.tile_archive(_BBOX).stem
        == layout.elevation_raster(_BBOX).stem
        == trip_bbox_key(_BBOX)
    )


def test_ensure_dirs_creates_only_the_payload_caches(tmp_path: Path) -> None:
    root = tmp_path / "app-support"
    layout = CacheLayout(root).ensure_dirs()
    assert layout.tiles_dir.is_dir()
    assert layout.elevation_dir.is_dir()
    assert layout.candidates_dir.is_dir()
    assert sorted(p.name for p in root.iterdir()) == sorted(
        [TILES_DIRNAME, ELEVATION_DIRNAME, CANDIDATES_DIRNAME]
    )


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
