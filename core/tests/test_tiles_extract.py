"""Unit tests for `plotlines_core.tiles.extract.extract_bbox` (FR94; issue
#154) — bbox-scoped on-demand extraction from a source PMTiles archive, the
pipeline shared between the live `/tiles` endpoint and any future offline
package export.
"""

from __future__ import annotations

import http.server
import threading

import pytest

from plotlines_core.tiles.archive import Archive
from plotlines_core.tiles.extract import ExtractStats, NoTilesInBbox, extract_bbox
from tiles_helpers import build_archive

# A synthetic world archive at z0-2 (1 + 4 + 16 = 21 tiles), each tile's
# payload naming its own address so extraction correctness is a plain
# membership check.
_WORLD_TILES = {
    (0, 0, 0): b"0/0/0",
}
for _x in range(2):
    for _y in range(2):
        _WORLD_TILES[(1, _x, _y)] = f"1/{_x}/{_y}".encode()
for _x in range(4):
    for _y in range(4):
        _WORLD_TILES[(2, _x, _y)] = f"2/{_x}/{_y}".encode()


@pytest.fixture
def world_archive(tmp_path):
    return build_archive(tmp_path / "world.pmtiles", _WORLD_TILES)


def test_extract_bbox_writes_only_covered_tiles(world_archive, tmp_path):
    # Roughly the western hemisphere, north-of-equator quadrant: at z=1
    # that's exactly tile (1, 0, 0).
    out = extract_bbox(world_archive, (-170.0, 10.0, -10.0, 80.0),
                       tmp_path / "out.pmtiles", min_zoom=1, max_zoom=1)
    with Archive(out) as archive:
        assert archive.tile(1, 0, 0) == b"1/0/0"
        assert archive.tile(1, 1, 0) is None
        assert archive.tile(1, 0, 1) is None
        assert archive.tile(1, 1, 1) is None


def test_extract_bbox_respects_the_zoom_range(world_archive, tmp_path):
    out = extract_bbox(world_archive, (-180.0, -85.0, 180.0, 85.0),
                       tmp_path / "out.pmtiles", min_zoom=0, max_zoom=0)
    with Archive(out) as archive:
        info = archive.info()
        assert info.min_zoom == 0
        assert info.max_zoom == 0
        assert archive.tile(0, 0, 0) == b"0/0/0"


def test_extract_bbox_defaults_to_the_source_archives_own_zoom_range(world_archive, tmp_path):
    out = extract_bbox(world_archive, (-180.0, -85.0, 180.0, 85.0), tmp_path / "out.pmtiles")
    with Archive(out) as archive:
        info = archive.info()
        assert info.min_zoom == 0
        assert info.max_zoom == 2


def test_extract_bbox_records_the_requested_bounds(world_archive, tmp_path):
    bbox = (-83.6, 35.2, -81.0, 36.4)
    out = extract_bbox(world_archive, bbox, tmp_path / "out.pmtiles", min_zoom=0, max_zoom=0)
    with Archive(out) as archive:
        assert archive.info().bounds == bbox


def test_extract_bbox_raises_when_source_has_no_matching_tiles(tmp_path):
    # An archive that only has data far from the requested bbox's zoom range.
    empty_source = build_archive(tmp_path / "sparse.pmtiles", {(0, 0, 0): b"only-z0"})
    with pytest.raises(NoTilesInBbox):
        extract_bbox(empty_source, (-83.6, 35.2, -81.0, 36.4),
                    tmp_path / "out.pmtiles", min_zoom=5, max_zoom=5)


def test_extract_bbox_leaves_no_file_on_failure(tmp_path):
    empty_source = build_archive(tmp_path / "sparse.pmtiles", {(0, 0, 0): b"only-z0"})
    out_path = tmp_path / "out.pmtiles"
    with pytest.raises(NoTilesInBbox):
        extract_bbox(empty_source, (-83.6, 35.2, -81.0, 36.4), out_path, min_zoom=5, max_zoom=5)
    assert not out_path.exists()


def test_a_callers_zoom_bound_is_a_ceiling_on_the_archives_own_not_an_override(
    world_archive, tmp_path,
):
    """Issue #456's regression: `max_zoom` past what the archive holds used
    to enumerate every address up to the caller's bound anyway (a large
    bbox against a shallow archive built an unbounded address list and took
    the WSL VM down via the OOM-killer). The bound may only narrow the
    archive's own `[min_zoom, max_zoom]`. The bbox here is one z2 tile
    wide so the old code's over-enumeration stays finite — ~1.9 M
    addresses to z15, a visibly wrong count in a few seconds rather than
    the OOM a trip-sized bbox produced."""
    stats = ExtractStats()
    out = extract_bbox(world_archive, (-170.0, 50.0, -160.0, 60.0),
                       tmp_path / "out.pmtiles", min_zoom=0, max_zoom=15, stats=stats)
    assert stats.addresses == 3  # z0, z1, z2 — nothing past the archive's z2
    assert stats.hits == 3
    with Archive(out) as archive:
        assert archive.info().max_zoom == 2

    # Symmetric on the floor: a `min_zoom` below the archive's own is raised
    # to it rather than enumerating levels the archive never had.
    z1_up = build_archive(tmp_path / "z1up.pmtiles",
                          {k: v for k, v in _WORLD_TILES.items() if k[0] >= 1})
    stats = ExtractStats()
    out = extract_bbox(z1_up, (-170.0, 50.0, -160.0, 60.0),
                       tmp_path / "out2.pmtiles", min_zoom=0, max_zoom=2, stats=stats)
    assert stats.addresses == 2  # z1, z2
    with Archive(out) as archive:
        assert archive.info().min_zoom == 1


# --------------------------------------------------------------- http_range_source

class _RangeRequestHandler(http.server.BaseHTTPRequestHandler):
    archive_path = None  # set per-test
    ranges: list[tuple[int, int]] = []  # every ranged GET served, in order
    # Keep-alive, so the source's one-connection posture (issue #456) is
    # exercised for real rather than reconnecting per request as HTTP/1.0
    # would force.
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 — stdlib handler method name
        data = self.archive_path.read_bytes()
        rng = self.headers.get("Range")
        if not rng:
            self.send_error(416)
            return
        start, end = rng.removeprefix("bytes=").split("-")
        start, end = int(start), int(end)
        self.ranges.append((start, end))
        chunk = data[start:end + 1]
        self.send_response(206)
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()
        self.wfile.write(chunk)

    def log_message(self, *_args):
        pass  # keep test output quiet


def _serve_ranges(archive_path):
    """A loopback range-serving HTTP server for `archive_path`; yields the
    URL and the handler class (whose `ranges` list counts every GET)."""
    handler = type("Handler", (_RangeRequestHandler,),
                   {"archive_path": archive_path, "ranges": []})
    server = http.server.HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/world.pmtiles", handler
    finally:
        server.shutdown()
        thread.join(timeout=5)


@pytest.fixture
def http_server(world_archive):
    yield from _serve_ranges(world_archive)


@pytest.fixture
def http_server_url(http_server):
    return http_server[0]


def test_extract_bbox_reads_an_http_range_upstream(http_server_url, tmp_path):
    # A loopback test server is not the Plotlines mirror, so this exercises
    # the dev-only `allow_unmirrored` path (the mirror policy itself lives in
    # `test_tiles_mirror.py`).
    out = extract_bbox(http_server_url, (-180.0, -85.0, 180.0, 85.0),
                       tmp_path / "out.pmtiles", min_zoom=0, max_zoom=0,
                       allow_unmirrored=True)
    with Archive(out) as archive:
        assert archive.tile(0, 0, 0) == b"0/0/0"


@pytest.fixture
def deep_http_server(tmp_path):
    # A z0–6 world (5,461 tiles) with a distinct ~1 KiB payload per tile, so
    # the writer cannot dedupe them and the tile-data section is large enough
    # (~5.5 MB) that a bbox's runs do *not* all fall inside one
    # `_COALESCE_GAP_BYTES` window — the merge has to earn its count.
    tiles = {}
    for z in range(7):
        for x in range(2 ** z):
            for y in range(2 ** z):
                tiles[(z, x, y)] = f"{z}/{x}/{y}:".encode().ljust(1024, b"x")
    archive = build_archive(tmp_path / "deep.pmtiles", tiles)
    yield from _serve_ranges(archive)


def test_extract_bbox_coalesces_ranged_gets_over_http(deep_http_server, tmp_path):
    """Issue #456's acceptance, hermetically: the request count for a
    many-tile bbox is within an order of magnitude of `pmtiles extract`'s,
    not one ranged GET per tile. Before coalescing this bbox cost two GETs
    per address (a fresh root-directory read, then the tile) on top of the
    header and metadata reads — over 560 for this bbox's 281 hits. The
    server's own tally is the oracle; `ExtractStats.requests` must agree
    with it, or the stat is not the number an operator reads off
    `mirror.log`."""
    url, handler = deep_http_server
    # Straddles quadrant boundaries at every level, so the bbox's tiles sit
    # in several separate runs on the Hilbert curve rather than one.
    bbox = (-100.0, 10.0, -20.0, 60.0)
    stats = ExtractStats()
    out = extract_bbox(url, bbox, tmp_path / "out.pmtiles",
                       allow_unmirrored=True, stats=stats)

    assert stats.requests == len(handler.ranges)
    assert stats.bytes == sum(end - start + 1 for start, end in handler.ranges)
    assert stats.hits >= 250, "the fixture is meant to be a many-tile bbox"
    assert stats.hits == stats.addresses  # the world archive covers every address
    assert stats.requests * 10 <= stats.hits, (
        f"{stats.requests} requests for {stats.hits} tiles is not coalesced")

    # Coalescing changed how the bytes are fetched, not which tiles land.
    with Archive(out) as archive:
        assert archive.tile(6, 20, 20) == b"6/20/20:".ljust(1024, b"x")
        assert archive.tile(0, 0, 0) == b"0/0/0:".ljust(1024, b"x")
        assert archive.tile(6, 60, 60) is None  # south-east, outside the bbox
        info = archive.info()
        assert (info.min_zoom, info.max_zoom) == (0, 6)
