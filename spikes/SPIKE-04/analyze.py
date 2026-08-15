"""SPIKE-04 step 3 — is the OSM waterway data a *routable network*, or just lines?

Counting tags (`probe_osm.py`) answers "does the data exist". It does not answer the
question the architecture actually asks, which is whether `WaterwayDataProvider` can
return a `WaterwayGraph` that the mode-agnostic scorer can solve over. Those are
different questions, and the gap between them is where paddling either works or doesn't:

  * **Topology.** Waterways are drawn as centrelines for cartography, not for routing.
    Two ways that *look* joined on a map are only joined to a router if they share an OSM
    node. This measures the real component structure, and reports the share of paddleable
    kilometres sitting in the largest connected component — the only part a solver can
    plan a trip across.
  * **Attachment.** A put-in that does not sit on the network cannot start a route, and a
    gauge that cannot be tied to a reach cannot gate one. Both are measured as a geodesic
    snap distance, not assumed.
  * **A real solve.** The end of the analysis routes between the two most distant access
    points in the largest component. If that returns a plausible river distance, the
    provider seam has something real to return; if it doesn't, the rest is bookkeeping.

Distances are computed in a region-local azimuthal-equidistant projection so a "50 m"
threshold means 50 m, rather than 50 m of longitude at one latitude and something else at
another.

Usage:
    python spikes/SPIKE-04/analyze.py           # needs probe_osm.py + probe_gauges.py first
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import networkx as nx
from pyproj import CRS, Transformer
from shapely.geometry import LineString, Point
from shapely.ops import nearest_points
from shapely.strtree import STRtree

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from regions import REGIONS  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"

# A put-in tagged more than this far from the nearest mapped waterway centreline is not
# usable as a route endpoint without human repair. 50 m is generous: it is wider than
# most rivers in these regions, so anything beyond it is a genuine mismatch rather than
# bank-versus-centreline error.
SNAP_M = 50.0


def local_transformer(region):
    crs = CRS.from_proj4(
        f"+proj=aeqd +lat_0={(region.south + region.north) / 2} "
        f"+lon_0={(region.west + region.east) / 2} +datum=WGS84 +units=m +no_defs")
    return Transformer.from_crs("EPSG:4326", crs, always_xy=True)


def load(region, name: str) -> list[dict]:
    path = RAW / f"{region.key}-{name}.json"
    if not cache.exists(path):
        raise SystemExit(f"missing {path} — run probe_osm.py first")
    return cache.load(path).get("elements", [])


def build_graph(ways: list[dict], tf) -> tuple[nx.Graph, dict]:
    """Node identity is the **OSM node id**, not a rounded coordinate. Rounding would
    silently weld together ways that merely pass near each other — inventing exactly the
    connectivity this analysis is trying to measure."""
    graph = nx.Graph()
    coords: dict[int, tuple[float, float]] = {}
    no_node_ids = 0

    for way in ways:
        geometry = way.get("geometry") or []
        node_ids = way.get("nodes") or []
        if len(node_ids) != len(geometry):
            no_node_ids += 1
            continue
        pts = [tf.transform(g["lon"], g["lat"]) for g in geometry]
        for nid, pt in zip(node_ids, pts):
            coords[nid] = pt
        for a, b, pa, pb in zip(node_ids, node_ids[1:], pts, pts[1:]):
            length = ((pa[0] - pb[0]) ** 2 + (pa[1] - pb[1]) ** 2) ** 0.5
            if graph.has_edge(a, b):
                continue
            graph.add_edge(a, b, length_m=length, way=way["id"],
                           waterway=way.get("tags", {}).get("waterway", ""))
    return graph, {"coords": coords, "ways_without_node_ids": no_node_ids}


def component_stats(graph: nx.Graph) -> dict:
    comps = sorted(nx.connected_components(graph), key=len, reverse=True)
    def km(nodes):
        sub = graph.subgraph(nodes)
        return sum(d["length_m"] for _, _, d in sub.edges(data=True)) / 1000
    total_km = sum(d["length_m"] for _, _, d in graph.edges(data=True)) / 1000
    largest_km = km(comps[0]) if comps else 0.0
    return {
        "total_km": round(total_km, 1),
        "components": len(comps),
        "largest_component_km": round(largest_km, 1),
        "largest_component_share": round(largest_km / total_km, 3) if total_km else 0.0,
        "components_over_10km": sum(1 for c in comps if km(c) >= 10),
        "_largest": comps[0] if comps else set(),
    }


def longest_run_km(graph: nx.Graph, component: set) -> float:
    """Double-sweep Dijkstra: the longest shortest-path in the component, which is the
    honest ceiling on 'how far could a trip go without leaving the water'."""
    if len(component) < 2:
        return 0.0
    sub = graph.subgraph(component)
    start = next(iter(component))
    far_a = max(nx.single_source_dijkstra_path_length(sub, start, weight="length_m").items(),
                key=lambda kv: kv[1])[0]
    far_b_len = max(nx.single_source_dijkstra_path_length(sub, far_a, weight="length_m").values())
    return round(far_b_len / 1000, 1)


def snap_distances(points: list[tuple[float, float]], lines: list[LineString]) -> list[float]:
    """Geodesic-equivalent snap distance from each point to the nearest line, in metres
    (inputs are already in the region-local metric projection)."""
    if not lines or not points:
        return []
    tree = STRtree(lines)
    out = []
    for xy in points:
        p = Point(xy)
        line = lines[int(tree.nearest(p))]   # shapely 2.x returns a positional index
        a, b = nearest_points(p, line)
        out.append(a.distance(b))
    return out


def pct(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    return round(s[min(len(s) - 1, int(q * len(s)))], 1)


def analyse(region) -> dict:
    tf = local_transformer(region)
    ways = load(region, "network")
    graph, meta = build_graph(ways, tf)
    stats = component_stats(graph)
    largest = stats.pop("_largest")

    lines = [LineString([tf.transform(g["lon"], g["lat"]) for g in w["geometry"]])
             for w in ways if len(w.get("geometry") or []) >= 2]

    # --- access points ------------------------------------------------------
    access = load(region, "access")
    access_pts, access_named, access_kinds = [], [], {}
    named = 0
    for el in access:
        lat = el.get("lat") or (el.get("center") or {}).get("lat")
        lon = el.get("lon") or (el.get("center") or {}).get("lon")
        if lat is None or lon is None:
            continue
        xy = tf.transform(lon, lat)
        access_pts.append(xy)
        tags = el.get("tags", {})
        # A put-in a Character is told to meet at needs a name. An unnamed node is still
        # routable but is not yet a usable instruction, so count the difference.
        label = tags.get("name")
        named += bool(label)
        access_named.append((label or f"{el['type']}/{el['id']}", xy))
        kind = ("canoe=put_in" if tags.get("canoe") == "put_in"
                else "whitewater=" + tags["whitewater"] if "whitewater" in tags
                else "waterway=access_point" if tags.get("waterway") == "access_point"
                else "leisure=slipway")
        access_kinds[kind] = access_kinds.get(kind, 0) + 1
    access_snap = snap_distances(access_pts, lines)

    # --- gauges -------------------------------------------------------------
    gauges_path = RESULTS / "gauges.json"
    gauge_snap: list[float] = []
    gauge_count = 0
    if gauges_path.exists():
        for entry in json.loads(gauges_path.read_text(encoding="utf-8")):
            if entry["region"] != region.key:
                continue
            pts = [tf.transform(g["lon"], g["lat"]) for g in entry["gauges"]]
            gauge_count = len(pts)
            gauge_snap = snap_distances(pts, lines)

    # --- class ratings on the network --------------------------------------
    # The census counts *elements* carrying a grade. What matters for routing is how many
    # kilometres of the network are graded, because an ungraded edge cannot honour FR13's
    # "never route beyond the stated ability band" — it has no band.
    graded_way_ids = set()
    for el in load(region, "class"):
        if el.get("type") == "way":
            graded_way_ids.add(el["id"])
    graded_km = sum(d["length_m"] for _, _, d in graph.edges(data=True)
                    if d["way"] in graded_way_ids) / 1000

    # --- can we actually route? --------------------------------------------
    route = route_attempt(graph, largest, access_named, meta["coords"])

    return {
        "region": region.key,
        "region_name": region.name,
        "area_km2": round(region.area_km2, 1),
        "network": {
            "ways": len(ways),
            "ways_without_node_ids": meta["ways_without_node_ids"],
            **stats,
            "km_per_1000km2": region.per_1000km2(int(stats["total_km"])),
            "longest_continuous_run_km": longest_run_km(graph, largest),
        },
        "access": {
            "count": len(access_pts),
            "named": named,
            "by_kind": access_kinds,
            "on_network_within_50m": sum(1 for d in access_snap if d <= SNAP_M),
            "median_snap_m": pct(access_snap, 0.5),
            "p90_snap_m": pct(access_snap, 0.9),
        },
        "class": {
            "graded_ways": len(graded_way_ids),
            "graded_km": round(graded_km, 1),
            "graded_share_of_network": (round(graded_km / stats["total_km"], 4)
                                        if stats["total_km"] else 0.0),
        },
        "gauge": {
            "count": gauge_count,
            "within_50m_of_network": sum(1 for d in gauge_snap if d <= SNAP_M),
            "median_snap_m": pct(gauge_snap, 0.5),
        },
        "route": route,
        "nhd": {f"order{o}": nhd_stats(region, o) for o in (3, 4)},
    }


def nhd_stats(region, order: int) -> dict | None:
    """The same connectivity question asked of NHDPlus HR, for a like-for-like comparison.

    The contrast is the point. Here the graph is built from the dataset's own declared
    `fromnode`/`tonode` topology — no geometry, no inference, no snapping tolerance. If
    NHD's largest component holds a far greater share of its kilometres than OSM's does,
    the difference is not that one dataset has more rivers; it is that one was built to be
    traversed and the other was built to be drawn."""
    path = RAW / f"{region.key}-nhd-order{order}.json"
    if not cache.exists(path):
        return None
    rows = cache.load(path)
    if not rows:
        return None

    graph = nx.Graph()
    for r in rows:
        a, b, km = r.get("fromnode"), r.get("tonode"), r.get("lengthkm") or 0.0
        if a is None or b is None:
            continue
        # Parallel flowlines between the same node pair (braided channels, divergences)
        # are real; keep the longer so total km is not silently deflated.
        if graph.has_edge(a, b) and graph[a][b]["length_m"] >= km * 1000:
            continue
        graph.add_edge(a, b, length_m=km * 1000, way=r.get("nhdplusid"), waterway="nhd")

    stats = component_stats(graph)
    largest = stats.pop("_largest")
    return {
        "order_min": order,
        "flowlines": len(rows),
        "named_share": round(sum(1 for r in rows if r.get("gnis_name")) / len(rows), 3),
        "flowdir_set_share": round(
            sum(1 for r in rows if r.get("flowdir") == 1) / len(rows), 3),
        **stats,
        "km_per_1000km2": region.per_1000km2(int(stats["total_km"])),
        "longest_continuous_run_km": longest_run_km(graph, largest),
    }


def route_attempt(graph, largest, access_named, coords) -> dict:
    """Route between the two most distant access points that both sit on the largest
    component. This is the spike's 'real route' test — the paddling equivalent of what
    SPIKE-00's harness demanded of the cycling graph: not "does the data parse" but "does
    a solver get a route out of it"."""
    if not largest or not access_named:
        return {"attempted": False, "reason": "no network component or no access points"}

    sub = graph.subgraph(largest)
    node_pts = [Point(coords[n]) for n in sub.nodes]
    node_ids = list(sub.nodes)
    if len(node_ids) < 2:
        return {"attempted": False, "reason": "largest component has <2 nodes"}
    tree = STRtree(node_pts)

    # Access points snap to the *largest component*; one that snaps 3 km away is not on
    # this river system at all and must not be counted as an endpoint for it.
    ON_COMPONENT_M = 200.0
    anchors: dict[int, str] = {}
    for name, xy in access_named:
        p = Point(xy)
        idx = int(tree.nearest(p))
        node = node_ids[idx]
        if p.distance(node_pts[idx]) <= ON_COMPONENT_M:
            anchors.setdefault(node, name)

    if len(anchors) < 2:
        return {"attempted": True, "routed": False,
                "reason": f"only {len(anchors)} access point(s) sit on the largest "
                          f"component within {ON_COMPONENT_M:.0f} m",
                "anchors_on_largest_component": len(anchors)}

    # Dijkstra from each anchor; keep the longest anchor-to-anchor water distance.
    best = (0.0, None, None)
    for node in list(anchors)[:40]:      # bounded: this is a spike, not a solver
        lengths = nx.single_source_dijkstra_path_length(sub, node, weight="length_m")
        for other, dist in lengths.items():
            if other in anchors and other != node and dist > best[0]:
                best = (dist, node, other)

    if best[1] is None:
        return {"attempted": True, "routed": False,
                "reason": "anchors are on the component but mutually unreachable",
                "anchors_on_largest_component": len(anchors)}

    path = nx.shortest_path(sub, best[1], best[2], weight="length_m")
    return {
        "attempted": True,
        "routed": True,
        "anchors_on_largest_component": len(anchors),
        "from": anchors[best[1]],
        "to": anchors[best[2]],
        "water_distance_km": round(best[0] / 1000, 1),
        "path_nodes": len(path),
    }


def main() -> int:
    out = []
    for region in REGIONS:
        print(f"\n=== {region.name} ===")
        result = analyse(region)
        out.append(result)
        n, a, c, g = (result["network"], result["access"],
                      result["class"], result["gauge"])
        print(f"  network  {n['total_km']:,} km in {n['components']:,} components; "
              f"largest {n['largest_component_km']:,} km "
              f"({n['largest_component_share']:.1%}); "
              f"longest run {n['longest_continuous_run_km']:,} km")
        print(f"  access   {a['count']} points, {a['on_network_within_50m']} within "
              f"{SNAP_M:.0f} m of the network (median {a['median_snap_m']} m)")
        print(f"  class    {c['graded_ways']} graded ways = {c['graded_km']} km "
              f"({c['graded_share_of_network']:.2%} of network)")
        print(f"  gauge    {g['count']} gauges, {g['within_50m_of_network']} within "
              f"{SNAP_M:.0f} m of the network (median {g['median_snap_m']} m)")
        nhd = result["nhd"].get("order4")
        if nhd:
            print(f"  NHD>=4   {nhd['total_km']:,} km in {nhd['components']:,} "
                  f"components; largest {nhd['largest_component_km']:,} km "
                  f"({nhd['largest_component_share']:.1%}); "
                  f"longest run {nhd['longest_continuous_run_km']:,} km")
        r = result["route"]
        if r.get("routed"):
            print(f"  ROUTE    {r['water_distance_km']} km on water: "
                  f"{r['from']} -> {r['to']} ({r['path_nodes']} nodes)")
        else:
            print(f"  ROUTE    not routed: {r.get('reason')}")

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "network.json").write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"\nwrote {RESULTS / 'network.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
