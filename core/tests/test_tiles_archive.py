"""Unit tests for `plotlines_core.tiles.archive` (FR92-94; issue #154)."""

from __future__ import annotations

from plotlines_core.tiles.archive import Archive, valid_zxy
from tiles_helpers import build_archive


# --------------------------------------------------------------------- valid_zxy

def test_valid_zxy_accepts_the_single_tile_at_zoom_zero():
    assert valid_zxy(0, 0, 0) is True


def test_valid_zxy_rejects_negative_zoom():
    assert valid_zxy(-1, 0, 0) is False


def test_valid_zxy_rejects_x_or_y_outside_the_zoom_level_span():
    assert valid_zxy(2, 4, 0) is False  # span at z=2 is 4 (0..3)
    assert valid_zxy(2, 0, 4) is False
    assert valid_zxy(2, 3, 3) is True


def test_valid_zxy_rejects_negative_x_or_y():
    assert valid_zxy(5, -1, 0) is False
    assert valid_zxy(5, 0, -1) is False


def test_valid_zxy_rejects_absurd_zoom():
    assert valid_zxy(999, 0, 0) is False


# --------------------------------------------------------------------- Archive

def test_archive_returns_stored_tile_bytes(tmp_path):
    path = build_archive(tmp_path / "a.pmtiles", {(0, 0, 0): b"world-tile"})
    with Archive(path) as archive:
        assert archive.tile(0, 0, 0) == b"world-tile"


def test_archive_returns_none_for_a_missing_tile(tmp_path):
    path = build_archive(tmp_path / "a.pmtiles", {(0, 0, 0): b"world-tile"})
    with Archive(path) as archive:
        assert archive.tile(3, 7, 7) is None


def test_archive_info_reports_bounds_and_zoom_range(tmp_path):
    path = build_archive(
        tmp_path / "a.pmtiles",
        {(1, 0, 0): b"a", (2, 1, 1): b"b"},
        bounds=(-83.6, 35.2, -81.0, 36.4),
    )
    with Archive(path) as archive:
        info = archive.info()
        assert info.min_zoom == 1
        assert info.max_zoom == 2
        assert info.bounds == (-83.6, 35.2, -81.0, 36.4)


def test_identity_is_stable_for_the_same_content_and_path_independent(tmp_path):
    # Issue #155 — the client namespaces its raster tile cache by this, so a
    # fresh checkout of the same committed archive must fingerprint the same.
    tiles = {(1, 0, 0): b"a", (2, 1, 1): b"b"}
    a = build_archive(tmp_path / "a.pmtiles", tiles, bounds=(-83.6, 35.2, -81.0, 36.4))
    b = build_archive(tmp_path / "b.pmtiles", tiles, bounds=(-83.6, 35.2, -81.0, 36.4))
    with Archive(a) as arc_a, Archive(b) as arc_b:
        assert arc_a.info().identity == arc_b.info().identity
        assert arc_a.info().identity == arc_a.identity()


def test_identity_changes_when_the_tile_payload_changes(tmp_path):
    # Replacing or extending the archive must invalidate renders derived
    # from the old one rather than serving them for the 30-day cache TTL.
    a = build_archive(tmp_path / "a.pmtiles", {(0, 0, 0): b"world-tile"})
    b = build_archive(tmp_path / "b.pmtiles", {(0, 0, 0): b"a-different-tile"})
    with Archive(a) as arc_a, Archive(b) as arc_b:
        assert arc_a.identity() != arc_b.identity()


def test_archive_info_reports_no_content_encoding_when_uncompressed(tmp_path):
    path = build_archive(tmp_path / "a.pmtiles", {(0, 0, 0): b"raw"})
    with Archive(path) as archive:
        assert archive.info().content_encoding is None


def test_archive_covers_true_inside_bounds_and_zoom(tmp_path):
    path = build_archive(
        tmp_path / "a.pmtiles",
        {(5, 8, 12): b"x"},  # covers Buncombe County's centre at z=5
        bounds=(-83.6, 35.2, -81.0, 36.4),
    )
    with Archive(path) as archive:
        info = archive.info()
        assert info.covers(5, 8, 12) is True


def test_archive_covers_false_outside_bounds(tmp_path):
    path = build_archive(
        tmp_path / "a.pmtiles",
        {(5, 9, 12): b"x"},
        bounds=(-83.6, 35.2, -81.0, 36.4),
    )
    with Archive(path) as archive:
        info = archive.info()
        # Boulder, CO at zoom 5 — far outside the Buncombe bounds above.
        assert info.covers(5, 6, 12) is False


def test_archive_covers_false_outside_zoom_range(tmp_path):
    path = build_archive(tmp_path / "a.pmtiles", {(5, 9, 12): b"x"})
    with Archive(path) as archive:
        info = archive.info()
        assert info.covers(9, 9 << 4, 12 << 4) is False
