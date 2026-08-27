# SPIKE-B — Co-location cluster ranking and cost

Measures the runtime/memory of co-location analysis at multi-day-bbox scale,
tunes the ranking function, and sets FR105a's reviewable cap — per issue #169.
**Verdict and full write-up: [`results/RESULTS.md`](results/RESULTS.md).**

```bash
# 1. pull the six OSM layer families for the Blue Ridge Parkway corridor
#    (needs network; cached + committed after — this took ~3h once, through
#    a bad Overpass day, and never needs re-running)
.venv/bin/python spikes/SPIKE-B/probe.py

# 2. cost: runtime + memory vs bbox area, layer count, and synthetic density
.venv/bin/python spikes/SPIKE-B/analyze.py            # add --json for results/cost.json

# 3. ranking: worked-pass reconstruction, corridor-treatment comparison, cap
.venv/bin/python spikes/SPIKE-B/ranking.py            # --json -> results/ranking.json

# 4. affinity union + a plugin layer (battlefield/manor_house/covered_bridge/crag)
.venv/bin/python spikes/SPIKE-B/plugin.py             # --json -> results/plugin.json

# 5. rejection memory survives a re-run with a new layer added
.venv/bin/python spikes/SPIKE-B/rejection.py          # --json -> results/rejection.json
```

`analyze.py` / `ranking.py` / `plugin.py` / `rejection.py` import
`plotlines_core.curation` directly — they run the product's own
`score_notability` and the `analyze_colocation` this spike wrote, not a
spike-local reimplementation.

## Files

| File | What |
|---|---|
| `regions.py` | the `brp` bbox (Asheville–Boone, ~8,800 km²), the §5.4a `WORKED_PASS` sub-box, and the concentric area-sweep crops |
| `route.py` | the Blue Ridge Parkway alignment, hand-digitised as a 20-vertex lon/lat polyline |
| `probe.py` | Overpass pulls (six FR97 families + `leisure` geometry), mirror fallback, gzip cache |
| `cache.py` | gzipped on-disk cache (shared shape with SPIKE-A) |
| `common.py` | `raw/` → `RawFeature` → `score_notability`; the `Meter` (perf_counter + tracemalloc) |
| `analyze.py` | cost: area sweep, layer-count sweep, synthetic-dense sweep |
| `ranking.py` | ranking function, four corridor treatments, cap-vs-scale, §5.4a worked pass |
| `plugin.py` | proposal-`kind` differentiation + a plugin `LayerProvider` shape; the §0 / punch-list-4.17 regression |
| `rejection.py` | bulk-reject → add a layer → re-run → assert rejections preserved, `diff_runs` marks the new |
| `raw/*.json.gz` | committed Overpass pulls (~0.75 MB gzipped) |
| `results/RESULTS.md` | the write-up |
| `results/*.json` | full JSON dumps from each script's `--json` |

The shipped artifact is **`core/plotlines_core/curation/colocate.py`** (ARCH
§4.4), with the tuned ranking parameters as `ColocationParams` config and
`core/tests/test_curation_colocate.py` locking the behaviour.
