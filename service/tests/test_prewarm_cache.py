"""`deploy/elevation/prewarm_cache.py` — issue #450's cache pre-warm script.
Companion to `test_geofabrik_pull.py` (#258): same "load the standalone
deploy script by file path and exercise it against a real loopback HTTP
server" reasoning, since this script deploys the same way — stdlib only,
copied and run directly, never imported as part of `plotlines_core` or
`plotlines_service`.
"""

from __future__ import annotations

import http.server
import importlib.util
import sys
import threading
from pathlib import Path

import pytest

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[2] / "deploy" / "elevation" / "prewarm_cache.py"
)


def _load_prewarm_cache():
    spec = importlib.util.spec_from_file_location("prewarm_cache", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["prewarm_cache"] = module
    spec.loader.exec_module(module)
    return module


pc = _load_prewarm_cache()


class _FakeProxyHandler(http.server.BaseHTTPRequestHandler):
    """Stands in for the real elevation proxy's `/dem` endpoint. Class
    attributes are the fixture's dial: `RESPONSES` maps a bbox tuple to
    either a body (success) or an (status, detail) pair (failure); `CALLS`
    records every request path so a test can assert on hit count."""

    RESPONSES: dict = {}
    CALLS: list = []

    def do_GET(self) -> None:  # noqa: N802 - stdlib method name
        from urllib.parse import parse_qs, urlparse

        type(self).CALLS.append(self.path)
        query = parse_qs(urlparse(self.path).query)
        bbox = (
            float(query["west"][0]),
            float(query["south"][0]),
            float(query["east"][0]),
            float(query["north"][0]),
        )
        outcome = type(self).RESPONSES.get(bbox)
        if outcome is None:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            body = b'{"error": "no_such_fixture_bbox"}'
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if isinstance(outcome, tuple):
            status, detail = outcome
            self.send_response(status)
            if status == 503:
                self.send_header("Retry-After", "60")
            self.send_header("Content-Type", "application/json")
            body = detail.encode("utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/tiff")
        self.send_header("Content-Length", str(len(outcome)))
        self.end_headers()
        self.wfile.write(outcome)

    def log_message(self, format, *args):  # noqa: A002 - silence stdlib logging
        pass


@pytest.fixture()
def fake_proxy():
    _FakeProxyHandler.RESPONSES = {}
    _FakeProxyHandler.CALLS = []
    server = http.server.HTTPServer(("127.0.0.1", 0), _FakeProxyHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, _FakeProxyHandler
    finally:
        server.shutdown()
        thread.join()


def test_parse_bbox_accepts_four_comma_separated_floats() -> None:
    assert pc._parse_bbox("-82.75,35.35,-82.35,35.70") == (-82.75, 35.35, -82.35, 35.70)


@pytest.mark.parametrize("raw", ["1,2,3", "1,2,3,4,5", "a,b,c,d"])
def test_parse_bbox_rejects_malformed_input(raw: str) -> None:
    import argparse

    with pytest.raises(argparse.ArgumentTypeError):
        pc._parse_bbox(raw)


def test_prewarm_one_succeeds_and_reports_bytes(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    bbox = (-82.75, 35.35, -82.35, 35.70)
    handler_cls.RESPONSES[bbox] = b"fake-dem-bytes"
    base_url = f"http://127.0.0.1:{server.server_port}/dem"

    assert pc.prewarm_one(base_url, bbox) is True
    assert len(handler_cls.CALLS) == 1


def test_prewarm_one_does_not_raise_on_free_tier_exhausted(fake_proxy) -> None:
    # #304's 503 + Retry-After shape (service/tests/test_elevation_proxy.py) —
    # a script pre-warming a long bbox list must survive one failure and
    # keep going, never crash the whole run.
    server, handler_cls = fake_proxy
    bbox = (-83.10, 35.65, -82.70, 36.00)
    handler_cls.RESPONSES[bbox] = (503, '{"error": "free_tier_exhausted"}')
    base_url = f"http://127.0.0.1:{server.server_port}/dem"

    assert pc.prewarm_one(base_url, bbox) is False


def test_main_reports_nonzero_exit_when_any_bbox_fails(fake_proxy, capsys) -> None:
    server, handler_cls = fake_proxy
    ok_bbox = (-82.75, 35.35, -82.35, 35.70)
    bad_bbox = (-90.0, 41.0, -89.6, 41.3)
    handler_cls.RESPONSES[ok_bbox] = b"fake-dem-bytes"
    handler_cls.RESPONSES[bad_bbox] = (404, '{"error": "no_mirror_coverage"}')
    base_url = f"http://127.0.0.1:{server.server_port}/dem"

    exit_code = pc.main(
        [
            "--base-url",
            base_url,
            "--",
            "-82.75,35.35,-82.35,35.70",
            "-90.0,41.0,-89.6,41.3",
        ]
    )

    assert exit_code == 1
    out = capsys.readouterr()
    assert "1/2 bbox(es) failed" in out.err


def test_main_exits_zero_when_every_bbox_succeeds(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    bbox = (-82.75, 35.35, -82.35, 35.70)
    handler_cls.RESPONSES[bbox] = b"fake-dem-bytes"
    base_url = f"http://127.0.0.1:{server.server_port}/dem"

    assert pc.main(["--base-url", base_url, "--", "-82.75,35.35,-82.35,35.70"]) == 0


def test_repeat_request_for_the_same_bbox_hits_the_proxy_again_but_a_real_cache_would_absorb_it(
    fake_proxy,
) -> None:
    # This script has no cache of its own — it is a thin HTTP client, and
    # the caching guarantee it exercises against the real deployed proxy
    # lives in service/tests/test_elevation_proxy.py's
    # "cache absorbs a repeat request" coverage. This test only pins that
    # calling prewarm_one twice makes two HTTP requests (never client-side
    # memoized), so the real proxy's own cache is genuinely what's being
    # exercised end to end, not masked by a second cache layer here.
    server, handler_cls = fake_proxy
    bbox = (-82.75, 35.35, -82.35, 35.70)
    handler_cls.RESPONSES[bbox] = b"fake-dem-bytes"
    base_url = f"http://127.0.0.1:{server.server_port}/dem"

    pc.prewarm_one(base_url, bbox)
    pc.prewarm_one(base_url, bbox)

    assert len(handler_cls.CALLS) == 2
