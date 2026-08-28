"""Shared load path and stage timers for the SPIKE-D scripts — issue #159.

Same discipline as SPIKE-A and SPIKE-B: the spike measures the *product's*
code. `extract_stage` calls `OsmLayerProvider.fetch` and `score_notability`,
the two functions the sidecar's `GET /candidates` calls, and times the boundary
between them — because "extraction and POI indexing" is two stages with very
different cost profiles and FR121 unlocks authoring only when both are done.
"""

from __future__ import annotations

import sys
import time
import tracemalloc
from dataclasses import dataclass, field
from pathlib import Path

CORE = Path(__file__).resolve().parents[2] / "core"
sys.path.insert(0, str(CORE))
sys.path.insert(0, str(Path(__file__).parent))

import osmnx as ox  # noqa: E402

import cache  # noqa: E402
import overpass_meter  # noqa: E402
from regions import Box  # noqa: E402

from plotlines_core.curation.defaults import resolve_default_layers  # noqa: E402
from plotlines_core.curation.notability import (  # noqa: E402
    Candidate, RawFeature, score_notability,
)
from plotlines_core.curation.providers import BBox, OsmLayerProvider  # noqa: E402
from plotlines_core.curation.taxonomy import LAYERS  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"
OVERPASS_CACHE = HERE / "cache" / "overpass"

ALL_LAYERS = frozenset(LAYERS)
#: What N3 makes live on a cycling route day with nothing overridden — the set
#: an Author actually starts with, and therefore the set FR121's
#: "extraction completes first" is a claim about.
DEFAULT_LAYERS = frozenset(resolve_default_layers("cycling", "route"))

# osmnx caches Overpass responses; keep them under the spike, not the repo root
# (SPIKE-00's lesson, and the same call `regions.configure_overpass_cache` makes
# in the product).
ox.settings.cache_folder = str(OVERPASS_CACHE)
ox.settings.use_cache = True

#: Public Overpass instances, in preference order. The canonical instance
#: first; the rest are the same fallback list SPIKE-A and SPIKE-B's hand-rolled
#: probes carried, minus the ones that turn out to be regional mirrors.
#:
#: This list exists because of what happened during this spike's own first run
#: (RESULTS §2): after a whole-extent multi-day pull, `overpass-api.de` stopped
#: completing the TCP handshake from this host and stayed that way for the rest
#: of the evening, while `kumi.systems` and `private.coffee` returned 500/502
#: and Geofabrik returned 502/503. **The product cannot express this list.**
#: `OsmLayerProvider.fetch` calls `osmnx.features_from_bbox`, which reads the
#: single `settings.overpass_url`; there is no second endpoint and no failover.
#: That is a finding, not a spike convenience — see RESULTS §2.
#:
#: `overpass.osm.ch` is deliberately absent: it answers, and it holds only
#: Switzerland, so a North Carolina query returns `{"elements": []}` with HTTP
#: 200. A failover list that ranks liveness above coverage would silently
#: answer "there is nothing here" for the Author's whole trip area, which is a
#: worse failure than an error.
ENDPOINTS = (
    "https://overpass-api.de/api",
    "https://maps.mail.ru/osm/tools/overpass/api",
    "https://overpass.kumi.systems/api",
    "https://overpass.private.coffee/api",
)


#: Seconds to wait between queries when osmnx's own rate limiter has had to be
#: turned off (see `_osmnx_can_pace`). Matches the pacing SPIKE-A and SPIKE-B's
#: hand-rolled probes used.
PACE_S = 12.0

#: Every extraction attempt is capped. osmnx has two unbounded waits — the
#: 429/504 retry (no attempt limit) and the status-parser recursion above — and
#: both were hit during this spike. A cap turns "still going" into a result.
DEFAULT_DEADLINE_S = 300.0


def _osmnx_can_pace(status_text: str) -> bool:
    """Whether osmnx's rate limiter can read this instance's status page.

    `_get_overpass_pause` does not parse the status page; it takes **line index
    4** and branches on its first word. On `overpass-api.de` that line is
    `"N slots available now."` or `"Slot available after: <time>"`. On an
    instance with `Rate limit: 0` — no per-user slot limit at all — that line
    is missing, so line 4 becomes the header `"Currently running queries (pid,
    ...)"`. osmnx reads `"Currently"` as *the server is busy with my query*,
    sleeps 5 s, and **calls itself again** — against a header that never
    changes, so it recurses until the stack runs out.

    Observed, not theorised: the first attempt to use such a mirror here left
    the process in `hrtimer_nanosleep` with 3 s of CPU consumed in 20 minutes
    and no query ever sent. The product inherits this exactly —
    `OsmLayerProvider.fetch` calls `osmnx.features_from_bbox`, which calls this
    same function — so it is recorded in RESULTS §2 as a constraint on A23's
    "don't depend on one endpoint" mitigation: the failover cannot be a URL
    swap alone.
    """
    lines = status_text.split("\n")
    if len(lines) < 5:
        return False
    first = lines[4].split(" ")[0]
    if first == "Slot":
        return True
    try:
        int(first)
    except ValueError:
        return False
    return True


def select_overpass_endpoint(endpoints=ENDPOINTS, *, timeout: float = 20.0) -> str:
    """Point osmnx at the first endpoint whose `/status` answers, and return
    it. A23's "tile-and-retry as the baseline access pattern" has an unstated
    predecessor — *pick an endpoint that is up* — and this is it.

    Also decides whether osmnx's rate limiter can be trusted against that
    endpoint, and turns it off (in favour of this module's own `PACE_S`) when
    it cannot.
    """
    import requests

    for url in endpoints:
        try:
            resp = requests.get(f"{url}/status", timeout=timeout,
                                headers={"User-Agent": "plotlines-spikeD/0.1"})
        except requests.RequestException:
            print(f"    overpass {url} -> unreachable")
            continue
        if resp.status_code != 200:
            print(f"    overpass {url} -> HTTP {resp.status_code}")
            continue
        ox.settings.overpass_url = url
        if _osmnx_can_pace(resp.text):
            ox.settings.overpass_rate_limit = True
            print(f"    overpass endpoint: {url} (osmnx rate limiter active)")
        else:
            ox.settings.overpass_rate_limit = False
            print(f"    overpass endpoint: {url} "
                  f"(osmnx rate limiter DISABLED — its status parser recurses "
                  f"forever on this instance; pacing at {PACE_S:.0f}s here instead)")
        return url
    raise RuntimeError(f"no Overpass endpoint answered /status: {endpoints}")


def pace() -> None:
    """Politeness gap between queries when we are pacing ourselves."""
    if not ox.settings.overpass_rate_limit:
        time.sleep(PACE_S)


class Meter:
    """perf_counter + tracemalloc around a block (copied from SPIKE-B)."""

    def __enter__(self) -> "Meter":
        tracemalloc.start()
        self._t = time.perf_counter()
        return self

    def __exit__(self, *exc) -> None:
        self.seconds = time.perf_counter() - self._t
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        self.peak_mb = peak / 1e6


@dataclass
class ExtractResult:
    """One bbox+layer-set extraction, split at the seam that matters."""

    box_key: str
    layers: tuple[str, ...]
    area_km2: float
    fetch_s: float = 0.0
    index_s: float = 0.0
    features: int = 0
    candidates: int = 0
    peak_mb: float = 0.0
    overpass: dict = field(default_factory=dict)
    error: str | None = None

    @property
    def total_s(self) -> float:
        return self.fetch_s + self.index_s

    def to_dict(self) -> dict:
        return {
            "box": self.box_key,
            "layers": list(self.layers),
            "area_km2": round(self.area_km2, 1),
            "fetch_s": round(self.fetch_s, 2),
            "index_s": round(self.index_s, 3),
            "total_s": round(self.total_s, 2),
            "features": self.features,
            "candidates": self.candidates,
            "peak_mb": round(self.peak_mb, 1),
            "overpass": self.overpass,
            "error": self.error,
        }


def clear_overpass_cache() -> None:
    """Make the next fetch genuinely cold. osmnx returns a cached response
    before it ever pauses or posts, so without this every run after the first
    measures JSON parsing."""
    if OVERPASS_CACHE.exists():
        for path in OVERPASS_CACHE.iterdir():
            if path.is_file():
                path.unlink()


def overpass_cache_bytes() -> int:
    if not OVERPASS_CACHE.exists():
        return 0
    return sum(p.stat().st_size for p in OVERPASS_CACHE.iterdir() if p.is_file())


class Deadline:
    """A hard wall-clock cap on one extraction attempt, via SIGALRM.

    Needed because osmnx's own retry is unbounded: `_overpass_request` handles
    429 and 504 by sleeping 55 s and calling itself again, with no attempt
    limit, so a pull against a busy public instance can spin indefinitely
    rather than fail. On the first run of this spike the multi-day extent did
    exactly that. "Did not complete within N minutes" is a legitimate A23
    result; "still going" is not one, and it is also what stops the tiled
    comparison from ever being reached.
    """

    def __init__(self, seconds: float) -> None:
        self.seconds = seconds

    def __enter__(self) -> "Deadline":
        import signal

        if self.seconds <= 0 or not hasattr(signal, "SIGALRM"):
            return self

        def _fire(_sig, _frame):
            raise TimeoutError(f"extraction exceeded the {self.seconds:.0f}s deadline")

        self._prev = signal.signal(signal.SIGALRM, _fire)
        signal.setitimer(signal.ITIMER_REAL, self.seconds)
        return self

    def __exit__(self, *exc) -> None:
        import signal

        if self.seconds <= 0 or not hasattr(signal, "SIGALRM"):
            return
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, self._prev)


def extract_stage(box: Box, layers: frozenset[str], *, provider=None,
                  cold: bool = True, deadline_s: float = DEFAULT_DEADLINE_S
                  ) -> tuple[ExtractResult, list[RawFeature], list[Candidate]]:
    """The whole bbox -> authorable-candidates path, timed in two halves.

    `fetch_s` is `OsmLayerProvider.fetch` — network, plus osmnx's GeoDataFrame
    build and this spike's conversion to `RawFeature`. `index_s` is
    `score_notability` — pure CPU, no I/O, the "POI indexing" of the issue's
    phrasing. They are reported separately because only one of them is a
    function of the Overpass commons' mood.
    """
    provider = provider or OsmLayerProvider()
    if cold:
        clear_overpass_cache()

    result = ExtractResult(box_key=box.key, layers=tuple(sorted(layers)),
                           area_km2=box.area_km2)
    features: list[RawFeature] = []
    candidates: list[Candidate] = []

    with overpass_meter.measure() as cost:
        try:
            with Deadline(deadline_s), Meter() as m:
                features = provider.fetch(BBox(*box.bbox_lonlat), set(layers))
            result.fetch_s, result.peak_mb = m.seconds, m.peak_mb
        except Exception as exc:  # noqa: BLE001 — a failed pull is a result (A23)
            result.error = f"{type(exc).__name__}: {exc}"
            # Time-to-failure, not zero: how long an Author waited before
            # being told nothing was coming is the number A23 cares about.
            result.fetch_s = getattr(locals().get("m"), "seconds", 0.0)
    result.overpass = cost.to_dict()

    pace()
    if result.error is None:
        result.features = len(features)
        with Meter() as m:
            candidates = score_notability(features, live_layers=set(layers))
        result.index_s = m.seconds
        result.candidates = len(candidates)

    return result, features, candidates


def save_features(key: str, features: list[RawFeature]) -> None:
    cache.save(RAW / f"{key}.json", cache.dump_features(features))


def load_features(key: str) -> list[RawFeature]:
    return cache.read_features(cache.load(RAW / f"{key}.json"))


def has_features(key: str) -> bool:
    return cache.exists(RAW / f"{key}.json")


def write_results(name: str, payload: dict) -> Path:
    import json

    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / name
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path
