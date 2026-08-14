# Shared routing-spike substrate

SPIKE-01, SPIKE-02, and SPIKE-03 ask three different questions of one thing: a real
bike graph with real elevation, real grades, and real OSM surface/highway tags. This
directory builds that once and hands it to all three.

```bash
.venv/bin/python spikes/shared/regions.py          # build fixtures (needs network)
.venv/bin/python spikes/run_routing_spikes.py      # run 01, 02, 03 over one setup
.venv/bin/python spikes/run_routing_spikes.py 03   # or just one
```

The runner exits non-zero if any spike's self-checks fail, so it doubles as a CI gate.

## Why they share a setup

Partly cost — graph parsing dominates, and paying it once instead of three times is the
whole reason these run together. But mostly **consistency**: a conflict SPIKE-02
explains has to be a conflict SPIKE-03 measured, on the same graph, from the same start
point, with the same via-node placement rule. Run separately they could quietly
disagree and neither result would mean anything.

## Files

| File | What it is |
|---|---|
| `regions.py` | Region definitions, Overpass download, Terrarium DEM mosaic, elevation + grade baking |
| `harness.py` | `Bench` — loads graphs once, warms the edge-feature cache, deterministic via-points, environment capture |
| `fixtures/` | Built artifacts (~29 MB). Git-ignored; `regions.py` is the reproducible definition |
| `cache/` | osmnx's Overpass response cache. Git-ignored, safe to delete |

## The three regions

Chosen as experiment design, not convenience — SPIKE-03 asks whether min/max bands
over-constrain, which is unanswerable without terrain that genuinely differs.

| Region | Character | Nodes | Edges | Relief | `surface` tagged |
|---|---|---:|---:|---:|---:|
| **boulder** | mountain-adjacent city: foothills against a street grid | 9,498 | 24,355 | 255 m | 81.7% |
| **davis** | flat cycling town: dense bike network, no relief | 5,404 | 13,803 | 9.6 m | 34.4% |
| **viroqua** | rural coulee country: steep, gravel, near-empty roads | 2,096 | 5,065 | 162 m | 24.5% |

Davis is there to produce honest infeasibility (a climbing band cannot be satisfied at
9.6 m of relief, and the engine should say so rather than return a bad route). Viroqua
is deliberately sparse — network density turned out to matter as much as terrain, most
visibly in SPIKE-01's overlap results.

## Two decisions worth knowing about

**Elevation comes from AWS Terrain Tiles (Terrarium), not an elevation API.** It is
keyless and global, which matters for a fixture builder: per the MVP scope doc the
elevation API key lives in `service/` config and never in the repo, so a build step
that needed one would be a build step nobody else could run. Tiles are mosaicked and
reprojected to **EPSG:4326** because `ElevationSampler` samples with raw `(lon, lat)` —
a DEM in a projected CRS would silently return garbage rather than fail.

**Grades are baked in at fixture-build time**, not computed per solve. SPIKE-03's band
search re-solves the same graph dozens of times per scenario; sampling a GeoTIFF inside
the cost function would have made the search a measurement of rasterio rather than of
routing.

## The osmnx tag trap

osmnx's default `useful_tags_way` **does not include `surface`**. The first build here
reported surface tagged on 0.0% of edges in all three regions — which reads as "OSM has
no surface data" and actually meant "we never asked for it". FR4's surface weight is
completely inert in that state: every edge falls to the untagged default, and changing
the weight changes nothing.

`regions.py` now sets the tag list explicitly. Anywhere else graphs get built should do
the same. `maxspeed` and `lanes` are retained for the same reason — SPIKE-03 found the
traffic model needs them, and a tag not requested at download time is not recoverable
later without re-downloading.
