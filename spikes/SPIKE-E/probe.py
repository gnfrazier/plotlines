"""The only file here that touches the network.

One Overpass pull per approach with the widest car-usable filter (`filters.FETCH_FILTER`),
committed to `raw/` as compact JSON so every published figure re-derives offline —
SPIKE-C's rule, for SPIKE-D's reason: the commons is not a fixture, and a number that
needs a live query to reproduce moves under the next reader.

Plus one control pull: a real `network_type="drive"` graph for `boulder`, which is what
`tests/test_filters.py` checks the offline variant reconstruction against. Without it
"the shipped filter drops the trailhead road" would rest on my reimplementation of the
filter rather than on osmnx's.

    core/.venv/bin/python spikes/SPIKE-E/probe.py            # all four approaches
    core/.venv/bin/python spikes/SPIKE-E/probe.py bigsandy   # one

Re-running is cheap and idempotent: an approach whose `raw/` file already exists is
skipped unless `--force` is passed.
"""

from __future__ import annotations

import gzip
import json
import sys
import time
from datetime import datetime, timezone

import osmnx as ox

from filters import FETCH_FILTER
from regions import APPROACHES, RAW

# Tags this spike reads. osmnx's default `useful_tags_way` carries none of FR29a's
# signals except `access` — the same trap `spikes/shared/regions.py` documented for
# `surface` on the cycling side, and the reason punch-list §5.3 is this spike's
# dependency. A tag not requested at download time is not recoverable later without
# re-downloading.
WAY_TAGS = [
    *ox.settings.useful_tags_way,
    "surface", "smoothness", "tracktype", "4wd_only", "motor_vehicle", "motorcar",
    "ford", "barrier", "bridge", "tunnel", "layer", "seasonal", "snowmobile",
    "hgv", "width", "maxweight", "operator", "ref",
]

#: Edge attributes kept in `raw/`. Geometry is kept because a cue sheet measures
#: against the drawn polyline, not the junction-to-junction path (`trips/cues.py`),
#: and the advisory has to land on the same axis as the cues.
KEEP = [
    "osmid", "highway", "name", "ref", "surface", "smoothness", "tracktype",
    "4wd_only", "motor_vehicle", "motorcar", "access", "service", "oneway",
    "maxspeed", "lanes", "ford", "barrier", "bridge", "tunnel", "width", "seasonal",
    "reversed", "junction", "operator",
]

MAX_ATTEMPTS = 4


def _clean(value):
    """OSM values arrive as str or list; ids as int or list of int. Keep both shapes,
    drop everything unhashable that JSON cannot carry."""
    if isinstance(value, (list, tuple, set)):
        return [_clean(v) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def serialise(graph, meta: dict) -> dict:
    nodes = {
        str(n): [round(float(d["x"]), 7), round(float(d["y"]), 7)]
        for n, d in graph.nodes(data=True)
    }
    edges = []
    for u, v, k, data in graph.edges(keys=True, data=True):
        tags = {key: _clean(data[key]) for key in KEEP if key in data}
        record = {
            "u": str(u), "v": str(v), "k": int(k),
            "length": round(float(data.get("length", 0.0)), 2),
            "tags": tags,
        }
        geom = data.get("geometry")
        if geom is not None:
            record["geom"] = [[round(x, 6), round(y, 6)] for x, y in geom.coords]
        edges.append(record)
    return {"meta": meta, "nodes": nodes, "edges": edges}


def write(path, payload) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = json.dumps(payload, separators=(",", ":")).encode()
    with gzip.open(path, "wb") as handle:
        handle.write(blob)
    return path.stat().st_size


def fetch(bbox, *, network_type=None, custom_filter=None) -> tuple:
    """One pull, with a bounded retry. SPIKE-D found osmnx's own 429/504 retry has no
    attempt limit — a pull against a busy instance does not fail, it spins — so the
    limit lives here rather than being wished for."""
    last: Exception | None = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        started = time.perf_counter()
        try:
            kwargs = {"simplify": True, "retain_all": True, "truncate_by_edge": True}
            if custom_filter:
                kwargs["custom_filter"] = custom_filter
            else:
                kwargs["network_type"] = network_type
            graph = ox.graph_from_bbox(bbox, **kwargs)
            return graph, round(time.perf_counter() - started, 2), attempt
        except Exception as exc:  # noqa: BLE001 — a spike reports the failure, not raises it
            last = exc
            print(f"    attempt {attempt}/{MAX_ATTEMPTS} failed after "
                  f"{time.perf_counter() - started:.1f}s: {type(exc).__name__}: {exc}")
            if attempt < MAX_ATTEMPTS:
                time.sleep(20 * attempt)
    raise RuntimeError(f"all {MAX_ATTEMPTS} attempts failed") from last


def probe_one(approach, *, force: bool = False) -> None:
    out = RAW / f"{approach.key}-graph.json.gz"
    if out.exists() and not force:
        print(f"  {approach.key}: cached ({out.stat().st_size / 1e6:.1f} MB)")
        return

    print(f"  {approach.key}: {approach.name}")
    graph, seconds, attempts = fetch(approach.bbox, custom_filter=FETCH_FILTER)
    meta = {
        "key": approach.key,
        "name": approach.name,
        "bbox": list(approach.bbox),
        "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "osmnx": ox.__version__,
        "filter": FETCH_FILTER,
        "fetch_seconds": seconds,
        "fetch_attempts": attempts,
        "nodes": graph.number_of_nodes(),
        "edges": graph.number_of_edges(),
        "origin": list(approach.origin),
        "destination": list(approach.destination),
        "destination_osm": approach.destination_osm,
    }
    size = write(out, serialise(graph, meta))
    print(f"    {meta['nodes']:,} nodes / {meta['edges']:,} edges in {seconds}s "
          f"-> {size / 1e6:.1f} MB")


def probe_control() -> None:
    """The reconstruction control: a genuine `network_type="drive"` pull over the
    boulder bbox, so the offline variant is checked against osmnx rather than
    against itself."""
    out = RAW / "boulder-drive-control.json.gz"
    if out.exists():
        print(f"  control: cached ({out.stat().st_size / 1e6:.1f} MB)")
        return
    approach = APPROACHES["boulder"]
    print("  control: boulder, network_type='drive' (what modes.py ships)")
    graph, seconds, attempts = fetch(approach.bbox, network_type="drive")
    meta = {
        "key": "boulder-drive-control",
        "bbox": list(approach.bbox),
        "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "osmnx": ox.__version__,
        "network_type": "drive",
        "fetch_seconds": seconds,
        "fetch_attempts": attempts,
        "nodes": graph.number_of_nodes(),
        "edges": graph.number_of_edges(),
    }
    write(out, serialise(graph, meta))
    print(f"    {meta['nodes']:,} nodes / {meta['edges']:,} edges in {seconds}s")


def main(argv: list[str]) -> int:
    force = "--force" in argv
    keys = [a for a in argv[1:] if not a.startswith("-")] or list(APPROACHES)

    ox.settings.useful_tags_way = list(dict.fromkeys(WAY_TAGS))
    ox.settings.cache_folder = str(RAW.parent / "cache" / "overpass")
    ox.settings.use_cache = True

    print(f"SPIKE-E probe — osmnx {ox.__version__}")
    for key in keys:
        probe_one(APPROACHES[key], force=force)
    probe_control()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
