"""Build the SPIKE-00 graph + DEM fixtures. Run once, online; the frozen binary is offline.

Downloads a small real OSM cycling graph and writes a synthetic DEM covering the same
bbox. The DEM is synthetic on purpose: SPIKE-00 measures *packaging*, and what matters
is that rasterio/GDAL is genuinely exercised at runtime inside the frozen binary, not
that the elevation numbers are real.
"""

import sys
import time
from pathlib import Path

import numpy as np
import osmnx as ox
import rasterio
from rasterio.transform import from_bounds

# Downtown Boulder, CO — small, real, bike-dense, and unambiguously a place a
# Plotlines Author would route through.
BBOX = (-105.30, 39.99, -105.25, 40.03)  # west, south, east, north

OUT = Path(__file__).parent / "fixtures"

# Keep osmnx's Overpass response cache inside the spike dir rather than letting it
# land in whatever the current working directory happens to be (it defaults to
# ./cache and otherwise litters the repo root).
ox.settings.cache_folder = str(Path(__file__).parent / "cache" / "osmnx")


def build_graph() -> None:
    t0 = time.perf_counter()
    print(f"downloading bike graph for bbox={BBOX} ...", flush=True)
    g = ox.graph.graph_from_bbox(bbox=BBOX, network_type="bike", simplify=True)
    print(f"  {g.number_of_nodes()} nodes / {g.number_of_edges()} edges "
          f"in {time.perf_counter() - t0:.1f}s", flush=True)

    # Edge lengths precomputed so the sidecar's cold start measures graph *load*
    # time, not graph *enrichment* time. Grade is sampled from the DEM at request
    # time in core, which is what keeps rasterio on the hot path.
    g = ox.distance.add_edge_lengths(g)

    path = OUT / "boulder_bike.graphml"
    ox.io.save_graphml(g, path)
    print(f"  wrote {path} ({path.stat().st_size / 1e6:.1f} MB)", flush=True)


def build_dem() -> None:
    """Synthetic DEM over the bbox — forces a real GDAL read path at runtime."""
    west, south, east, north = BBOX
    width = height = 512
    ys, xs = np.mgrid[0:height, 0:width]
    # Boulder sits ~1650 m and climbs hard to the west; fake that gradient plus
    # some ridging so grade sampling returns varied, non-degenerate values.
    elev = (
        1650.0
        + 900.0 * (1.0 - xs / width) ** 2
        + 40.0 * np.sin(ys / 18.0)
        + 25.0 * np.cos(xs / 11.0)
    ).astype("float32")

    path = OUT / "boulder_dem.tif"
    with rasterio.open(
        path, "w", driver="GTiff", height=height, width=width, count=1,
        dtype="float32", crs="EPSG:4326",
        transform=from_bounds(west, south, east, north, width, height),
        compress="deflate",
    ) as dst:
        dst.write(elev, 1)
    print(f"  wrote {path} ({path.stat().st_size / 1e6:.2f} MB)", flush=True)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    build_graph()
    build_dem()
    print("fixtures ready", file=sys.stderr)
