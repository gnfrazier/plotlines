# Plotlines — Research Spikes

**Purpose:** Feasibility, cost, and platform-behavior unknowns that should be de-risked with a time-boxed spike *before* the corresponding feature is committed to build. These are distinct from the Design decisions in the PRD's Open Items (which concern *what* to build); a spike answers *whether — and at what cost —* it can be built as written.

**How to read the priority:** **Scope-shaping** spikes can send you back to revise the PRD if they come back negative. **Implementation-informing** spikes won't change scope but determine how a committed feature is built. Do the scope-shaping ones first.

**Companion to:** `Plotlines_PRD.md` (101 FRs / 98 stories).

---

## Priority order (by risk of reshaping scope)

**Gates desktop MVP (do first):**
0. ~~Frozen sidecar packaging — the desktop-MVP foundation~~ — **complete (SPIKE-00, 2026-08-13/14)** — **ARCH §4, A1/A5, Q4/Q5**
0a. ~~Vector mapping — `maplibre_gl` + PMTiles~~ — **complete (SPIKE-14, 2026-08-15)** — **negative on `maplibre_gl`, positive on the goal.** Neither `maplibre_gl` nor its successor runs on Flutter desktop at all; `flutter_map` + `vector_map_tiles` does, offline, **on both Linux and Windows**, and the basemap source and licence are settled. Both residuals closed the same day — Windows needs no source change (GPU 2–3× faster in the median, no faster in the tail, ~1 GB memory), and the missing basemap labels are fixed by a style transform rather than a renderer change — **ARCH §7.2/§9.2/§11, D22/D23/D24, A15/A16, Q9/Q10, PRD FR95, MVP §1.4.5**
0b. ~~Elevation data provider & void-handling policy~~ — **complete (SPIKE-18, 2026-08-15, resolved via prior art)** — **ARCH §6.1/§6.5/§11/§11.1, PRD FR85–FR91, MVP §1.4.5**

**Scope-shaping (later milestones):**
1. ~~Multimodal / paddling data availability~~ — **complete (SPIKE-04, 2026-08-14)**, and its build-side successor ~~SPIKE-19~~ is **complete too (2026-08-16)** — the retired-source check came back clean, so scope is untouched; what it changed is ARCH §13.2
2. Backgrounded GPS-triggered audio on real devices — **FR49, FR47, FR50a**
3. ~~Via-node loop routing~~ — **complete (SPIKE-01, 2026-08-14)**
4. Dart-first offline engine at feature scale — **FR63, FR64**
5. Community data-input extensions — **SPIKE-17, FR84** — shape-shaping for Leg 7, and it carries one question that touches MVP principles rather than Leg 7 alone (see the spike)

Everything below these is implementation-informing rather than scope-shaping.

**Note on sequencing:** SPIKE-00 was the only one that blocked the *near-term* build, and it is closed. **SPIKE-14 (vector mapping) held that position and is now closed too** — nothing unrun stands between the docs and a desktop client that renders. SPIKE-01 (via-node) and SPIKE-04 (paddling) were the routing unknowns worth running alongside early desktop work; the rest gate later milestones (field execution, mobile, Web) and can wait for those. **No spike now gates the desktop MVP**; the two residuals SPIKE-14 left open (Windows verification, basemap labels) were both closed the same day — Windows renders with no source change, and labels are recovered by a style transform.

**Status (2026-08-15):** **SPIKE-00, SPIKE-01, SPIKE-02, SPIKE-03, SPIKE-04, SPIKE-05, SPIKE-14, and SPIKE-18 are complete.** SPIKE-14 ran the same day it was added and came back **negative on its own named hypothesis**: `maplibre_gl` has no desktop support at all, and its successor `maplibre` advertises Linux/Windows/macOS on pub.dev but throws `UnsupportedError` at widget construction — the tags are wrong, which is exactly the kind of claim a spike exists to check. The goal survived the hypothesis: `flutter_map` + `vector_map_tiles` renders a real 6,864-vertex route with 60 node markers over a correct Protomaps vector basemap with the network severed at the OS level, and **route geometry turned out to be free** (zero frames over budget at 41k vertices) while the basemap carries the whole cost. The basemap licence is settled (ODbL, OSM attribution — **PRD FR95**), and Q9/Q10 are answered with measurements rather than deferred: we **extract** bbox archives from the published planet build in ~6 s rather than generating tiles, at ~3.5 MB per 1,000 km². Two residuals were recorded rather than resolved on the first pass — the second desktop platform, and **no basemap labels rendering on any renderer version** — and **both closed the same day**. Windows builds and renders the identical inputs with no source change; on GPU hardware frames are 2–3× faster in the median and **no faster in the tail**, which pins the surviving cost on tile decode rather than drawing, and puts the client's memory budget nearer 1 GB than 700 MB. Labels turned out not to need the renderer at all: two mechanical rewrites in the style file (a simplified `text-field`, and the legacy form of `in` in one filter) bring back street, path and place names, so the recommendation is a Plotlines-authored theme generated in the tile pipeline. SPIKE-05 came back positive for moving time (7–8% MAPE against real activity files) and negative for elapsed time, and turned up a build consequence: FR16's *system default* pace holds for hiking and fails for cycling, which makes the Character-activity-upload path load-bearing rather than optional. SPIKE-04 came back negative on class ratings and reshaped PRD scope accordingly (B4/B5 removed — ARCH D19), which is the outcome this whole document exists to make cheap. SPIKE-18 (elevation provider) closed same-day, resolved via prior art from the cycling-tour-planner POC rather than a fresh run — see its entry below. **All routing-algorithm unknowns are now closed** (01/02/03, run together over one shared fixture set — see [`spikes/shared/`](../spikes/shared/README.md)): via-node loops are nearly free (**A9 promoted to MVP at 1–2 nodes; A9a holds 3+ at P1**), A6's AC is deliverable as written, and min/max bands converge provided their defaults come from measured terrain rather than constants (**FR6 reworded to bound the realized attribute**). **No unrun spike now gates the desktop MVP.** The next scope-shaping ones are **SPIKE-06 / SPIKE-12** (backgrounded GPS audio and playback), which gate the field-execution milestone rather than the MVP build.

**Update (2026-08-16): SPIKE-19 added and run the same day — the desktop MVP is unaffected and paddling's scope is untouched, but one architectural contract has to change before the Leg 3 provider is written.** The paddling provider is Leg 3 work (MVP §1.2), so no new spike gates the MVP. SPIKE-04 remains correct on its own question, and the **product** it named — NHDPlus HR — was retired by USGS on 1 October 2023, with the gauge API it measured decommissioned in Q1 2027. SPIKE-19 confirms the migration to **3DHP is safe**: three of the four load-bearing attributes are renamed, the fourth has moved layers, **none is lost**, and a real **148.2 km downstream route** with **five identifier-bound live gauges** comes out of the successor. Two results carry beyond the spike. **ARCH §13.2 is wrong as written** — `reachcode` is no longer a flowline attribute, and binding gauges needs *both* `mainstemid` and a reach code (77.8% / 80.6% alone, **94.4%** together). And **the data has not been remapped yet** — every flowline in all three regions still reads `workunitid = NHD`, so this migration buys a *maintained* product rather than better data, and the reassuring "within 0.1% of SPIKE-04" comparison expires when elevation-derived hydrography actually arrives. **With SPIKE-19 closed, all paddling-data unknowns that can be settled from open sources are settled**; what remains for paddling is a licensing conversation (American Whitewater) and a non-US assessment, neither of which is an engineering task.

**Both implied PRD amendments have been applied (2026-08-14)** — A9 split into A9 (1–2 via-nodes, MVP) and A9a (3+, P1), and FR6 reworded to bound the realized attribute. See [PRD changes these implied](#prd-changes-these-implied) at the end of this document.

**Four spikes added 2026-08-15 (SPIKE-14 … SPIKE-17); SPIKE-14 has since run, 15–17 have not.** They come from a technology-choice note written during the PRD work and only filed later — [`docs/Plotlines - Spike Candidates.md`](Plotlines%20-%20Spike%20Candidates.md), kept as provenance. They cover the **client** side of the build, which this document had almost nothing on: everything here through SPIKE-13 concerns routing, data availability, packaging, or mobile OS behaviour, and the Flutter client's own rendering, threading, export, and extension questions went unrecorded. **SPIKE-14 gated the desktop MVP** and closed the basemap gap flagged in MVP §1.4.5 — and is the clearest argument for having filed this note as spikes rather than acting on it: its summary table listed `maplibre_gl` as the vector-mapping choice, and running it found that package has **no Flutter desktop support at all**. SPIKE-16 bears directly on an `[MVP]` story (F3) *and* raises where export runs. The note's summary table also contained three technology calls that are **not** spikes — see [Technology choices from the same note that are not spikes](#technology-choices-from-the-same-note-that-are-not-spikes) below, because one of them conflicts with an architectural principle.

**A fifth spike, SPIKE-18, was also added 2026-08-15 — from a different source.** Unlike SPIKE-14–17, it does not come from the Spike Candidates note; it closes the *other* unassigned decision MVP §1.4.5 flagged (the elevation provider), and it is recorded already-resolved via prior art from a separate working POC (`github.com/gnfrazier/cycling-tour-planner`) rather than as something still to run.

**A sixth spike, SPIKE-19, was added 2026-08-16 and ran the same day.** On its face it was the build-side successor to SPIKE-04: implement the paddling provider, bind live gauges to reaches. What made it worth running first is that **USGS retired the National Hydrography Dataset on 1 October 2023 and stopped maintaining NHDPlus HR** — the source SPIKE-04 settled on, and the one ARCH §11, §13.2 and D19 all rest on. USGS 3DHP is its replacement, not an alternative to it. That made SPIKE-19 partly a **migration-readiness** spike, and together with the USGS WaterServices decommissioning already scheduled for Q1 2027 it meant **both halves of the paddling data answer were mid-migration at once.** A closed spike's verdict does not expire, but the external product behind it can, and this register is where that surfaces before the code is written. **It came back clean on scope and not clean on design:** nothing SPIKE-04 measured was lost, and **ARCH §13.2's single-key `reachcode` rule turned out to be unbuildable on the successor** — which is exactly the class of error that is cheap now and a re-fetch of an entire network later.

---

## Packaging & distribution (desktop MVP foundation)

### SPIKE-00 — Frozen sidecar packaging ✅ **COMPLETE**
**Covers:** ARCH §4 (portability), risks A1/A5, Open Questions Q4/Q5 — the foundation of desktop MVP
**Priority:** Scope-shaping — **was the only spike blocking the near-term build**
**Run:** 2026-08-13 (Linux) + 2026-08-14 (Windows) · **Result:** [`spikes/SPIKE-00/results/RESULTS.md`](../spikes/SPIKE-00/results/RESULTS.md) and [`WINDOWS.md`](../spikes/SPIKE-00/results/WINDOWS.md) — **the sidecar model holds (ARCH D1 confirmed).** Q4 → PyInstaller `--onedir`; Q5 → bundle in the installer. Identical routes on both platforms; §7.3's stop contract corrected for Windows. **Closed.**
**Unknown:** Can `plotlines-core` plus its heavy native dependency tree (GDAL, GEOS, rasterio, numpy, shapely) actually be frozen into a standalone binary that the Flutter app spawns as a child process, serves FastAPI on loopback, and shuts down cleanly — at an acceptable binary size and cold-start time? Every other spike concerns a later milestone; this one gates the thing being built first.
**Spike question:** On your primary desktop platform, freeze `service`+`core` (try PyInstaller and Nuitka — Q4) into a single binary; confirm it spawns, answers a `/health` and a real `/segments/generate` call over loopback, and terminates on signal. Measure binary size and cold-start-to-ready time. Repeat on a second desktop OS to expose cross-platform surprises. Assess bundle-in-installer vs. download-on-first-run (Q5) from the resulting size.
**Decides:** Whether the sidecar model (ARCH D1) holds for desktop as designed, and the answers to Q4 (which freezer) and Q5 (bundle vs. download). A negative result reshapes the entire desktop delivery approach before any UI is built.
**Done when:** A frozen binary generates a real route over loopback on two desktop platforms, with size and startup time quantified — or the blocking failure is documented and the delivery model revisited.

---

## Elevation & terrain data (desktop MVP foundation)

### SPIKE-18 — Elevation data provider & void-handling policy ✅ **COMPLETE (resolved via prior art)**
**Covers:** ARCH §6.1 (`enrich_elevation`), §6.5 (void handling), §11/§11.1/§11.2 (integration table, two-phase cache, attribution); PRD M3/FR62/FR85–FR91; MVP §1.4.5 — the second of the four "decisions this list cannot make for itself"
**Priority:** Gates desktop MVP — M3 is `[MVP]` and cannot be built against an unnamed provider
**Run:** N/A — resolved via prior art. The cycling-tour-planner POC (`backend/ctp_core/elevation.py`, `backend/ctp_service`, `README.md`) is a working, tested implementation of this exact provider (GEDTM30 via OpenTopography) that already found and fixed a real NaN-vs-`==` nodata defect (`test_elevation.py`).
**Unknown:** Which elevation provider to use, under what licence and rate limit, and what void/failure policy keeps a route solve from ever blocking or raising.
**Decides:** GEDTM30 via OpenTopography as the single source (no fallback), its CC BY attribution and 50 calls/24h free-tier limit, and the exact void/nodata/NaN fallback policy — recorded as PRD FR85–FR91 and ARCH D20.
**Done when:** A named provider, licence, and void-handling policy are written down and traceable to a working implementation. **Met** — see FR85–FR91, ARCH §6.5, D20.

---

## Client platform & rendering (desktop MVP foundation)

The client half of the foundation. SPIKE-00 proved `plotlines-core` can be frozen and spawned; these two ask whether the Flutter app around it can draw a map and stay responsive. Both were absent from this document until 2026-08-15.

### SPIKE-14 — Vector mapping: `maplibre_gl` + PMTiles ✅ **COMPLETE**
**Covers:** ARCH §7.2 (`GET /tiles/{z}/{x}/{y}`), §9.2 (tile storage per platform), §11 (which had **no tile-provider row**), §11.3 (offline package size), FR35/FR64 (buffer + offline package, later); MVP §1.4.5 — the first of the four "decisions this list cannot make for itself"
**Priority:** **Gated desktop MVP**
**Run:** 2026-08-15 · **Result:** [`spikes/SPIKE-14/results/RESULTS.md`](../spikes/SPIKE-14/results/RESULTS.md) — **negative on the named hypothesis, positive on the goal.** `maplibre_gl` 0.26.2 supports **android, ios, web only**; there is nothing to test on desktop. Its successor `maplibre` 0.3.5 is tagged `windows, linux, macos` on pub.dev — and those tags are **wrong**: its plugin manifest declares only three implementations, and a Linux build compiles, links, opens a window, and then throws `UnsupportedError: MapLibre is not supported on this platform` at widget construction. A technology note written from pub.dev tags would have put a map on every Author Desktop screen before discovering this. **The GPU-native MapLibre path does not exist on Flutter desktop.**
**What does work:** `flutter_map` 8.3.1 + `vector_map_tiles` 9.0.0-beta.11 + `vector_tile_renderer` 6.1.0, which rasterizes vector tiles onto Flutter's own canvas. It rendered a real 6,864-vertex routed polyline with 60 node markers over a correct Protomaps v4 basemap **inside a network namespace with no route and no DNS** (`unshare -rn`) — P2's offline claim, verified at the OS level rather than by asking the app.
**Performance (Linux pass — software rasterization, `llvmpipe`, no GPU; every figure is a floor, and see the Windows/GPU numbers below):** **route geometry is free** — 0% of frames over the 16.7 ms budget at 1.2k, 6.9k *and* 41k vertices; the 41k case is ~660 km of OSM-noded route, well past any real trip. **The basemap is the entire cost, and it is a first-view cost**: cold, 14–47% of frames miss budget while tiles decode; warm, p95 falls to **15.5 ms** and jank to **2%**. Offline costs nothing measurable (73 vs 77 fps). Memory is the number to watch — the basemap adds ~400 MB RSS (~280 → ~680 MB).
**Three findings that change the build:** (1) the last **stable** `vector_map_tiles` (8.0.0, Aug 2024) pins `flutter_map ^7` and a renderer that **silently drops every road** from the current Protomaps v4 basemap — no error, just an unusable map; the working combination is a **pre-release**. (2) **No labels render on any renderer version** — the v4 themes drive labels through `format`/`case`/`is-supported-script` expressions the Dart renderer does not implement (**since fixed in the style — see Labels below**). (3) **PMTiles cannot be read inside the Flutter client**: `pmtiles` 1.x/2.x conflict with the modern `vector_map_tiles` on `latlong2` and `protobuf` respectively, and the bridge package pins the broken stable. No version triple resolves.
**Settled:** The basemap stack (`flutter_map`, not MapLibre — **ARCH D22**), the tile source and licence (Protomaps Basemap, **ODbL**, OSM attribution required, hotlinking discouraged so we mirror — **PRD FR95, ARCH D23**, filling the missing §11 tile row), and **the sidecar-vs-client fork, in the sidecar's favour** — not by preference but because the client-side path is dependency-blocked, which independently vindicates FR92/D21. Also answers **Q9** (extract from the published planet build in ~6 s rather than generate tiles — Planetiler stays on the shelf for custom layers) and most of **Q10** (~3.5 MB per 1,000 km² at z0–15; 1.0 MB CI bbox, 22 MB for an 80 km square, 118 MB for a multi-day corridor; z14 halves it).
**Second platform — run 2026-08-15, closing the clause the first pass could not reach:** the harness builds and renders on **Windows 11 with no source change** (`flutter create --platforms=windows .`; the only edit was a non-Linux fallback for the harness's own `/proc/self/status` RSS probe, which had been silently returning zero). Same 8-cell matrix, **byte-identical inputs** — same route payloads, same 171 tiles, verified by hash. On real GPU hardware (Intel Iris Xe) frames are **2–3× faster in the median** (basemap multi cold 13.1 → 5.5 ms; warm p95 15.5 → **7.6 ms**, 1% over budget) — and **no faster in the tail** (cold p99 45.5 → 64.8 ms, *worse*). Two rasterizers, same shape: **the cost that survives hardware acceleration is tile decode, not drawing**, which is where any future optimization belongs. Route geometry is free on both. **Memory went the other way and is the number to carry: ~1.0–1.2 GB working set on Windows against ~680 MB RSS on Linux** — different metrics, not subtractable, but the client should be budgeted near 1 GB. Offline was re-verified more weakly there (socket audit by PID — no remote endpoint observed; a firewall rule needs Administrator), so **the Linux `unshare -rn` result stays the load-bearing evidence for P2**.
**Labels — fixed, in the style rather than the renderer (2026-08-15).** The gap turned out not to be missing label support but **two specific expression constructs a style can avoid**: `text-field`'s multi-script name fallback (`format`/`coalesce`/`is-supported-script`) on 10 symbol layers, and the expression form of `in` in one filter. `probes/simplify_labels.py` rewrites both, and street, path and waterway names render with halos and line placement ([`shots/windows-labels-z15.png`](../spikes/SPIKE-14/results/shots/windows-labels-z15.png)) at no measurable frame cost. **Recommendation: ship a Plotlines-authored theme generated by that transform, in the tile pipeline beside the mirror** — not a renderer fork and not an upstream contribution. Two limits recorded: `["get","name"]` is local-name-only (fine for the US/English MVP, a debt for later locales), and the `pois` layer still needs a per-feature zoom threshold replaced by a static one — a cartographic decision, not a rewrite, and park/peak/beach names are what it costs until it is made.
**Left open, deliberately:** **macOS**, which was never claimed — two desktop platforms was the bar and two is what there is. The **pre-release dependency** is unchanged: the working stack is a `vector_map_tiles` beta, and whether to ship on it or wait for 9 stable is a call this spike surfaces rather than makes (ARCH A14). **Closed.**
**Already decided, out of this spike's scope (2026-08-15, from the cycling-tour-planner POC — PRD FR92–94, ARCH D21):** the client talks only to Plotlines' own `GET /tiles/{z}/{x}/{y}` service, never a third-party tile host directly; the service validates `z/x/y` range before any upstream work; tile generation/caching is bbox-scoped and on-demand (not a standing global server), sharing one pipeline with offline bundles. These are contract decisions, not renderer decisions — they hold regardless of what this spike finds below.
**Unknown:** Every screen in the Author Desktop wireframe is a map, and **no document in this repo names a basemap.** The integration table in ARCH §11 lists elevation, weather, geocoding, OSM Overpass, and USGS — and no tiles. `client/pubspec.yaml` declares no dependencies at all. So three things are unproven at once: that `maplibre_gl` renders and performs acceptably on Flutter *desktop* (its Linux/Windows desktop support is materially less exercised than its mobile support), that PMTiles gives us a single-file offline tile archive the sidecar or the client can serve locally, and — the part that is not a technology question at all — **which tile source we are licensed to use and what attribution it obliges.** Two further unknowns carried over from the tile-contract review: the **concrete tile-generation tooling** (`tilemaker` → MBTiles, or an alternative — ARCH Q9), and the **region/bbox selection strategy** (fixed named regions, per-trip bounding box, or both; the first-run experience for a Character with nothing downloaded; a minimum-useful-region sizing criterion — ARCH Q10). On that last point, the cycling-tour-planner POC's first default bbox was too small to produce real routes and had to be widened to a ~80 km square (Marion, NC) before it worked — a cautionary reference data point on sizing, not a Plotlines default.
**Spike question:** Render a real routed polyline with node markers over a vector basemap in a Flutter desktop window on at least two desktop platforms. Serve tiles from a local PMTiles archive with the network unplugged (P2), and measure: pan/zoom frame rate at a realistic node count, archive size for a region comparable to a multi-day trip corridor, cold-open time, and memory. Separately, settle the licensing: which tile source (self-hosted from OSM data, a hosted vendor's free tier, a public PMTiles build), under what terms, and what attribution string must appear where — feeding the About surface obligation (ARCH §11.2/§12.4, MVP §1.4.3). Alongside that, settle the tile-generation tooling (Q9) and the region/bbox selection strategy and its minimum-useful-region sizing criterion (Q10), including a small pinned bbox for CI/tests.
**Decides:** The basemap stack, the offline tile story, and the tile row missing from ARCH §11 — including whether tiles route through the sidecar (`GET /tiles/{z}/{x}/{y}` as designed) or the client reads the PMTiles archive directly, which is a real architectural fork the endpoint surface currently presumes one answer to. A negative result on desktop `maplibre_gl` sends the presentation layer to a different map package before any screen is built. **That last clause is what happened** — see Result above.
**Done when:** A themed route renders offline over a local tile archive on two desktop platforms with quantified performance and size, and the tile source's licence and attribution obligation are written down — or the failure is documented and an alternative package chosen. **Met in full on the alternative-package branch, on two platforms** (Linux 2026-08-15, Windows same day).

### SPIKE-15 — Dart isolates for background processing
**Covers:** ARCH §9.1 (client layering), Developer story M7 (core-limit parameter — the same "don't starve the UI" concern on the Dart side); FR68/FR70/FR71 and stories L1/L3/L4 (GeoJSON auto-backup, `.zip` archive export/restore); FR64/H7 (offline package assembly, later)
**Priority:** Implementation-informing
**Unknown:** The desktop client does not compute routes — the sidecar does — but it *does* parse and hold their output, and Epic L asks it to build and restore `.zip` archives containing GeoJSON, Markdown, and photo binaries "without choking the device" (L3's AC, verbatim). Whether `Isolate.run` is the right mechanism, what the payload-size threshold is at which main-isolate parsing becomes visible, and how much the isolate-boundary copy costs for large geometry are all unmeasured.
**Spike question:** Parse a realistic multi-day trip payload — routed geometry, elevation samples, nodes — on the main isolate and via `Isolate.run`, and measure dropped frames and wall time for each. Repeat for a representative `.zip` archive (L3) with photo binaries. Find the payload size at which the main isolate visibly stutters, so the threshold is a measured number rather than a guess.
**Decides:** Whether client-side heavy work needs isolates from the first milestone or only when Epic L lands, and where the size threshold sits. Cheap to get wrong early and annoying to retrofit, since moving work across an isolate boundary later changes the data structures that cross it.
**Done when:** The stutter threshold is quantified for both the trip payload and the archive path, with a recommendation on which client operations run off the main isolate.

---

## Routing-algorithm feasibility

### SPIKE-01 — Via-node loop routing ✅ **COMPLETE**
**Covers:** FR8a (Story A9)
**Priority:** Scope-shaping
**Run:** 2026-08-14 · **Result:** [`spikes/SPIKE-01/results/RESULTS.md`](../spikes/SPIKE-01/results/RESULTS.md) — **A9's own promotion condition is met literally.** Point-to-point, out-and-back, loop, and via-loop are all one call to `solve_circuit(graph, anchors, close=)` with a different anchor list; there is no via-node code path. Out-and-back and a 1-via loop are *the same anchor list*. The cost is not merely acceptable but **negative**: a 1-via loop solves in **48 ms against the unconstrained loop's 295 ms**, because a via *replaces* a synthesised shaping anchor the engine would otherwise have to place and tune. Weights are still honoured — mean edge cost per metre stays within **0.976–1.014** of the same theme's unconstrained loop — and 24/24 runs hit every via and closed.
**Limit found:** at **three or more via-nodes the target distance stops being honourable** — error jumps from under ±14% to **+30.7% (Boulder) and +81.9% (Viroqua)** — because the vias themselves determine the loop's length and leave the distance search nothing to move. This is exactly the case A9 hands to A6, and that hand-off was verified working (the via-node is named as the binding constraint, not the terrain).
**Also settled — degenerate routes:** retracing is fixed by *where* the re-ride penalty applies, not how large it is. A flat penalty cannot distinguish "don't ride the corridor back" from "you may ride the café's dead-end lane back". A locality-aware penalty (full charge in the corridor, near-neutral inside a ball of 5% of target distance around Author-designated points) cut corridor doubling from **41.7% to 6.0%** while *improving* distance conformance — the "lollipop": a spur ridden twice, hung off a loop ridden once.
**Scope decision taken (2026-08-14, PRD FR8a):** the story was **split**. **A9** (one or two via-nodes) promoted from P1 to **MVP** and can be built and closed on its own; **A9a** (three or more) is a new **P1** backlog story where target distance is presented as advisory and A6's relaxation path is offered in the same interaction. **Closed.**
**Unknown:** Can the OSMnx/solver approach constrain a loop to pass through one or more mandatory via-nodes while still honoring weights and a target distance — without unacceptable compute time or degenerate routes?
**Spike question:** Generate loops through 1, 2, and 3 forced via-nodes on a real graph; measure solve time and route quality vs. an unconstrained themed loop.
**Decides:** Whether A9 is promotable to MVP. If via-node and start/destination turn out to be the same constraint primitive, A9 is nearly free and should land in MVP; if not, it stays P1.
**Done when:** A via-node loop generates in acceptable time and returns a sensible route, or the cost is quantified and the P1/MVP call is made on evidence.

### SPIKE-02 — Conflict detection & relaxation ✅ **COMPLETE**
**Covers:** FR9 (Story A6)
**Priority:** Implementation-informing
**Run:** 2026-08-14 · **Result:** [`spikes/SPIKE-02/results/RESULTS.md`](../spikes/SPIKE-02/results/RESULTS.md) — **A6's acceptance criteria are achievable as written; no adjustment to them is needed.** Across 8 scenarios: **8/8 classified correctly, 8/8 named exactly the right constraints, 0 false conflicts** on satisfiable controls, and **5/5 offered relaxations were applied and verified to actually route**. The deletion filter correctly narrowed a three-band conflict to the two bands that actually bind, dropping the one that did not.
**Key distinction the spike forced:** "name the conflicting constraints" splits in two, and collapsing them produces confidently wrong advice. **Unattainable alone** — the band is outside what the graph can produce at any weights ("nothing from here climbs 300 m in 20 km"; a measurement, and nothing else is at fault). **Conflicting in combination** — each is reachable alone but not together ("the climbing is up the busy road"; the useful offer is which *one* to loosen). Reporting the second as the first would tell an Author their mountain town is flat.
**Cost, which shapes the UI more than any other finding:** a satisfiable request is ~1 solve (**27–218 ms**), but diagnosis costs **1.3–15.0 s** and scales with the number of bands. **A6's explanation cannot be produced synchronously inside a route request** — return the best-effort route with its violations immediately, then stream the named conflict and relaxations.
**Honesty boundary:** the search underneath is incomplete, so a combination conflict is worded "no route was **found** meeting them together", never "impossible". Only the unattainable verdict rests on a measurement. **Closed.**
**Unknown:** Can the solver introspect an infeasible constraint set to name *which* constraints conflict and propose the nearest relaxation — rather than just returning an empty result?
**Spike question:** Construct several deliberately-infeasible weight/constraint combinations; determine whether the engine can identify the binding constraints and compute a minimal relaxation.
**Done when:** The engine names a real conflict and a valid relaxation for the test cases, or the limitation is documented so A6's AC can be adjusted.

### SPIKE-03 — Min/max weight-band convergence ✅ **COMPLETE**
**Covers:** FR6 (Story A5)
**Priority:** Implementation-informing
**Run:** 2026-08-14 · **Result:** [`spikes/SPIKE-03/results/RESULTS.md`](../spikes/SPIKE-03/results/RESULTS.md) — **bands converge fine; absolute band *defaults* are what over-constrain.** Same solver, same three graphs, same 20 km target: **8/36 (22.2%) feasible with fixed absolute defaults** (climbing 100–400 m × traffic ≤15/25/35%) versus **3/3 with defaults derived from each region's attainable envelope**. The 77.8% failure rate is manufactured entirely by asking for numbers the place cannot produce, and would have read as "min/max bands don't work" had the envelope not been measured separately. **Band sliders must open on the range the region can actually deliver** — probing costs 10 solves and can be cached per region and distance.
**Band behaviour characterised (the "done when"):** two-sided bands hold down to **±10% of the envelope centre everywhere and ±5% in two regions of three**; solve count is the early-warning signal, climbing toward the budget as a band approaches infeasibility. Precision should be floored in **absolute** units (≈25 m of climbing), not percentages — ±5% of Davis's 19 m is a ±0.95 m window no engine should promise. **Distance must be banded like any other metric**: left unbanded, the compromise silently spent up to **+14.8%** extra mileage to satisfy climbing and traffic.
**Requirements conflict found and resolved (2026-08-14, PRD FR6 / A5):** FR6 said Authors set a min/max on any **weight**; A5's AC says the engine "returns a route **within all bands** where one exists; where none exists, A6 governs." Both cannot hold. A band on a *weight value* can never be infeasible — any number inside the band is a legal weight — which makes A5's clause unreachable and A6 dead code. This spike therefore treats a band as an acceptance range on the **realised route attribute** ("between 400 and 600 m of climbing"), the only reading under which A5's own AC means anything — and **FR6 has been reworded to bound the attribute**, with A5's AC kept and extended to require envelope-derived defaults and an absolute precision floor. **Closed.**
**Two weight-shape limits found:** FR4's surface weight is **unipolar** and cannot *seek* gravel (only tolerate it), so no unpaved-minimum band is satisfiable anywhere — it needs a bipolar weight like FR2's `peaks`. And traffic stress inferred from **highway class alone** overstates rural traffic badly, giving rural Viroqua a 35% traffic *floor* on empty county roads.
**Unknown:** Does compromise-finding across multiple bounded (min/max) weights converge to a good route, or do bands routinely over-constrain into infeasibility?
**Spike question:** Run realistic competing bands (e.g. high climbing-min + low traffic-max) across varied geographies; measure how often a valid route exists and whether it's good.
**Done when:** Band behavior is characterized well enough to set sensible default ranges and know how often A6's conflict path will fire.

---

## Multimodal routing data

### SPIKE-04 — Paddling network & difficulty data availability ✅ **COMPLETE**
**Covers:** FR14, FR14a, FR15 (Stories B6, B8, H11) — *originally FR13–FR15 / B4, B5, B6, H11*
**Priority:** Scope-shaping — **was the highest risk in the PRD**
**Run:** 2026-08-14 · **Result:** [`spikes/SPIKE-04/results/RESULTS.md`](../spikes/SPIKE-04/results/RESULTS.md) — **network yes, gauge yes, access partial, class no, portage no.**
The waterway network and live gauge data are solid and public-domain, but from **USGS (NHDPlus HR / Water Data APIs / NLDI), not OSM** — which resolved ARCH Q2 and makes `WaterwayDataProvider` a real implementation. **Class ratings do not exist in open data** (one graded feature across all three regions; 58 in all of North America) and American Whitewater prohibits reuse of its inventory.
**Scope decision taken (2026-08-14, PRD §8 / ARCH D19):** FR13 retired, **stories B4 and B5 removed** as unbuildable, FR14 narrowed to an advisory gauge band (new story B8, Leg 3, alongside weather), FR15/B6 portages made Author-drawn. Paddling stays a first-class mode. **Closed — reopen only if American Whitewater licensing or North American OSM adoption makes per-reach class ratings available.**
**Carried forward to SPIKE-19 — run 2026-08-16, and this spike's verdict survives it.** The *product* behind that verdict did not: **USGS retired the NHD and stopped maintaining NHDPlus HR on 1 October 2023**, with 3DHP as the single replacement, and the gauge API measured in §5 is decommissioned in Q1 2027. SPIKE-19 found **all four §3.2 attributes intact** in the successor (three renamed, `reachcode` moved to its own layer), reproduced this spike's network within **0.1%** in Western NC, took the threshold decision (**order ≥ 4** — outstanding item 2), and did the geometry pull §10 records as skipped (item 4), producing the **directed 148.2 km route** this spike could only approximate over OSM. It also found that §3.3's undirected routing overstates a paddling route by up to **2×** where a network has two river systems. Items **1** (American Whitewater) and **3** (a non-US region) remain untouched.
**Unknown:** Does usable data exist to route and grade paddling segments? Cycling on OSM is proven; the waterway network, put-ins/take-outs, portages, class ratings, and gauge readings are not.
**Spike question:** For 2–3 representative regions, assess whether OSM carries the paddling waterway graph and access points; identify whether class ratings and gauge heights require third-party sources (e.g. American Whitewater, USGS water-services gauge APIs) and whether those are licensable/usable.
**Decides:** Whether full multimodal MVP (cycling + hiking + paddling as equals) is grounded in real data, or whether paddling scope must be narrowed, deferred, or made dependent on a data partnership.
**Done when:** A clear yes/no per data element (network, access points, class, gauge) with a source and licensing note, feeding a go/no-go on paddling-in-MVP.

### SPIKE-19 — Waterway routing on USGS 3DHP, and binding live gauges to reaches ✅ **COMPLETE**
**Run:** 2026-08-16 · **Result:** [`spikes/SPIKE-19/results/RESULTS.md`](../spikes/SPIKE-19/results/RESULTS.md) — **the succession is safe, and one documented design decision is wrong.** All four attributes SPIKE-04's verdict rests on survive: `flowdir`→`flowdirection`, `streamorde`→`streamorder`, `fromnode`/`tonode`→`hydrosequence`/`dnhydrosequence`, and `reachcode` **moved off the flowline** to a hydrolocation layer. **Nothing lost.** A real **148.2 km downstream route on the French Broad** comes out of 3DHP geometry between the same access points SPIKE-04 used (its 151.1 km OSM route, now directed and solved in 0.01 s), and **five live USGS gauges bind to it by identifier** reading 130 → 512 → 840 → 1,240 → 1,370 cfs downstream. Network length lands within **0.1%** (WNC) and **1.6%** (SW WI) of SPIKE-04's NHDPlus HR figures. **Closed.**
**What must change — ARCH §13.2 is wrong as written:** it requires `reachcode` on every `WaterwayGraph` edge, and 3DHP flowlines do not carry one. Measured over **all 112** real-time sites in the three regions rather than a sample: `mainstemid` binds **77.8%** of NLDI-resolved sites, reach code **80.6%**, and **the two together 94.4%**. They fail on different sites, so **the edge needs both keys**. A related trap is measured and must not be "fixed": the two `mainstemid` namespaces (`geoconnex.us/usgs/…` and `…/ref/…`) are **disjoint registries, not aliases** — 0 of 933 numeric ids appear under both — so normalising the prefix away manufactures false joins.
**The strategic finding: the data has not actually moved yet.** Every flowline in all three regions carries `workunitid = "NHD"` and `featuredate = 2023-09-14` — **3DHP in the product's regions is the converted NHD snapshot, not new elevation-derived hydrography.** Migrating now costs almost nothing and gains almost nothing in data terms; what it buys is a **maintained** product instead of an archived one, which is the whole reason to do it. It also means §1's "within 0.1%" reassurance **expires** when elevation-derived hydrography arrives.
**Three findings that change how it gets built:** (1) **`featuretypelabel` is anti-correlated with paddleability** — every major river in both riverine regions (French Broad, Wisconsin, Kickapoo, Mississippi, Little Tennessee, Pigeon, Tuckasegee) is ~100% `Waterbody Connector`, and the share climbs monotonically with stream order (12.5% at order 4 → 100% at order 8). The careful-looking filter to `Channel Line` **deletes the French Broad**. Filter on `streamorder`. (2) **Paddling routes must be solved downstream-directed** — undirected, Southwest Wisconsin's best route is 207.3 km against 103.8 km downstream, a **2× overstatement** on a path that goes up one river and down another; SPIKE-04's 151.1 km was an undirected solve. (3) **Topology must be built by inverting `dnhydrosequence`**, never by reading `uphydrosequence`, which names only the *main* upstream path and silently drops every tributary at a confluence.
**The elevation decision took itself, and D20 holds unchanged.** 3DHP advertises `hasZ: true` and the geometry carries a third ordinate — which is **0.0 on all 40,938 vertices sampled across all three regions**. There is nothing to weigh against GEDTM30; the Z is a placeholder awaiting the remapping that has not happened. **Re-test when a region's `workunitid` stops reading `NHD`.**
**Also settled:** the **corridor clip** is not a constraint — a true 2 km geodesic buffer around the 176 km run is **392 KB gzipped**, roughly a sixth of the ~2.5 MB of basemap SPIKE-14 prices for the same area, giving FR64 both halves of its budget. The **paddleable-water threshold** (SPIKE-04 outstanding item 2) is taken: **order ≥ 4 as the shipped default**, because order ≥ 3 roughly doubles the network while the longest downstream run barely moves and the largest component's share *falls* in all three regions — the extra water hangs off the network rather than extending it. And the operational story is far better than SPIKE-04 §8's Overpass ordeal: every 3DHP pull ran straight through, no key, no quota, no rate limiting.
**Left open, deliberately:** the provider is a **spike harness, not `plotlines-core` code** — nothing here is written against the real `WaterwayDataProvider` protocol or wired into scoring; **no route was scored** (a shortest path is not a good paddling route); access points are still OSM's, with all of SPIKE-04 §4's problems intact; and SPIKE-04's items **1** (confirm American Whitewater) and **3** (a non-US region) are untouched. A 19.8% network difference in Southern California is reported, not explained.
**Covers:** FR14/FR14a (story **B8**, Leg 3), FR15/B6/H11 (portages and water detail), FR10/FR12 (paddling as a first-class mode, transition nodes); ARCH §6.4 (uncertain multimodal data), §6.5 (nothing blocks a solve), **§11 — both USGS rows**, §13.2 (`WaterwayDataProvider`, `WaterwayGraph.reachcode`), risk **A2**, decision **D19**; MVP §1.2's call that *the paddling graph provider lands in Leg 3 alongside B8*. Picks up SPIKE-04's outstanding items **2** (paddleable-water threshold) and **4** (implement the provider) — not item 1 (American Whitewater) or item 3 (a non-US region), which are a licensing conversation and a separate assessment.
**Priority:** Implementation-informing — it *was* conditionally scope-shaping, and **the condition did not fire**: the attribute check came back clean, so paddling's scope is untouched and what changed is an architectural contract (ARCH §13.2) rather than a PRD story.

**Why this runs before the Leg 3 provider is written: the source SPIKE-04 settled on has been retired.** SPIKE-04 measured **NHDPlus High Resolution** and made it load-bearing — ARCH §11's waterway row, §13.2's `reachcode` rule, and D19's whole scope call sit on it. **USGS retired the NHD on 1 October 2023 and shifted production to the 3D Hydrography Program**; NHDPlus HR remains downloadable but is **no longer maintained**, and 3DHP replaces NHD, WBD and NHDPlus HR with a single product built from lidar-derived elevation. So what this repo currently documents as the paddling network source is a **frozen snapshot**, and 3DHP is not an alternative source to weigh against it — it is its successor. Put that beside the decommissioning of USGS WaterServices in **Q1 2027** that SPIKE-04 §5 already scheduled, and **both halves of the paddling data answer are mid-migration at the same time.** This spike is migration-readiness as much as feature work, which is why it should run before the Leg 3 provider is written rather than after.

**The first task is a regression check, not a feature.** SPIKE-04's network verdict rests on exactly four declared attributes (§3.2), and whether 3DHP carries them — under those names or any names — is unverified. Each failure has a known, specific consequence, which is what makes this cheap to test and expensive to skip:

| SPIKE-04 attribute | What it settled | If 3DHP does not carry it |
|---|---|---|
| `fromnode` / `tonode` | Topology **declared**, not inferred | Connectivity goes back to guessing whether two drawn lines share a vertex — the precise thing §3.2 credits NHD for avoiding |
| `flowdir` | Which way the water goes (100% populated) | The router can send a Character **up** a rapid |
| `streamorde` | Objective "big enough to float a boat" | The Los Angeles flood channels return to the paddling network (§3.1) |
| `reachcode` | The identifier space USGS gauges are indexed in | Gauge association reverts to a spatial nearest-neighbour guess — wrong exactly at confluences and below dams |

The flowline layer's own metadata (`usgs_3dhp_all/FeatureServer/1`) did not return when this entry was written, which is a reason to verify rather than assume.

**And the identifier join is the sharpest unknown in the spike.** It has an obvious wrong answer: bind gauges on whichever identifier the flowline service happens to expose — `NHDPlusID`, `Permanent_Identifier` — and match the remainder by proximity. ARCH §13.2 requires `reachcode` on every edge specifically because **NLDI indexes NWIS sites by it**. 3DHP is organised around *mainstem* identifiers. Which identifier actually joins **3DHP ↔ NLDI ↔ NWIS site** is the one question that, answered wrong, silently turns SPIKE-04's strongest result — 58 of 59 gauges resolved to a reach by lookup — back into a proximity match.

**Boundaries this spike inherits.** A waterway provider touches enough of the system to drift outside its own question, and five of the constraints it must respect are already settled elsewhere. They are listed because each has an appealing shortcut:

- **It runs in the core.** `WaterwayDataProvider` is Python in `plotlines-core`, because a data source has to influence `edge_cost` *during* scoring (ARCH §13.1, P1/D21/FR92). A client that queries USGS directly is a map overlay wearing a provider's name — and it would give sidecar and hosted deployments different water data.
- **It reads a local extract, not a live service.** SPIKE-04 §8 could not complete one region's pull from the public endpoints without tiling each bbox, caching per tile and pacing queries 20 s apart. Same rule as ARCH §14.1's committed fixtures, and the only way to honour §6.5's "nothing blocks a solve".
- **Caching stays on the device.** Per-source adapters inside the provider, with volatility-matched TTLs (P7) — gauge values short, reach linkage long, exactly as ARCH §11 already splits them. A hosted normalization proxy is a **sixth item on P3's list and therefore a design event**; SPIKE-17 is where that evidence gets gathered, and desktop MVP has no hosted tier to put one in.
- **The gauge payload carries a reading, never a verdict.** FR14 as narrowed by D19: current value in the Author's chosen unit (cfs or stage), an age stamp per FR66, and whether it falls inside **the Author's** band. A `status: "runnable"` field is a difficulty grade — the capability D19 removed — and a safety claim no discharge number supports. Class stays Author-declared; American Whitewater's inventory is not licensable and must not be scraped.
- **Rendering and isolates are not this spike's questions.** The flowline overlay is a `flutter_map` polyline layer (D22 — no MapLibre binding runs on Flutter desktop at all), and SPIKE-14 already measured route geometry as **free**: 0% of frames over the 16.7 ms budget at 41k vertices. Where client-side geometry work needs an isolate belongs to **SPIKE-15**, over the whole trip payload. The display surface here is B8's segment inspector on **Author Desktop** — the position-aware cue sheet is FR47 / story I1 in Leg 5, gated by SPIKE-06 and SPIKE-12, and a data-provider spike should not depend on an unbuilt field runtime.

**One decision this spike must take rather than assume: where a river's gradient comes from.** 3DHP is built from lidar-derived elevation and its flowlines are Z-aware, which makes stream slope look free. **D20 names GEDTM30 via OpenTopography as the single elevation source with no fallback**, so drawing slope from flowline Z introduces a second source, and a river's gradient and the trip's elevation profile can then disagree about the same segment. Neither answer is obvious — a lidar-derived water surface may genuinely beat a 30 m DEM on a river. Measure both on a known reach and record the outcome as a decision: either D20 holds and flowline Z is ignored, or water-surface elevation becomes a stated exception in the Decision Log. ✅ **Taken 2026-08-16 — D20 holds, unchanged.** No trade-off existed to weigh: the third ordinate is advertised (`hasZ: true`) and **0.0 on all 40,938 vertices sampled in all three regions**. Ignore flowline Z, and re-test when a region's `workunitid` stops reading `NHD` — that is when the question genuinely reopens.

**Unknown:** Whether the paddling network SPIKE-04 proved exists is still reachable from the product that replaced its source, and whether the gauge→reach join survives the identifier change. Underneath that sit three things SPIKE-04 explicitly did not do: it analysed **attributes, not geometry** (§10 — "building the provider will need the geometry pull this spike skipped"), so no NHD-based route has ever been computed; the **paddleable-water threshold** was left as a product decision measured two ways (order ≥ 4 and ≥ 3, roughly 2× the network) and never taken; and **no route was scored** — a connected directed graph is not a good paddling route.
**Spike question:** For at least two of SPIKE-04's three regions — reuse the same bboxes, because comparability against `spikes/SPIKE-04/raw/` is most of the value — pull real 3DHP flowline **geometry** and answer the four-attribute table above by name. Build a `WaterwayDataProvider` implementation in `plotlines-core` against it, from a **local extract rather than a live service** (SPIKE-04 §8: the public endpoints could not complete that spike's pulls without tiling, caching and pacing), and solve a real put-in→take-out route on it — the geometry-based route SPIKE-04 could not produce. Bind at least one live NWIS gauge to a segment of that route **by identifier, not proximity**, and record which identifier carried the join. Pull both quantities paddlers actually quote — `00060` discharge (cfs) and `00065` gauge height (ft) — from `api.waterdata.usgs.gov` rather than the endpoint being decommissioned, and specify the normalized payload the client receives: site, coordinates, both values, age stamp, and the band comparison, and nothing that grades the water. Confirm nothing in the path blocks a solve (§6.5). Then measure the corridor clip: on-disk size of a buffered flowline network for a multi-day paddle, against SPIKE-14's ~3.5 MB per 1,000 km² of basemap, so FR64's package budget has both halves. Finally, take the threshold decision — stream order, mean annual flow, or both — and re-measure the network against it.
**Decides:** Whether `WaterwayDataProvider` is implemented against **3DHP** or deliberately pinned to the archived NHDPlus HR snapshot with a stated end-of-life; the join identifier that replaces or confirms `reachcode` in ARCH §13.2; whether water-surface Z is an exception to D20; and the paddleable-water threshold that every SPIKE-04 network number moves with. A negative result on the attribute table does not remove paddling — it makes the frozen snapshot the source of record and puts a dated migration risk in the register, which is a **worse** answer than it looks, because the data stops improving while the rivers do not.
**Done when:** A real paddling route is solved from 3DHP geometry with declared topology in at least two regions, a live gauge is bound to one of its segments by identifier, the four-attribute checklist is answered yes/no with the actual field names, the normalized gauge payload is written down as a schema, and the corridor-clip size is quantified — or the regression is documented precisely enough that ARCH §11, §13.2 and D19 can be revisited on evidence. **Met in full, across all three regions rather than two** (routes in two; Southern California produced none, for the same reason SPIKE-04 found — its access points are lake ramps that do not sit on the river network).

### SPIKE-05 — Mode/terrain travel-speed calibration ✅ **COMPLETE**
**Covers:** FR16, FR31 (Story B7)
**Priority:** Implementation-informing (can become scope-shaping if ETAs prove untrustworthy) — **it did not become scope-shaping; ETAs are trustworthy for moving time**
**Run:** 2026-08-15 · **Result:** [`spikes/SPIKE-05/results/RESULTS.md`](../spikes/SPIKE-05/results/RESULTS.md) — **moving time predicts to 7–8% MAPE with personal data; elapsed time only to 13–24%.** All 12 supplied real activity files (7 cycling, 4 hiking, 1 paddling; FIT and GPX) parsed first time. Every figure is leave-one-out cross-validated.
**What it settles for FR16:** the three pace options are **not interchangeable, and which you need depends on the mode.** Hiking's *system default* (Tobler's hiking function, zero personal data) reaches **9.6%** — within a point of the fitted personal model. Cycling's default is **31.4%** off and personal data cuts it to **7.5%**, a 4× improvement. **So the Character-activity-upload feature is load-bearing for cycling and optional for hiking.** No evidence that modelling speed-by-grade beats a single average speed per mode+terrain at this data scale — ship the simple model.
**What it flags for FR31:** stops are a decision, not a terrain property, and elapsed time is roughly **2× worse** than moving time in every model. Recommend presenting **moving time as the estimate with stops as an explicit Author-set allowance**, rather than one blended number whose error a Character cannot attribute. *(Note: the spike question asks for predicted vs. actual **elapsed** times; the spike measured both and the split is the finding.)*
**Also found:** devices label *mode* reliably (every file self-identified) but never label *terrain* — the corpus's mountain-bike ride is recorded as `cycling / generic`, and treating it as road costs **41%** on its ETA. Terrain must be inferred from behaviour; three signals identified it correctly, on n=1.
**Privacy result worth keeping:** the FIT path derives every metric **without reading a single position field**, so a Character's device can share a pace profile without a location history leaving it. **Closed.**
**Unknown:** Can believable moving-time/ETA figures be produced across pavement/gravel/singletrack and flatwater/moving-water, given the terrain data available?
**Spike question:** Feed real GPX from cycling, hiking, and paddling activities through a draft speed model; compare predicted vs. actual elapsed times.
**Done when:** The model predicts within a tolerance you'd trust to show a Character, or the gap is quantified so FR16's default/custom/aggregated pace options can be tuned.

---

## Export interop

### SPIKE-16 — Byte-accurate FIT export via the Garmin FIT SDK
**Covers:** FR44, FR45 (story **F3, `[MVP]`**); ARCH §6.1 (`export_trip` in the core), §7.2 (`POST /trips/{id}/export`), §13.3 (the Dart-side output-integration seam); MVP §1.4.5 — the fourth "decision this list cannot make for itself" named FIT as the hard one of the three formats and observed that no library has been chosen
**Priority:** Implementation-informing — **but it gates an `[MVP]` story and raises an architectural question the routing spikes did not**
**Unknown:** Two things, and the second is the interesting one.

*First, the format.* GPX and TCX are XML and forgiving; **FIT is a binary protocol with a message/field schema, and head units reject files that are structurally wrong rather than degrading.** FR45 requires waypoints, regroup markers, rest-stop names, and plot-point notes to survive "as native course/turn points **where the target format supports them**" — for FIT that means real `course_point` messages with the right type enum, not a track with names attached. Whether a Python writer can produce a file that a real Garmin, Coros, and Wahoo unit all accept is unproven, and "it parsed in a validator" is not the bar — the bar is a device.

*Second, where export runs.* The architecture puts export in the core: `export_trip(trip, fmt, contents) -> bytes` (§6.1) behind `POST /trips/{id}/export` (§7.2), which keeps one implementation for sidecar and hosted alike (P1/D2). **The spike-candidates note proposes Dart FFI against the official Garmin FIT SDK on the device instead** — which would put one of the four export formats outside the core, on a different code path from the other three, and give sidecar and hosted deployments different FIT writers. That is a real fork, not a detail: it trades a licensing-and-fidelity guarantee for a boundary violation, and it should be decided on measured evidence rather than assumed either way.
**Spike question:** Produce a course FIT file containing a track, elevation, and several `course_point`s of distinct types (turn, water, food, danger, generic) for a real routed segment. Do it twice — once from Python inside `plotlines-core`, once via Dart FFI against the official Garmin FIT SDK — and **load both onto real head units** from at least two vendors. Record what each device does with every course-point type, whether notes survive, whether the file is accepted at all, and what each path costs to build and ship (the FFI path adds a native dependency per platform to a binary already carrying GDAL/GEOS — ARCH risk A5). Check the FIT SDK's licence terms for redistribution while you are there.
**Decides:** Which FIT writer F3 ships, and — if the Dart path wins on fidelity — whether that justifies exporting one format outside the core (a P1 boundary question and a Decision Log entry, not a library preference). Also settles what FR45's "where the target format supports them" actually means per device, which currently no one can state.
**Done when:** A generated FIT course loads and displays its course points correctly on head units from two vendors, with the winning implementation path chosen on evidence and any P1 consequence written up — or the fidelity ceiling is documented so FR45's AC can be narrowed to what devices really do.

---

## Platform & OS behavior (field execution)

### SPIKE-06 — Backgrounded GPS-triggered audio on real devices
**Covers:** FR49, FR47, FR50a (Stories H2, I1, I2a)
**Priority:** Scope-shaping
**Unknown:** Reading the platform docs is not proving it works. Does GPS-triggered narration + silent cue advancement actually survive screen-lock and app-backgrounding on real iOS and Android hardware, across OS versions?
**Spike question:** Build a throwaway app that fires an audio trigger at a geofenced point with the screen locked and the phone pocketed. Run on real iOS and Android devices across at least two OS versions each. Confirm it survives backgrounding, screen-lock, and the 60–130-minute continuous-background-update drop-off reported on iOS.
**Platform notes to verify in the spike:**
- iOS: "While in Use" + `location` background mode + `allowsBackgroundLocationUpdates`; `pausesLocationUpdatesAutomatically = false`; correct `activityType`. Confirm updates persist past ~2 hours.
- Android: typed foreground service (`foregroundServiceType="location"`, `FOREGROUND_SERVICE_LOCATION`) with the mandatory persistent notification; confirm starting the service while foregrounded is sufficient (no "Allow all the time" needed) for the pocketed-but-just-opened flow.
**Decides:** Whether the pocketed-companion model — the core of the field experience — is deliverable as written, or whether the interaction model needs rethinking.
**Done when:** A trigger reliably fires screen-locked and pocketed on both platforms for a multi-hour session, or the failure modes are documented and H2/I2a are revised.

### SPIKE-07 — Adaptive location-accuracy battery savings
**Covers:** FR54a (Story I6a)
**Priority:** Implementation-informing
**Unknown:** Does the low-power→high-accuracy escalation actually save meaningful battery while still firing triggers reliably at their Author-set distances?
**Spike question:** Instrument battery draw over a simulated multi-hour ride, comparing continuous high-accuracy GNSS against the adaptive tier; verify triggers still fire at 50–400 m radii.
**Done when:** A measured battery delta justifies the added complexity, and trigger reliability is confirmed under the adaptive tier.

### SPIKE-08 — Power-saving-mode survival across OEMs
**Covers:** FR67, M9 (Story M9)
**Priority:** Implementation-informing
**Unknown:** Does a typed foreground service keep delivering location under each platform's battery-saver mode on real devices — including aggressive OEM battery managers (Samsung, Xiaomi, etc.)?
**Spike question:** Run the SPIKE-06 test app under OS battery-saver on a spread of real devices from different manufacturers; confirm location keeps flowing.
**Done when:** Location delivery is confirmed under battery-saver on the target device spread, or per-OEM caveats are documented.

### SPIKE-12 — Backgrounded audio playback
**Covers:** FR49, FR50a (Stories H2, I2a) — the audio half of the pocketed-companion model
**Priority:** Scope-shaping (pairs with SPIKE-06)
**Unknown:** SPIKE-06 proves the *trigger fires* when backgrounded; it does not prove the *narration plays*. iOS and Android treat background audio as a separate session/permission concern from background location — playing sound while the screen is locked and the app is backgrounded requires an audio session explicitly configured for background playback, which may interact with other audio (music, turn-by-turn from another app) and with silent-mode/ringer settings.
**Spike question:** Extend the SPIKE-06 test app to *play an audio clip* on the geofence trigger, screen-locked and pocketed. Verify on iOS (background audio mode, `AVAudioSession` category/mixing behavior, silent-switch interaction) and Android (audio focus, playback from a backgrounded foreground-service context). Confirm it plays over or ducks other audio sensibly and isn't silenced by the ringer switch.
**Decides:** Whether narration actually reaches the Character's ears in the pocketed model, or whether the audio-session model needs rethinking (e.g. requiring headphones, or a haptic-plus-audio cue).
**Done when:** A triggered clip reliably plays screen-locked and pocketed on both platforms, with sensible mixing and mode behavior — or the constraints are documented and H2/I2a revised.

---

## Offline engine

### SPIKE-09 — Dart-first offline routing at feature scale
**Covers:** FR63 (Story I7)
**Priority:** Scope-shaping
**Unknown:** The rebrand-plan calls Dart-first offline routing a *direction from a spike*, not a proven feature. Does the offline engine route acceptably within a downloaded map set on a phone's compute and memory budget?
**Spike question:** Route realistic point-to-point requests within a downloaded region on mid-range and low-end phones; measure solve time, memory, and route quality.
**Decides:** Whether Leg 5 can be built on the Dart-first engine as planned, or whether the offline routing approach needs to change.
**Done when:** Offline point-to-point routing performs acceptably on target-tier hardware, or the limits are quantified against Leg 5's scope.

### SPIKE-10 — Adventure-package size
**Covers:** FR64, FR35 (Story H7, C14)
**Priority:** Implementation-informing (scope-shaping if sizes are extreme)
**Unknown:** How large is a realistic offline package — routes + basemap buffer + narration audio + node media — for a multi-day trip?
**Spike question:** Assemble a representative week-long, multi-day package at a typical buffer distance; measure on-disk size and download time on a normal connection.
**Done when:** Package size is known for realistic trips, informing whether the buffer-distance control (C14) and download UX need constraints or tiering.

---

## Plugin & community data (Leg 7)

### SPIKE-17 — Community data-input extensions over normalized JSON
**Covers:** FR84 (Leg 7, deliberately open); ARCH §13.1 (two plugin directions), §13.2 (`EdgeDataProvider` / `NodeDataProvider` / `ShapeDataProvider` / `WaterwayDataProvider`), P6 (plugins extend, never modify), P7 (external resources are borrowed), P3 (server-side state is exceptional and enumerable)
**Priority:** Scope-shaping for Leg 7 — **and one of its sub-questions reaches back into MVP principles**
**Unknown:** ARCH §13 defines the *shape* of a data-input plugin and deliberately leaves the contract open, on the reasoning that the built-in OSM path implementing the same interfaces is the proof they are real. That reasoning has never been tested against a **second, differently-shaped source.** The candidate sources are wildly heterogeneous — ArcGIS MapServer REST, OGC API - Features, WaterML, bespoke DOT feeds, vendor APIs with keys and rate limits — and it is unproven that one `annotate_edges` / `fetch_nodes` contract absorbs them, or that a community contributor could write one without touching core code (P6's actual test).

Three specific unknowns sit inside that:

1. **Does the interface hold across source shapes?** SPIKE-04 already produced one hard case — the paddling network needed USGS NHDPlus HR with declared `fromnode`/`tonode` topology and a `reachcode` per edge, not OSM's inferred shared vertices. That is one non-OSM source and it changed the provider's shape. A second and third will say whether §13.2 generalizes or whether it was fitted to two examples.
2. **Edge-annotation sources are the hard half, and the reason is timing.** A node source (NPS sites, historic markers, campgrounds) is a fetch and a map pin. An **edge** source — realtime traffic, construction, closures — must influence `edge_cost` *during scoring*, which means it has to be resolved and cached before the solve, not fetched during it (ARCH §6.5's rule that nothing blocks a solve). Whether a realtime feed can be usefully snapshotted into a graph annotation, and what staleness rule applies (FR66's age-stamping generalized beyond weather), is unaddressed.
3. **Does normalization need a server?** The note proposes a *serverless edge proxy* to flatten USGS WaterML and weather APIs into light JSON. That is convenient and it **conflicts with P3 and P2 as written**: P3 enumerates exactly five things the hosted service does and normalization is not among them, and desktop MVP has no hosted tier at all (MVP §1.2). The honest alternatives are per-source adapter code inside the provider (no server, more client code, key handling on device) or a proxy that is explicitly added to P3's list as a sixth item by decision. **Adding it silently would be the P3 violation the principle exists to catch.**

**Spike question:** Implement two data-input providers against the existing §13.2 interfaces without changing core code, chosen to be maximally unlike each other and unlike OSM — suggest **one node source** and **one edge source** from the candidate list below. Record every place the interface had to bend. Then, for the edge source, measure the fetch-and-annotate step against a real graph build: how long, how cacheable, what TTL the data's actual volatility justifies (P7), and what a stale annotation should surface to the Author. Finally, write down what a third-party contributor would have to know to add a third source — the packaging, the key handling, the registration — since FR84's whole claim is that the interface is *clean*.

**Candidate sources** (from the note; the point is heterogeneity, not coverage):

| Kind | Source | Shape |
|---|---|---|
| Node | [NPS Data API](https://www.nps.gov/subjects/developer/api-documentation.htm) | REST + JSON, keyed |
| Node | [Active.com Campground APIs](https://developer.active.com/docs/read/Campground_APIs) | proprietary, keyed — tests the licence/redistribution question |
| Node | [NC Highway Historical Markers](https://gis2.ncdcr.gov/dncrgis/rest/services/NCHHM_Public/NC_Highway_Historical_Markers/MapServer) | ArcGIS MapServer REST |
| Shape | [US Scenic Byways](https://geo.dot.gov/server/rest/services/US_Scenic_Byways/MapServer) | ArcGIS MapServer REST — a *route* overlay, exercising `ShapeDataProvider` |
| Edge | State DOT realtime traffic / construction / closures — [NC TIMS](https://tims.ncdot.gov/tims/V2/webservices), [511 WI](https://511wi.gov/developers/doc), [511 SF Bay](https://511.org/open-data/traffic) | three different bespoke schemas for the same concept — the sharpest test of normalization, and directly relevant to **FR3's traffic weight**, which SPIKE-03 found overstates rural traffic when inferred from highway class alone |
| Edge/node | [USGS Water Data](https://api.waterdata.usgs.gov/), [CUAHSI WaterOneFlow](https://his.cuahsi.org/wofws.html) | already partly built for FR14a — the known-good baseline to compare the others against |
| Node/edge | Alternative weather providers | tests swapping a source the core already has a built-in for |

**Decides:** Whether FR84's interface is real or aspirational, what the data-input contract concretely looks like, and whether API normalization needs a server tier — which, if yes, is a **P3 design event requiring an explicit decision**, not a quiet addition. A negative result reshapes Leg 7's promise before anything is published to contributors.
**Done when:** Two unlike providers annotate a real graph through unchanged core interfaces, with the edge-source timing and staleness rule quantified — or the interface's limits are documented so §13.2 can be revised before Leg 7 commits to it publicly.

---

## Cross-account sync

### SPIKE-11 — Group amendment & field-note propagation
**Covers:** FR56, FR56a, FR59 (Stories I9, I9a, I9b)
**Priority:** Implementation-informing
**Unknown:** How do route amendments and field notes reach connected group members, and how does the version-checked conditional write (FR59) behave when several participants amend near-simultaneously? This is the one device→group→devices path in an otherwise per-account local-first model.
**Spike question:** Simulate multiple participants publishing amendments/notes on one trip with overlapping timing; observe notification delivery and conflict behavior under the version check.
**Done when:** Propagation and near-simultaneous-edit behavior are characterized, and any conflict-handling gap for group content is identified before I9/I9a–b are built.

---

## Authentication

### SPIKE-13 — Magic-link email deliverability
**Covers:** FR57 (Story K1) — the sole auth path (Web/Leg-4 milestone)
**Priority:** Implementation-informing — but with an unusually high failure cost
**Unknown:** Magic-link-only auth has a single point of failure by design: there is no password fallback (ARCH D9). If the login email lands in spam, is delayed minutes, or is dropped, the user simply *cannot log in*. Whether a chosen transactional-email provider delivers reliably and within seconds — across common consumer mail hosts and their spam filters — is an unglamorous but real feasibility question.
**Spike question:** Send magic-link emails through a candidate provider (e.g. a transactional-email service) to accounts on the major consumer mail hosts; measure delivery rate, time-to-inbox, and spam-folder placement. Check SPF/DKIM/DMARC setup and whether the custom domain (ARCH §9.3) is needed for sender reputation too.
**Decides:** Which email provider and sender configuration the Web milestone depends on, and whether magic-link-only is safe as the sole path or wants a documented backup (e.g. re-send, or a support recovery route).
**Done when:** Delivery rate and time-to-inbox meet a bar you'd stake login on across the major mail hosts, or the gap is documented so the auth approach can add a fallback before Web ships.

---

## Summary table

| Spike | Covers | Priority | Reshapes scope? |
|---|---|---|---|
| ~~**SPIKE-00 Frozen sidecar**~~ | ARCH §4, A1/A5 | Scope-shaping | **Run 2026-08-13/14 — closed.** Sidecar model holds; Q4/Q5 answered |
| ~~**SPIKE-14 Vector mapping (maplibre_gl + PMTiles)**~~ | ARCH §7.2/§9.2/§11, MVP §1.4.5 | **Gated desktop MVP** | **Complete (2026-08-15) — negative on `maplibre_gl`, positive on the goal.** No MapLibre binding runs on Flutter desktop (pub.dev's desktop tags for `maplibre` are wrong — it throws at widget construction). `flutter_map` + `vector_map_tiles` renders offline; route geometry is free, the basemap is the cost. Basemap = Protomaps/**ODbL** (FR95, D22/D23); sidecar-vs-client fork resolved **to the sidecar** (client-side PMTiles is dependency-blocked), vindicating FR92/D21. Q9 and most of Q10 answered. **Both residuals since closed the same day**: Windows builds and renders with no source change (GPU 2–3× faster in the median, **no faster in the tail** — the cost is tile decode; ~1 GB memory), and labels are recovered by two mechanical rewrites in the style rather than a renderer change. Remaining: the pre-release dependency (A14) and macOS, never claimed |
| ~~SPIKE-18 Elevation provider~~ | ARCH §6.5/§11.1, PRD FR85–91 | Gates desktop MVP | **Complete 2026-08-15 — resolved via prior art.** GEDTM30/OpenTopography, no fallback, exact void/NaN policy (D20) |
| ~~SPIKE-04 Paddling data~~ | FR14–15 | Scope-shaping | **Complete 2026-08-14.** Network/gauge yes (USGS), class no → **B4/B5 removed**, FR14 narrowed (ARCH D19) |
| ~~**SPIKE-19 Waterway routing on 3DHP + gauge binding**~~ | FR14/FR14a (**B8**), FR15; ARCH §11, §13.2, D19 | Implementation | **Complete 2026-08-16 — no. The succession is safe; one architectural contract is wrong.** All four SPIKE-04 attributes survive (three renamed, `reachcode` moved off the flowline); a real **148.2 km downstream French Broad route** comes out of 3DHP geometry and **five live gauges bind to it by identifier**. **ARCH §13.2 must change**: `reachcode` alone binds 80.6% of gauges and `mainstemid` alone 77.8% — **the edge needs both (94.4%)**. **The data has not moved yet** (`workunitid = NHD` everywhere), which makes this a migration to a *maintained* product rather than better data. **D20 holds** — advertised Z is 0.0 on all 40,938 vertices. Threshold taken: **order ≥ 4** |
| SPIKE-06 Backgrounded GPS audio | FR49, FR47, FR50a | Scope-shaping | Yes |
| SPIKE-12 Backgrounded audio playback | FR49, FR50a | Scope-shaping | Yes (pairs with 06) |
| ~~SPIKE-01 Via-node loops~~ | FR8a | Scope-shaping | **Complete 2026-08-14.** Same primitive as start/destination and *cheaper* than an unconstrained loop → **A9 (1–2 vias) promoted to MVP**; **A9a (3+) split out at P1** |
| SPIKE-09 Dart offline engine | FR63 | Scope-shaping | Yes |
| **SPIKE-17 Community data extensions** | FR84, ARCH §13 | Scope-shaping (Leg 7) | Yes — and its normalization-proxy sub-question is a **P3 design event** if answered "server", not a library choice |
| ~~SPIKE-05 Travel-speed calibration~~ | FR16, FR31 | Implementation | **Complete 2026-08-15.** No — ETAs are trustworthy for moving time (7–8%). FR16's system default holds for hiking, fails for cycling |
| SPIKE-10 Package size | FR64, FR35 | Implementation | Possibly |
| **SPIKE-16 FIT export (Garmin FIT SDK)** | FR44, FR45 (**F3, MVP**) | Implementation | Possibly — decides which writer ships, and whether one format legitimately runs outside the core (a **P1 boundary** call) |
| **SPIKE-15 Dart isolates** | ARCH §9.1, M7; FR68/FR70/FR71 | Implementation | No |
| ~~SPIKE-02 Conflict/relaxation~~ | FR9 | Implementation | **Complete 2026-08-14.** A6's AC deliverable as written; 8/8 named correctly, 0 false conflicts, 5/5 relaxations verified. Diagnosis must be async (1.3–15 s) |
| ~~SPIKE-03 Weight-band convergence~~ | FR6 | Implementation | **Complete 2026-08-14.** Bands converge; defaults must come from measured envelope (22% → 100% feasible). **FR6/A5 wording conflict needs a decision** |
| SPIKE-07 Adaptive accuracy | FR54a | Implementation | No |
| SPIKE-08 Power-saving OEMs | FR67 | Implementation | No |
| SPIKE-11 Group propagation | FR56, FR56a, FR59 | Implementation | No |
| SPIKE-13 Magic-link deliverability | FR57 | Implementation | No (high failure cost) |

---

## Technology choices from the same note that are not spikes

[`docs/Plotlines - Spike Candidates.md`](Plotlines%20-%20Spike%20Candidates.md) opened with a summary table of six technology choices. Four became SPIKE-14 … SPIKE-17 above. The other three are recorded here rather than as spikes, because two are already decided and the third is a principle question that no experiment settles.

| Note's recommendation | Status | Note |
|---|---|---|
| **Mobile framework — Dart / Flutter** | **Already decided.** ARCH §3, §9; the whole sidecar model (D1) exists *because* the client is Flutter and the core is Python | No spike needed — this is the premise, not a candidate. Recorded for provenance. |
| **Local database — Drift (SQLite) *or Isar*** | **Already decided: drift.** ARCH §9.2 names drift for Desktop and Mobile; MVP §1.1 repeats it | **Isar is a genuine alternative the architecture never considered**, and the note's stated reason — "clean isolate support" — is the one axis on which it might beat drift, which ties it to SPIKE-15. Not worth a spike on its own; if SPIKE-15 finds drift's isolate story is the bottleneck, reopen it as an ARCH decision then. Until that evidence exists, changing a decided component would be churn. |
| **API normalization — Serverless Edge Proxy** | **Not a technology choice — a principle question.** Folded into **SPIKE-17** as its third sub-question | It reads like infrastructure and behaves like scope. **P3 enumerates exactly five things the hosted service does, and normalization is not one of them**; desktop MVP has no hosted tier at all (MVP §1.2). Adopting a proxy is legitimate — as an explicit sixth item added to P3 by decision, which P3 itself calls "a design event." Adopting it quietly, as an implementation detail of a plugin, is the failure mode P3 was written to catch. SPIKE-17 is where the evidence for that decision gets gathered; the decision itself belongs in ARCH's Decision Log. |

---

## PRD changes these implied

SPIKE-01/02/03 produced two amendments to `Plotlines_PRD.md`. **Both were applied on
2026-08-14**, and are recorded here with the reasoning that produced them.

### 1. Promote A9 (FR8a) from P1 to MVP, capped at two via-nodes ✅ **applied**

A9's priority note already specifies the condition: *"if via-node support is the natural
way the router implements start/destination handling (i.e. a loop's start and a
via-node are the same constraint mechanism), it should land in MVP rather than being
artificially deferred."* SPIKE-01 confirmed that literally — one `solve_circuit` call
serves every route shape, and a 1-via loop is **6× faster** than an unconstrained one
because the via replaces an anchor the engine would otherwise have to search for.

The cap is the new information: beyond two vias the distance envelope cannot be
honoured (+30.7% to +81.9% error), so a **3+ via-node feature stays P1** and needs
A6's relaxation UI to go with it.

**Applied:** the story was **split in two** so the MVP half can be built and closed
without carrying an open caveat. **A9 — Route a loop through one or two designated
nodes** `[MVP]`, whose AC now also requires a genuine loop with retraced road reported,
and requires A6 to name the via-node rather than the terrain on infeasibility.
**A9a — Route a loop through three or more designated nodes** `[P1]`, a new backlog
story whose AC makes target distance explicitly *advisory*, surfaces the deviation, and
offers A6's relaxation path in the same interaction. A9a is a UI-and-expectations
story, not a solver one: at three vias every via was still hit and every loop still
closed — only the distance envelope broke. FR8a's row names both stories; the MVP scope
doc's routing row and the 95 → 96 story count were updated to match.

### 2. Resolve the FR6 / A5 disagreement about what a band bounds ✅ **applied**

FR6: *"Authors set a **min and max** on any **weight**."*
A5 AC: *"engine returns a route **within all bands** where one exists; where none
exists, A6 governs."*

These cannot both be true. A band on a *weight value* is never infeasible — every
number inside it is a legal weight — so A5's "where none exists" clause becomes
unreachable and A6's conflict path becomes dead code for FR6. A band on a *realised
attribute* ("between 400 and 600 m of climbing") can genuinely be infeasible, which is
what makes A5's AC and A6 mean something, and is what SPIKE-02 and SPIKE-03 both
implement and measure against.

**Decision: FR6 reworded to bound the realised attribute**, keeping A5. This was the
smaller edit and preserved the story that already depends on it; the alternative —
softening A5's AC to match FR6's literal wording — would have removed the only route by
which A6 ever fires from a weight band.

**Applied:** FR6 now reads as a band on the realized value of a weighted route
attribute, explicitly "not the weight setting". A5's AC gained two clauses the spike
earned: band controls open on the region's attainable envelope rather than a fixed
absolute scale, and band precision is floored in absolute units so a control cannot ask
for a resolution the terrain cannot support.

### Lower-priority, implementation-level (no PRD wording change required)

- **FR4's surface weight needs to be bipolar** (−1 avoid … 0 indifferent … +1 seek),
  matching FR2's `peaks`. As specified it can only *tolerate* unpaved surfaces, never
  prefer them, so "relative preference across paved / gravel / singletrack" is not
  currently expressible. No FR text change needed — the requirement is already written
  as a *relative preference*; the implementation simply has to match it.
- **Distance should be banded by default**, not treated as a soft target (FR8), or the
  compromise quietly spends the Author's mileage (+14.8% measured).
