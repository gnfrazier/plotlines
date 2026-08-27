# SPIKE-A — Notability ruleset calibration

Calibrates FR98's notability rules (`historic=*` sub-weighting and
density-triggered qualification) against real OSM extracts in three trip-sized
bboxes, per issue #158. **Verdict and full write-up: [`results/RESULTS.md`](results/RESULTS.md).**

```bash
# 1. pull the six OSM layer families for each region (needs network; cached after)
.venv/bin/python spikes/SPIKE-A/probe.py

# 2. run plotlines_core's notability filter over them and print the analysis
.venv/bin/python spikes/SPIKE-A/analyze.py

# 3. (re)write the golden candidate sets
.venv/bin/python spikes/SPIKE-A/analyze.py --write-golden

# 4. dump the calibrated ruleset to versioned-config JSON
.venv/bin/python spikes/SPIKE-A/export_ruleset.py
```

`analyze.py` and `export_ruleset.py` import `plotlines_core.curation` directly —
the analysis is the product's own scoring, not a spike reimplementation.

## Files

| File | What |
|---|---|
| `regions.py` | the three bboxes (`avl` / `lwr` / `sgv`) and geodesic-area maths |
| `probe.py` | Overpass pulls, mirror fallback, gzip cache |
| `cache.py` | gzipped on-disk cache (shared shape with SPIKE-04) |
| `analyze.py` | runs `score_notability`, tabulates counts / gates / `historic=*` frequency, writes golden sets |
| `export_ruleset.py` | serializes `taxonomy.TAXONOMY` → `results/notability_ruleset.v{N}.json` |
| `raw/` | committed Overpass pulls (~0.5 MB gzipped) |
| `results/RESULTS.md` | the write-up |
| `results/golden/` | per-region golden candidate sets |
| `results/notability_ruleset.v1.2.0.json` | the calibrated ruleset in config form |
| `results/analysis.json` | full `analyze.py --json` dump |

The compact golden set the core suite asserts on lives in
`core/tests/fixtures/golden_candidates/` (`core/tests/test_curation_golden.py`).
