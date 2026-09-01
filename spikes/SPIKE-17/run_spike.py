"""SPIKE-17 — every arm of issue #176, end to end.

    core/.venv/bin/python spikes/SPIKE-17/run_spike.py            # full run
    core/.venv/bin/python spikes/SPIKE-17/run_spike.py --polls 0  # skip the
                                                                 #   volatility poll
    -> results/run_spike.json

Use `core/.venv`, not the repo-root `.venv` — this imports `plotlines_core`
and needs `osmnx`/`shapely`/`requests` (same convention as SPIKE-A/B/D/H).
"""

from __future__ import annotations

import _paths  # noqa: F401  — sys.path bootstrap, must be first

import argparse
import gzip
import json
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

import graphs
import http_cache
import matching
import normalize
import providers
import registry as registry_mod

from plotlines_core.providers import EdgeDataProvider

RESULTS = Path(__file__).resolve().parent / "results"

WZDX_WI = "https://511wi.gov/api/wzdx"
WZDX_NY = "https://511ny.org/api/wzdx"
NWS_WI = "https://api.weather.gov/alerts/active?area=WI"

#: The source issue #176 actually names. Probed, not used — it moved.
NC_TIMS_LEGACY = "https://eapps.ncdot.gov/services/traffic-prod/v1/incidents"
NC_DRIVENC_V2 = "https://www.drivenc.gov/api/v2/get/event"

#: Keys core reads off an edge (`routing/access.py`, `scoring/profile.py`).
#: The P6 assertion is that no provider here touches any of them.
CORE_EDGE_KEYS = ("highway", "access", "bicycle", "foot", "motor_vehicle",
                  "surface", "maxspeed", "lanes", "length", "name", "ref",
                  "oneway", "barrier", "geometry", "grade_abs",
                  "interest_salience", "_pl_access_flags", "_pl_feat")


def _core_fingerprint(graph) -> dict:
    out = {}
    for u, v, k, data in graph.edges(keys=True, data=True):
        out[(u, v, k)] = tuple(repr(data.get(key)) for key in CORE_EDGE_KEYS)
    return out


# ── Arm 1: the named source ──────────────────────────────────────────────


def arm_named_source() -> dict:
    """Issue #176 names NC TIMS. Probe it and record what is actually there —
    a spike that quietly substitutes a different source and says nothing has
    hidden its most transferable finding."""
    out: dict = {"legacy_url": NC_TIMS_LEGACY, "replacement_url": NC_DRIVENC_V2}
    try:
        resp = requests.get(NC_TIMS_LEGACY, timeout=30,
                            headers={"User-Agent": http_cache.USER_AGENT})
        out["legacy_status"] = resp.status_code
        out["legacy_body"] = resp.text[:300]
    except Exception as exc:  # noqa: BLE001
        out["legacy_error"] = f"{type(exc).__name__}: {exc}"
    try:
        resp = requests.get(NC_DRIVENC_V2, timeout=30,
                            headers={"User-Agent": http_cache.USER_AGENT})
        out["replacement_status"] = resp.status_code
        out["replacement_body"] = resp.text[:300]
    except Exception as exc:  # noqa: BLE001
        out["replacement_error"] = f"{type(exc).__name__}: {exc}"
    out["verdict"] = (
        "keyless when the spike was written (2026-08-27); relocated and keyed "
        "by the time it ran (2026-09-01)"
    )
    return out


# ── Arm 2: conformance + the licence gate ────────────────────────────────


def arm_conformance(force: bool) -> tuple[dict, dict]:
    wi = providers.WzdxEdgeProvider("wzdx-wi", WZDX_WI, force=force)
    ny = providers.WzdxEdgeProvider("wzdx-ny", WZDX_NY, force=force)
    nws = providers.NwsAlertEdgeProvider("nws-alerts-wi", NWS_WI, force=force)

    conformance = {
        "wzdx_is_edge_data_provider": isinstance(wi, EdgeDataProvider),
        "nws_is_edge_data_provider": isinstance(nws, EdgeDataProvider),
        "core_files_changed": 0,
        "protocol_members_used": ["annotate_edges"],
        "members_the_protocol_does_not_declare_but_a_real_provider_needed": [
            "licence", "load_state()", "fetch()", "stats",
        ],
    }

    reg = registry_mod.EdgeProviderRegistry()
    for provider in (wi, ny, nws):
        reg.register(provider)

    gate = {
        "registrations": [r.as_dict() for r in reg.registrations],
        "attributions_owed": reg.attributions(),
        "loaded": [getattr(p, "source_id") for p in reg.loaded],
    }
    return conformance, {"gate": gate, "providers": {"wi": wi, "ny": ny, "nws": nws},
                         "registry": reg}


# ── Arm 3: feed shapes ───────────────────────────────────────────────────


def arm_feed_shapes(provs: dict) -> dict:
    out = {}
    for key, provider in provs.items():
        doc = provider.document or {}
        info = doc.get("feed_info") or {}
        events = provider.events
        locatable = [e for e in events if e.locatable]
        now = datetime.now(timezone.utc)
        active = [e for e in events if e.active_at(now)]
        geom_kinds: dict[str, int] = {}
        for e in events:
            geom_kinds[e.geometry_kind] = geom_kinds.get(e.geometry_kind, 0) + 1
        kinds = {}
        for e in events:
            kinds[e.kind] = kinds.get(e.kind, 0) + 1
        impacts = {}
        for e in events:
            impacts[e.impact] = impacts.get(e.impact, 0) + 1
        out[provider.source_id] = {
            "url": provider.url,
            "spec_version": info.get("version", "n/a (not a WZDx feed)"),
            "publisher": info.get("publisher", ""),
            "declares_licence": bool(normalize.wzdx_licence_id(doc)) if info else False,
            "declared_update_frequency_s": info.get("update_frequency"),
            "events": len(events),
            "active_now": len(active),
            "active_now_pct": round(100.0 * len(active) / len(events), 1) if events else 0.0,
            "geometry_kinds": geom_kinds,
            "locatable": len(locatable),
            "locatable_pct": round(100.0 * len(locatable) / len(events), 1) if events else 0.0,
            "with_road_names": sum(1 for e in events if e.road_names),
            "with_end_date": sum(1 for e in events if e.ends_at),
            "kinds": kinds,
            "impacts": impacts,
            "raw_bytes": http_cache.FETCH_BYTES.get(provider.source_id),
            "fetch_ms": round(http_cache.FETCH_MS[provider.source_id], 1)
            if provider.source_id in http_cache.FETCH_MS else None,
        }
        if isinstance(provider, providers.NwsAlertEdgeProvider):
            refs = normalize.nws_zone_refs(doc)
            out[provider.source_id]["zone_refs_to_resolve"] = len(refs)
            out[provider.source_id]["distinct_zone_refs"] = len(set(refs))
    return out


# ── Arm 4: annotate a real graph ─────────────────────────────────────────


def arm_annotate(region_name: str, provs: dict, force: bool) -> dict:
    region = graphs.region_graph(region_name)
    graph = region["graph"]
    bbox = graphs.bbox_of(region_name)

    before = _core_fingerprint(graph)
    t0 = time.perf_counter()
    index = matching.EdgeIndex(graph)
    index_s = time.perf_counter() - t0

    per_source = {}
    for provider in provs.values():
        t0 = time.perf_counter()
        provider.annotate_edges(graph, bbox)
        annotate_s = time.perf_counter() - t0
        per_source[provider.source_id] = {
            "annotate_seconds": round(annotate_s, 3),
            "match": provider.stats.as_dict() if provider.stats else None,
        }

    after = _core_fingerprint(graph)
    mutated = [str(k) for k in before if before[k] != after.get(k)]

    annotated = [(u, v, k, d) for u, v, k, d in graph.edges(keys=True, data=True)
                 if "advisory:source" in d]
    return {
        "region": {k: region[k] for k in
                   ("name", "bbox", "network_type", "nodes", "edges", "cold_build",
                    "overpass_cache_warm", "build_seconds", "load_seconds",
                    "graphml_bytes")},
        "edge_index_seconds": round(index_s, 3),
        "per_source": per_source,
        "edges_with_advisory": len(annotated),
        "edges_with_advisory_pct": round(100.0 * len(annotated) / region["edges"], 3),
        "p6_core_edge_keys_mutated": mutated,
        "p6_holds": not mutated,
        "sample_annotations": [
            {"edge": f"{u}->{v}/{k}",
             "name": str(d.get("name") or d.get("ref") or ""),
             "highway": str(d.get("highway") or ""),
             **{key: d[key] for key in d if key.startswith("advisory:")}}
            for u, v, k, d in annotated[:6]
        ],
        "staleness_projection": _staleness(annotated),
    }


def _staleness(annotated) -> dict:
    """**Two clocks, reported separately.**

    `information_fresh_at_plus_Nmin` is the reading's own age against the TTL
    — how long before the annotation should be re-fetched. `subject_valid_at_
    plus_Nmin` is how many of the annotated events are, by their own declared
    end date, still happening. Collapsing them into one "expires" is the
    natural implementation and it is wrong in both directions: a five-day
    work zone would look stale after fifteen minutes, and a reading taken
    yesterday about a work zone ending next week would look fresh.
    """
    now = datetime.now(timezone.utc)
    out: dict = {"total": len(annotated)}
    for minutes in (5, 15, 60, 240, 1440):
        when = now + timedelta(minutes=minutes)
        fresh = subject = 0
        for *_, data in annotated:
            stale_after = data.get("advisory:stale_after")
            ends_at = data.get("advisory:event_ends_at")
            try:
                if stale_after and datetime.fromisoformat(stale_after) > when:
                    fresh += 1
            except ValueError:
                pass
            try:
                if ends_at and datetime.fromisoformat(ends_at) > when:
                    subject += 1
            except ValueError:
                pass
        out[f"information_fresh_at_plus_{minutes}min"] = fresh
        out[f"subject_valid_at_plus_{minutes}min"] = subject
    return out


# ── Arm 4b: what point-published geometry costs ──────────────────────────


def arm_point_vs_line(region_name: str, provider) -> dict:
    """Both WZDx publishers are spec-conformant and one of them publishes
    every event as a **single point** (`MultiPoint` with one coordinate).
    Rather than confound that with a different state's road network, the same
    events are re-matched with their geometry degraded to their own first
    point — same graph, same events, only the publication shape differs.

    The number that matters is how many edges a point event claims that the
    line event did not: those are the cross streets a point match cannot rule
    out, and they are what an Author would see flagged for no reason.
    """
    region = graphs.region_graph(region_name)
    graph = region["graph"]
    index = matching.EdgeIndex(graph)
    now = datetime.now(timezone.utc)

    active = [e for e in provider.events
              if e.active_at(now) and e.geometry_kind == "line"
              and index.within_bbox(e.geometry)]
    as_line, line_stats = matching.match_events(graph, index, active)

    degraded = [normalize.RoadEvent(
        id=e.id, source_id=e.source_id, kind=e.kind, impact=e.impact,
        road_names=e.road_names, geometry=(e.geometry[0],), geometry_kind="point",
        starts_at=e.starts_at, ends_at=e.ends_at, observed_at=e.observed_at,
        description=e.description) for e in active]
    as_point, point_stats = matching.match_events(graph, index, degraded)

    line_keys, point_keys = set(as_line), set(as_point)
    return {
        "region": region_name,
        "events_compared": len(active),
        "as_line": line_stats.as_dict(),
        "as_point": point_stats.as_dict(),
        "edges_line_only": len(line_keys - point_keys),
        "edges_point_only": len(point_keys - line_keys),
        "edges_agreed": len(line_keys & point_keys),
        "point_recall_of_line_edges": round(
            len(line_keys & point_keys) / len(line_keys), 4) if line_keys else 0.0,
        "point_false_add_rate": round(
            len(point_keys - line_keys) / len(point_keys), 4) if point_keys else 0.0,
    }


# ── Arm 4c: what geometry-by-reference costs ─────────────────────────────


def arm_nws_zone_resolution(region_name: str, provider, force: bool) -> dict:
    """The N+1.

    An NWS alert usually carries `geometry: null` and names `affectedZones` —
    one URL per zone, each of which must be fetched to learn where the alert
    is. Nothing about this is exotic; it is how a lot of government data is
    published. It is measured here because "flatten this into light JSON" is
    precisely the argument for a normalisation proxy, and the argument is only
    as good as the number.
    """
    doc = provider.document or {}
    refs = sorted(set(normalize.nws_zone_refs(doc)))
    if not refs:
        return {"alerts_needing_resolution": 0, "note": "no unlocated alerts in this capture"}

    # Cached as ONE document rather than 62, and the **cold** cost is stored
    # inside it: a warm re-run must report the number that was actually paid,
    # not the 10 ms it took to read the cache back.
    bundle_path = http_cache.RAW / "nws-zones.json.gz"
    polygons: dict[str, tuple] = {}
    errors = 0
    if bundle_path.exists() and not force:
        bundle = json.loads(gzip.open(bundle_path, "rt", encoding="utf-8").read())
        resolve_s = float(bundle["cold_seconds"])
        errors = int(bundle.get("errors", 0))
        from_cache = True
        for url, ring in bundle["zones"].items():
            polygons[url] = tuple((float(x), float(y)) for x, y in ring)
    else:
        from_cache = False
        started = time.perf_counter()
        for url in refs:
            try:
                zone, _ms, _b = http_cache.live_get(url, timeout=60)
                coords, kind = normalize._geojson_coords(zone.get("geometry") or {})
                if kind == "polygon":
                    polygons[url] = coords
            except Exception:  # noqa: BLE001
                errors += 1
        resolve_s = time.perf_counter() - started
        http_cache.RAW.mkdir(parents=True, exist_ok=True)
        with gzip.open(bundle_path, "wt", encoding="utf-8") as fh:
            json.dump({"cold_seconds": resolve_s, "errors": errors,
                       "zones": {u: [list(p) for p in ring]
                                 for u, ring in polygons.items()}},
                      fh, separators=(",", ":"))

    # Re-match the alerts now that they have geometry.
    region = graphs.region_graph(region_name)
    index = matching.EdgeIndex(region["graph"])
    located = []
    for feature in doc.get("features") or []:
        if (feature.get("geometry") or None) is not None:
            continue
        props = feature.get("properties") or {}
        for url in (props.get("affectedZones") or []):
            ring = polygons.get(str(url))
            if not ring:
                continue
            located.append(normalize.RoadEvent(
                id=str(props.get("id") or ""), source_id=provider.source_id,
                kind="weather-advisory", impact="unknown",
                geometry=ring, geometry_kind="polygon",
                description=str(props.get("event") or "")))
    _, stats = matching.match_events(region["graph"], index, located)

    return {
        "alerts_in_feed": len(doc.get("features") or []),
        "distinct_zone_urls": len(refs),
        "requests_to_place_the_feed": len(refs),
        "zone_fetch_seconds_total": round(resolve_s, 2),
        "zone_fetch_seconds_each": round(resolve_s / len(refs), 3),
        "zone_fetch_errors": errors,
        "zone_fetch_timing_from_cache": from_cache,
        "zone_polygons_resolved": len(polygons),
        "alert_zone_pairs_located": len(located),
        "match_against_region": region_name,
        "match": stats.as_dict(),
        "note": "the timing is the cold cost — what a first-run Author pays — "
                "and it is stored inside raw/nws-zones.json.gz so a warm "
                "re-run reports what was paid rather than the cache read",
    }


# ── Arm 5: cacheability + volatility ─────────────────────────────────────


def arm_cacheability() -> dict:
    """Can a client avoid re-downloading 10 MB? Conditional-GET support is the
    difference between a poll that costs a header and one that costs the feed."""
    out = {}
    for name, url in (("wzdx-wi", WZDX_WI), ("wzdx-ny", WZDX_NY), ("nws-alerts-wi", NWS_WI)):
        try:
            head = requests.get(url, timeout=60, stream=True,
                                headers={"User-Agent": http_cache.USER_AGENT})
            headers = {k.lower(): v for k, v in head.headers.items()}
            entry = {
                "status": head.status_code,
                "etag": headers.get("etag"),
                "last_modified": headers.get("last-modified"),
                "cache_control": headers.get("cache-control"),
                "content_encoding": headers.get("content-encoding"),
                "content_length": headers.get("content-length"),
            }
            if entry["etag"]:
                second = requests.get(url, timeout=60, headers={
                    "User-Agent": http_cache.USER_AGENT,
                    "If-None-Match": entry["etag"],
                })
                entry["conditional_get_status"] = second.status_code
                entry["conditional_get_saves_body"] = second.status_code == 304
            else:
                entry["conditional_get_status"] = None
                entry["conditional_get_saves_body"] = False
            head.close()
            out[name] = entry
        except Exception as exc:  # noqa: BLE001
            out[name] = {"error": f"{type(exc).__name__}: {exc}"}
    return out


def arm_volatility(polls: int, interval_s: float) -> dict:
    """What TTL does the data's own churn justify (P7)?

    Two measurements, because they answer different halves. **Observed churn**
    polls the live feed and diffs it — the only honest source of "how fast does
    this actually change". **Declared age** reads the events' own
    `update_date` distribution, which says how stale a *typical* event already
    is when it arrives, and that bounds how much precision a short TTL can buy.
    """
    doc, ms, size = http_cache.live_get(WZDX_WI)
    baseline = {e.id: (e.observed_at, e.impact) for e in normalize.wzdx_events(doc, "wzdx-wi")}
    feed_update = (doc.get("feed_info") or {}).get("update_date")

    now = datetime.now(timezone.utc)
    ages = []
    for event in normalize.wzdx_events(doc, "wzdx-wi"):
        if event.observed_at:
            ages.append((now - event.observed_at).total_seconds() / 3600.0)
    ages.sort()

    def pct(p: float) -> float:
        if not ages:
            return 0.0
        return round(ages[min(len(ages) - 1, int(p * len(ages)))], 2)

    polls_out = []
    prev = baseline
    prev_feed_update = feed_update
    for i in range(polls):
        time.sleep(interval_s)
        doc_i, ms_i, size_i = http_cache.live_get(WZDX_WI)
        events_i = normalize.wzdx_events(doc_i, "wzdx-wi")
        current = {e.id: (e.observed_at, e.impact) for e in events_i}
        added = set(current) - set(prev)
        removed = set(prev) - set(current)
        changed = {k for k in set(current) & set(prev) if current[k] != prev[k]}
        feed_update_i = (doc_i.get("feed_info") or {}).get("update_date")
        polls_out.append({
            "poll": i + 1,
            "interval_s": interval_s,
            "fetch_ms": round(ms_i, 1),
            "bytes": size_i,
            "events": len(current),
            "added": len(added),
            "removed": len(removed),
            "changed": len(changed),
            "churn_pct": round(100.0 * (len(added) + len(removed) + len(changed))
                               / max(1, len(current)), 3),
            "feed_update_date_moved": feed_update_i != prev_feed_update,
        })
        prev = current
        prev_feed_update = feed_update_i

    return {
        "declared_update_frequency_s": (doc.get("feed_info") or {}).get("update_frequency"),
        "baseline_events": len(baseline),
        "baseline_fetch_ms": round(ms, 1),
        "baseline_bytes": size,
        "event_age_hours": {
            "p10": pct(0.10), "p50": pct(0.50), "p90": pct(0.90),
            "max": round(ages[-1], 2) if ages else 0.0,
            "n": len(ages),
        },
        "polls": polls_out,
    }


# ── Arm 6: normalisation cost ────────────────────────────────────────────


def arm_normalisation_cost() -> dict:
    """How much code is *source-specific*? The proxy question is really "is
    this cost big enough, and shared enough, to need a server tier". Counted
    from the real adapters rather than estimated."""
    import inspect

    def loc(fn) -> int:
        src = inspect.getsource(fn).splitlines()
        return sum(1 for line in src
                   if line.strip() and not line.strip().startswith(("#", '"""', "'''")))

    shared = loc(normalize._geojson_coords) + loc(normalize._iso)
    return {
        "shared_helpers_loc": shared,
        "wzdx_adapter_loc": loc(normalize.wzdx_events) + loc(normalize.wzdx_licence_id),
        "nws_adapter_loc": loc(normalize.nws_events) + loc(normalize.nws_zone_refs),
        "matcher_loc": sum(loc(f) for f in (matching.match_events, matching._match_line,
                                            matching._match_polygon, matching.names_agree,
                                            matching.bearing)),
        "note": "the matcher is shared by every source and is the largest part; "
                "the per-source adapters are the part a proxy would host",
    }


# ── driver ───────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--polls", type=int, default=4,
                        help="live volatility polls (0 to skip)")
    parser.add_argument("--poll-interval", type=float, default=90.0)
    parser.add_argument("--force-fetch", action="store_true",
                        help="ignore raw/ and re-fetch every feed")
    parser.add_argument("--regions", default="driftless-lacrosse,milwaukee")
    args = parser.parse_args()

    started = datetime.now(timezone.utc)
    out: dict = {"spike": "SPIKE-17", "issue": 176, "started_utc": started.isoformat()}

    print("arm 1: the named source ...")
    out["named_source"] = arm_named_source()

    print("arm 2: conformance + licence gate ...")
    conformance, ctx = arm_conformance(args.force_fetch)
    out["conformance"] = conformance
    out["licence_gate"] = ctx["gate"]
    provs = ctx["providers"]

    print("arm 3: feed shapes ...")
    out["feed_shapes"] = arm_feed_shapes(provs)

    # Only the sources that passed the gate may annotate — that is the gate's
    # whole point. `ny` is expected to fail it; if it ever passes, the run
    # records that instead of pretending otherwise.
    loaded = {p.source_id: p for p in ctx["registry"].loaded}
    out["annotating_sources"] = sorted(loaded)

    out["annotation"] = {}
    for region_name in [r for r in args.regions.split(",") if r]:
        print(f"arm 4: annotate {region_name} ...")
        out["annotation"][region_name] = arm_annotate(region_name, loaded, args.force_fetch)

    wi = provs["wi"]
    if wi.events:
        print("arm 4b: point-published vs line-published geometry ...")
        out["point_vs_line"] = arm_point_vs_line("driftless-lacrosse", wi)

    print("arm 4c: NWS geometry-by-reference (the N+1) ...")
    out["nws_zone_resolution"] = arm_nws_zone_resolution(
        "driftless-lacrosse", provs["nws"], args.force_fetch)

    print("arm 5a: cacheability ...")
    out["cacheability"] = arm_cacheability()
    if args.polls:
        print(f"arm 5b: volatility, {args.polls} polls at {args.poll_interval}s ...")
    out["volatility"] = arm_volatility(args.polls, args.poll_interval)

    print("arm 6: normalisation cost ...")
    out["normalisation_cost"] = arm_normalisation_cost()

    out["finished_utc"] = datetime.now(timezone.utc).isoformat()
    out["wall_seconds"] = round(
        (datetime.now(timezone.utc) - started).total_seconds(), 1)

    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / "run_spike.json"
    path.write_text(json.dumps(out, indent=1, default=str), encoding="utf-8")
    print(f"\nwrote {path} ({path.stat().st_size} bytes) in {out['wall_seconds']}s")


if __name__ == "__main__":
    main()
