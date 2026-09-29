"""The sidecar's client for the mirror's fill contract — issue #521 (epic
#516, ARCH D67; the contract itself is `service/plotlines_service/
mirror_fill.py`, #517).

`request_fill` asks the mirror to fill an area (`POST /fill`) and
`fill_status` polls one (`GET /fill/{id}`). Both are blocking HTTP calls,
so **neither may run on a request thread** (ARCH §8.6, D66): the sidecar
calls them only from a region build phase, which runs on its own pool behind
its own deadline. `test_request_thread_contract.py` fails any endpoint
handler that calls them directly.

A transport failure is reported as a `failed:unreachable` answer rather than
raised — transient, like every other mirror failure (D66: never latched).
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass

from .osm_identity import osm_user_agent

CLIENT_KEY_HEADER = "X-Plotlines-Client-Key"

#: Socket timeout on a fill call. The mirror answers these from local state
#: (a plan and an enqueue, or a table read), so seconds is generous; the
#: caller's own phase deadline covers the DNS leg this cannot (#488).
FILL_CALL_TIMEOUT_S = 15.0

FETCHING = "fetching"
READY = "ready"
NO_UPSTREAM_COVERAGE = "no_upstream_coverage"


@dataclass(frozen=True)
class FillAnswer:
    """One answer on the contract: `state` is `fetching` / `ready` /
    `no_upstream_coverage` / `failed:<reason>`."""

    state: str
    fill_id: str | None = None
    retry_after_s: float | None = None
    detail: str = ""
    progress: float | None = None

    @property
    def fetching(self) -> bool:
        return self.state == FETCHING

    @property
    def failed(self) -> bool:
        return self.state.startswith("failed:")

    @classmethod
    def from_json(cls, body: dict, *, retry_after: str | None = None) -> "FillAnswer":
        retry = body.get("retry_after_s")
        if retry is None and retry_after and retry_after.isdigit():
            retry = float(retry_after)
        return cls(state=str(body.get("state") or "failed:malformed_answer"),
                   fill_id=body.get("fill_id"), retry_after_s=retry,
                   detail=str(body.get("detail") or ""), progress=body.get("progress"))


def _call(req: urllib.request.Request, *, urlopen) -> FillAnswer:
    try:
        with urlopen(req, timeout=FILL_CALL_TIMEOUT_S) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            return FillAnswer.from_json(body, retry_after=resp.headers.get("Retry-After"))
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read().decode("utf-8")).get("detail")
        except (ValueError, UnicodeDecodeError, AttributeError):
            detail = None
        code = detail.get("error") if isinstance(detail, dict) else None
        message = detail.get("message") if isinstance(detail, dict) else str(exc)
        retry = exc.headers.get("Retry-After") if exc.headers else None
        return FillAnswer(state=f"failed:{code or f'http_{exc.code}'}",
                          retry_after_s=float(retry) if retry and retry.isdigit() else None,
                          detail=message or "")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return FillAnswer(state="failed:unreachable", detail=str(exc))


def _headers(client_key: str | None, version: str | None) -> dict:
    headers = {"User-Agent": osm_user_agent(version), "Content-Type": "application/json"}
    if client_key:
        headers[CLIENT_KEY_HEADER] = client_key
    return headers


def request_fill(mirror_url: str, layer: str, bbox: tuple[float, float, float, float], *,
                 client_key: str | None = None, version: str | None = None,
                 urlopen=urllib.request.urlopen) -> FillAnswer:
    """`POST {mirror_url}/fill` — ask for `layer` over `bbox`. Off the
    request thread only (see the module docstring)."""
    west, south, east, north = bbox
    body = json.dumps({"layer": layer, "west": west, "south": south,
                       "east": east, "north": north}).encode("utf-8")
    req = urllib.request.Request(f"{mirror_url.rstrip('/')}/fill", data=body,
                                 headers=_headers(client_key, version), method="POST")
    return _call(req, urlopen=urlopen)


def fill_status(mirror_url: str, fill_id: str, *, client_key: str | None = None,
                version: str | None = None, urlopen=urllib.request.urlopen) -> FillAnswer:
    """`GET {mirror_url}/fill/{fill_id}`. Off the request thread only."""
    req = urllib.request.Request(f"{mirror_url.rstrip('/')}/fill/{fill_id}",
                                 headers=_headers(client_key, version))
    return _call(req, urlopen=urlopen)
