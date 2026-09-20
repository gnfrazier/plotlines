"""Serve the harness and range-proxy the corridor archive from the mirror.

Why a proxy at all: MapLibre reads a PMTiles archive with HTTP `Range`
requests from the page's origin, and the mirror's Caddy config
(`deploy/mirror/Caddyfile`) sends no `Access-Control-Allow-Origin` — it was
built for the sidecar's `http_range_source` and the Flutter client, neither
of which is a browser. So a page served from `localhost` is refused by CORS
before the first byte. Putting the archive behind the *same* origin as the
page sidesteps that without touching the mirror (README §5 records it as a
finding for any future web client, not something this spike fixes).

The proxy forwards `Range` verbatim and returns the mirror's `206` with its
`Content-Range` intact, which is the whole contract `pmtiles.js` needs. No
caching, no rewriting, no CORS headers of its own — same origin needs none.

    python3 harness/serve.py [--port 8765] [--mirror URL]
    → http://localhost:8765/
"""

from __future__ import annotations

import argparse
import functools
import http.server
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_MIRROR = (
    "http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles"
)
PROXY_PATH = "/corridor.pmtiles"
# Same discipline as every other Plotlines request to the mirror: identify.
USER_AGENT = "plotlines-spike-k/1 (+https://github.com/gnfrazier/plotlines/issues/461)"


class Handler(http.server.SimpleHTTPRequestHandler):
    mirror_url = DEFAULT_MIRROR

    def do_GET(self):  # noqa: N802 — stdlib naming
        if self.path.split("?", 1)[0] == PROXY_PATH:
            return self.proxy()
        return super().do_GET()

    def do_HEAD(self):  # noqa: N802
        if self.path.split("?", 1)[0] == PROXY_PATH:
            return self.proxy(head=True)
        return super().do_HEAD()

    def proxy(self, head: bool = False) -> None:
        req = urllib.request.Request(self.mirror_url, method="HEAD" if head else "GET")
        req.add_header("User-Agent", USER_AGENT)
        rng = self.headers.get("Range")
        if rng:
            req.add_header("Range", rng)
        try:
            with urllib.request.urlopen(req, timeout=30) as up:
                self.send_response(up.status)
                for k in ("Content-Type", "Content-Length", "Content-Range",
                          "Accept-Ranges", "ETag", "Last-Modified"):
                    v = up.headers.get(k)
                    if v:
                        self.send_header(k, v)
                self.end_headers()
                if not head:
                    while chunk := up.read(1 << 16):
                        self.wfile.write(chunk)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
        except (urllib.error.URLError, OSError) as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"mirror unreachable: {e}\n".encode())

    def log_message(self, fmt, *args):
        # Keep the range traffic visible; it is how you tell the archive is
        # being read rather than downloaded whole.
        sys.stderr.write("%s %s\n" % (self.headers.get("Range", "-"), fmt % args))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--mirror", default=DEFAULT_MIRROR)
    args = ap.parse_args()
    Handler.mirror_url = args.mirror
    handler = functools.partial(Handler, directory=str(HERE))
    with http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler) as srv:
        print(f"http://localhost:{args.port}/  (archive ← {args.mirror})")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
