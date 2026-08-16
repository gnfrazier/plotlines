"""SPIKE-19 step 3 — routability: does a real paddling route come out of 3DHP?

SPIKE-04 proved a *connected directed graph* exists in NHDPlus HR, and said plainly what
it had not done (§10): the topology came from declared attributes, **no geometry was ever
fetched, and the route it published was solved over OSM**. This is where that gap closes.
Everything below is computed from 3DHP geometry and 3DHP topology, so a route here is a
route on the network the provider would actually ship.

Four things are measured, in the order they can invalidate each other:

1. **Topology reconstruction.** 3DHP has no `fromnode`/`tonode`. Connectivity is carried
   by `hydrosequence` / `dnhydrosequence` — a downstream pointer per flowline. That is
   still *declared* topology, so it inherits NHDPlus HR's advantage over OSM's inferred
   shared vertices, but it is a different shape and it has to be inverted to get a graph.
   If this step is wrong every number after it is decoration.
2. **Connectivity**, reported the way SPIKE-04 §3.1 reported it, so the two are readable
   side by side.
3. **A real put-in to take-out route**, over the same OSM access points SPIKE-04 used, so
   the comparison is the network and not the endpoints. Solved **downstream-only**, which
   is what a paddling route actually is, and undirected as well because that is what
   SPIKE-04's 151.1 km figure was.
4. **The corridor clip** — what a buffered flowline network weighs for a multi-day trip,
   which is the half of FR64's package budget SPIKE-14 could not supply.

Usage:
    python spikes/SPIKE-19/analyze.py
"""

from __future__ import annotations

import collections
import gzip
import json
import math
import time
from pathlib import Path

import networkx as nx
from pyproj import Geod

from common import RAW, REGIONS, RESULTS, cache

GEOD = Geod(ellps="WGS84")
SPIKE04_RAW = Path(__file__).parent.parent / "SPIKE-04" / "raw"

# SPIKE-04 §4 measured access-point snapping at 50 m and found the failures were lake
# ramps up to 3 km from a centreline. The same threshold is used here so the two access
# tables mean the same thing; 200 m is reported alongside because SPIKE-04's own routing
# attempt used it.
SNAP_M = (50, 200)


def load_flowlines(region_key: str, order: int) -> list[dict]:
    return cache.load(RAW / f"{region_key}-3dhp-order{order}.json")


def access_points(region_key: str) -> list[dict]:
    """OSM paddling access points, from SPIKE-04's committed cache.

    Reused rather than re-queried: this spike is testing the network, and changing the
    endpoints at the same time would make any difference in the route unattributable.
    """
    path = SPIKE04_RAW / f"{region_key}-access.json"
    if not cache.exists(path):
        return []
    out = []
    for el in cache.load(path).get("elements", []):
        lat = el.get("lat") or (el.get("center") or {}).get("lat")
        lon = el.get("lon") or (el.get("center") or {}).get("lon")
        if lat is None or lon is None:
            continue
        out.append({"id": el.get("id"), "lat": lat, "lon": lon,
                    "name": (el.get("tags") or {}).get("name"),
                    "tags": el.get("tags") or {}})
    return out


def build_graph(rows: list[dict]) -> tuple[nx.DiGraph, dict]:
    """Flowline-as-node graph, wired by the hydrosequence downstream pointer.

    Each flowline becomes a node carrying its own length; an arc runs from a flowline to
    the flowline it drains into. Weighting by the *target's* length makes a path's cost
    the water actually travelled after the first segment, which is the correct thing to
    minimise and the reason lengths live on nodes rather than arcs here.

    `dnhydrosequence` is 0 (or absent) at a terminus. Divergences mean the inverse map is
    one-to-many, which is why the arcs are built by inverting rather than by assuming each
    flowline has a single upstream neighbour — `uphydrosequence` names only the *main*
    upstream path and would quietly drop every tributary at a confluence.
    """
    by_hydroseq: dict[float, str] = {}
    for r in rows:
        hs = r.get("hydrosequence")
        if hs:
            by_hydroseq[hs] = r["id3dhp"]

    g = nx.DiGraph()
    for r in rows:
        g.add_node(r["id3dhp"], km=r.get("lengthkm") or 0.0,
                   name=r.get("gnisidlabel"), order=r.get("streamorder"),
                   mainstem=r.get("mainstemid"), ftype=r.get("featuretypelabel"))

    linked = dangling = terminal = 0
    for r in rows:
        dn = r.get("dnhydrosequence")
        if not dn:
            terminal += 1
            continue
        tgt = by_hydroseq.get(dn)
        if tgt is None:
            # The downstream flowline exists in the national dataset but falls outside
            # this bbox or below the order threshold. Not an error — a clipped network
            # has edges to the outside world — but it must be counted, because a high
            # rate would mean the threshold is severing the network rather than filtering
            # it.
            dangling += 1
            continue
        g.add_edge(r["id3dhp"], tgt, km=g.nodes[tgt]["km"])
        linked += 1

    stats = {
        "flowlines": len(rows),
        "arcs": linked,
        "terminal_no_downstream": terminal,
        "downstream_outside_selection": dangling,
        "downstream_resolved_pct": round(
            100 * linked / max(1, linked + dangling + terminal), 1),
    }
    return g, stats


def component_report(g: nx.DiGraph) -> dict:
    total_km = sum(d["km"] for _, d in g.nodes(data=True))
    comps = list(nx.weakly_connected_components(g))
    comps.sort(key=lambda c: sum(g.nodes[n]["km"] for n in c), reverse=True)
    largest = comps[0] if comps else set()
    largest_km = sum(g.nodes[n]["km"] for n in largest)
    return {
        "total_km": round(total_km, 1),
        "components": len(comps),
        "largest_component_km": round(largest_km, 1),
        "largest_component_pct": round(100 * largest_km / total_km, 1) if total_km else 0,
        "_largest": largest,
    }


def longest_downstream_run(g: nx.DiGraph, nodes: set[str]) -> tuple[float, list[str]]:
    """Longest directed downstream path, in km.

    The graph is a DAG in the direction water flows, so this is a longest-path problem
    solved in topological order rather than a search. It is the honest "longest continuous
    run" for paddling: the furthest a boat can go without leaving the water or going
    upstream.
    """
    sub = g.subgraph(nodes)
    try:
        order = list(nx.topological_sort(sub))
    except nx.NetworkXUnfeasible:
        # A cycle means the hydrosequence chain is not acyclic in this clip — worth
        # knowing rather than crashing on.
        return (float("nan"), [])
    best: dict[str, float] = {}
    prev: dict[str, str | None] = {}
    for n in order:
        best[n] = sub.nodes[n]["km"]
        prev[n] = None
        for p in sub.predecessors(n):
            cand = best.get(p, 0) + sub.nodes[n]["km"]
            if cand > best[n]:
                best[n] = cand
                prev[n] = p
    if not best:
        return (0.0, [])
    end = max(best, key=best.get)
    path, cur = [], end
    while cur is not None:
        path.append(cur)
        cur = prev[cur]
    return round(best[end], 1), list(reversed(path))


def snap_access(rows: list[dict], pts: list[dict]) -> list[dict]:
    """Nearest flowline vertex per access point, with the geodesic distance.

    Brute force over vertices with a cheap degree-box prefilter. scipy is not installed in
    this venv and adding a dependency to a spike for one nearest-neighbour query is a bad
    trade; the prefilter keeps it to seconds.
    """
    verts = []
    for r in rows:
        for path in r.get("_paths", []):
            for lon, lat in path:
                verts.append((lon, lat, r["id3dhp"]))
    out = []
    for p in pts:
        plat, plon = p["lat"], p["lon"]
        # ~0.05 deg latitude is ~5.5 km; widen until something is in the box.
        best = None
        for box in (0.05, 0.2, 1.0, 90.0):
            cand = [v for v in verts
                    if abs(v[1] - plat) < box and abs(v[0] - plon) < box]
            if cand:
                for lon, lat, fid in cand:
                    _, _, d = GEOD.inv(plon, plat, lon, lat)
                    if best is None or d < best[0]:
                        best = (d, fid)
                break
        if best:
            out.append({**p, "snap_m": round(best[0], 1), "flowline": best[1]})
    return out


def route(g: nx.DiGraph, snapped: list[dict], component: set[str],
          limit_pairs: int = 4000) -> dict:
    """Longest real put-in to take-out route on the largest component.

    Reported twice. **Downstream** is the paddling answer: a directed path, which is what
    a boat can actually do. **Undirected** is the comparison to SPIKE-04's 151.1 km, which
    was solved on an undirected OSM graph and would otherwise look like a regression when
    it is a change of question.
    """
    on = [s for s in snapped if s["flowline"] in component]
    if len(on) < 2:
        return {"access_on_component": len(on), "downstream": None, "undirected": None}

    und = g.to_undirected(as_view=True)
    result: dict = {"access_on_component": len(on)}

    for mode, graph in (("downstream", g), ("undirected", und)):
        t0 = time.perf_counter()
        best = None
        # All-pairs over the access points that sit on the component. Bounded by
        # limit_pairs so a dense region cannot turn the spike into an overnight job.
        srcs = on[:int(math.sqrt(limit_pairs)) + 1] if len(on) ** 2 > limit_pairs else on
        for a in srcs:
            try:
                lengths = nx.single_source_dijkstra_path_length(
                    graph, a["flowline"], weight="km")
            except nx.NodeNotFound:
                continue
            for b in on:
                if b["flowline"] == a["flowline"]:
                    continue
                km = lengths.get(b["flowline"])
                if km is not None and (best is None or km > best["km"]):
                    best = {"km": round(km, 1), "from": a, "to": b}
        if best:
            best["solve_s"] = round(time.perf_counter() - t0, 2)
            best["from"] = {k: best["from"][k] for k in ("name", "lat", "lon", "snap_m")}
            best["to"] = {k: best["to"][k] for k in ("name", "lat", "lon", "snap_m")}
        result[mode] = best
    return result


def corridor_clip(rows: list[dict], path_ids: list[str], buffer_km: float) -> dict:
    """Size a true buffered flowline clip around a real route.

    A **distance buffer, not a bounding box.** The first version of this measurement took
    the route's bbox and expanded it, and the numbers gave the mistake away: a 2 km and a
    5 km "buffer" differed by 10%, because a 176 km sinuous river has a bbox tens of times
    larger than its own corridor and the bbox was doing all the work. A trip package that
    sized itself that way would ship most of a state.

    Implemented as a degree-grid index over the route's vertices — cells sized to the
    buffer, so a candidate only has to check the nine cells around it. Longitude degrees
    are shortened by cos(lat) so the cells stay roughly square in metres; the final test is
    a real geodesic distance, so the grid only decides what to test, never what to keep.
    """
    by_id = {r["id3dhp"]: r for r in rows}
    route_pts = [(lon, lat) for fid in path_ids
                 for path in by_id.get(fid, {}).get("_paths", [])
                 for lon, lat in path]
    if not route_pts:
        return {}

    mean_lat = sum(p[1] for p in route_pts) / len(route_pts)
    lat_deg = buffer_km / 110.574
    lon_deg = buffer_km / (111.320 * max(0.1, math.cos(math.radians(mean_lat))))

    grid: dict[tuple[int, int], list[tuple[float, float]]] = collections.defaultdict(list)
    for lon, lat in route_pts:
        grid[(int(lon / lon_deg), int(lat / lat_deg))].append((lon, lat))

    buf_m = buffer_km * 1000.0

    def within(lon: float, lat: float) -> bool:
        cx, cy = int(lon / lon_deg), int(lat / lat_deg)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for rlon, rlat in grid.get((cx + dx, cy + dy), ()):
                    if GEOD.inv(lon, lat, rlon, rlat)[2] <= buf_m:
                        return True
        return False

    kept = [r for r in rows
            if any(within(lon, lat)
                   for path in r.get("_paths", []) for lon, lat in path)]

    # Two payloads, because they answer different questions. "full" is every attribute the
    # service returned; "routing" is what a provider actually needs to rebuild the graph
    # and bind a gauge — geometry, identity, length, order, direction, topology, mainstem.
    # Shipping the first when the second would do is the easiest way to double a package.
    keep_fields = ("id3dhp", "mainstemid", "lengthkm", "streamorder", "flowdirection",
                   "hydrosequence", "dnhydrosequence", "gnisidlabel", "_paths")
    full = json.dumps(kept, separators=(",", ":")).encode()
    routing = json.dumps([{k: r.get(k) for k in keep_fields} for r in kept],
                         separators=(",", ":")).encode()
    return {
        "buffer_km": buffer_km,
        "flowlines": len(kept),
        "km": round(sum(r.get("lengthkm") or 0 for r in kept), 1),
        "vertices": sum(len(p) for r in kept for p in r.get("_paths", [])),
        "full_gzip_kb": round(len(gzip.compress(full, 6)) / 1024, 1),
        "routing_gzip_kb": round(len(gzip.compress(routing, 6)) / 1024, 1),
    }


def main() -> int:
    report: dict = {"regions": {}}
    for region in REGIONS:
        print(f"\n=== {region.name} ===")
        entry: dict = {}
        for order in (3, 4):
            rows = load_flowlines(region.key, order)
            g, topo = build_graph(rows)
            comp = component_report(g)
            largest = comp.pop("_largest")
            run_km, run_path = longest_downstream_run(g, largest)
            o = {"topology": topo, "connectivity": comp,
                 "longest_downstream_run_km": run_km}
            print(f"  order>={order}: {topo['flowlines']:,} flowlines, "
                  f"{comp['total_km']:,.0f} km, {comp['components']:,} components, "
                  f"largest {comp['largest_component_pct']}%, "
                  f"longest downstream run {run_km:,.0f} km")
            print(f"            downstream pointer resolved on "
                  f"{topo['downstream_resolved_pct']}% "
                  f"({topo['downstream_outside_selection']:,} leave the selection, "
                  f"{topo['terminal_no_downstream']:,} terminal)")

            if order == 4:
                pts = access_points(region.key)
                snapped = snap_access(rows, pts)
                for thr in SNAP_M:
                    n = sum(1 for s in snapped if s["snap_m"] <= thr)
                    o[f"access_within_{thr}m"] = n
                o["access_total"] = len(pts)
                o["access_median_snap_m"] = round(
                    sorted(s["snap_m"] for s in snapped)[len(snapped) // 2], 1
                ) if snapped else None
                print(f"            access: {len(pts)} points, "
                      f"{o['access_within_50m']} within 50 m, "
                      f"{o['access_within_200m']} within 200 m, "
                      f"median snap {o['access_median_snap_m']} m")

                usable = [s for s in snapped if s["snap_m"] <= 200]
                o["route"] = route(g, usable, largest)
                r = o["route"]
                for mode in ("downstream", "undirected"):
                    if r.get(mode):
                        b = r[mode]
                        print(f"            route [{mode}]: {b['km']:,.1f} km  "
                              f"{b['from']['name'] or '(unnamed)'} -> "
                              f"{b['to']['name'] or '(unnamed)'}  ({b['solve_s']}s)")
                    else:
                        print(f"            route [{mode}]: none "
                              f"({r['access_on_component']} access on largest component)")

                if run_path:
                    o["corridor"] = {str(b): corridor_clip(rows, run_path, b)
                                     for b in (2, 5)}
                    for b, c in o["corridor"].items():
                        print(f"            corridor {b} km: {c['flowlines']:,} "
                              f"flowlines, {c['km']:,.0f} km, "
                              f"{c['routing_gzip_kb']:,.0f} KB gz routing / "
                              f"{c['full_gzip_kb']:,.0f} KB gz full")
            entry[f"order{order}"] = o
        report["regions"][region.key] = entry

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "routability.json").write_text(json.dumps(report, indent=2, default=str),
                                              encoding="utf-8")
    print(f"\nwrote {RESULTS / 'routability.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
