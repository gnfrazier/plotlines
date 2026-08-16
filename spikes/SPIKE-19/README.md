# SPIKE-19 — Waterway routing on USGS 3DHP, and binding live gauges to reaches

Run 2026-08-16. Results: [`results/RESULTS.md`](results/RESULTS.md).

SPIKE-04 chose USGS **NHDPlus High Resolution** for the paddling network. USGS retired the
National Hydrography Dataset on **1 October 2023** and stopped maintaining NHDPlus HR;
**3DHP** replaces it. So this spike asks whether the successor still supports SPIKE-04's
verdict, does the geometry pull SPIKE-04 explicitly skipped, and binds a live gauge to a
real routed segment by identifier.

**Short answer:** three of SPIKE-04's four load-bearing attributes are renamed, one has
moved to a different layer, none is lost. A 148.2 km downstream route on the French Broad
comes out of 3DHP geometry, five gauges bind to it by identifier, and `WaterwayGraph`
needs **two** join keys rather than the one ARCH §13.2 specifies.

## Layout

| Path | What it is |
|---|---|
| `common.py` | Service endpoints, paginated ArcGIS query, and the shared cache. Imports SPIKE-04's `regions.py` and `cache.py` rather than copying them. |
| `probe_3dhp.py` | The regression check — reads the service schema, then pulls network attributes (order ≥ 3) and geometry (order ≥ 4), plus the Z audit. |
| `probe_join.py` | Whether a gauge still binds to a reach: NLDI resolution for every site SPIKE-04 found, matched against 3DHP's `mainstemid` and layer-40 reach codes. |
| `analyze.py` | Topology reconstruction, connectivity, access snapping, the route, and the corridor clip. |
| `probe_gauge_bind.py` | End to end: route → mainstems → gauges → live readings → the normalized payload. |
| `raw/` | Cached upstream responses, gzipped (~12 MB). Committed, so the numbers reproduce offline. |
| `results/` | `RESULTS.md` and the measurements behind it (`schema_and_network.json`, `join.json`, `routability.json`, `gauge_binding.json`). |

## Reproducing

```bash
.venv/Scripts/python spikes/SPIKE-19/probe_3dhp.py        # schema + network + Z audit
.venv/Scripts/python spikes/SPIKE-19/probe_join.py        # NLDI → 3DHP identifier join
.venv/Scripts/python spikes/SPIKE-19/analyze.py           # topology, route, corridor
.venv/Scripts/python spikes/SPIKE-19/probe_gauge_bind.py  # live gauges on the real route
```

Every probe caches into `raw/` and reuses it; pass `--refresh` to refetch. The cache is
committed, so everything except the live gauge readings reproduces without touching a USGS
server. The readings will not reproduce — they are provisional values from 2026-08-16.

## Three things worth knowing before re-running

- **The flowlines are layer 50.** `usgs_3dhp_all/FeatureServer/1` returns **HTTP 500 with
  the body `json`**, which looks like a transport failure rather than a wrong layer id.
  The service is 20/30/40 hydrolocations, **50 Flowline**, 60 Waterbody, 80 Catchment.
- **`streamorder` is the filter, never `featuretypelabel`.** Every major paddling river in
  these regions is typed `Waterbody Connector`, and the share rises with stream order —
  12.5% at order 4 to 100% at order 8. Filtering to `Channel Line` deletes the French
  Broad. See RESULTS §3.
- **The two `mainstemid` namespaces are disjoint registries, not aliases.** Zero of 933
  distinct numeric ids in WNC appear under both `geoconnex.us/usgs/mainstems/` and
  `geoconnex.us/ref/mainstems/`. Match the full URI; normalising the prefix away
  manufactures false joins.

## Why the regions and endpoints come from SPIKE-04

`common.py` imports `spikes/SPIKE-04/regions.py` instead of restating the three bounding
boxes, and `analyze.py` reads that spike's committed OSM access points instead of
re-querying Overpass. This spike's whole value is a comparison against SPIKE-04's numbers,
and copying inputs is how a comparison quietly becomes two different experiments — a
changed decimal in a bbox would turn "3DHP has 0.1% more river than NHDPlus HR" into a
statement about bbox drafting. Importing makes that impossible rather than unlikely.

The one thing deliberately **not** reused is the network itself, which is the point.

## Cache size

`raw/` is ~12 MB. Geometry is fetched only at order ≥ 4, because that is the only place
anything consumes it — order ≥ 3 exists to answer "how far does the threshold move the
network", and length, connectivity and topology are all attributes. Pulling its geometry as
well tripled the committed cache to buy a number nothing reads. Coordinates are stored at 6
decimal places (~11 cm, finer than the source's own accuracy) with the dead Z ordinate
dropped.
