# SPIKE-I — Local extract and graph parity

**Issue:** [#265](https://github.com/gnfrazier/plotlines/issues/265) ·
**Epic:** [#268](https://github.com/gnfrazier/plotlines/issues/268) — OSM acquisition Phase 2 ·
**Covers:** review §7.1, §8, §11.1, §11.5, §11.7, §6.7, §12 (Q1, Q6) ·
addendum **G5**, **2b**, **2c**, **L1** · ARCH **A23/A23a** · PRD **FR121** ·
**Bands:** [`HARNESS.md`](HARNESS.md) / [`bands.py`](bands.py) ·
**Result:** [`results/RESULTS.md`](results/RESULTS.md)

```bash
# the bands — committed BEFORE the first measurement (git log will show it)
git log --oneline -- spikes/SPIKE-I/HARNESS.md

# one-time: the extracts, pulled with the shipped client (#258), ~2.1 GB
../../deploy/mirror/build_tree.sh mirror
../../service/.venv/bin/python ../../deploy/mirror/geofabrik_pull.py \
    --root mirror --pinned-date 2026-09-13 -v \
    --region north-america/us/colorado --region north-america/us/california \
    --region north-america/us/wisconsin --region north-america/us/wyoming

# network + compute — writes raw/, publishes nothing
.venv/bin/python probe.py
.venv/bin/python probe.py --check-attic          # the §1 control on its own

# leg 3, on the Pi — addendum 2c says server-side or it does not count
./deploy_mirror.sh argon-robot
.venv/bin/python mirror_bench.py --base-url http://argon-robot \
    --host-header tiles.plotlines.app

# offline — every published figure, from raw/ -> results/
.venv/bin/python analyze.py

# offline — the verdict gate: every published clause re-derived and asserted
.venv/bin/python run.py -v

# tests
.venv/bin/python -m pytest tests -q
```

`analyze.py` and `run.py` touch no network and no clock. Everything they need is
in `raw/`, so every number in `RESULTS.md` reproduces without querying the
Overpass commons again (ARCH §14 P7) and without moving under the next reader —
SPIKE-C's rule, for SPIKE-D's reason, and the same split SPIKE-E used.

## Why this spike exists

Phase 3 (#272) replaces the *transport* under `ensure_graph(region, cache_dir)`
— public Overpass out, a mirror-clipped `.osm.pbf` in — and keeps every
interface above it. **That is only true if the graph that comes out the other
side is the same graph**, and §11.1 is blunt about why it might not be:
`ox.graph_from_bbox` does far more than download, and everything calibrated to
date — SPIKE-A's golden candidate sets and `RULESET_VERSION 1.2.0`, SPIKE-G's
density model and its ~2,800-marker ceiling, the scoring weights, SPIKE-21's cue
derivation — was measured on osmnx output.

## The one idea worth taking away

§11.1 describes **two different swaps** in one paragraph and the spike's design
turns on separating them:

| | path | what changes | what does not |
|---|---|---|---|
| **T** | clipped `.osm.pbf` → OSM elements in Overpass's own response shape → `osmnx._create_graph` → the identical post-download pipeline | the bytes, and the code that decides which ways match `network_type` | every line of osmnx after the download |
| **R** | clipped `.osm.pbf` → pyrosm → graph | the bytes **and** the whole graph construction | nothing |

`graph_from_polygon` is one download call followed by about ten lines of
post-processing. Path T replaces exactly the download call; path R replaces all
of it. Both are graded against the same pre-registered bands, and
`bands.classify` does not special-case either — encoding a preference would have
been deciding the answer in the pre-registration.

## What is here

| Path | What it is |
|---|---|
| `HARNESS.md` | **The pre-registration.** Bands, their reasons, the snapshot control, and what is measured where. Committed before the first measurement. |
| `bands.py` | The machine-readable form of the same. `classify()` is what `run.py` grades against; the two vetoes (B0, B5) sit outside the ladder. |
| `regions.py` | The matrix cells. Shared fixture bboxes are **imported** from `spikes/shared/regions.py`, not copied; `coline` (the CO/WY border box) exists only here. |
| `elements.py` | Path T. Reads a clipped pbf into Overpass's response shape, with the way filter **parsed from osmnx's own QL string** rather than transcribed. |
| `graphs.py` | The three builds. `_graph_from_elements` is `graph_from_polygon` with one line swapped, transcribed rather than monkey-patched so the inheritance is visible. |
| `clip.py` | `simple` / `complete_ways` / `smart`, **implemented** through pyosmium's API — L1 says they cannot be selected by flag, because those are osmium-tool concepts and osmium-tool is GPL-3.0. Each clip runs in its own subprocess. |
| `parity.py` | The comparison. Produces counts and distributions, never a verdict. |
| `tags.py` | B5, asserted on the bytes at three points — clip, graph, and the `barrier` node→edge fold. |
| `offline.py` | B9, the Q1-D trigger: what an offline bbox edit can be served from what the client actually holds. |
| `egress.py` | B8, Q6's arithmetic — the one open question §12 left with no measurement attached. |
| `probe.py` | Network + compute. The only thing here that touches the network or the 2.1 GB of extracts. |
| `mirror_bench.py` | Leg 3, against the real `/clip` on the Pi. |
| `deploy_mirror.sh` | Stands the mirror up on the Pi using `deploy/mirror`'s own artifacts, not a bespoke path. |
| `analyze.py` / `run.py` | Offline grading, and the verdict gate. |
| `results/` | The write-up and every number in it. |

## Three things that cost time, recorded so they do not cost it twice

- **The 500 m buffer is load-bearing.** `graph_from_polygon` queries a polygon
  buffered by 500 m and truncates to the requested bbox only *after*
  simplification and component selection have run on the buffered graph. A clip
  taken at the raw trip bbox cannot reproduce the golden's boundary. The probe
  runs both extents so the cost of getting this wrong is a number rather than a
  warning.
- **Overpass has been returning complete ways all along.** The query is
  `(way<filter>(poly:…);>;);out;` and the `>` recurses to every member node of
  every matched way, including nodes outside the polygon. So `complete_ways` is
  the *floor* for parity, not one of three equal options; `simple` is measured
  to price what it would have cost.
- **`ru_maxrss` is a process high-water mark.** It never decreases, so six
  sequential clips in one process yield one real number and five flattering
  fictions. Every clip here runs in its own subprocess. The same defect exists
  in the shipped `/clip` response header and is filed as
  [#374](https://github.com/gnfrazier/plotlines/issues/374).

## No product code changes

Same discipline as SPIKE-A/C/D/E/F/G/H. Nothing under `core/plotlines_core/` or
`service/plotlines_service/` is edited here. Where a finding implies a product
change it is filed as an issue and named in `results/RESULTS.md`.
