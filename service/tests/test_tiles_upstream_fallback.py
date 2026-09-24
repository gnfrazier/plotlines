"""`/tiles` reads through to the configured `--tiles-upstream` (issue #154).

The live symptom, reopened on #154 and blocking #453's verification: with the
Pi mirror running and `--tiles-upstream` defaulted to it, the trip-extent
draw map was still grey everywhere outside Buncombe County. `/tiles` only
answered from ensured regions and the home archive, and a region needs the
extent the Author could not see to draw (FR120). The first test below is the
regression: against the pre-fix handler it returns 404.

An upstream read is an outbound call on a request thread, so the rest of
this module is the ARCH §8.6 / D66 shape: a stuck upstream answers 503
inside its deadline and never slows a neighbour.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.tiles.upstream import UpstreamTileReader
from plotlines_service import app as app_module
from plotlines_service.app import create_app
from plotlines_service.tiles_paths import default_home_region_archive
from tiles_helpers import build_archive

pytestmark = pytest.mark.skipif(
    not default_home_region_archive().exists(),
    reason="committed home-region archive not present in this checkout",
)

# A z10 tile over Boulder, CO — nowhere near the committed Buncombe archive,
# so only the upstream can answer it.
_OUTSIDE_HOME = (10, 212, 387)
_UPSTREAM_BOUNDS = (-106.0, 39.5, -104.5, 40.5)


@pytest.fixture
def upstream(tmp_path: Path) -> Path:
    z, x, y = _OUTSIDE_HOME
    return build_archive(tmp_path / "upstream.pmtiles",
                         {(z, x, y): b"upstream-tile"}, bounds=_UPSTREAM_BOUNDS)


def test_a_tile_outside_home_and_every_region_is_read_from_the_upstream(
    tmp_path: Path, upstream: Path,
) -> None:
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=upstream))
    resp = client.get("/tiles/{}/{}/{}".format(*_OUTSIDE_HOME))
    assert resp.status_code == 200
    assert resp.content == b"upstream-tile"
    assert resp.headers["content-type"] == "application/vnd.mapbox-vector-tile"


def test_the_home_archive_still_answers_first(tmp_path: Path, upstream: Path) -> None:
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=upstream))
    # Buncombe at z10 — the committed archive's tile, not the upstream's.
    resp = client.get("/tiles/10/277/403")
    assert resp.status_code == 200
    assert resp.headers.get("content-encoding") == "gzip"


def test_an_address_the_upstream_lacks_is_still_an_honest_404(
    tmp_path: Path, upstream: Path,
) -> None:
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=upstream))
    assert client.get("/tiles/14/0/0").status_code == 404


def test_no_upstream_configured_reads_nothing_beyond_home(tmp_path: Path) -> None:
    app = create_app(tmp_path / "cache")
    assert app.state.readiness.upstream_tiles is None
    assert TestClient(app).get("/tiles/{}/{}/{}".format(*_OUTSIDE_HOME)).status_code == 404


def test_a_refused_upstream_is_never_read(tmp_path: Path) -> None:
    app = create_app(tmp_path / "cache",
                     tiles_upstream="https://tile.example.invalid/x.pmtiles")
    assert app.state.readiness.upstream_tiles is None


def test_health_reports_upstream_bounds_only_once_a_tile_read_has_loaded_them(
    tmp_path: Path, upstream: Path,
) -> None:
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=upstream))
    tiles_up = lambda: client.get("/health").json()["capabilities"]["tiles"]["upstream"]  # noqa: E731
    # D41/D57: polling `/health` never reads the upstream to learn this.
    assert tiles_up()["bounds"] is None
    assert tiles_up()["bounds"] is None
    client.get("/tiles/{}/{}/{}".format(*_OUTSIDE_HOME))
    assert tiles_up()["bounds"] == pytest.approx(list(_UPSTREAM_BOUNDS))


def test_a_stuck_upstream_answers_503_by_its_deadline_and_starves_nothing(
    tmp_path: Path, upstream: Path, monkeypatch,
) -> None:
    monkeypatch.setattr(app_module, "_UPSTREAM_TILE_TIMEOUT_S", 0.3)
    unblock = threading.Event()

    def hang(self, z, x, y):
        unblock.wait(timeout=15.0)
        return None

    monkeypatch.setattr(UpstreamTileReader, "tile", hang)
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=upstream))
    results: dict = {}

    def call_stuck():
        start = time.monotonic()
        resp = client.get("/tiles/{}/{}/{}".format(*_OUTSIDE_HOME))
        results["stuck"] = (time.monotonic() - start, resp.status_code)

    stuck = threading.Thread(target=call_stuck)
    stuck.start()
    time.sleep(0.05)
    try:
        for path in ("/layers", "/health", "/tiles/10/277/403"):
            start = time.monotonic()
            resp = client.get(path)
            assert resp.status_code == 200, path
            assert time.monotonic() - start < 1.0, (
                f"{path} slowed while the tile upstream was stuck")
        stuck.join(timeout=5.0)
        elapsed, status = results["stuck"]
        assert status == 503
        assert elapsed < 2.0
        # Transient, never latched: the next call tries again (and, with the
        # one worker still wedged, gives up by the same deadline).
        assert client.get("/tiles/{}/{}/{}".format(*_OUTSIDE_HOME)).status_code == 503
    finally:
        unblock.set()
        stuck.join(timeout=5.0)
        client.app.state.readiness.shutdown()


def test_past_the_waiting_bound_a_tile_is_503_immediately(
    tmp_path: Path, upstream: Path,
) -> None:
    app = create_app(tmp_path / "cache", tiles_upstream=upstream)
    waiting = app.state.readiness._upstream_tile_waiting
    for _ in range(app_module._UPSTREAM_TILE_MAX_WAITING):
        assert waiting.acquire(blocking=False)
    try:
        start = time.monotonic()
        resp = TestClient(app).get("/tiles/{}/{}/{}".format(*_OUTSIDE_HOME))
        assert resp.status_code == 503
        assert "busy" in resp.json()["detail"]
        assert time.monotonic() - start < 0.5
    finally:
        for _ in range(app_module._UPSTREAM_TILE_MAX_WAITING):
            waiting.release()
