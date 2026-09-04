"""Standalone region-build diagnostic (issue #232).

Runs the real `plotlines_core.graph.regions.ensure_graph` path for one bbox
with INFO logging to stdout, times each phase, and on failure prints the
full traceback — the fastest way to root-cause a region that fails or never
settles in the running app, with no GUI in the loop.

    python -m plotlines_service.diagnose_region \
        --cache-dir ~/.local/share/plotlines/sidecar_cache \
        --bbox -82.83 35.36 -82.14 35.79 --network-type bike

`--bbox` is `west south east north` (osmnx order — the same order the client
sends). Add `--force` to rebuild even if a cached graph already exists.
Exit code is non-zero if the build fails.
"""

from __future__ import annotations

import argparse
import sys
import time
import traceback
from pathlib import Path

from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import load_graphml
from plotlines_core.osm_identity import apply_osm_http_identity

from .logging_setup import configure_logging
from .version import VERSION


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="plotlines-diagnose-region")
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--bbox", type=float, nargs=4, required=True,
                        metavar=("W", "S", "E", "N"),
                        help="west south east north (osmnx order)")
    parser.add_argument("--network-type", default="bike")
    parser.add_argument("--force", action="store_true",
                        help="rebuild even if a cached graph exists")
    parser.add_argument("--log-level", default="info",
                        choices=("debug", "info", "warning", "error"))
    args = parser.parse_args(argv)

    configure_logging(None, args.log_level)  # stderr only

    # This bypasses `create_app`, so it must stamp the Plotlines identity
    # itself before `ensure_graph` reaches Overpass (issue #241), and point
    # osmnx's response cache inside `--cache-dir` rather than at the
    # CWD-relative `./cache` default (issue #242).
    user_agent = apply_osm_http_identity(VERSION)
    region_lib.configure_overpass_cache(args.cache_dir)

    region = region_lib.region_for(tuple(args.bbox), args.network_type)
    print(f"region key={region.key} bbox={region.bbox} nt={region.network_type}")
    print(f"user-agent: {user_agent}")
    print(f"endpoints: {list(region_lib.overpass_endpoints())}")
    print(f"cache path: {region.graph_path(args.cache_dir)} "
          f"(exists={region.graph_path(args.cache_dir).exists()})")

    t0 = time.monotonic()
    try:
        path = region_lib.ensure_graph(region, args.cache_dir, force=args.force)
    except region_lib.OverpassUnavailable as exc:
        print(f"\nRESULT: OverpassUnavailable after {time.monotonic() - t0:.1f}s")
        print(f"  {exc}")
        return 3
    except Exception:  # noqa: BLE001 — this is the diagnostic; show everything
        print(f"\nRESULT: build FAILED after {time.monotonic() - t0:.1f}s")
        traceback.print_exc(file=sys.stdout)
        return 1

    acquire_s = time.monotonic() - t0
    t_load = time.monotonic()
    graph = load_graphml(path)
    load_s = time.monotonic() - t_load

    print(f"\nRESULT: OK in {acquire_s + load_s:.1f}s "
          f"(acquire {acquire_s:.1f}s, load {load_s:.1f}s)")
    print(f"  graph: {graph.node_count} nodes, {graph.edge_count} edges")
    print(f"  saved: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
