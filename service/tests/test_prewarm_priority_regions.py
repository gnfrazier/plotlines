"""`deploy/elevation/prewarm_priority_regions.py` — the live orchestrator
for issue #450's priority-region pre-warm run. Same "load the standalone
deploy script by file path and exercise it against a real loopback HTTP
server" pattern as `test_prewarm_cache.py`, extended with a fake `/health`
endpoint since the orchestrator's control flow depends on it.
"""

from __future__ import annotations

import http.server
import importlib.util
import json
import sys
import threading
from pathlib import Path
from urllib.parse import urlparse

import pytest

_ELEVATION_DIR = Path(__file__).resolve().parents[2] / "deploy" / "elevation"


def _load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, _ELEVATION_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# prewarm_priority_regions.py does `import prewarm_cache` as a sibling import
# (it inserts its own directory onto sys.path), so loading it by file path
# still resolves correctly as long as deploy/elevation/ is genuinely on
# sys.path -- which it is, since that's where both files live.
sys.path.insert(0, str(_ELEVATION_DIR))
_load_module("prewarm_cache", "prewarm_cache.py")
_load_module("priority_regions", "priority_regions.py")
ppr = _load_module("prewarm_priority_regions", "prewarm_priority_regions.py")


class _FakeProxyHandler(http.server.BaseHTTPRequestHandler):
    """Stands in for the real elevation proxy's `/dem` and `/health`
    endpoints. `CALL_COUNT` counts `/dem` requests only (matching what the
    real ledger spends against); `EXHAUST_AFTER` (0-based) is the index of
    the first `/dem` call that gets refused with 503 -- `None` means never.
    `/health`'s `remaining_calls_24h` is derived from the same counter so a
    test can assert on the reported budget without a second source of
    truth."""

    CALL_COUNT = 0
    EXHAUST_AFTER: int | None = None
    CEILING = 50

    def do_GET(self) -> None:  # noqa: N802 - stdlib method name
        path = urlparse(self.path).path
        if path == "/health":
            # Only calls before EXHAUST_AFTER actually "spend" against the
            # ceiling -- a refused call (idx >= EXHAUST_AFTER) never records,
            # matching the real ledger (CallLedger.record only runs when
            # authorize() succeeded).
            exhaust_after = type(self).EXHAUST_AFTER
            spent = (
                min(type(self).CALL_COUNT, exhaust_after)
                if exhaust_after is not None
                else type(self).CALL_COUNT
            )
            remaining = max(0, type(self).CEILING - spent)
            body = json.dumps(
                {"ready": True, "remaining_calls_24h": remaining, "next_free_at": None}
            ).encode("utf-8")
            self._send(200, body, "application/json")
            return

        idx = type(self).CALL_COUNT
        type(self).CALL_COUNT += 1
        if type(self).EXHAUST_AFTER is not None and idx >= type(self).EXHAUST_AFTER:
            # FastAPI's real HTTPException(detail={"error": ...}) wire shape
            # (elevation_proxy.py) — {"detail": {...}}, not a flat
            # {"error": ...}; a flat fixture here previously masked a
            # classifier bug (issue #459) that made run() never recognize
            # real exhaustion and grind through the whole candidate list.
            body = (
                b'{"detail": {"error": "free_tier_exhausted", '
                b'"message": "ceiling reached"}}'
            )
            self.send_response(503)
            self.send_header("Retry-After", "60")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._send(200, b"fake-dem-bytes", "image/tiff")

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002 - silence stdlib logging
        pass


@pytest.fixture()
def fake_proxy():
    _FakeProxyHandler.CALL_COUNT = 0
    _FakeProxyHandler.EXHAUST_AFTER = None
    _FakeProxyHandler.CEILING = 50
    server = http.server.HTTPServer(("127.0.0.1", 0), _FakeProxyHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, _FakeProxyHandler
    finally:
        server.shutdown()
        thread.join()


def test_run_stops_on_the_first_natural_exhaustion_and_skips_the_rest(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    handler_cls.EXHAUST_AFTER = 3  # calls 0,1,2 succeed (nc, brp x2); call 3 (skyline) is refused
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    report = ppr.run(proxy_root, widen_rounds=1, min_delay_s=0, max_delay_s=0)

    assert report.ceiling_confirmed is True
    assert report.ceiling_confirmed_via == "natural"
    attempted = [a for a in report.attempts if a.result is not None]
    skipped = [a for a in report.attempts if a.result is None]
    assert len(attempted) == 4  # nc, brp x2, skyline all OK/refused -- see below
    assert attempted[-1].result.outcome is ppr.prewarm_cache.PrewarmOutcome.EXHAUSTED
    assert all(
        a.result.outcome is ppr.prewarm_cache.PrewarmOutcome.OK for a in attempted[:-1]
    )
    assert len(skipped) > 0
    assert all(a.skipped_reason == "ceiling exhausted earlier in this run" for a in skipped)
    # No calls happened beyond the one that triggered the refusal.
    assert handler_cls.CALL_COUNT == 4


def test_run_falls_back_to_widened_pct_then_synthetic_confirmation(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    # base priority list is 9 calls (nc=1, brp=2, skyline=1, bwcaw=1,
    # yellowstone=1, champlain=1, pct=2); a single widen round at 2x adds 2
    # more (verified empirically in priority_regions.py's own module
    # comment) -- so the 12th call overall is the synthetic confirmation.
    handler_cls.EXHAUST_AFTER = 11
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    report = ppr.run(proxy_root, widen_rounds=1, min_delay_s=0, max_delay_s=0)

    assert report.ceiling_confirmed is True
    assert report.ceiling_confirmed_via == "synthetic"
    assert handler_cls.CALL_COUNT == 12
    synthetic_attempts = [a for a in report.attempts if a.candidate.region_key == "synthetic"]
    assert len(synthetic_attempts) == 1
    assert synthetic_attempts[0].result.outcome is ppr.prewarm_cache.PrewarmOutcome.EXHAUSTED


def test_run_reports_not_confirmed_when_nothing_ever_exhausts(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    handler_cls.EXHAUST_AFTER = None  # every call, including the synthetic one, succeeds
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    report = ppr.run(proxy_root, widen_rounds=1, min_delay_s=0, max_delay_s=0)

    assert report.ceiling_confirmed is False
    assert report.ceiling_confirmed_via is None
    assert all(
        a.result is None or a.result.outcome is ppr.prewarm_cache.PrewarmOutcome.OK
        for a in report.attempts
    )


def test_run_attempts_only_the_first_candidate_when_budget_is_already_zero(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    handler_cls.EXHAUST_AFTER = 0  # even the very first /dem call is refused
    handler_cls.CEILING = 0  # /health reports remaining_calls_24h = 0 up front
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    report = ppr.run(proxy_root, widen_rounds=3, min_delay_s=0, max_delay_s=0)

    assert report.health_before["remaining_calls_24h"] == 0
    assert report.ceiling_confirmed is True
    assert report.ceiling_confirmed_via == "natural"
    assert handler_cls.CALL_COUNT == 1
    attempted = [a for a in report.attempts if a.result is not None]
    skipped = [a for a in report.attempts if a.result is None]
    assert len(attempted) == 1
    assert len(skipped) > 0
    assert all(
        a.skipped_reason == "budget already exhausted before this run started" for a in skipped
    )


def test_dry_run_makes_no_network_calls(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    exit_code = ppr.main(["--proxy-root", proxy_root, "--dry-run"])

    assert exit_code == 0
    assert handler_cls.CALL_COUNT == 0


def test_main_refuses_a_live_run_without_yes(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    exit_code = ppr.main(["--proxy-root", proxy_root])

    assert exit_code == 2
    assert handler_cls.CALL_COUNT == 0


def test_main_exit_code_reflects_ceiling_confirmation(fake_proxy) -> None:
    server, handler_cls = fake_proxy
    handler_cls.EXHAUST_AFTER = 3
    proxy_root = f"http://127.0.0.1:{server.server_port}"

    exit_code = ppr.main(
        [
            "--proxy-root", proxy_root, "--yes",
            "--widen-rounds", "1", "--min-delay-s", "0", "--max-delay-s", "0",
        ]
    )

    assert exit_code == 0
