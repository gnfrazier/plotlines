"""End-to-end proof for the WNC-corridor basemap stand-in (issue #257;
review §6.3/addendum G3-1b, checklist item 13, parent epic #264).

The stand-in ships under its own honest build id
(`mirror.MIRROR_WNC_CORRIDOR_URL`) rather than as `planet.pmtiles`, because a
one-corridor archive named for the whole planet turns every bbox outside WNC
into a silent miss that looks like a mirror bug. This module proves the two
halves of that claim against the real code path — `extract.http_range_source`
reading over HTTP range requests, exactly as `pmtiles extract` would against
the deployed archive on the Pi — rather than a `curl` smoke test:

1. a bbox inside the corridor's actual tile coverage extracts successfully;
2. a bbox outside it fails as a diagnosable `NoTilesInBbox`, never a blank.

The 118 MB real archive (`spikes/SPIKE-14/tiles/wnc-corridor.pmtiles`) is a
gitignored local build artifact, not something CI can depend on being
present. This test stands in a small synthetic archive shaped the same way —
tiles only within the corridor's real tile-address range at z8, computed
from `mirror.WNC_CORRIDOR_BBOX` (itself read off the real archive's own
PMTiles header, see that constant's docstring) — so the coverage-miss
behaviour is exercised deterministically and fast.
"""

from __future__ import annotations

import http.server
import threading

import pytest

from plotlines_core.tiles.archive import Archive
from plotlines_core.tiles.extract import NoTilesInBbox, _lonlat_to_tile, extract_bbox
from plotlines_core.tiles.mirror import WNC_CORRIDOR_BBOX
from tiles_helpers import build_archive

_ZOOM = 8

# A bbox nowhere near western North Carolina — open Pacific — used only to
# prove an out-of-coverage request is diagnosable, not to assert anything
# about that location itself.
_FAR_FROM_WNC_BBOX = (150.0, -10.0, 151.0, -9.0)


def _tiles_covering(bbox: tuple[float, float, float, float], z: int,
                    payload_prefix: str) -> dict[tuple[int, int, int], bytes]:
    west, south, east, north = bbox
    x0, y0 = _lonlat_to_tile(west, north, z)
    x1, y1 = _lonlat_to_tile(east, south, z)
    return {
        (z, x, y): f"{payload_prefix}/{z}/{x}/{y}".encode()
        for x in range(min(x0, x1), max(x0, x1) + 1)
        for y in range(min(y0, y1), max(y0, y1) + 1)
    }


@pytest.fixture
def corridor_standin_archive(tmp_path):
    # Only the corridor's own tile range exists — nothing "under the planet
    # name" here actually covers the planet, which is exactly the honesty
    # property under test.
    tiles = _tiles_covering(WNC_CORRIDOR_BBOX, _ZOOM, "wnc")
    return build_archive(tmp_path / "corridor.pmtiles", tiles, bounds=WNC_CORRIDOR_BBOX)


class _RangeRequestHandler(http.server.BaseHTTPRequestHandler):
    """Serves one archive with real byte-range semantics — the mirror
    Caddyfile is explicit that `python -m http.server` must never stand in
    for this because `SimpleHTTPRequestHandler` ignores `Range` outright."""

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
def corridor_standin_url(corridor_standin_archive):
    handler = type("Handler", (_RangeRequestHandler,), {"archive_path": corridor_standin_archive})
    server = http.server.HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        # A loopback test server stands in for the Pi/Caddy here (the
        # DNS-override step that lets it classify as UpstreamKind.MIRROR is
        # #261's job, per deploy/mirror/README.md) — exercised via the
        # dev-only allow_unmirrored path, same posture as
        # test_tiles_extract.py's generic http_range_source coverage.
        yield f"http://127.0.0.1:{server.server_port}/corridor.pmtiles"
    finally:
        server.shutdown()
        thread.join(timeout=5)


def test_a_tile_inside_the_corridor_renders_via_http_range_source(corridor_standin_url, tmp_path):
    out = extract_bbox(corridor_standin_url, WNC_CORRIDOR_BBOX, tmp_path / "out.pmtiles",
                       min_zoom=_ZOOM, max_zoom=_ZOOM, allow_unmirrored=True)
    with Archive(out) as archive:
        info = archive.info()
        assert info.min_zoom == _ZOOM
        # At least the tile actually addressed by the bbox's own top-left
        # corner must have made it through the range-read pipeline.
        x, y = _lonlat_to_tile(WNC_CORRIDOR_BBOX[0], WNC_CORRIDOR_BBOX[3], _ZOOM)
        assert archive.tile(_ZOOM, x, y) == f"wnc/{_ZOOM}/{x}/{y}".encode()


def test_a_tile_outside_the_corridor_is_a_diagnosable_coverage_miss_not_a_blank(
    corridor_standin_url, tmp_path,
):
    # This is the exact failure mode G3/1b names: a `planet.pmtiles` that
    # only covers WNC would otherwise let a bbox outside it fail silently.
    # `NoTilesInBbox` (raised, never a 0-byte/empty archive written) is what
    # makes the miss read as "outside coverage" instead of "mirror bug".
    with pytest.raises(NoTilesInBbox):
        extract_bbox(corridor_standin_url, _FAR_FROM_WNC_BBOX, tmp_path / "out.pmtiles",
                    min_zoom=_ZOOM, max_zoom=_ZOOM, allow_unmirrored=True)
    assert not (tmp_path / "out.pmtiles").exists()
