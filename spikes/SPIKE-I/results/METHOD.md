# SPIKE-I — method, and the three things that would have made the numbers lie

Companion to [`RESULTS.md`](RESULTS.md). The bands are in
[`../HARNESS.md`](../HARNESS.md) and [`../bands.py`](../bands.py), committed
before the first measurement. This file records *how* the numbers were taken,
and specifically the three ways this run could have produced confident,
meaningless figures. Each was caught by construction rather than by luck, and
each is the kind of thing a later reader should be able to check rather than
trust.

## 1. Snapshot drift would have made every difference look like a finding

A golden built from live Overpass today and a Geofabrik extract pinned on some
other day describe **different databases**. Every id that changed in between
would score as a parity difference while being nothing of the kind, and with
OSM's edit rate that alone would have decided the verdict.

The control: read `osmosis_replication_timestamp` out of the clip's own pbf
header and build the golden with `[date:"<that instant>"]`. Both sides then
describe the same snapshot, and exact set identity becomes a legitimate thing to
require rather than an unreasonable one.

All four extracts pulled on 2026-09-13 carry the **same** timestamp,
`2026-09-12T20:21:58Z` — Geofabrik cuts its daily extracts from one planet
replication state, so the border cell has no inter-extract skew to correct for.
That is a fact about Geofabrik worth knowing and not something to rely on
silently; `probe_cell` compares the timestamps of every source extract and
prints a warning if they ever disagree, using the older one.

**The control is verified, not assumed.** A `[date:]` that Overpass silently
ignored would return today's data and bias every band toward a pass — the
failure would be invisible and in the flattering direction. So `probe.py`
checks it against a live undated query before building any golden, and aborts
the run if they match:

```
attic control: live=4505 2020=2608 honoured=True
```

## 2. `ru_maxrss` is monotonic, and six clips in one process would be one number and five fictions

`resource.getrusage(...).ru_maxrss` is a **process-lifetime high-water mark**.
It never decreases. Six sequential clips in one process report: the first clip's
true peak, then `max(so far)` forever after. Every figure after the largest clip
is that clip's, wearing a different label — and the error is always in the
direction of looking consistent.

So every clip in this spike runs in its own subprocess (`clip.run_clip`), and
the figure reported is that subprocess's own high-water mark with nothing else
having run in it.

The same defect exists in shipped code — `/clip`'s `X-Plotlines-Clip-Peak-Rss-Kb`
header is taken the same way on a long-lived service — and is filed as
[#374](https://github.com/gnfrazier/plotlines/issues/374). It showed up live
during this run: the same 5.77 MB clip reported 3,718 MB on a fresh process and
4,664 MB on a process that had already served one. `mirror_bench.py` therefore
treats only the first clip after a process start as a valid RSS sample and says
so in its output.

A hard `RLIMIT_AS` in the clip subprocess is the other half: without it a clip
too large for the box does not fail, it **swaps**, and the wall-time figure
becomes a measurement of the page cache.

## 3. Grading a known-wrong arm would have made the bands meaningless

The probe runs four path-T arms per cell, because two harness variables might
have mattered:

- **raw vs buffered clip extent** — `graph_from_polygon` queries a polygon
  buffered by 500 m and truncates to the requested bbox only *after*
  simplification and component selection have run on the buffered graph.
- **vertex vs intersects way selection** — the shipped clip selects a way when
  one of its nodes is inside the box; Overpass's `(poly:)` selects when the
  geometry intersects at all.

Both were discovered by **reading osmnx's source**, not by looking at results.
Only the canonical configuration of each path is graded (`CANONICAL_ARMS` in
`analyze.py`); the others are reported in full under `diagnostic_arms`, with the
band they *would* have scored, so a reader can see they were run and what they
cost. Grading an arm built to fail would RESCOPE every run on a technicality and
tell nobody anything.

**This is the part where a prediction failed, and the failure is the finding.**
The expectation was that the 500 m buffer would be load-bearing and the raw-bbox
arm would diverge. It did not — see `RESULTS.md`. The distinction between
"measured but not graded" and "quietly dropped" is exactly what made that
visible rather than invisible.

## What is measured where

| leg | where | why |
|---|---|---|
| B0–B5 parity | dev box (x86, 16 core) | comparing two graphs is not a timing measurement |
| B6 clip cost | **the Pi mirror, through `/clip`** | addendum 2c: Q1-C is decidable only on server-side numbers |
| B7 border | the Pi, through `/clip` | same |
| B8 arithmetic | offline, from measured sizes | |
| B9 offline edit | dev box | it is a client-side question |

`bands.clip_band` refuses PARITY to any clip figure whose `measured_on_mirror`
is false, so a fast dev-box number cannot decide Q1-C even by accident. Dev-box
clip figures are still reported — they are what makes the x86-to-aarch64
comparison possible — but they are labelled and they do not count toward B6.

## The mirror under measurement

```json
{
  "host": "argon-robot",
  "model": "Raspberry Pi 5 Model B Rev 1.0",
  "arch": "aarch64",
  "kernel": "Linux 6.12.62+rpt-rpi-2712",
  "cores": 4,
  "mem_total_mb": 8063,
  "root_fs": "/dev/nvme0n1p2 916G 784G avail",
  "docker": "Docker version 29.8.0",
  "clip_image": "plotlines-mirror-clip:latest 611MB"
}
```

This is §6.2's specified hardware, running §6.4's Caddy config and #262's clip
container, serving the extracts #258's pull client put on disk — not a stand-in.
Requests go through Caddy on :80 with `Host: tiles.plotlines.app`, because the
Caddyfile declares one named vhost with no fallback; that is §6.5's "exercise
the real code path" applied to the request line.

Leg 3 deliberately uses the regions the mirror had **already pinned**
(`north-carolina`, `tennessee`) rather than the four states the parity matrix
needs. Reshaping the mirror to match the parity matrix would have measured a
mirror nobody runs — and the NC/TN pair is the review's own §11.7 example.
