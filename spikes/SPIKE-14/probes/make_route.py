"""Emit a real routed polyline as GeoJSON, for the SPIKE-14 rendering harness.

SPIKE-14 asks for "a real routed polyline with node markers", not a synthetic
squiggle. The point of using genuine solver output is that real route geometry has
the vertex density OSM actually produces — a densely-noded switchback costs the
renderer far more per kilometre than a straight rural mile, and a hand-drawn test
line would hide that.

Geometry comes from the same `spikes/shared/fixtures/` graphs SPIKE-01/02/03 ran on,
so the rendering numbers are comparable to the routing numbers already recorded.

Three payloads are written, spanning the range the client must survive:
  day     — one 20 km themed loop, the SPIKE-01 baseline shape
  multi   — several loops chained, standing in for a multi-day trip corridor
  stress  — `multi` densified, to find where the renderer actually breaks
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

SPIKE = Path(__file__).resolve().parent.parent
REPO = SPIKE.parent.parent
sys.path.insert(0, str(REPO / "core"))
sys.path.insert(0, str(REPO / "spikes"))

import networkx as nx  # noqa: E402

from plotlines_core.graph.loader import load_graphml  # noqa: E402
from plotlines_core.routing.loops import generate_loop  # noqa: E402
from plotlines_core.scoring.profile import WeightProfile  # noqa: E402

FIXTURES = REPO / "spikes" / "shared" / "fixtures"
OUT = SPIKE / "harness" / "assets"


def edge_coords(graph: nx.MultiDiGraph, walk) -> list[list[float]]:
    """[lon, lat] vertices along the walk, using each edge's own geometry.

    OSMnx stores a `geometry` LineString on edges that are not straight lines. Using
    the node-to-node straight segment instead would quietly discard most of the
    vertices on exactly the curvy terrain that stresses a renderer hardest.
    """
    coords: list[list[float]] = []
    for u, v, data in walk:
        geom = data.get("geometry")
        if geom is not None:
            pts = [[float(x), float(y)] for x, y in geom.coords]
        else:
            pts = [
                [float(graph.nodes[u]["x"]), float(graph.nodes[u]["y"])],
                [float(graph.nodes[v]["x"]), float(graph.nodes[v]["y"])],
            ]
        if coords and pts and coords[-1] == pts[0]:
            pts = pts[1:]
        coords.extend(pts)
    return coords


def solve(region: str, target_m: float, bearing: float) -> tuple[list, list, dict]:
    loaded = load_graphml(FIXTURES / f"{region}.graphml")
    graph = loaded.graph
    ys = [d["y"] for _, d in graph.nodes(data=True)]
    xs = [d["x"] for _, d in graph.nodes(data=True)]
    centre = (sum(ys) / len(ys), sum(xs) / len(xs))

    profile = WeightProfile(name="scenic", scenic=0.7, quiet=0.7, peaks=0.3)
    loop = generate_loop(graph, centre, target_m, profile, base_bearing=bearing)

    coords = edge_coords(graph, loop.walk)
    return coords, markers_along(coords, 12), loop.summary()


def markers_along(coords: list[list[float]], count: int) -> list[dict]:
    """`count` marker positions spread evenly along the polyline.

    A Plotlines Node is an Author-designated waypoint — a scene on the route — not a
    graph vertex, so marker count is a story-authoring number (a dozen or so a day),
    not a routing one. The solver's own anchor list is far too small to stand in for
    it: a themed loop needs only one anchor, which would understate marker cost by an
    order of magnitude.
    """
    if not coords:
        return []
    step = max(len(coords) // count, 1)
    return [
        {"lon": coords[i][0], "lat": coords[i][1]}
        for i in range(0, len(coords), step)
    ][:count]


def feature_collection(coords, nodes, props) -> dict:
    return {
        "type": "FeatureCollection",
        "properties": props,
        "features": [
            {
                "type": "Feature",
                "properties": {"kind": "route"},
                "geometry": {"type": "LineString", "coordinates": coords},
            },
            *[
                {
                    "type": "Feature",
                    "properties": {"kind": "node", "index": i},
                    "geometry": {"type": "Point", "coordinates": [n["lon"], n["lat"]]},
                }
                for i, n in enumerate(nodes)
            ],
        ],
    }


def densify(coords: list[list[float]], factor: int) -> list[list[float]]:
    """Insert `factor - 1` interpolated vertices into every segment.

    This raises vertex count without changing the drawn shape, which isolates
    "how many points" from "how much screen area" as a performance variable.
    """
    if factor <= 1:
        return coords
    out: list[list[float]] = []
    for i in range(len(coords) - 1):
        (x0, y0), (x1, y1) = coords[i], coords[i + 1]
        for s in range(factor):
            t = s / factor
            out.append([x0 + (x1 - x0) * t, y0 + (y1 - y0) * t])
    out.append(coords[-1])
    return out


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}

    day_coords, day_nodes, day_props = solve("boulder", 20_000, 0.0)
    report["day"] = {**day_props, "vertices": len(day_coords), "markers": len(day_nodes)}
    (OUT / "route_day.geojson").write_text(
        json.dumps(feature_collection(day_coords, day_nodes, report["day"]))
    )

    # A multi-day corridor is not one 20 km loop; it is several days' riding laid
    # end to end. Chaining differently-oriented loops from the same graph produces a
    # realistically long, realistically noded polyline without inventing geometry.
    multi_coords: list[list[float]] = []
    multi_nodes: list[dict] = []
    for i, bearing in enumerate((0.0, 72.0, 144.0, 216.0, 288.0)):
        c, n, _ = solve("boulder", 40_000, bearing)
        multi_coords.extend(c)
        multi_nodes.extend(n)
    report["multi"] = {"vertices": len(multi_coords), "markers": len(multi_nodes)}
    (OUT / "route_multi.geojson").write_text(
        json.dumps(feature_collection(multi_coords, multi_nodes, report["multi"]))
    )

    stress_coords = densify(multi_coords, 6)
    report["stress"] = {"vertices": len(stress_coords), "markers": len(multi_nodes)}
    (OUT / "route_stress.geojson").write_text(
        json.dumps(feature_collection(stress_coords, multi_nodes, report["stress"]))
    )

    lons = [c[0] for c in multi_coords]
    lats = [c[1] for c in multi_coords]
    report["bbox"] = [min(lons), min(lats), max(lons), max(lats)]

    (SPIKE / "results" / "route_payloads.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
