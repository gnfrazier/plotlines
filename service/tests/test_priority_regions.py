"""`deploy/elevation/priority_regions.py` — pure geometry for the
priority-region live pre-warm run (issue #450's ceiling-exhaustion check,
spent productively). Loaded by file path, same reasoning as
`test_prewarm_cache.py`: these standalone deploy scripts are never imported
as part of `plotlines_core` or `plotlines_service`.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[2] / "deploy" / "elevation" / "priority_regions.py"
)


def _load_priority_regions():
    spec = importlib.util.spec_from_file_location("priority_regions", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["priority_regions"] = module
    spec.loader.exec_module(module)
    return module


pr = _load_priority_regions()


def _bboxes_overlap(a, b) -> bool:
    aw, asouth, ae, anorth = a
    bw, bsouth, be, bnorth = b
    return not (ae < bw or be < aw or anorth < bsouth or bnorth < asouth)


def test_bbox_area_km2_matches_a_known_rectangle() -> None:
    # A 1deg x 1deg box straddling the equator at lon 0 is close to
    # 111.32km x 110.57km (WGS84) -- geodesic area should land near there,
    # not a naive flat-degrees-squared approximation.
    area = pr.bbox_area_km2((-0.5, -0.5, 0.5, 0.5))
    assert 12_200 < area < 12_400


def test_split_bbox_to_cap_never_returns_an_over_cap_piece() -> None:
    huge = (-100.0, 20.0, -70.0, 50.0)  # a large chunk of North America
    pieces = pr.split_bbox_to_cap(huge, max_area_km2=100_000)
    assert len(pieces) > 1
    for piece in pieces:
        assert pr.bbox_area_km2(piece) <= 100_000 * 1.01  # tiny float slack


def test_split_bbox_to_cap_is_a_noop_under_the_cap() -> None:
    small = (-83.0, 35.0, -82.5, 35.5)
    assert pr.split_bbox_to_cap(small, max_area_km2=1_000_000) == [small]


def test_chunk_polyline_into_tiles_covers_every_vertex_with_no_gap() -> None:
    route = pr.SKYLINE_DRIVE_ROUTE
    tiles = pr.chunk_polyline_into_tiles(route, pr.SKYLINE_BUFFER_KM)
    assert len(tiles) >= 1
    for lon, lat in route:
        assert any(
            west <= lon <= east and south <= lat <= north for (west, south, east, north) in tiles
        )
    for tile_a, tile_b in zip(tiles, tiles[1:]):
        assert _bboxes_overlap(tile_a, tile_b)


def test_chunk_polyline_into_tiles_respects_a_tighter_area_cap() -> None:
    tiles = pr.chunk_polyline_into_tiles(pr.PCT_ROUTE, pr.PCT_BUFFER_KM, max_area_km2=100_000)
    assert len(tiles) >= 4  # a tighter cap than the default forces more, smaller tiles
    for tile in tiles:
        assert pr.bbox_area_km2(tile) <= 100_000 * 1.01
    for lon, lat in pr.PCT_ROUTE:
        assert any(
            west <= lon <= east and south <= lat <= north for (west, south, east, north) in tiles
        )


def test_build_priority_candidates_covers_all_seven_regions_in_order() -> None:
    candidates = pr.build_priority_candidates()
    region_order: list[str] = []
    for c in candidates:
        if not region_order or region_order[-1] != c.region_key:
            region_order.append(c.region_key)
    assert region_order == ["nc", "brp", "skyline", "bwcaw", "yellowstone", "champlain", "pct"]
    priorities = [c.priority for c in candidates]
    assert priorities == sorted(priorities)
    assert all(1 <= p <= 7 for p in priorities)


def test_build_priority_candidates_respects_the_area_cap() -> None:
    candidates = pr.build_priority_candidates(max_tile_area_km2=200_000)
    for c in candidates:
        assert c.area_km2 <= 200_000 * 1.01


def test_build_priority_candidates_tile_index_and_count_are_consistent() -> None:
    candidates = pr.build_priority_candidates()
    by_region: dict[str, list] = {}
    for c in candidates:
        by_region.setdefault(c.region_key, []).append(c)
    for region_key, tiles in by_region.items():
        assert [t.tile_index for t in tiles] == list(range(1, len(tiles) + 1)), region_key
        assert all(t.tile_count == len(tiles) for t in tiles), region_key


def test_pct_tiles_with_wider_buffer_covers_more_area_than_the_base_pass() -> None:
    base = [c for c in pr.build_priority_candidates() if c.region_key == "pct"]
    wide = pr.pct_tiles_with_wider_buffer(4.0)
    assert sum(c.area_km2 for c in wide) > sum(c.area_km2 for c in base)


def test_synthetic_confirmation_bbox_is_far_from_every_named_region() -> None:
    # Tiny and remote (Alaska Peninsula) -- must not overlap any real
    # candidate bbox, or a live run's final "confirm the 503" step could
    # accidentally land on an already-cached bbox instead of forcing a fresh
    # proxy request.
    for c in pr.build_priority_candidates():
        assert not _bboxes_overlap(pr.SYNTHETIC_CONFIRMATION_BBOX, c.bbox)
    for wide in [pr.pct_tiles_with_wider_buffer(m) for m in (2, 4, 8)]:
        for c in wide:
            assert not _bboxes_overlap(pr.SYNTHETIC_CONFIRMATION_BBOX, c.bbox)
