# SPIKE-04 — Paddling network & difficulty data availability

Time-boxed spike answering `docs/Plotlines_Research_Spikes.md` SPIKE-04, the PRD's
highest-risk item: **does usable data exist to route and grade paddling segments?**
Cycling on OSM is proven; the waterway network, put-ins/take-outs, portages, class
ratings, and gauge readings are not.

**Results and the paddling-in-MVP call: [`results/RESULTS.md`](results/RESULTS.md).**

## Layout

| Path | What it is |
|---|---|
| `regions.py` | The three regions and the geodesic area maths that makes their counts comparable. |
| `probe_osm.py` | Overpass tag census + geometry pulls, **with cycling/hiking controls in the same bboxes**. |
| `probe_gauges.py` | USGS gauges: which exist, which are reporting right now, and whether the successor API agrees. |
| `probe_nhd.py` | USGS NHDPlus HR flowlines — the purpose-built alternative to OSM's waterway centrelines. |
| `probe_nldi.py` | USGS NLDI: does a gauge resolve to a river reach, which is what FR14 actually needs. |
| `analyze.py` | Turns the pulls into routability: topology, snapping, graded kilometres, and a real route attempt. |
| `cache.py` | Gzipped on-disk cache shared by the probes. |
| `raw/` | Cached upstream responses, gzipped (~4 MB). Committed, so the numbers are reproducible without re-hitting anyone's server. `raw/tiles/` holds the per-tile pulls the merged files are built from — kept, not cleaned, so deleting a merged file costs a rebuild rather than a refetch. |
| `results/` | The findings (`RESULTS.md`) and the machine-readable measurements behind them (`census.json`, `network.json`, `gauges.json`, `nldi.json`). |

## Why three regions, and why controls

The regions are the ones the product already names (`docs/osm_reference.md` open items):
Western North Carolina, southwest Wisconsin, Southern California. They were chosen there
because they differ in the way that matters — steep whitewater, a flatwater state water
trail, and a dry region where paddling is coastal rather than riverine. A mode that only
works in one of the product's three regions is not "first-class" in the sense FR10 claims.

Every paddling count is reported next to a **cycling or hiking count from the same bbox
and the same source**. "OSM has 31 whitewater put-ins in Western North Carolina" means
nothing alone; read against the cycleway and hiking-route counts beside it, it means
something specific. Counts are also normalised per 1,000 km², because the bboxes follow
river systems rather than a grid and differ in area by 3×.

## Reproducing

```bash
python spikes/SPIKE-04/probe_osm.py       # Overpass; slow, and rate-limited at times
python spikes/SPIKE-04/probe_gauges.py    # USGS Water Services
python spikes/SPIKE-04/probe_nhd.py       # USGS NHDPlus HR
python spikes/SPIKE-04/probe_nldi.py      # USGS NLDI gauge -> reach linkage
python spikes/SPIKE-04/analyze.py         # reads the cached pulls, writes results/
```

Every probe caches into `raw/` and reuses it; pass `--refresh` to refetch. The cache is
committed, so `analyze.py` reproduces the published numbers offline. Re-running the
probes against live services will not reproduce them exactly — OSM and the state
datasets change under you, which is part of the finding.

Three things worth knowing before re-running the Overpass probe — all of them hard-won
during this run, and all of them the difference between it completing and not:

- **Keep the server-side `[timeout:]` short.** This is the one that mattered. At
  `timeout:300`, a query the gateway had already answered with a 504 *kept running on the
  Overpass instance*, still holding one of the client's two slots for five more minutes.
  A handful of those starve the script, every retry gets 429, and the retry loop feeds the
  rate limiting it is retrying against. These queries finish in under ten seconds when the
  server is healthy, so the 90 s budget costs nothing and frees an abandoned slot six
  times faster.
- **Exact tag values, never regexes.** Overpass indexes `["waterway"="dam"]` and does not
  index `["waterway"~"^(dam|weir)$"]`, so the regex form scans every waterway object in
  the bbox. The regex version of the hazard probe timed out on all three endpoints; the
  union-of-exact-values version returns in seconds.
- **A failure must never be recorded as a zero.** Every probe raises on an exhausted
  endpoint list rather than returning an empty result, because in a spike that exists to
  count things, "0 put-ins" and "the server was busy" look identical in a results table
  and mean opposite things.

Geometry pulls are tiled and cached **per tile**, so a failure costs only the tile that
failed rather than discarding three successful ones.

## Scope

This is a **data-availability** spike. It does not implement `WaterwayDataProvider`, and
the route it computes is a shortest path over the raw waterway graph — enough to prove a
solver has something to solve over, not a paddling router. Weighting, class-band
enforcement, portage insertion, and gauge-gated feasibility are the build that this
spike's answer either justifies or doesn't.
