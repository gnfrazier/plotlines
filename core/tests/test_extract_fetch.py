"""Unit tests for `plotlines_core.graph.extract_fetch` — issue #274 (Phase
3.2 of epic #272; docs/Plotlines_OSM_Acquisition_Review.md §8(1)-(2), §11.5).

`fetch_extract`/`ensure_extract` take `urlopen` as an injectable parameter,
the same shape `qa_proxy_client.qa_proxy_fetch`'s tests use for
`urllib.request.urlopen` — no real socket opens in this file. The HTTP
*wire* contract (the real `X-Plotlines-Clip-Source-Pin` header, the real
`404 no_mirror_coverage` body shape) is covered from the server side in
`service/tests/test_mirror_clip_server.py`; this file exercises the client
reading exactly the shapes that module actually sends.
"""

from __future__ import annotations

import io
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

import pytest

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.graph import extract_fetch as ef

_BBOX = (-82.6, 34.9, -81.9, 35.6)
_NOW = datetime(2026, 9, 6, tzinfo=timezone.utc)


class _FakeResponse:
    """Enough of `http.client.HTTPResponse` for `fetch_extract` to read: a
    context manager, `.headers.get`, and chunked `.read(n)`."""

    def __init__(self, body: bytes, headers: dict[str, str] | None = None):
        self._body = body
        self._pos = 0
        self.headers = headers or {}

    def read(self, n: int = -1) -> bytes:
        if n < 0:
            chunk = self._body[self._pos:]
            self._pos = len(self._body)
            return chunk
        chunk = self._body[self._pos:self._pos + n]
        self._pos += len(chunk)
        return chunk

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc) -> bool:
        return False


def _http_error(code: int, body: bytes, reason: str = "error") -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "http://mirror.example/clip", code, reason, None, io.BytesIO(body)
    )


# --- fetch_extract: happy path ---------------------------------------------

def test_fetch_extract_writes_the_body_under_the_pin_directory(tmp_path: Path) -> None:
    body = b"fake-pbf-bytes-0123456789"
    captured: dict = {}

    def _urlopen(req, timeout=None):
        captured["req"] = req
        captured["timeout"] = timeout
        return _FakeResponse(
            body,
            headers={ef.PIN_HEADER: "2026-09-01", "Content-Length": str(len(body))},
        )

    progress = ef.DownloadProgress()
    dest = ef.fetch_extract(
        _BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
        progress=progress, urlopen=_urlopen,
    )

    assert dest == CacheLayout(tmp_path).osm_extract(_BBOX, "2026-09-01")
    assert dest.read_bytes() == body
    assert progress.status == "downloading" or progress.ready  # settled by return
    assert progress.ready
    assert progress.bytes_downloaded == len(body)
    assert progress.total_bytes == len(body)
    assert progress.reused is False
    # No leftover `.part` temp file once the atomic rename lands.
    assert list(dest.parent.glob("*.part")) == []


def test_fetch_extract_requests_the_bbox_as_query_params(tmp_path: Path) -> None:
    captured: dict = {}

    def _urlopen(req, timeout=None):
        captured["url"] = req.full_url
        return _FakeResponse(b"x", headers={ef.PIN_HEADER: "2026-09-01"})

    ef.fetch_extract(_BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
                      urlopen=_urlopen)

    url = captured["url"]
    assert url.startswith("http://mirror.example/clip?")
    for coord in ("west=-82.6", "south=34.9", "east=-81.9", "north=35.6"):
        assert coord in url


def test_fetch_extract_strips_a_trailing_slash_from_mirror_url(tmp_path: Path) -> None:
    captured: dict = {}

    def _urlopen(req, timeout=None):
        captured["url"] = req.full_url
        return _FakeResponse(b"x", headers={ef.PIN_HEADER: "2026-09-01"})

    ef.fetch_extract(_BBOX, mirror_url="http://mirror.example/", cache_dir=tmp_path,
                      urlopen=_urlopen)

    assert "//clip" not in captured["url"].replace("http://", "")


def test_fetch_extract_identifies_itself_and_sends_the_client_key(tmp_path: Path) -> None:
    captured: dict = {}

    def _urlopen(req, timeout=None):
        captured["req"] = req
        return _FakeResponse(b"x", headers={ef.PIN_HEADER: "2026-09-01"})

    ef.fetch_extract(
        _BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
        client_key="s3cr3t", version="9.9.9", urlopen=_urlopen,
    )

    req = captured["req"]
    assert "Plotlines/9.9.9" in req.get_header("User-agent")
    assert req.get_header(ef.CLIENT_KEY_HEADER.capitalize()) == "s3cr3t"


def test_fetch_extract_sends_no_client_key_header_when_unconfigured(tmp_path: Path) -> None:
    captured: dict = {}

    def _urlopen(req, timeout=None):
        captured["req"] = req
        return _FakeResponse(b"x", headers={ef.PIN_HEADER: "2026-09-01"})

    ef.fetch_extract(_BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
                      urlopen=_urlopen)

    assert captured["req"].get_header(ef.CLIENT_KEY_HEADER.capitalize()) is None


# --- fetch_extract: honest failure surface (§248's contract extended) -----

def test_fetch_extract_raises_no_extract_coverage_on_404(tmp_path: Path) -> None:
    def _urlopen(req, timeout=None):
        raise _http_error(
            404, b'{"detail": {"error": "no_mirror_coverage", "message": "nope"}}'
        )

    progress = ef.DownloadProgress()
    with pytest.raises(ef.NoExtractCoverage) as excinfo:
        ef.fetch_extract(_BBOX, mirror_url="http://mirror.example",
                          cache_dir=tmp_path, progress=progress, urlopen=_urlopen)

    assert "doesn't have OSM data for this area" in str(excinfo.value)
    assert progress.status == "failed"
    # Never reads as "no data here" being confused with an outage, and vice
    # versa — the two exception types must stay distinct.
    assert not isinstance(excinfo.value, ef.MirrorUnreachable)


def test_fetch_extract_raises_mirror_unreachable_on_connection_failure(tmp_path: Path) -> None:
    def _urlopen(req, timeout=None):
        raise urllib.error.URLError("connection refused")

    progress = ef.DownloadProgress()
    with pytest.raises(ef.MirrorUnreachable) as excinfo:
        ef.fetch_extract(_BBOX, mirror_url="http://mirror.example",
                          cache_dir=tmp_path, progress=progress, urlopen=_urlopen)

    assert "Couldn't reach the Plotlines map-data mirror" in str(excinfo.value)
    assert progress.status == "failed"


@pytest.mark.parametrize("code,reason", [(401, "unauthorized_client"), (429, "rate_limited"),
                                          (500, "clip_failed")])
def test_fetch_extract_raises_mirror_unreachable_on_non_coverage_errors(
    tmp_path: Path, code: int, reason: str,
) -> None:
    def _urlopen(req, timeout=None):
        raise _http_error(code, f'{{"detail": {{"error": "{reason}", "message": "x"}}}}'.encode())

    with pytest.raises(ef.MirrorUnreachable) as excinfo:
        ef.fetch_extract(_BBOX, mirror_url="http://mirror.example",
                          cache_dir=tmp_path, urlopen=_urlopen)

    assert str(code) in str(excinfo.value)


def test_fetch_extract_raises_mirror_unreachable_when_pin_header_missing(tmp_path: Path) -> None:
    def _urlopen(req, timeout=None):
        return _FakeResponse(b"x", headers={})  # no PIN_HEADER

    progress = ef.DownloadProgress()
    with pytest.raises(ef.MirrorUnreachable) as excinfo:
        ef.fetch_extract(_BBOX, mirror_url="http://mirror.example",
                          cache_dir=tmp_path, progress=progress, urlopen=_urlopen)

    assert "naming the" in str(excinfo.value)
    assert progress.status == "failed"


def test_fetch_extract_leaves_no_partial_file_on_an_interrupted_download(tmp_path: Path) -> None:
    class _DyingResponse(_FakeResponse):
        def read(self, n: int = -1) -> bytes:
            if self._pos == 0:
                self._pos = 1
                return b"partial-bytes"
            raise ConnectionError("connection reset")

    def _urlopen(req, timeout=None):
        return _DyingResponse(b"never-fully-read", headers={ef.PIN_HEADER: "2026-09-01"})

    progress = ef.DownloadProgress()
    with pytest.raises(ConnectionError):
        ef.fetch_extract(_BBOX, mirror_url="http://mirror.example",
                          cache_dir=tmp_path, progress=progress, urlopen=_urlopen)

    assert progress.status == "failed"
    dest = CacheLayout(tmp_path).osm_extract(_BBOX, "2026-09-01")
    assert not dest.exists()
    assert list(dest.parent.glob("*.part")) == []


# --- find_reusable_extract / ensure_extract (§11.5's mitigation) ----------

def _seed_extract(cache_dir: Path, bbox, pin: str, body: bytes = b"seed") -> Path:
    path = CacheLayout(cache_dir).osm_extract(bbox, pin)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)
    return path


def test_find_reusable_extract_returns_none_when_nothing_cached(tmp_path: Path) -> None:
    assert ef.find_reusable_extract(_BBOX, tmp_path, now=_NOW) is None


def test_find_reusable_extract_returns_a_pin_within_max_age(tmp_path: Path) -> None:
    seeded = _seed_extract(tmp_path, _BBOX, "2026-08-25")  # 12 days before _NOW
    assert ef.find_reusable_extract(_BBOX, tmp_path, now=_NOW) == seeded


def test_find_reusable_extract_ignores_a_pin_older_than_max_age(tmp_path: Path) -> None:
    _seed_extract(tmp_path, _BBOX, "2026-01-01")  # far past 45 days
    assert ef.find_reusable_extract(_BBOX, tmp_path, now=_NOW) is None


def test_find_reusable_extract_respects_a_custom_max_age(tmp_path: Path) -> None:
    _seed_extract(tmp_path, _BBOX, "2026-08-25")  # 12 days before _NOW
    assert ef.find_reusable_extract(_BBOX, tmp_path, now=_NOW, max_age_days=5.0) is None


def test_find_reusable_extract_ignores_a_different_bbox(tmp_path: Path) -> None:
    other_bbox = (-83.0, 35.0, -81.9, 35.5)
    _seed_extract(tmp_path, other_bbox, "2026-09-01")
    assert ef.find_reusable_extract(_BBOX, tmp_path, now=_NOW) is None


def test_find_reusable_extract_prefers_the_freshest_qualifying_pin(tmp_path: Path) -> None:
    older = _seed_extract(tmp_path, _BBOX, "2026-08-01", body=b"older")
    newer = _seed_extract(tmp_path, _BBOX, "2026-08-28", body=b"newer")
    assert older != newer
    assert ef.find_reusable_extract(_BBOX, tmp_path, now=_NOW) == newer


def test_ensure_extract_reuses_a_fresh_cached_extract_without_a_network_call(
    tmp_path: Path,
) -> None:
    seeded = _seed_extract(tmp_path, _BBOX, "2026-08-25", body=b"already-here")

    def _urlopen(req, timeout=None):
        raise AssertionError("ensure_extract must not fetch when a fresh extract is cached")

    progress = ef.DownloadProgress()
    result = ef.ensure_extract(
        _BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
        progress=progress, now=_NOW, urlopen=_urlopen,
    )

    assert result == seeded
    assert progress.ready
    assert progress.reused is True
    assert progress.bytes_downloaded == len(b"already-here")


def test_ensure_extract_fetches_when_nothing_reusable(tmp_path: Path) -> None:
    called = {}

    def _urlopen(req, timeout=None):
        called["yes"] = True
        return _FakeResponse(b"fresh-bytes", headers={ef.PIN_HEADER: "2026-09-01"})

    progress = ef.DownloadProgress()
    result = ef.ensure_extract(
        _BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
        progress=progress, now=_NOW, urlopen=_urlopen,
    )

    assert called == {"yes": True}
    assert result == CacheLayout(tmp_path).osm_extract(_BBOX, "2026-09-01")
    assert progress.reused is False


def test_ensure_extract_fetches_when_the_cached_pin_is_stale(tmp_path: Path) -> None:
    _seed_extract(tmp_path, _BBOX, "2026-01-01")  # far past 45 days

    def _urlopen(req, timeout=None):
        return _FakeResponse(b"fresh-bytes", headers={ef.PIN_HEADER: "2026-09-01"})

    result = ef.ensure_extract(
        _BBOX, mirror_url="http://mirror.example", cache_dir=tmp_path,
        now=_NOW, urlopen=_urlopen,
    )

    assert result == CacheLayout(tmp_path).osm_extract(_BBOX, "2026-09-01")


# --- DownloadProgress.to_dict() (FR121's `/health` shape) ------------------

def test_download_progress_pending_shape() -> None:
    assert ef.DownloadProgress().to_dict() == {"ready": False, "reason": "pending"}


def test_download_progress_downloading_shape_with_a_known_total() -> None:
    p = ef.DownloadProgress(status="downloading", bytes_downloaded=50, total_bytes=200,
                             detail="requesting mirror clip")
    d = p.to_dict()
    assert d["ready"] is False
    assert d["bytes_downloaded"] == 50
    assert d["total_bytes"] == 200
    assert d["progress"] == 0.25


def test_download_progress_downloading_shape_with_no_known_total() -> None:
    # FR121: never fabricate a total/percentage when the mirror didn't send
    # Content-Length.
    p = ef.DownloadProgress(status="downloading", bytes_downloaded=50, total_bytes=None)
    d = p.to_dict()
    assert "total_bytes" not in d
    assert "progress" not in d
    assert d["bytes_downloaded"] == 50


def test_download_progress_ready_shape() -> None:
    p = ef.DownloadProgress(status="ready", bytes_downloaded=999, total_bytes=999)
    assert p.to_dict() == {"ready": True}


def test_download_progress_reused_shape() -> None:
    p = ef.DownloadProgress(status="ready", reused=True)
    assert p.to_dict() == {"ready": True, "reused": True}


def test_download_progress_failed_shape() -> None:
    p = ef.DownloadProgress(status="failed", detail="no_mirror_coverage")
    assert p.to_dict() == {"ready": False, "reason": "failed:no_mirror_coverage"}
