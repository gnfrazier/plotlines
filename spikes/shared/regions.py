"""Fixture regions shared by SPIKE-01/02/03 — built once, used by all three.

The three routing spikes ask different questions of the *same* substrate: a real bike
graph with real elevation and real OSM surface/highway tags. Building that substrate
once and holding it in one process is the whole reason these spikes run together.

Region choice is the experiment design for SPIKE-03, not convenience. SPIKE-03 asks
whether min/max bands "routinely over-constrain into infeasibility"; that question is
meaningless without terrain that actually differs. So the three regions are picked to
span the axes the bands pull on:

  boulder  — mountain-adjacent city: steep foothills *and* a dense street grid, so
             climbing and quiet are both attainable but not in the same place.
  davis    — famously flat cycling town: climbing bands should be unsatisfiable here
             no matter the weights. This is the region that should produce honest
             infeasibility rather than a bad route.
  viroqua  — Driftless-area rural: steep coulees, gravel, almost no traffic. Where
             "high climbing-min + low traffic-max" ought to be *easy*.

Elevation comes from AWS Terrain Tiles (Terrarium encoding), which is keyless and
global. That matters for a spike: no API key means no secret, and per ARCH the
elevation key lives in `service/` config only — a fixture builder must not need one.
"""

from __future__ import annotations

import math
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from urllib.request import Request, urlopen

import numpy as np
import osmnx as ox
import rasterio
from rasterio.transform import from_origin
from rasterio.warp import Resampling, calculate_default_transform, reproject

SHARED = Path(__file__).resolve().parent
FIXTURES = SHARED / "fixtures"

# osmnx caches Overpass responses; keep them out of the repo root (SPIKE-00 lesson).
ox.settings.cache_folder = str(SHARED / "cache" / "overpass")
ox.settings.use_cache = True

# osmnx's default `useful_tags_way` does NOT include `surface`. The first fixture
# build here came back with surface tagged on 0.0% of edges in all three regions,
# which reads like "OSM has no surface data" and is really "we never asked for it".
# FR4's surface weight and any unpaved band are inert without this — every edge falls
# to the untagged default and the weight changes nothing. `maxspeed`/`lanes` are kept
# for the same reason: a traffic model better than highway-class alone will want them.
ox.settings.useful_tags_way = list(dict.fromkeys([
    *ox.settings.useful_tags_way,
    "surface", "tracktype", "smoothness", "maxspeed", "lanes", "bicycle",
]))


@dataclass(frozen=True)
class Region:
    key: str
    name: str
    character: str
    # (left, bottom, right, top) — osmnx 2.x bbox order
    bbox: tuple[float, float, float, float]
    network_type: str = "bike"

    @property
    def graph_path(self) -> Path:
        return FIXTURES / f"{self.key}.graphml"

    @property
    def dem_path(self) -> Path:
        return FIXTURES / f"{self.key}_dem.tif"

    @property
    def centre(self) -> tuple[float, float]:
        left, bottom, right, top = self.bbox
        return ((bottom + top) / 2.0, (left + right) / 2.0)


REGIONS: dict[str, Region] = {
    "boulder": Region(
        key="boulder",
        name="Boulder, CO",
        character="mountain-adjacent city — foothills against a street grid",
        bbox=(-105.30, 39.98, -105.23, 40.04),
    ),
    "davis": Region(
        key="davis",
        name="Davis, CA",
        character="flat cycling town — dense bike network, no relief",
        bbox=(-121.78, 38.53, -121.71, 38.57),
    ),
    "viroqua": Region(
        key="viroqua",
        name="Viroqua, WI (Driftless)",
        character="rural coulee country — steep, gravel, near-empty roads",
        # Deliberately wider than the two urban boxes: a rural network is sparse, and
        # at the first (city-sized) extent there was not enough road to build a 20 km
        # loop out of. Sparseness is itself a variable these spikes care about.
        bbox=(-91.00, 43.48, -90.80, 43.62),
    ),
}


# --------------------------------------------------------------------------- DEM

_TERRARIUM = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
_MERC_R = 20_037_508.342789244
_TILE_PX = 256


def _deg2tile(lat: float, lon: float, z: int) -> tuple[int, int]:
    n = 2**z
    x = int((lon + 180.0) / 360.0 * n)
    lat_r = math.radians(lat)
    y = int((1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * n)
    return x, y


def _fetch_tile(z: int, x: int, y: int) -> np.ndarray:
    """One Terrarium tile, decoded to metres. RGB -> (R*256 + G + B/256) - 32768."""
    url = _TERRARIUM.format(z=z, x=x, y=y)
    with urlopen(Request(url, headers={"User-Agent": "plotlines-spike/0.1"}), timeout=60) as r:
        blob = r.read()
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        tmp.write(blob)
        tmp.flush()
        with rasterio.open(tmp.name) as ds:
            rgb = ds.read([1, 2, 3]).astype("float64")
    return (rgb[0] * 256.0 + rgb[1] + rgb[2] / 256.0) - 32768.0


def build_dem(region: Region, zoom: int = 12, *, force: bool = False) -> Path:
    """Mosaic Terrarium tiles over the bbox and write an EPSG:4326 GeoTIFF.

    4326 deliberately: `ElevationSampler` samples with raw (lon, lat), so a DEM in a
    projected CRS would silently return garbage rather than fail. Writing geographic
    keeps the fixture honest against the sampler that exists.
    """
    if region.dem_path.exists() and not force:
        return region.dem_path

    left, bottom, right, top = region.bbox
    x0, y0 = _deg2tile(top, left, zoom)      # top-left tile
    x1, y1 = _deg2tile(bottom, right, zoom)  # bottom-right tile

    rows = []
    for ty in range(y0, y1 + 1):
        rows.append(np.hstack([_fetch_tile(zoom, tx, ty) for tx in range(x0, x1 + 1)]))
    mosaic = np.vstack(rows)

    tile_m = 2.0 * _MERC_R / (2**zoom)
    px = tile_m / _TILE_PX
    src_transform = from_origin(-_MERC_R + x0 * tile_m, _MERC_R - y0 * tile_m, px, px)
    src_crs = "EPSG:3857"

    dst_crs = "EPSG:4326"
    dst_transform, width, height = calculate_default_transform(
        src_crs, dst_crs, mosaic.shape[1], mosaic.shape[0],
        *rasterio.transform.array_bounds(mosaic.shape[0], mosaic.shape[1], src_transform),
    )
    dest = np.empty((height, width), dtype="float32")
    reproject(
        source=mosaic.astype("float32"), destination=dest,
        src_transform=src_transform, src_crs=src_crs,
        dst_transform=dst_transform, dst_crs=dst_crs,
        resampling=Resampling.bilinear, src_nodata=None, dst_nodata=-9999.0,
    )

    region.dem_path.parent.mkdir(parents=True, exist_ok=True)
    with rasterio.open(
        region.dem_path, "w", driver="GTiff", height=height, width=width, count=1,
        dtype="float32", crs=dst_crs, transform=dst_transform, nodata=-9999.0,
        compress="deflate",
    ) as ds:
        ds.write(dest, 1)
    return region.dem_path


# ------------------------------------------------------------------------- graph


def build_graph(region: Region, *, force: bool = False) -> Path:
    """Download the bike graph and bake elevation + per-edge grade into it.

    Grades are baked at *fixture-build* time, not solve time, because SPIKE-03's
    weight search re-solves the same graph dozens of times per scenario. Sampling a
    GeoTIFF inside the cost function would make the search's cost a measure of
    rasterio rather than of routing.
    """
    if region.graph_path.exists() and not force:
        return region.graph_path

    graph = ox.graph_from_bbox(region.bbox, network_type=region.network_type)

    # osmnx's default keeps the largest *weakly* connected component, which is not a
    # routable guarantee: a node on the far side of a one-way pair, or a service road
    # off a dual carriageway, can be reachable while nothing is reachable *from* it.
    # A synthesised loop anchor landing on one of those killed the whole request with
    # NetworkXNoPath. Strong connectivity means any anchor can reach any other.
    graph = ox.truncate.largest_component(graph, strongly=True)

    graph = ox.elevation.add_node_elevations_raster(graph, build_dem(region), cpus=1)
    graph = ox.elevation.add_edge_grades(graph, add_absolute=True)

    region.graph_path.parent.mkdir(parents=True, exist_ok=True)
    ox.io.save_graphml(graph, region.graph_path)
    return region.graph_path


def build_all(*, force: bool = False) -> list[dict]:
    out = []
    for region in REGIONS.values():
        dem = build_dem(region, force=force)
        graph_path = build_graph(region, force=force)
        graph = ox.io.load_graphml(graph_path)
        elevs = np.array(
            [d["elevation"] for _, d in graph.nodes(data=True)], dtype="float64"
        )
        out.append({
            "region": region.key,
            "name": region.name,
            "character": region.character,
            "nodes": graph.number_of_nodes(),
            "edges": graph.number_of_edges(),
            "elev_min_m": round(float(elevs.min()), 1),
            "elev_max_m": round(float(elevs.max()), 1),
            "relief_m": round(float(elevs.max() - elevs.min()), 1),
            "graph_mb": round(graph_path.stat().st_size / 1e6, 1),
            "dem_mb": round(dem.stat().st_size / 1e6, 1),
        })
    return out


def teardown_cache() -> None:
    """Drop the Overpass response cache. Fixtures themselves are kept."""
    shutil.rmtree(SHARED / "cache", ignore_errors=True)


if __name__ == "__main__":
    import json

    print(json.dumps(build_all(), indent=2))
