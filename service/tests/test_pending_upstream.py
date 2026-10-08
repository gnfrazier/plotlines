"""The sidecar waits on mirror fills: `pending_upstream` — issue #521 (epic
#516, ARCH D67).

Routing: `ensure_extract` is scripted to raise the real `ExtractFilling`
(what `fetch_extract` raises on `/clip`'s 202, #518) a set number of times,
then land. Tiles: a fake mirror over a real socket serves `MIRROR_STATE.json`,
`POST /fill` and ranged reads of one cell archive, and the test flips it from
`fetching` to `ready`. Elevation: `qa_proxy_fetch` is scripted to raise the
real `ElevationFilling` (#520's 202). Poll delays are shrunk to milliseconds.
"""

from __future__ import annotations

import http.server
import io
import json
import threading
import time
from pathlib import Path

import networkx as nx
import numpy as np
import pytest
import rasterio
from fastapi.testclient import TestClient
from rasterio.transform import from_origin

from plotlines_core.elevation.qa_proxy_client import ElevationFilling
from plotlines_core.cache_areas import pad_bbox
from plotlines_core.graph import extract_fetch
from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import LoadedGraph
from plotlines_core.tiles.extract import _lonlat_to_tile
from plotlines_service import app as app_module
from plotlines_service.app import create_app
from plotlines_service.tiles_paths import default_home_region_archive
from tiles_helpers import build_archive

_BBOX = [-79.9, 36.05, -79.75, 36.15]
_BBOX_T = (-79.9, 36.05, -79.75, 36.15)
_CELL = (-80.0, 36.0, -78.0, 38.0)
#: The region a build asks `ensure_graph` for since epic #641: the trip's
#: padded held area (D73), not the trip bbox itself.
_AREA_KEY = region_lib.region_key(pad_bbox(_BBOX_T), "bike")


def _wait(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


@pytest.fixture
def fast_polls(monkeypatch):
    monkeypatch.setattr(app_module, "_FILL_POLL_MIN_S", 0.02)
    monkeypatch.setattr(app_module, "_FILL_POLL_DEFAULT_S", 0.05)


@pytest.fixture
def fast_graph(monkeypatch):
    calls = []

    def ensure_graph(region, cache_dir):
        calls.append(region.key)
        return region.graph_path(cache_dir)

    def load(path):
        g = nx.MultiDiGraph()
        g.add_node(1, y=36.1, x=-79.85)
        g.add_node(2, y=36.1, x=-79.8)
        g.add_edge(1, 2, length=4500.0, highway="residential")
        return LoadedGraph(graph=g, source=Path(path), load_seconds=0.0)

    monkeypatch.setattr(app_module.region_lib, "ensure_graph", ensure_graph)
    monkeypatch.setattr(app_module, "load_graphml", load)
    return calls


def _scripted_extract(monkeypatch, *, fillings: int, then=None):
    """`ensure_extract` that answers `fetching` `fillings` times, then
    `then` (a path to return, or an exception to raise)."""
    calls = []

    def ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None, progress=None, **_):
        calls.append(time.monotonic())
        if len(calls) <= fillings:
            progress.status = "pending_upstream"
            progress.detail = "The map-data mirror is fetching OSM data for this area."
            progress.fill_id = "fill-osm-1"
            progress.retry_after_s = 0.05
            raise extract_fetch.ExtractFilling("filling", fill_id="fill-osm-1",
                                               retry_after_s=0.05, detail="pulling")
        if isinstance(then, Exception):
            raise then
        progress.status = "ready"
        return then or (Path(cache_dir) / "x.osm.pbf")

    monkeypatch.setattr(app_module.extract_fetch, "ensure_extract", ensure_extract)
    return calls


@pytest.fixture
def open_client():
    """A `TestClient` entered as a context manager, so the app's lifespan
    shutdown runs and cancels the fill-poll timers a test leaves behind."""
    clients = []

    def _open(app):
        client = TestClient(app)
        client.__enter__()
        clients.append((client, app))
        return client

    yield _open
    for client, app in clients:
        client.__exit__(None, None, None)
        # A region that resolved elevation holds an open rasterio dataset;
        # left for interpreter exit, GDAL closes it after stderr is gone and
        # the process prints "Error in sys.excepthook". Close it here.
        for _key, region in app.state.readiness.snapshot():
            if region.sampler is not None:
                region.sampler.close()


def _routing(client, key):
    return client.get("/health").json()["capabilities"]["routing"]["regions"][key]


# -- routing ------------------------------------------------------------------


def test_a_fill_answered_fetching_twice_then_ready_ends_ready_with_no_author_action(
    tmp_path, monkeypatch, fast_polls, fast_graph, open_client,
) -> None:
    calls = _scripted_extract(monkeypatch, fillings=2)
    seen = []
    client = open_client(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]

    def ready():
        entry = _routing(client, key)
        seen.append(entry)
        return entry.get("ready") is True

    assert _wait(ready)
    waiting = [e for e in seen if e.get("pending_upstream")]
    assert waiting, "/health showed pending_upstream while the mirror filled"
    assert waiting[0]["fill_id"] == "fill-osm-1"
    assert "fetching" in waiting[0]["reason"] and waiting[0]["progress"] == 0.0
    assert not any(e.get("reason", "").startswith("failed:") for e in seen)
    assert len(calls) == 3
    # D63 phase 2: no Overpass fallback while fetching — the graph was
    # built once, after the extract landed.
    assert fast_graph == [_AREA_KEY]


def test_extract_reports_pending_upstream_too(
    tmp_path, monkeypatch, fast_polls, fast_graph, open_client,
) -> None:
    _scripted_extract(monkeypatch, fillings=1000)
    client = open_client(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    assert _wait(lambda: client.get("/health").json()["capabilities"]["extract"]
                 ["regions"].get(key, {}).get("pending_upstream"))
    diag = client.get(f"/regions/{key}/diagnostics").json()
    assert set(diag["upstream_wait"]) >= {"routing", "extract"}
    assert fast_graph == []


def test_no_upstream_coverage_is_terminal_with_no_polling(
    tmp_path, monkeypatch, fast_polls, fast_graph, open_client,
) -> None:
    def ensure_extract(bbox, *, progress=None, **_):
        progress.status = "failed"
        progress.detail = "no_upstream_coverage"
        raise extract_fetch.NoExtractCoverage("No OpenStreetMap extract covers this area")

    calls = []
    monkeypatch.setattr(app_module.extract_fetch, "ensure_extract",
                        lambda *a, **k: (calls.append(1), ensure_extract(*a, **k)))
    client = open_client(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    assert _wait(lambda: client.get("/health").json()["capabilities"]["extract"]
                 ["regions"].get(key, {}).get("reason") == "failed:no_upstream_coverage")
    time.sleep(0.3)
    assert calls == [1], "a terminal answer is never polled"
    extract = client.get("/health").json()["capabilities"]["extract"]["regions"][key]
    assert "pending_upstream" not in extract


def test_a_wait_past_the_ceiling_is_failed_fill_timeout_and_a_retry_resumes_it(
    tmp_path, monkeypatch, fast_polls, fast_graph, open_client,
) -> None:
    monkeypatch.setattr(app_module, "FILL_WAIT_CEILING_S", 0.15)
    calls = _scripted_extract(monkeypatch, fillings=1000)
    client = open_client(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    assert _wait(lambda: _routing(client, key).get("reason", "").startswith("failed:fill_timeout"))
    entry = _routing(client, key)
    assert "fill-osm-1" in entry["reason"]
    polled = len(calls)
    time.sleep(0.3)
    assert len(calls) == polled, "no polling after the ceiling"

    client.post("/regions", json={"bbox": _BBOX, "retry": True})
    assert _wait(lambda: len(calls) > polled), "a later /regions resumes the wait"
    assert _wait(lambda: _routing(client, key).get("pending_upstream") is True)


# -- tiles ----------------------------------------------------------------------


def _tiles_for(bbox, zooms=range(6, 11)):
    west, south, east, north = bbox
    out = {}
    for z in zooms:
        x0, y0 = _lonlat_to_tile(west, north, z)
        x1, y1 = _lonlat_to_tile(east, south, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                out[(z, x, y)] = f"cell:{z}/{x}/{y}".encode()
    return out


class _FakeMirror(http.server.BaseHTTPRequestHandler):
    """The mirror's store (a record + one ranged archive) and its `/fill`."""

    filled = False
    fills: list = []
    archive: bytes = b""

    def _json(self, code, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        cls = type(self)
        if self.path == "/MIRROR_STATE.json":
            areas = {"basemap/cell-2d-w080-n36": {
                "layer": "basemap", "area": "cell-2d-w080-n36",
                "path": "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles",
                "bbox": list(_CELL), "filled_at": "2026-09-28T00:00:00Z"}} if cls.filled else {}
            return self._json(200, {"areas": areas})
        if self.path.endswith("cell-2d-w080-n36.pmtiles") and cls.filled:
            start, end = 0, len(cls.archive) - 1
            rng = self.headers.get("Range")
            if rng:
                a, b = rng.split("=")[1].split("-")
                start, end = int(a), min(int(b), len(cls.archive) - 1)
            body = cls.archive[start:end + 1]
            self.send_response(206 if rng else 200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):  # noqa: N802
        cls = type(self)
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        cls.fills.append(body)
        if cls.filled:
            return self._json(200, {"fill_id": None, "state": "ready", "layer": "basemap"})
        return self._json(202, {"fill_id": "fill-bm-1", "state": "fetching",
                                "retry_after_s": 1, "layer": "basemap", "detail": "extracting"},
                          {"Retry-After": "1"})

    def log_message(self, *_):
        pass


@pytest.fixture
def fake_mirror(tmp_path):
    archive = build_archive(tmp_path / "cell.pmtiles", _tiles_for(_CELL), bounds=_CELL)
    handler = type("M", (_FakeMirror,), {"filled": False, "fills": [],
                                         "archive": archive.read_bytes()})
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}", handler
    server.shutdown()


pytestmark_home = pytest.mark.skipif(
    not default_home_region_archive().exists(),
    reason="committed home-region archive not present in this checkout",
)


@pytestmark_home
def test_tiles_503_while_the_cell_fills_404_elsewhere_then_200(
    tmp_path, monkeypatch, fast_polls, fast_graph, fake_mirror, open_client,
) -> None:
    url, mirror = fake_mirror
    _scripted_extract(monkeypatch, fillings=0)
    client = open_client(create_app(tmp_path, mirror_clip_url="http://mirror.test",
                                   tiles_upstream=url, allow_unmirrored_tiles=True))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    tiles_regions = lambda: client.get("/health").json()["capabilities"]["tiles"]["regions"]  # noqa: E731
    assert _wait(lambda: tiles_regions().get(key, {}).get("pending_upstream"))
    assert mirror.fills[0]["layer"] == "basemap"
    assert tiles_regions()[key]["cells"] == [list(_CELL)]
    # Routing is independent (PRD D-E): ready while the basemap fills.
    assert _routing(client, key)["ready"] is True

    inside = (10, *_lonlat_to_tile(-79.8, 36.1, 10))
    far = (10, *_lonlat_to_tile(-70.0, 30.0, 10))
    resp = client.get("/tiles/{}/{}/{}".format(*inside))
    assert resp.status_code == 503
    assert int(resp.headers["retry-after"]) >= 1
    assert client.get("/tiles/{}/{}/{}".format(*far)).status_code == 404

    mirror.filled = True
    assert _wait(lambda: tiles_regions().get(key, {}).get("ready") is True)
    resp = client.get("/tiles/{}/{}/{}".format(*inside))
    assert resp.status_code == 200 and resp.content.startswith(b"cell:")


# -- elevation ---------------------------------------------------------------------


def _dem_bytes() -> bytes:
    data = np.array([[1000.0, 1100.0], [1000.0, 1100.0]], dtype="float32")
    buf = io.BytesIO()
    with rasterio.MemoryFile() as mem:
        with mem.open(driver="GTiff", height=2, width=2, count=1, dtype="float32",
                      crs="EPSG:4326", transform=from_origin(-79.9, 36.15, 0.075, 0.05),
                      nodata=-9999.0) as ds:
            ds.write(data, 1)
        buf.write(mem.read())
    return buf.getvalue()


def test_elevation_waiting_on_the_proxy_reads_pending_upstream_then_ready(
    tmp_path, monkeypatch, fast_polls, fast_graph, open_client,
) -> None:
    """#520's acceptance, closed here: the sidecar reports elevation
    `fetching`, never `elevation_source_not_configured` or a flat profile."""
    calls = []

    def qa_fetch(base_url, bbox, dest):
        calls.append(1)
        if len(calls) <= 2:
            raise ElevationFilling("filling", fill_id="fill-elev-1", retry_after_s=0.05,
                                   detail="the shared OpenTopography allowance is spent")
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        Path(dest).write_bytes(_dem_bytes())
        return dest

    monkeypatch.setattr(app_module, "qa_proxy_fetch", qa_fetch)
    _scripted_extract(monkeypatch, fillings=0)
    seen = []
    client = open_client(create_app(tmp_path, mirror_clip_url="http://mirror.test",
                                   elevation_upstream="http://pi5.test/dem"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]

    def elevation():
        entry = client.get("/health").json()["capabilities"]["elevation"]["regions"].get(key, {})
        seen.append(entry)
        return entry.get("ready") is True

    assert _wait(elevation), (seen[:3], seen[-3:], calls)
    waiting = [e for e in seen if e.get("pending_upstream")]
    assert waiting and waiting[0]["fill_id"] == "fill-elev-1"
    assert "allowance" in waiting[0]["reason"]
    assert not any(e.get("reason", "").startswith("failed:") for e in seen)
    assert fast_graph == [_AREA_KEY], "an elevation retry never rebuilds the graph"


def test_waiting_s_counts_from_the_first_report_across_phase_retries(monkeypatch) -> None:
    # An elevation retry passes back through `start` before it learns the fill
    # is still running; the observed wait must not restart from zero each poll.
    now = {"t": 1000.0}
    monkeypatch.setattr(app_module.time, "monotonic", lambda: now["t"])
    cap = app_module.CapabilityState(0.0)
    cap.start("fetching terrain data for this area")
    cap.wait_upstream("filling", fill_id="f1", retry_after_s=60)
    for _ in range(3):  # three polls, a minute apart
        now["t"] += 60
        cap.start("fetching terrain data for this area")
        cap.wait_upstream("filling", fill_id="f1", retry_after_s=60)
    assert cap.to_dict()["waiting_s"] == 180

    cap.succeed("ready")
    cap.start("fetching terrain data for this area")
    cap.wait_upstream("filling", fill_id="f2", retry_after_s=60)
    assert cap.to_dict()["waiting_s"] == 0  # a new wait after an outcome
