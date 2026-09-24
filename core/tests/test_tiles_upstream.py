"""`UpstreamTileReader` — single-tile reads from the configured tile upstream
(issue #154: the trip-extent draw map had no basemap outside the home region,
because the upstream was only ever read once a region existed)."""

from __future__ import annotations

import pytest

from plotlines_core.tiles.extract import local_source
from plotlines_core.tiles.mirror import HotlinkRefused
from plotlines_core.tiles.upstream import UpstreamTileReader
from tiles_helpers import build_archive

# Coverage: roughly the WNC corridor, so a tile outside it is a real miss.
_BOUNDS = (-83.6, 35.2, -81.0, 36.4)


def _tiles():
    tiles = {(0, 0, 0): b"0/0/0"}
    # z10 tiles over the corridor, each naming its own address.
    for x in range(274, 282):
        for y in range(400, 406):
            tiles[(10, x, y)] = f"10/{x}/{y}".encode()
    return tiles


class _Counting:
    """An opener that records every ranged read and every (re)connect."""

    def __init__(self, path, fail_after: int | None = None):
        self.path = path
        self.opens = 0
        self.reads = 0
        self.fail_after = fail_after

    def __call__(self, _source):
        self.opens += 1
        get, close = local_source(self.path)

        def counted(offset, length):
            self.reads += 1
            if self.fail_after is not None and self.reads > self.fail_after:
                raise OSError("connection reset")
            return get(offset, length)

        return counted, close


@pytest.fixture
def archive(tmp_path):
    return build_archive(tmp_path / "corridor.pmtiles", _tiles(), bounds=_BOUNDS)


def test_constructing_a_reader_makes_no_request(archive):
    # D41/D57: `/health` reads `info()`; neither it nor construction may
    # reach the upstream.
    opener = _Counting(archive)
    reader = UpstreamTileReader(archive, opener=opener)
    assert reader.info() is None
    assert opener.opens == 0 and opener.reads == 0


def test_a_tile_is_read_and_info_becomes_known(archive):
    reader = UpstreamTileReader(archive, opener=_Counting(archive))
    assert reader.tile(10, 277, 403) == b"10/277/403"
    info = reader.info()
    assert info is not None
    assert info.bounds == _BOUNDS
    assert (info.min_zoom, info.max_zoom) == (0, 10)


def test_a_repeated_tile_and_a_shared_directory_cost_no_new_directory_reads(archive):
    opener = _Counting(archive)
    reader = UpstreamTileReader(archive, opener=opener)
    reader.tile(10, 277, 403)
    after_first = opener.reads
    reader.tile(10, 277, 403)
    assert opener.reads == after_first, "a cached tile must not reach the upstream again"
    reader.tile(10, 278, 403)
    # Header and root directory were already held: one read, the tile itself.
    assert opener.reads == after_first + 1


def test_a_tile_outside_the_upstreams_bounds_is_a_miss_with_no_request(archive):
    opener = _Counting(archive)
    reader = UpstreamTileReader(archive, opener=opener)
    reader.tile(10, 277, 403)  # load the header
    before = opener.reads
    # z10 over Boulder, CO — outside the corridor's header bounds.
    assert reader.tile(10, 212, 387) is None
    assert opener.reads == before
    # Past the upstream's own max zoom: likewise.
    assert reader.tile(11, 554, 806) is None
    assert opener.reads == before


def test_an_address_inside_bounds_with_no_tile_is_none(archive):
    reader = UpstreamTileReader(archive, opener=_Counting(archive))
    # z5 is inside the zoom range and the bounds, but the archive holds none.
    assert reader.tile(5, 8, 12) is None


def test_a_transport_failure_raises_is_not_cached_and_reconnects(archive):
    # D66: transient, never latched.
    opener = _Counting(archive, fail_after=0)
    reader = UpstreamTileReader(archive, opener=opener)
    with pytest.raises(OSError):
        reader.tile(10, 277, 403)
    opener.fail_after = None
    assert reader.tile(10, 277, 403) == b"10/277/403"
    assert opener.opens == 2


def test_a_third_party_host_is_refused_before_any_byte(archive):
    opener = _Counting(archive)
    with pytest.raises(HotlinkRefused):
        UpstreamTileReader("https://tile.example.invalid/x.pmtiles", opener=opener)
    assert opener.opens == 0


def test_the_default_opener_reads_a_local_path(archive):
    reader = UpstreamTileReader(archive)
    try:
        assert reader.tile(0, 0, 0) == b"0/0/0"
    finally:
        reader.close()
