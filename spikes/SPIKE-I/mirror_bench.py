"""SPIKE-I leg 3 (B6/B7) — the clip, measured server-side on the mirror.

    .venv/bin/python mirror_bench.py --base-url http://<pi> --out raw/mirror.json

Addendum **2c** is the whole reason this file is separate from `clip.py`:

    "Measure the clip **server-side** as well as client-side, so Q1-C is
     decidable on evidence."

and §6.7 adds the reason it cannot be inferred from a dev-box run — the clip's
CPU, disk-IO and concurrency profile is "exactly what §9 says Phase 3 does *not*
prove for free." The mirror is a Raspberry Pi 5 with NVMe; this laptop is not,
and an x86 figure divided by a guess is not a measurement.

So this drives the **real `/clip` endpoint over HTTP**, on the box that will
serve it, and reads the figures out of the response headers `mirror_clip.py`
already emits (`X-Plotlines-Clip-Wall-Time-Ms`, `-Output-Bytes`,
`-Peak-Rss-Kb`, `-Source-Regions`).

**One caveat about the RSS header, and it is not cosmetic.** `clip_bbox` takes
it from `resource.getrusage(RUSAGE_SELF).ru_maxrss`, which is a *process*
high-water mark that never decreases. On a long-lived service the second request
reports the first request's peak, and every request after the largest one
reports that one's. The header name says `Clip-Peak-Rss-Kb`, which reads as
per-clip and is not. This harness therefore treats only the **first clip after a
process start** as a valid RSS sample, and `--restart-cmd` exists so a sequence
of them can be taken honestly. The wall-time and output-size headers have no
such problem and are sampled normally.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import requests

SPIKE = Path(__file__).resolve().parent
sys.path.insert(0, str(SPIKE))

import regions as R  # noqa: E402

UA = "plotlines-spike-I/0.1 (+https://github.com/gnfrazier/plotlines)"


def clip_once(base_url: str, bbox: tuple[float, float, float, float],
              *, client_key: str | None, out: Path | None,
              host_header: str | None = None,
              timeout: float = 600.0) -> dict[str, Any]:
    west, south, east, north = bbox
    headers = {"User-Agent": UA}
    if client_key:
        headers["X-Plotlines-Client-Key"] = client_key
    if host_header:
        # `deploy/mirror/Caddyfile` declares a single named vhost
        # (`http://tiles.plotlines.app`) with no fallback block, so a request
        # addressed to the Pi's own hostname does not match the site and never
        # reaches `reverse_proxy /clip*`. Sending the Host header is how the
        # bench hits the production route rather than a route invented for the
        # measurement — §6.5's "exercise the real code path" applied to the
        # request line and not only to the deployment.
        headers["Host"] = host_header

    started = time.monotonic()
    r = requests.get(
        f"{base_url.rstrip('/')}/clip",
        params={"west": west, "south": south, "east": east, "north": north},
        headers=headers, timeout=timeout, stream=True,
    )
    body = r.content
    round_trip = time.monotonic() - started

    if r.status_code != 200:
        return {"status": r.status_code, "body": body[:400].decode("utf-8", "replace")}

    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(body)

    h = r.headers
    return {
        "status": 200,
        # Round-trip includes transfer; the header is the clip's own compute.
        # Both are reported because Phase 3 pays both and B6's band is about
        # what the Author waits for.
        "round_trip_s": round(round_trip, 3),
        "server_wall_s": (int(h["X-Plotlines-Clip-Wall-Time-Ms"]) / 1000.0
                          if "X-Plotlines-Clip-Wall-Time-Ms" in h else None),
        "output_bytes": int(h.get("X-Plotlines-Clip-Output-Bytes", len(body))),
        "peak_rss_kb": (int(h["X-Plotlines-Clip-Peak-Rss-Kb"])
                        if h.get("X-Plotlines-Clip-Peak-Rss-Kb", "unknown").isdigit()
                        else None),
        "source_regions": h.get("X-Plotlines-Clip-Source-Regions", ""),
        # #364: the notice has to travel with a Derivative Database, and the
        # header values must stay US-ASCII or a client decoding them breaks.
        "licence": h.get("X-Plotlines-Data-Licence"),
        "attribution": h.get("X-Plotlines-Data-Attribution"),
        "link": h.get("Link"),
        "bytes_received": len(body),
    }


def bench(base_url: str, *, repeats: int, client_key: str | None,
          restart_cmd: str | None, save_dir: Path | None,
          host_header: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "base_url": base_url, "host_header": host_header, "repeats": repeats,
        "restart_between_samples": bool(restart_cmd),
        "cells": {},
    }

    for cell in R.CELLS:
        if cell.key == "boulder-drive":
            continue  # same bbox as boulder-bike; the clip does not know modes

        samples = []
        for i in range(repeats):
            if restart_cmd and i > 0:
                subprocess.run(restart_cmd, shell=True, check=False)
                time.sleep(5)
            dest = (save_dir / f"{cell.key}.osm.pbf") if (save_dir and i == 0) else None
            s = clip_once(base_url, tuple(cell.bbox), client_key=client_key,
                          out=dest, host_header=host_header)
            samples.append(s)
            print(f"  {cell.key} [{i + 1}/{repeats}] "
                  f"{s.get('status')} server={s.get('server_wall_s')}s "
                  f"rt={s.get('round_trip_s')}s "
                  f"out={s.get('output_bytes', 0) / 1e6:.2f} MB "
                  f"rss={(s.get('peak_rss_kb') or 0) / 1024:.0f} MB")

        ok = [s for s in samples if s.get("status") == 200]
        walls = [s["server_wall_s"] for s in ok if s.get("server_wall_s")]
        rts = [s["round_trip_s"] for s in ok]
        out["cells"][cell.key] = {
            "bbox": list(cell.bbox),
            "area_km2": round(cell.area_km2, 1),
            "spans_two_extracts": cell.spans_two_extracts,
            "samples": samples,
            "n_ok": len(ok),
            "server_wall_s": _dist(walls),
            "round_trip_s": _dist(rts),
            "output_bytes": ok[0]["output_bytes"] if ok else None,
            # Only the first sample after a process start is a valid RSS
            # reading — see the module docstring. With --restart-cmd every
            # sample qualifies; without it, only index 0.
            "peak_rss_kb_first_after_start": (
                ok[0].get("peak_rss_kb") if ok else None
            ),
            "rss_samples_valid": repeats if restart_cmd else 1,
        }
    return out


def _dist(values: list[float]) -> dict[str, float] | None:
    if not values:
        return None
    v = sorted(values)
    def pct(p):
        if len(v) == 1:
            return v[0]
        return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]
    return {
        "n": len(v), "min": v[0], "p50": pct(0.5), "p95": pct(0.95), "max": v[-1],
        "mean": round(statistics.fmean(v), 3),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", required=True,
                    help="e.g. http://argon-robot — Caddy publishes :80, and the "
                         "clip container publishes no port at all")
    ap.add_argument("--host-header", default="tiles.plotlines.app",
                    help="Caddyfile declares one named vhost with no fallback, so "
                         "this must match it or the request never reaches /clip")
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--client-key", default=None)
    ap.add_argument("--restart-cmd", default=None,
                    help="shell command that restarts the clip container between "
                         "samples, so every RSS reading is a first-after-start "
                         "one (e.g. 'ssh pi docker restart mirror-clip')")
    ap.add_argument("--save-dir", type=Path, default=SPIKE / "raw" / "mirror-clips")
    ap.add_argument("--out", type=Path, default=SPIKE / "raw" / "mirror.json")
    args = ap.parse_args(argv)

    print(f"benching {args.base_url} ({args.repeats} repeats/cell)")
    result = bench(args.base_url, repeats=args.repeats,
                   client_key=args.client_key, restart_cmd=args.restart_cmd,
                   save_dir=args.save_dir, host_header=args.host_header)
    result["measured_on_mirror"] = True
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2))
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
