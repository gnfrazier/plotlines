"""The Geofabrik pull client — issue #258 (Phase 1.4 of epic #264),
companion to #256/#257's `test_mirror_deploy_config.py`.
`deploy/mirror/geofabrik_pull.py` is deployed to the Pi5 mirror host
standalone (see `deploy/mirror/README.md`) rather than imported as part of
`plotlines_core`, so it's loaded here by file path rather than as a package.

Each test below maps directly to one #258 acceptance-criterion clause:

- a second run inside the cadence window makes **no request at all**
  (proven from the fake upstream's own request log, not an internal flag);
- once the cadence window has elapsed, an unchanged `.md5` still skips the
  `.osm.pbf` body;
- an `.md5` mismatch fails the pull and leaves a previously-served file
  untouched;
- every request carries the Plotlines UA, kept in lockstep with
  `osm_identity.osm_user_agent`;
- repeated failures back off rather than hammering, and land in
  `MIRROR_STATE.json` where #260's monitor can see them;
- cadence and what was pulled land in `MIRROR_STATE.json`.

`pull_index` (issue #259) gets its own tests below, exercising the same
etiquette shape against the one substitution Geofabrik's actual `index-v1
.json` response forces: an ETag-conditional GET standing in for the `.md5`
check (Geofabrik publishes no digest for the index), verified against a real
304 from the fake upstream, not an internal "would have skipped" flag.
"""

from __future__ import annotations

import hashlib
import http.server
import importlib.util
import json
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from plotlines_core.osm_identity import osm_user_agent

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[2] / "deploy" / "mirror" / "geofabrik_pull.py"
)


def _load_geofabrik_pull():
    import sys

    spec = importlib.util.spec_from_file_location("geofabrik_pull", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["geofabrik_pull"] = module  # dataclass() needs this at import time
    spec.loader.exec_module(module)
    return module


gp = _load_geofabrik_pull()

_REGION = "north-america/us/north-carolina"
_PBF_BODY = b"pretend this is an osm.pbf extract"
_PBF_DIGEST = hashlib.md5(_PBF_BODY).hexdigest()
_MD5_BODY = f"{_PBF_DIGEST}  {_REGION}-latest.osm.pbf\n".encode()

_INDEX_BODY = b'{"type": "FeatureCollection", "features": []}'
_INDEX_ETAG = '"abc123"'


def test_plotlines_user_agent_matches_osm_identity() -> None:
    # "One contactable string across every upstream we touch" (issue #241) —
    # this script duplicates the literal (it's deployed without
    # plotlines_core, see its module docstring) so this is the drift guard.
    assert gp.PLOTLINES_USER_AGENT == osm_user_agent("mirror-geofabrik-pull")


class _Route:
    def __init__(self, status: int = 200, body: bytes = b"", etag: str | None = None):
        self.status = status
        self.body = body
        self.etag = etag


class _RecordingHandler(http.server.BaseHTTPRequestHandler):
    routes: dict[str, _Route] = {}
    request_log: list[tuple[str, dict]] = []

    def do_GET(self):  # noqa: N802 — stdlib handler method name
        self.request_log.append((self.path, dict(self.headers)))
        route = self.routes.get(self.path)
        if route is None:
            self.send_error(404)
            return
        if route.etag and self.headers.get("If-None-Match") == route.etag:
            self.send_response(304)
            self.send_header("ETag", route.etag)
            self.end_headers()
            return
        self.send_response(route.status)
        if route.etag:
            self.send_header("ETag", route.etag)
        self.send_header("Content-Length", str(len(route.body)))
        self.end_headers()
        if route.body:
            self.wfile.write(route.body)

    def log_message(self, *_args):
        pass  # keep test output quiet


@pytest.fixture
def upstream():
    routes: dict[str, _Route] = {
        f"/{_REGION}-latest.osm.pbf.md5": _Route(200, _MD5_BODY),
        f"/{_REGION}-latest.osm.pbf": _Route(200, _PBF_BODY),
        "/index-v1.json": _Route(200, _INDEX_BODY, etag=_INDEX_ETAG),
    }
    request_log: list[tuple[str, dict]] = []
    handler = type("Handler", (_RecordingHandler,),
                    {"routes": routes, "request_log": request_log})
    server = http.server.HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield SimpleNamespace(
            base_url=f"http://127.0.0.1:{server.server_port}",
            routes=routes,
            request_log=request_log,
        )
    finally:
        server.shutdown()
        thread.join(timeout=5)


@pytest.fixture
def mirror_root(tmp_path) -> Path:
    root = tmp_path / "mirror"
    root.mkdir()
    (root / "MIRROR_STATE.json").write_text(json.dumps(
        {"schema_version": 1, "basemap": {"build_id": None, "covered_regions": []},
         "geofabrik": {"pinned_date": None, "regions": {}}}
    ))
    return root


def _clock(*times: datetime):
    it = iter(times)
    return lambda: next(it)


def test_first_pull_downloads_verifies_and_publishes(upstream, mirror_root) -> None:
    state = {"geofabrik": {"regions": {}}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    result = gp.pull_region(
        region=_REGION, root=mirror_root, pinned_date="2026-09-01", state=state,
        base_url=upstream.base_url, now=_clock(t0),
    )

    assert result.action == "pulled"
    assert result.detail == _PBF_DIGEST

    dest = mirror_root / "osm" / "geofabrik" / "2026-09-01" / f"{_REGION}.osm.pbf"
    assert dest.read_bytes() == _PBF_BODY
    assert dest.with_name(dest.name + ".md5").read_text().startswith(_PBF_DIGEST)

    entry = state["geofabrik"]["regions"][_REGION]
    assert entry["md5"] == _PBF_DIGEST
    assert entry["pulled_at"] == gp._iso(t0)
    assert entry["checked_at"] == gp._iso(t0)
    assert entry["consecutive_failures"] == 0
    assert state["geofabrik"]["pinned_date"] == "2026-09-01"

    # Requests carried the Plotlines UA on both the conditional check and
    # the body download.
    paths_seen = {path for path, _headers in upstream.request_log}
    assert paths_seen == {f"/{_REGION}-latest.osm.pbf.md5", f"/{_REGION}-latest.osm.pbf"}
    for _path, headers in upstream.request_log:
        assert headers["User-Agent"] == gp.PLOTLINES_USER_AGENT


def test_second_run_within_cadence_window_makes_no_request(upstream, mirror_root) -> None:
    state = {"geofabrik": {"regions": {}}}
    t0 = datetime(2026, 9, 1, 12, 0, tzinfo=timezone.utc)
    t1 = t0 + timedelta(hours=3)  # well inside the 24h default cadence

    first = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                            state=state, base_url=upstream.base_url, now=_clock(t0))
    assert first.action == "pulled"
    requests_after_first = len(upstream.request_log)
    assert requests_after_first > 0

    second = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                             state=state, base_url=upstream.base_url, now=_clock(t1))

    assert second.action == "skipped_cadence"
    # Proven from the upstream's own request log, not an internal flag: the
    # repeat run inside the window transferred zero body bytes because it
    # made no request whatsoever.
    assert len(upstream.request_log) == requests_after_first


def test_unchanged_md5_skips_body_once_cadence_has_elapsed(upstream, mirror_root) -> None:
    state = {"geofabrik": {"regions": {}}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)
    t1 = t0 + timedelta(hours=25)  # past the 24h cadence window

    gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                    state=state, base_url=upstream.base_url, now=_clock(t0))
    upstream.request_log.clear()

    result = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                             state=state, base_url=upstream.base_url, now=_clock(t1))

    assert result.action == "skipped_unchanged"
    paths_seen = [path for path, _headers in upstream.request_log]
    # Conditional first: the .md5 was re-checked (the cadence window had
    # elapsed) but the unchanged body was never requested.
    assert paths_seen == [f"/{_REGION}-latest.osm.pbf.md5"]


def test_md5_mismatch_fails_and_leaves_previous_file_untouched(upstream, mirror_root) -> None:
    # A published .md5 that doesn't match the body it names — simulating a
    # corrupted or truncated upstream response.
    upstream.routes[f"/{_REGION}-latest.osm.pbf.md5"] = _Route(
        200, f"{'0' * 32}  {_REGION}-latest.osm.pbf\n".encode()
    )
    dest = mirror_root / "osm" / "geofabrik" / "2026-09-01" / f"{_REGION}.osm.pbf"
    dest.parent.mkdir(parents=True)
    dest.write_bytes(b"previously-served good extract")

    state = {"geofabrik": {"regions": {}}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    result = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                             state=state, base_url=upstream.base_url, now=_clock(t0))

    assert result.action == "failed"
    assert "mismatch" in result.detail
    # The previously-served file at the immutable path is untouched.
    assert dest.read_bytes() == b"previously-served good extract"
    # No half-downloaded temp file left lying around either.
    assert list(dest.parent.glob(".pull-*")) == []

    entry = state["geofabrik"]["regions"][_REGION]
    assert entry["consecutive_failures"] == 1
    assert entry["last_failure"]["reason"] and "mismatch" in entry["last_failure"]["reason"]


def test_repeated_failures_back_off_instead_of_hammering(upstream, mirror_root) -> None:
    upstream.routes[f"/{_REGION}-latest.osm.pbf.md5"] = _Route(500, b"")
    state = {"geofabrik": {"regions": {}}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    first = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                            state=state, base_url=upstream.base_url, now=_clock(t0))
    assert first.action == "failed"
    entry = state["geofabrik"]["regions"][_REGION]
    assert entry["consecutive_failures"] == 1
    requests_after_first_failure = len(upstream.request_log)

    # 30 minutes later — inside the 1h base backoff for a single failure —
    # a retry must not hit the network at all.
    soon = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                           state=state, base_url=upstream.base_url,
                           now=_clock(t0 + timedelta(minutes=30)))
    assert soon.action == "skipped_backoff"
    assert len(upstream.request_log) == requests_after_first_failure

    # Two hours later — past the 1h backoff — a retry is attempted again,
    # fails again, and the failure count/backoff grows.
    second = gp.pull_region(region=_REGION, root=mirror_root, pinned_date="2026-09-01",
                             state=state, base_url=upstream.base_url,
                             now=_clock(t0 + timedelta(hours=2)))
    assert second.action == "failed"
    assert entry["consecutive_failures"] == 2
    assert len(upstream.request_log) > requests_after_first_failure

    # The failure is visible in MIRROR_STATE.json's own shape, not only a
    # log line — this is what feeds #260's staleness monitor.
    assert entry["last_failure"]["at"] == gp._iso(t0 + timedelta(hours=2))


def test_run_persists_state_and_leaves_other_keys_untouched(upstream, mirror_root) -> None:
    (mirror_root / "MIRROR_STATE.json").write_text(json.dumps({
        "schema_version": 1,
        "basemap": {"build_id": "20250101-wnc", "covered_regions": [{"name": "wnc-corridor"}]},
        "geofabrik": {"pinned_date": None, "regions": {}},
    }))

    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)
    results = gp.run([_REGION], root=mirror_root, pinned_date="2026-09-01",
                      base_url=upstream.base_url, now=_clock(t0))

    assert [r.action for r in results] == ["pulled"]
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    # basemap (#257's key) survives byte-for-byte.
    assert state["basemap"] == {"build_id": "20250101-wnc",
                                 "covered_regions": [{"name": "wnc-corridor"}]}
    assert state["geofabrik"]["pinned_date"] == "2026-09-01"
    assert state["geofabrik"]["regions"][_REGION]["md5"] == _PBF_DIGEST


def test_run_raises_a_clear_error_without_build_tree_having_run(tmp_path) -> None:
    empty_root = tmp_path / "no-state-yet"
    empty_root.mkdir()
    with pytest.raises(SystemExit, match="build_tree.sh"):
        gp.run([_REGION], root=empty_root, pinned_date="2026-09-01")


@pytest.mark.parametrize("region", ["../../etc/passwd", "/absolute", "has space", "UPPER"])
def test_invalid_region_paths_are_rejected(region, mirror_root) -> None:
    state = {"geofabrik": {"regions": {}}}
    with pytest.raises(gp.InvalidRegion):
        gp.pull_region(region=region, root=mirror_root, pinned_date="2026-09-01",
                        state=state, base_url="http://127.0.0.1:1")


# --- pull_index (issue #259) ------------------------------------------------


def test_pull_index_first_pull_downloads_and_records_etag(upstream, mirror_root) -> None:
    state = {"geofabrik": {}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    result = gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                            base_url=upstream.base_url, now=_clock(t0))

    assert result.action == "pulled"
    dest = mirror_root / "osm" / "geofabrik" / "2026-09-01" / "index-v1.json"
    assert dest.read_bytes() == _INDEX_BODY

    entry = state["geofabrik"]["index"]
    assert entry["etag"] == _INDEX_ETAG
    assert entry["pulled_at"] == gp._iso(t0)
    assert entry["checked_at"] == gp._iso(t0)
    assert entry["consecutive_failures"] == 0

    path, headers = upstream.request_log[-1]
    assert path == "/index-v1.json"
    assert headers["User-Agent"] == gp.PLOTLINES_USER_AGENT
    assert "If-None-Match" not in headers  # nothing cached yet on the first pull


def test_pull_index_second_run_within_cadence_makes_no_request(upstream, mirror_root) -> None:
    state = {"geofabrik": {}}
    t0 = datetime(2026, 9, 1, 12, 0, tzinfo=timezone.utc)
    t1 = t0 + timedelta(hours=3)  # well inside the 24h default cadence

    gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                  base_url=upstream.base_url, now=_clock(t0))
    requests_after_first = len(upstream.request_log)

    second = gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                            base_url=upstream.base_url, now=_clock(t1))

    assert second.action == "skipped_cadence"
    assert len(upstream.request_log) == requests_after_first


def test_pull_index_conditional_get_skips_body_once_cadence_has_elapsed(
    upstream, mirror_root
) -> None:
    state = {"geofabrik": {}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)
    t1 = t0 + timedelta(hours=25)  # past the 24h cadence window

    gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                  base_url=upstream.base_url, now=_clock(t0))
    upstream.request_log.clear()

    result = gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                            base_url=upstream.base_url, now=_clock(t1))

    assert result.action == "skipped_unchanged"
    # A real 304 came back from the fake upstream (not an internal
    # short-circuit) because the second request carried the etag recorded
    # from the first pull.
    assert len(upstream.request_log) == 1
    _path, headers = upstream.request_log[0]
    assert headers["If-None-Match"] == _INDEX_ETAG


def test_pull_index_rejects_a_response_that_is_not_valid_json(upstream, mirror_root) -> None:
    upstream.routes["/index-v1.json"] = _Route(200, b"<html>not json</html>")
    state = {"geofabrik": {}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    result = gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                            base_url=upstream.base_url, now=_clock(t0))

    assert result.action == "failed"
    assert "not valid JSON" in result.detail
    dest = mirror_root / "osm" / "geofabrik" / "2026-09-01" / "index-v1.json"
    assert not dest.exists()
    assert state["geofabrik"]["index"]["consecutive_failures"] == 1


def test_pull_index_repeated_failures_back_off_instead_of_hammering(
    upstream, mirror_root
) -> None:
    upstream.routes["/index-v1.json"] = _Route(500, b"")
    state = {"geofabrik": {}}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    first = gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                           base_url=upstream.base_url, now=_clock(t0))
    assert first.action == "failed"
    requests_after_first_failure = len(upstream.request_log)

    soon = gp.pull_index(root=mirror_root, pinned_date="2026-09-01", state=state,
                          base_url=upstream.base_url,
                          now=_clock(t0 + timedelta(minutes=30)))
    assert soon.action == "skipped_backoff"
    assert len(upstream.request_log) == requests_after_first_failure


def test_run_pulls_index_only_when_the_flag_is_passed(upstream, mirror_root) -> None:
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    default_results = gp.run([_REGION], root=mirror_root, pinned_date="2026-09-01",
                              base_url=upstream.base_url, now=_clock(t0))
    assert [r.region for r in default_results] == [_REGION]

    t1 = t0 + timedelta(hours=25)
    with_index = gp.run([_REGION], root=mirror_root, pinned_date="2026-09-01",
                         base_url=upstream.base_url, now=lambda: t1,
                         pull_index_too=True)

    assert [r.region for r in with_index] == [_REGION, "index-v1.json"]
    assert with_index[-1].action == "pulled"
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert state["geofabrik"]["index"]["etag"] == _INDEX_ETAG
