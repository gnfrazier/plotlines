"""Strand 1 — how a share token is carried without leaking.

A live, hermetic demonstration: a stdlib HTTP server records every request
line and header it receives into an in-memory access log (the thing a real
edge / CDN / app tier would write to disk). Four carrier strategies each
fetch a reading page and then a subresource the way a browser would, and we
read the access log back to see what the token did.

The one browser behaviour we cannot exercise from `urllib` is the URL
**fragment** (`#...`): by RFC 3986 §3.5 the fragment is never sent to the
server, and every browser strips it from the `Referer` of outbound requests.
The `fragment` strategy models that by construction (the client never puts
the token after `#` on the wire) and the assertions treat browser history as
the residual exposure that a fragment does NOT solve.

Run standalone:  python3 carriers.py
"""

from __future__ import annotations

import hashlib
import hmac
import http.client
import http.server
import json
import threading
import urllib.request
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse, parse_qs

SHARE_TOKEN = "pl_" + "S3cr3tShareTokenDoNotLog_0000000000"
_HMAC_KEY = b"spike-f-demo-key-not-a-real-secret"


# --------------------------------------------------------------------------
# server

class _Handler(http.server.BaseHTTPRequestHandler):
    server_version = "spikeF/0"
    protocol_version = "HTTP/1.1"

    def log_message(self, *_a: Any) -> None:  # silence stderr
        pass

    def _record(self) -> None:
        parsed = urlparse(self.path)
        self.server.access_log.append({  # type: ignore[attr-defined]
            "method": self.command,
            "path": parsed.path,
            "query": parsed.query,
            "referer": self.headers.get("Referer", ""),
            "cookie": self.headers.get("Cookie", ""),
            "user_agent": self.headers.get("User-Agent", ""),
        })

    def do_GET(self) -> None:  # noqa: N802
        self._record()
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        # exchange-for-cookie: first hit carries the token, we set an opaque
        # HttpOnly cookie and redirect to a tokenless URL.
        if parsed.path.startswith("/read/") or "t" in qs:
            raw = (parsed.path.split("/read/", 1)[-1]
                   if parsed.path.startswith("/read/") else qs["t"][0])
            if raw == SHARE_TOKEN and self.headers.get("X-Exchange") == "1":
                opaque = hmac.new(_HMAC_KEY, raw.encode(), hashlib.sha256).hexdigest()[:24]
                body = b"redirecting"
                self.send_response(302)
                self.send_header("Location", f"/j/{opaque}")
                self.send_header(
                    "Set-Cookie",
                    f"__Host-pl_read={opaque}; Path=/; HttpOnly; Secure; "
                    "SameSite=Strict; Max-Age=1800",
                )
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

        body = b"<!doctype html><title>trip</title><p>the journey</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class _Server(http.server.ThreadingHTTPServer):
    def __init__(self, addr: tuple[str, int]) -> None:
        super().__init__(addr, _Handler)
        self.access_log: list[dict[str, str]] = []


@dataclass
class Demo:
    server: _Server
    thread: threading.Thread

    @property
    def base(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    @property
    def log(self) -> list[dict[str, str]]:
        return self.server.access_log

    def stop(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)


def start() -> Demo:
    srv = _Server(("127.0.0.1", 0))
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    return Demo(srv, th)


def _get(url: str, headers: dict[str, str] | None = None) -> tuple[int, dict[str, str]]:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req) as resp:  # noqa: S310 (localhost)
        return resp.status, dict(resp.headers)


# --------------------------------------------------------------------------
# carrier strategies — each returns (name, verdict dict)

def run_all() -> dict[str, Any]:
    demo = start()
    try:
        results: dict[str, Any] = {}

        # 1. token in PATH ----------------------------------------------------
        base_len = len(demo.log)
        _get(f"{demo.base}/read/{SHARE_TOKEN}")
        # browser then fetches a subresource, sending the page URL as Referer
        _get(f"{demo.base}/app.js", {"Referer": f"{demo.base}/read/{SHARE_TOKEN}"})
        rows = demo.log[base_len:]
        results["path"] = _verdict(rows, carrier="path")

        # 2. token in QUERY -------------------------------------------------
        base_len = len(demo.log)
        _get(f"{demo.base}/read?t={SHARE_TOKEN}")
        _get(f"{demo.base}/app.js", {"Referer": f"{demo.base}/read?t={SHARE_TOKEN}"})
        rows = demo.log[base_len:]
        results["query"] = _verdict(rows, carrier="query")

        # 3. token in FRAGMENT --------------------------------------------
        # the wire never sees the token: page is /read, fragment is client-only,
        # and the browser strips '#...' from the outbound Referer.
        base_len = len(demo.log)
        _get(f"{demo.base}/read")
        _get(f"{demo.base}/app.js", {"Referer": f"{demo.base}/read"})
        rows = demo.log[base_len:]
        v = _verdict(rows, carrier="fragment")
        v["residual_exposure"] = ["browser_history", "clipboard_when_copied"]
        results["fragment"] = v

        # 4. EXCHANGE-FOR-COOKIE ----------------------------------------
        base_len = len(demo.log)
        # one-time exchange hit carries the token; read the 302 directly with
        # http.client so the redirect is NOT followed and Set-Cookie survives.
        host, port = demo.server.server_address[:2]
        conn = http.client.HTTPConnection(host, port)
        conn.request("GET", f"/read/{SHARE_TOKEN}", headers={"X-Exchange": "1"})
        raw_resp = conn.getresponse()
        set_cookie = raw_resp.getheader("Set-Cookie", "") or ""
        raw_resp.read()
        conn.close()
        cookie_val = set_cookie.split(";", 1)[0]
        # every subsequent request carries only the opaque cookie
        _get(f"{demo.base}/j/abc", {"Cookie": cookie_val})
        _get(f"{demo.base}/app.js",
             {"Cookie": cookie_val, "Referer": f"{demo.base}/j/abc"})
        rows = demo.log[base_len:]
        v = _verdict(rows, carrier="exchange")
        v["set_cookie"] = set_cookie
        v["cookie_httponly"] = "HttpOnly" in set_cookie
        v["cookie_samesite"] = "SameSite=Strict" in set_cookie
        v["cookie_is_token"] = SHARE_TOKEN in set_cookie
        v["token_hits_in_log"] = sum(
            1 for r in rows
            if SHARE_TOKEN in r["path"] or SHARE_TOKEN in r["query"]
            or SHARE_TOKEN in r["referer"])
        results["exchange"] = v

        # stabilise the dump: the ephemeral test port must not churn the
        # committed results file.
        blob = json.dumps({"share_token": SHARE_TOKEN, "carriers": results})
        blob = blob.replace(demo.base, "http://reader.example")
        return json.loads(blob)
    finally:
        demo.stop()


def _verdict(rows: list[dict[str, str]], carrier: str) -> dict[str, Any]:
    def leaks(where: str) -> bool:
        return any(SHARE_TOKEN in r[where] for r in rows)
    return {
        "carrier": carrier,
        "requests": len(rows),
        "token_in_request_path": leaks("path"),
        "token_in_query_string": leaks("query"),
        "token_in_referer_header": leaks("referer"),
        "access_log_lines": [
            _clf(r) for r in rows
        ],
    }


def _clf(r: dict[str, str]) -> str:
    q = f"?{r['query']}" if r["query"] else ""
    return (f'{r["method"]} {r["path"]}{q} '
            f'referer="{r["referer"]}" cookie="{r["cookie"]}"')


if __name__ == "__main__":
    print(json.dumps(run_all(), indent=2))
