"""SPIKE-I — the network/compute leg. Writes `raw/`; publishes nothing.

    .venv/bin/python probe.py                    # every cell
    .venv/bin/python probe.py --cells boulder-bike
    .venv/bin/python probe.py --check-attic      # the §1 control, on its own

Split from `analyze.py` on SPIKE-E's precedent, for SPIKE-C's reason: everything
published has to reproduce from committed bytes without querying the Overpass
commons again and without moving under the next reader. This module is the only
one here that touches the network or the 2.1 GB of extracts; `analyze.py` and
`run.py` read `raw/` and nothing else.

**The attic control runs first and is allowed to abort the run.** `HARNESS.md`
§1 makes the dated query the primary control for snapshot drift, and a `[date:]`
that Overpass silently ignored would not fail loudly — it would return today's
data, make every difference look like drift, and bias every band in the
direction that produces a pass. So it is verified against a live undated query
before a single golden is built, and a failure stops the run rather than
downgrading it silently.
"""

from __future__ import annotations

import argparse
import gzip
import json
import logging
import sys
import time
from pathlib import Path
from typing import Any

SPIKE = Path(__file__).resolve().parent
sys.path.insert(0, str(SPIKE))

import osmnx as ox  # noqa: E402

# Route osmnx's own response cache into raw/ before anything can query. This is
# both the politeness measure (#242's lesson: a cache that lands wherever the
# process started is a cache nobody reuses) and the archive — a cached response
# here IS the raw byte record analyze.py rebuilds the golden from.
ox.settings.cache_folder = str(SPIKE / "raw" / "overpass")
ox.settings.use_cache = True

import bands  # noqa: E402
import clip as C  # noqa: E402
import elements as E  # noqa: E402
import graphs as G  # noqa: E402
import parity as P  # noqa: E402
import regions as R  # noqa: E402
import tags as T  # noqa: E402

import osmium  # noqa: E402

log = logging.getLogger("spike-i.probe")

RAW = SPIKE / "raw"
CLIPS = RAW / "clips"
MIRROR_ROOT = SPIKE / "mirror"
PINNED_DATE = "2026-09-13"


def extract_path(extract: R.Extract) -> Path:
    return (MIRROR_ROOT / "osm" / "geofabrik" / PINNED_DATE
            / f"{extract.path}.osm.pbf")


def _clip_key(cell: R.Cell, which: str) -> str:
    """Clip filename stem: the *bbox and sources*, never the network type.

    Two cells over the same box (`boulder-bike`, `boulder-drive`) share a clip
    because the clip is bytes and the network type is a filter applied later.
    Keying on `cell.key` instead would have silently doubled the run's clip time
    and produced two identical files whose measurements would then have been
    reported as independent samples.
    """
    import hashlib

    stem = "+".join(sorted(e.key for e in cell.extracts))
    digest = hashlib.sha256(
        f"{stem}|{which}|{cell.bbox}".encode()
    ).hexdigest()[:10]
    return f"{stem}-{which}-{digest}"


def replication_timestamp(pbf: Path) -> str | None:
    """The extract's own instant, off its pbf header. This is what the attic
    query is pinned to — not 'today', not the pull date."""
    reader = osmium.io.Reader(str(pbf))
    try:
        return reader.header().get("osmosis_replication_timestamp") or None
    finally:
        reader.close()


# ------------------------------------------------------------- the §1 control


def check_attic(verbose: bool = True) -> dict[str, Any]:
    """Prove `[date:]` is honoured before trusting any golden built with it.

    Two queries over one small box: one dated far enough back that the answer
    must differ, one undated. If they come back identical, Overpass is ignoring
    the date and every band downstream is measuring drift rather than parity.
    """
    import requests

    endpoint = "https://overpass-api.de/api/interpreter"
    ua = "plotlines-spike-I/0.1 (+https://github.com/gnfrazier/plotlines)"
    poly = ('(poly:"40.010 -105.280 40.010 -105.270 40.020 -105.270 '
            '40.020 -105.280")')

    def ask(date: str | None) -> int:
        d = f'[date:"{date}"]' if date else ""
        q = f'[out:json][timeout:180]{d};(way["highway"]{poly};>;);out;'
        for attempt in range(3):
            r = requests.post(endpoint, data={"data": q},
                              headers={"User-Agent": ua}, timeout=180)
            if r.status_code == 200:
                return len(r.json()["elements"])
            time.sleep(5 * (attempt + 1))
        raise RuntimeError(f"attic control query failed: {r.status_code}")

    live = ask(None)
    time.sleep(3)
    old = ask("2020-01-01T00:00:00Z")
    ok = live != old
    result = {
        "live_elements": live,
        "dated_2020_elements": old,
        "honoured": ok,
        "note": (
            "A dated query returning the same element count as an undated one "
            "would mean Overpass dropped [date:] — every parity band would then "
            "be measuring OSM churn and would be permissive in the direction "
            "that produces a pass."
        ),
    }
    if verbose:
        print(f"  attic control: live={live} 2020={old} honoured={ok}")
    return result


# ------------------------------------------------------------------ one cell


#: Which cells get the full three-strategy comparison (§7.1(3) / L1) rather than
#: just the `complete_ways` clip every cell needs for parity.
#:
#: `simple` and `smart` are measured where their difference is legible: on a
#: dense urban box where a severed way is one of thousands, and on the border
#: box where §11.7 says severing is the whole risk. Running them on all five
#: cells would add ~40 minutes of clipping to re-observe the same ordering —
#: and the strategy question is about behaviour, which does not vary by region,
#: not about per-region cost, which does and is reported from `complete_ways`
#: across all five.
FULL_STRATEGY_CELLS = frozenset({"boulder-bike", "coline-bike"})

#: Which cells get B9's offline-edit measurement. Its fidelity leg costs one
#: extra Overpass query per cell (a golden for the edited bbox), and Q5's
#: politeness budget is ours to spend deliberately rather than five times to
#: re-observe the same geometry. Dense-urban and sparse-rural is the axis B9
#: could plausibly vary along — coverage is pure geometry, but whether a
#: truncated graph stays strongly connected is a property of network density.
OFFLINE_CELLS = frozenset({"boulder-bike", "viroqua-bike"})


def strategies_for(cell: R.Cell) -> tuple[str, ...]:
    return C.STRATEGIES if cell.key in FULL_STRATEGY_CELLS else ("complete_ways",)


def measure_offline(cell: R.Cell, held_graph, coverage) -> dict[str, Any]:
    """B9 — what an offline bbox edit can be served from what the client holds.

    Two legs, because coverage alone would be a half-answer. Coverage says how
    often the edited box lands inside what is held; fidelity says whether the
    graph you get by truncating the held one is the graph you would have got by
    clipping fresh. An offline edit that quietly returns a *worse* graph is
    worse than one that fails — it is B7's undetectable-split failure wearing
    different clothes.
    """
    import offline as O

    per_shape, fraction = O.measure_coverage(tuple(cell.bbox), tuple(coverage))

    # Fidelity on one representative servable edit: the median shrink. Compared
    # against a freshly-built golden for that same edited bbox, so the question
    # asked is "is the offline answer the right answer", not "is it self-
    # consistent".
    shrunk = O._scale(tuple(cell.bbox), 0.75)
    truncated = O.truncate_held(held_graph, shrunk)
    fidelity: dict[str, Any] = {
        "edited_bbox": list(shrunk),
        "truncated": G.graph_summary(truncated),
    }
    try:
        fresh_cell = R.Cell(key=f"{cell.key}-offline", bbox=shrunk,
                            network_type=cell.network_type,
                            extracts=cell.extracts, note="B9 fidelity control")
        fresh = G.build_golden(fresh_cell)
        fidelity["fresh_golden"] = G.graph_summary(fresh.graph)
        fidelity["parity"] = P.compare_graphs(fresh.graph, truncated).to_dict()
    except Exception as exc:  # noqa: BLE001
        fidelity["error"] = repr(exc)

    return O.OfflineResult(
        held_bbox=tuple(cell.bbox), held_coverage=tuple(coverage),
        per_shape=per_shape, servable_fraction=fraction, fidelity=fidelity,
    ).to_dict()


def probe_cell(cell: R.Cell, *, strategies=None) -> dict[str, Any]:
    strategies = strategies or strategies_for(cell)
    print(f"\n=== {cell.key} ({cell.network_type}) strategies={list(strategies)} ===")
    CLIPS.mkdir(parents=True, exist_ok=True)

    sources = [extract_path(e) for e in cell.extracts]
    for s in sources:
        if not s.exists():
            raise FileNotFoundError(f"extract missing: {s} — run geofabrik_pull.py")

    stamps = {s.name: replication_timestamp(s) for s in sources}
    pinned = min(t for t in stamps.values() if t)
    if len({t for t in stamps.values() if t}) > 1:
        # The border case can straddle two extracts cut at different instants.
        # That is a real Phase 3 concern (a trip bbox pinned to "the mirror" is
        # pinned to two different snapshots), so it is recorded rather than
        # averaged away, and the older one is used so the golden cannot contain
        # edits neither extract has.
        print(f"  ! extracts disagree on replication timestamp: {stamps}")

    out: dict[str, Any] = {
        "cell": cell.key,
        "bbox": list(cell.bbox),
        "network_type": cell.network_type,
        "area_km2": round(cell.area_km2, 1),
        "note": cell.note,
        "extracts": [
            {"path": e.path, "bytes": extract_path(e).stat().st_size,
             "replication_timestamp": stamps[extract_path(e).name]}
            for e in cell.extracts
        ],
        "pinned_timestamp": pinned,
        "spans_two_extracts": cell.spans_two_extracts,
    }

    # --- the golden, pinned to the extract's own instant -------------------
    G.set_attic_date(pinned)
    print(f"  golden: Overpass @ {pinned}")
    golden = G.build_golden(cell)
    out["golden"] = {**G.graph_summary(golden.graph), "wall_s": round(golden.wall_s, 1)}
    print(f"    {out['golden']}")

    # --- clips --------------------------------------------------------------
    # Two bboxes, not one. The shipped `/clip` clips to the trip bbox; osmnx
    # queries a polygon buffered by 500 m and only truncates to the trip bbox on
    # the way back down, after simplification and component selection have
    # already run on the buffered graph. Clipping at the raw bbox therefore
    # cannot reproduce the golden's boundary, and how much that costs is a
    # Phase 3 design answer, not a footnote.
    buffered_bounds = R.buffered_polygon(cell.bbox).bounds  # (w, s, e, n)
    clip_bboxes = {
        "raw": tuple(cell.bbox),
        "buffered": (buffered_bounds[0], buffered_bounds[1],
                     buffered_bounds[2], buffered_bounds[3]),
    }

    source = sources[0]
    merged_tmp = None
    if len(sources) > 1:
        from plotlines_service.mirror_clip import _merge_extracts

        merged_tmp = CLIPS / f"{cell.key}-merged.osm.pbf"
        print(f"  merging {len(sources)} extracts (§11.7 border case)")
        t0 = time.monotonic()
        _merge_extracts(sources, merged_tmp)
        out["merge"] = {
            "wall_s": round(time.monotonic() - t0, 1),
            "bytes": merged_tmp.stat().st_size,
            "sources": [s.name for s in sources],
        }
        print(f"    merged in {out['merge']['wall_s']}s -> "
              f"{out['merge']['bytes'] / 1e6:.0f} MB")
        source = merged_tmp

    out["clips"] = {}
    for which, bbox in clip_bboxes.items():
        for strategy in strategies:
            # Clips are keyed on (source, bbox, strategy) and NOT on
            # network_type, because clipping does not know about network types —
            # the way filter runs at graph-build time, downstream of the bytes.
            # `boulder-bike` and `boulder-drive` are the same clip, and clipping
            # a 381 MB extract twice to prove that would cost ~10 minutes to
            # measure the filesystem.
            dest = CLIPS / f"{_clip_key(cell, which)}-{strategy}.osm.pbf"
            label = f"{which}/{strategy}"
            if dest.exists() and dest.stat().st_size > 0:
                out["clips"][label] = {
                    "bbox": list(bbox), "strategy": strategy,
                    "reused_from": dest.name,
                    "output_bytes": dest.stat().st_size,
                    "output_fraction": dest.stat().st_size / source.stat().st_size,
                    "note": "timing not re-measured — identical clip already taken",
                }
                print(f"  clip {label}: reusing {dest.name}")
                continue
            try:
                m = C.run_clip(strategy, bbox, source, dest)
            except Exception as exc:  # noqa: BLE001
                # A clip that cannot complete is a B6 result, not a lost cell.
                # The most likely cause on a large extract is the address-space
                # ceiling in clip.py — "this strategy does not fit on this
                # extract" is exactly the kind of thing §6.7 says Phase 3 must
                # not discover in production.
                out["clips"][label] = {
                    "bbox": list(bbox), "strategy": strategy,
                    "error": repr(exc)[:600],
                    "source_bytes": source.stat().st_size,
                }
                print(f"  clip {label}: FAILED {repr(exc)[:200]}")
                dest.unlink(missing_ok=True)
                continue
            out["clips"][label] = {
                "bbox": list(bbox),
                "strategy": strategy,
                "wall_s": round(m.wall_s, 2),
                "output_bytes": m.output_bytes,
                "output_fraction": m.output_fraction,
                "peak_rss_mb": round(m.peak_rss_mb, 1),
                "nodes": m.nodes, "ways": m.ways, "relations": m.relations,
                "dangling_ways": m.dangling_ways,
            }
            print(f"  clip {label}: {m.wall_s:.1f}s "
                  f"{m.output_bytes / 1e6:.2f} MB rss {m.peak_rss_mb:.0f} MB "
                  f"({m.nodes} nodes, {m.ways} ways)")

    # --- local builds -------------------------------------------------------
    out["locals"] = {}
    out["parity"] = {}
    out["tags"] = {}

    bytes_source = T.count_tags_in_pbf(sources[0], bbox=cell.bbox)
    graph_golden_tags = T.count_tags_in_graph(golden.graph)

    for which in clip_bboxes:
        cw = CLIPS / f"{_clip_key(cell, which)}-complete_ways.osm.pbf"
        if not cw.exists():
            continue

        # Path T, twice: once selecting ways the way the shipped clip does (a
        # node inside the box), once the way Overpass does (geometry intersects
        # at all). The gap between them is B0's structural finding.
        for vertex_rule, label in ((True, "vertex"), (False, "intersects")):
            key = f"T/{which}/{label}"
            try:
                bt = G.build_path_t(cell, cw, require_vertex_inside=vertex_rule)
            except Exception as exc:  # noqa: BLE001 - a failed build is a result
                out["locals"][key] = {"error": repr(exc)}
                print(f"  path {key}: FAILED {exc!r}")
                continue
            out["locals"][key] = {
                **G.graph_summary(bt.graph), "wall_s": round(bt.wall_s, 1),
                **bt.read,
            }
            cmp = P.compare_graphs(golden.graph, bt.graph)
            out["parity"][key] = cmp.to_dict()
            print(f"  path {key}: {out['locals'][key]['nodes']} nodes "
                  f"({cmp.to_dict()['nodes']['only_golden']} missing, "
                  f"{cmp.to_dict()['nodes']['only_local']} extra)")

            if which == "buffered" and label == "vertex":
                out["tags"] = T.assess_survival(
                    bytes_source, T.count_tags_in_pbf(cw),
                    graph_golden_tags, T.count_tags_in_graph(bt.graph),
                ).to_dict()
                # B9 rides on this graph because it IS what the client would
                # hold: the buffered-clip path-T build is the Phase 3 artefact
                # `ensure_graph` would cache. Measuring the offline question
                # against a separately-constructed graph would be measuring a
                # graph no client ever has.
                if cell.key in OFFLINE_CELLS:
                    out["offline"] = measure_offline(
                        cell, bt.graph, clip_bboxes["buffered"]
                    )

        # Path R — pyrosm. §11.1's actual named risk.
        key = f"R/{which}"
        try:
            br = G.build_path_r(cell, cw)
            out["locals"][key] = {
                **G.graph_summary(br.graph), "wall_s": round(br.wall_s, 1), **br.read,
            }
            out["parity"][key] = P.compare_graphs(golden.graph, br.graph).to_dict()
            print(f"  path {key}: {out['locals'][key]['nodes']} nodes")
        except Exception as exc:  # noqa: BLE001
            out["locals"][key] = {"error": repr(exc)}
            print(f"  path {key}: FAILED {exc!r}")

    if merged_tmp is not None and merged_tmp.exists():
        merged_tmp.unlink()

    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cells", nargs="*", default=None)
    parser.add_argument("--check-attic", action="store_true")
    parser.add_argument("--skip-attic-check", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.WARNING,
                        format="%(levelname)s %(name)s %(message)s")
    RAW.mkdir(parents=True, exist_ok=True)

    if args.check_attic:
        print(json.dumps(check_attic(), indent=2))
        return 0

    record: dict[str, Any] = {
        "spike": "SPIKE-I",
        "issue": 265,
        "settings": G.way_tag_settings(),
        "pinned_date": PINNED_DATE,
    }

    if not args.skip_attic_check:
        print("checking the §1 snapshot control before building any golden")
        record["attic_control"] = check_attic()
        if not record["attic_control"]["honoured"]:
            print("ABORT: Overpass is not honouring [date:]; every band below "
                  "would be measuring OSM churn. See HARNESS.md §1.")
            return 2

    cells = R.CELLS
    if args.cells:
        cells = tuple(R.CELLS_BY_KEY[k] for k in args.cells)

    record["cells"] = {}
    for cell in cells:
        try:
            record["cells"][cell.key] = probe_cell(cell)
        except Exception as exc:  # noqa: BLE001 - one bad cell must not lose the rest
            log.exception("cell %s failed", cell.key)
            record["cells"][cell.key] = {"error": repr(exc)}

    dest = RAW / "probe.json.gz"
    with gzip.open(dest, "wt") as fh:
        json.dump(record, fh, indent=2, default=str)
    print(f"\nwrote {dest} ({dest.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
