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
from plotlines_core.tiles.extract import NoTilesInBbox, extract_bbox
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


# --------------------------------------------------------------- http_range_source

class _RangeRequestHandler(http.server.BaseHTTPRequestHandler):
    archive_path = None  # set per-test

    def do_GET(self):  # noqa: N802 — stdlib handler method name
        data = self.archive_path.read_bytes()
        rng = self.headers.get("Range")
        if not rng:
            self.send_error(416)
            return
        start, end = rng.removeprefix("bytes=").split("-")
        start, end = int(start), int(end)
        chunk = data[start:end + 1]
        self.send_response(206)
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()
        self.wfile.write(chunk)

    def log_message(self, *_args):
        pass  # keep test output quiet


@pytest.fixture
def http_server_url(world_archive):
    handler = type("Handler", (_RangeRequestHandler,), {"archive_path": world_archive})
    server = http.server.HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/world.pmtiles"
    finally:
        server.shutdown()
        thread.join(timeout=5)


def test_extract_bbox_reads_an_http_range_upstream(http_server_url, tmp_path):
    # A loopback test server is not the Plotlines mirror, so this exercises
    # the dev-only `allow_unmirrored` path (the mirror policy itself lives in
    # `test_tiles_mirror.py`).
    out = extract_bbox(http_server_url, (-180.0, -85.0, 180.0, 85.0),
                       tmp_path / "out.pmtiles", min_zoom=0, max_zoom=0,
                       allow_unmirrored=True)
    with Archive(out) as archive:
        assert archive.tile(0, 0, 0) == b"0/0/0"
