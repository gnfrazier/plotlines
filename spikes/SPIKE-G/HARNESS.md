# SPIKE-G — live re-measurement spec

The analytical model in this spike is calibrated to SPIKE-14's measured anchors,
but its load-bearing coefficient — the per-frame cost of a `flutter_map` widget
marker during interaction (`regions.WIDGET_MARKER_FRAME_US`) — is set from
practitioner consensus, not measurement. This is the run that replaces it with a
number. It is a **delta against SPIKE-14**, on the same harness and the same two
desktop platforms, so the marker cost is attributable.

## Where it runs

`spikes/SPIKE-14/harness` — the existing `flutter_map` + `vector_map_tiles`
Flutter desktop app, on:

* **Linux** (`llvmpipe` software raster) — the floor, as in SPIKE-14 §3.0
* **Windows** (integrated GPU, D3D) — the target, as in SPIKE-14 §3.1

Same 1280×720 profile build, same scripted orbit-and-zoom, 5 repeats per cell,
median reported, `probes/bench.py`'s load-average gate.

## What to add to the harness

1. **A candidate layer** fed a fixture built by `extract.py` — dump
   `load_candidates("sgv")` (the densest, 1,208) and `("avl")` (715) to GeoJSON
   with `salience` as a property. Commit these next to SPIKE-14's route payloads.
2. **Four toggleable render modes**, one per `strategies.py` strategy:
   * `naive` — a `MarkerLayer` with one `Marker` per candidate, radius/opacity
     driven by `salience`.
   * `zoom_threshold` — the same `MarkerLayer`, mounted only at `zoom >= 13`.
   * `cluster_grid` — `flutter_map_marker_cluster` (or a 64 px screen-grid
     clusterer), count glyph per cluster.
   * `salience_gated` — top-K (K from `regions.cut_k(platform)`) as a
     `MarkerLayer`; the rest as one `CustomPainter` drawing
     `Canvas.drawPoints` / batched circles, styled by salience, **not**
     hit-tested individually.
3. **An area-anchor layer** — `PolygonLayer` fed the reconstructed rings
   (`Candidate.ring`), filled + stroked. Toggle independently so its cost
   separates from the marker cost.
4. **A tap probe** — on pointer-up, resolve the hit (widget hit-test for
   markers; nearest-point scan for the canvas layer), select it, and call
   `setState`. Log wall-clock from pointer-up to the first frame that shows the
   selection highlight. This is the number the frame-rate figure hides.
5. **A list widget** beside the map with two-way binding: tapping a row moves the
   camera and highlights on the map (`list -> map`); a map tap selects the row
   (`map -> list`). Log both latencies.

## The matrix

For each `{platform} x {strategy} x {region: sgv, avl} x {zoom: 10, 12, 14, 16}
x {areas: on, off}`:

| metric | how | compare against |
|---|---|---|
| frame p50 / p95 / p99, % over 16.7 ms | `bench.py` orbit-and-zoom, warm | SPIKE-14 "Vector basemap, multi, warm" row |
| RSS (Linux) / working set (Windows) | `bench.py` memory probe | SPIKE-14's ~680 MB / ~1.0–1.2 GB |
| `list -> map` latency | probe (5) | — |
| `map -> list` latency, incl. rebuild | probe (4) | the "instant" ≤ 100 ms / "usable" ≤ 250 ms bar |
| cluster-extent highlight latency | probe on a cluster tap | same bar |

## What the run decides

* Replaces `WIDGET_MARKER_FRAME_US`, `CANVAS_DOT_FRAME_US`,
  `POLYGON_VERTEX_FRAME_US`, `SELECTION_REBUILD_US_PER_WIDGET` with measured
  values; re-runs `analyze.py`; re-states the bands and A16 if they move.
* Confirms or moves the **GPU display-density ceiling** (~2,800 from the model).
* Confirms whether `salience_gated` needs the `cluster_grid` backstop only above
  the ceiling (model's finding) or earlier.

Until it runs, `results/RESULTS.md` is a **recommendation on a calibrated model**,
not a measurement — stated as such, the same way SPIKE-13's verdict is.
