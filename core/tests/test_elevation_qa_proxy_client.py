"""QA-only elevation proxy client (companion to epic #264, not #148).

`qa_proxy_fetch` is the sidecar-side `Fetcher` that talks to the Pi5 caching
elevation proxy (`plotlines_service.elevation_proxy`) instead of
OpenTopography directly. See `core/plotlines_core/elevation/qa_proxy_client.py`.
"""

from __future__ import annotations

import io
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from plotlines_core.elevation import qa_proxy_client

_BBOX = (10.0, 46.0, 14.0, 50.0)


def test_qa_proxy_fetch_builds_the_expected_query_and_writes_the_body(
    tmp_path: Path, monkeypatch
) -> None:
    captured: dict = {}

    def _fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["timeout"] = timeout
        return io.BytesIO(b"fake-geotiff-bytes")

    monkeypatch.setattr(qa_proxy_client.urllib.request, "urlopen", _fake_urlopen)

    dest = tmp_path / "out.tif"
    result = qa_proxy_client.qa_proxy_fetch("http://pi5.local/dem", _BBOX, dest)

    assert result == dest
    assert dest.read_bytes() == b"fake-geotiff-bytes"
    # Atomic write: no leftover .part file after a successful fetch.
    assert list(tmp_path.glob("*.part")) == []

    parts = urlsplit(captured["url"])
    assert parts.scheme == "http"
    assert parts.netloc == "pi5.local"
    assert parts.path == "/dem"
    query = parse_qs(parts.query)
    assert query["west"] == ["10.0"]
    assert query["south"] == ["46.0"]
    assert query["east"] == ["14.0"]
    assert query["north"] == ["50.0"]


def test_qa_proxy_fetch_carries_no_api_key(tmp_path: Path, monkeypatch) -> None:
    captured: dict = {}

    def _fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        return io.BytesIO(b"x")

    monkeypatch.setattr(qa_proxy_client.urllib.request, "urlopen", _fake_urlopen)
    qa_proxy_client.qa_proxy_fetch("http://pi5.local/dem", _BBOX, tmp_path / "out.tif")

    query = parse_qs(urlsplit(captured["url"]).query)
    assert "API_Key" not in query


def test_qa_proxy_fetch_propagates_a_transport_failure(tmp_path: Path, monkeypatch) -> None:
    def _fake_urlopen(req, timeout=None):
        raise OSError("connection refused")

    monkeypatch.setattr(qa_proxy_client.urllib.request, "urlopen", _fake_urlopen)

    with pytest.raises(OSError):
        qa_proxy_client.qa_proxy_fetch("http://pi5.local/dem", _BBOX, tmp_path / "out.tif")
    # Nothing partial left behind on failure.
    assert not (tmp_path / "out.tif").exists()


def test_qa_proxy_fetch_identifies_itself_as_plotlines(tmp_path: Path, monkeypatch) -> None:
    """Every outbound request carries the Plotlines UA with its contact URL,
    never urllib's `Python-urllib/3.x` default."""
    captured: dict = {}

    def _fake_urlopen(req, timeout=None):
        captured["ua"] = req.get_header("User-agent")
        return io.BytesIO(b"x")

    monkeypatch.setattr(qa_proxy_client.urllib.request, "urlopen", _fake_urlopen)
    qa_proxy_client.qa_proxy_fetch("http://pi5.local/dem", _BBOX, tmp_path / "out.tif")

    assert captured["ua"].startswith("Plotlines/")
    assert "(+https://" in captured["ua"]


def test_qa_proxy_fetch_leaves_no_part_file_when_the_body_dies_mid_transfer(
    tmp_path: Path, monkeypatch,
) -> None:
    class _Dying(io.RawIOBase):
        def readinto(self, buf):
            raise ConnectionResetError("reset mid-body")

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    monkeypatch.setattr(qa_proxy_client.urllib.request, "urlopen",
                        lambda req, timeout=None: _Dying())

    with pytest.raises(ConnectionResetError):
        qa_proxy_client.qa_proxy_fetch("http://pi5.local/dem", _BBOX, tmp_path / "out.tif")
    assert list(tmp_path.iterdir()) == []


def test_a_202_from_the_proxy_is_a_wait_and_writes_nothing(tmp_path: Path, monkeypatch) -> None:
    """#520: the proxy on the fill contract answers a miss with a JSON fill
    status. It must never land in the DEM cache as a raster."""

    class _Accepted(io.BytesIO):
        status = 202
        headers = {"Retry-After": "86000"}

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    body = (b'{"state": "fetching", "fill": {"fill_id": "f1", "state": "fetching", '
            b'"detail": "allowance spent", "retry_after_s": 86000}}')
    monkeypatch.setattr(qa_proxy_client.urllib.request, "urlopen",
                        lambda req, timeout=None: _Accepted(body))

    with pytest.raises(qa_proxy_client.ElevationFilling) as excinfo:
        qa_proxy_client.qa_proxy_fetch("http://pi5.local/dem", _BBOX, tmp_path / "out.tif")
    assert excinfo.value.fill_id == "f1"
    assert excinfo.value.retry_after_s == 86000
    assert excinfo.value.detail == "allowance spent"
    assert list(tmp_path.iterdir()) == []
