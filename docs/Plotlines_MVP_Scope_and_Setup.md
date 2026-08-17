# Plotlines — MVP Scope & Setup

**Purpose:** The day-one document for the fresh repository. It draws the explicit "build this, skip that" line for the desktop MVP and captures the first-week structural decisions — repo layout, the core/sidecar build-and-version pipeline, error/empty-state handling, and config/secrets — that the PRD and architecture imply but don't pin down.

**Companion to:** `Plotlines_PRD.md` (what/why), `Plotlines_ARCHITECTURE.md` (how), `Plotlines_Research_Spikes.md` (what to prove first). Where those decided something, this doesn't re-argue it — it points.

**The MVP in one sentence:** a **desktop** Plotlines client that generates theme-weighted, multimodal-capable routes locally via the sidecar, curates them, and exports them — with **no hosted service, no accounts, no sync, no Web, no mobile field execution.**

---

## 1. MVP scope — build this, skip that

The line here is the one already drawn in the earlier conversation ("can I get to MVP without Render") and in the architecture's tiering. Restated concretely for the repo.

### 1.1 In scope for desktop MVP

| Area | What ships | Reference |
|---|---|---|
| **Routing core** | `plotlines-core` as a pure library: graph build, scoring, elevation, solve, export | ARCH §6 |
| **Themes/weights** | Climbing, traffic, surface, POI-density weights; min/max bands on *realized* attributes, defaults derived from the region's attainable envelope; shape; target distance (banded, not a soft target); via-node loops at 1–2 nodes (A9; 3+ is A9a, P1) | PRD FR2–FR9, FR8a; SPIKE-01/03 |
| **Multimodal (schema + cycling/hiking real)** | Mode-per-segment, transitions, day composition; paddling *pending SPIKE-04* | PRD FR10–FR16; SPIKE-04 |
| **Logistics** | Day splitting, alternates, waypoints/regroup/rest, lodging, historical weather, live metrics dashboard | PRD Epic C, D |
| **Curation** | Node notes/media, narrative arc, POI-themed trips, trigger-distance metadata (authored, not played) | PRD Epic E |
| **Outputs** | GPX/TCX/FIT/GeoJSON export with selectable contents; cue sheets; itineraries | PRD Epic F |
| **Sidecar** | Frozen binary, spawn/health/lifecycle, direct external calls (Phase-1 elevation) | ARCH §4, §7.3, §11.1 |
| **Local storage** | drift (SQLite) for trips; no sync | ARCH §9.2 |
| **About surface** | Attribution (required), app+sidecar version | ARCH §12.4 |
| **UI reference** | Author Desktop wireframe + brand guide, UI gallery, and design tokens → `client/design/`; the `plotlines_ui` Flutter package → `client/packages/` | §2.4 |
| **Distribution** | Manual GitHub Releases, signed installer | ARCH §12.2–12.3 |

> **This table is a capability sketch, not a build list.** It names several capabilities the PRD tags `[P1]`, and it omits obligations that have no story at all. **§1.4 below is the authoritative list and governs where the two disagree.**

### 1.2 Explicitly skipped for desktop MVP

Each of these is deferred *on purpose*, not forgotten. Naming them keeps them from sneaking in.

- **Everything hosted:** Render, custom domain, Postgres, the FastAPI hosted mode. (ARCH §7.1 hosted column, §9.3.)
- **Accounts & auth:** magic-link, sessions — sidecar mode registers no `/auth/*` routes. (ARCH §7.1.)
- **Sync & version-check:** single-device local storage has nothing to reconcile. (ARCH §10.4 is a hosted concern.)
- **Guest tier & rate limiting:** protects the hosted service; irrelevant locally. (ARCH §7.4–7.5.)
- **Web client:** the whole Leg-4 tranche. (PRD Leg 4.)
- **Mobile & field execution:** GPS-triggered narration, cue HUD, adaptive accuracy, dead-zone odometer, the Dart offline engine. (PRD Epic I, ARCH §5.)
- **Group relay:** field notes, amendments, trip feedback — needs the hosted relay. (ARCH §8.)
- **Portability suite (S3–S6 / L1–L4):** GeoJSON auto-backup, archive export/restore — P1, not MVP. (PRD Epic L.)
- **Plugins:** the Leg-7 interface is designed-for, not built. (ARCH §13.)

### 1.3 The paddling scope decision — fully resolved 2026-08-16

**SPIKE-04 ran and closed.** The original question ("is paddling grounded in real data?") came back **network yes, gauge yes, access partial, class no** — and the PRD already absorbed the negative half: FR13 retired, stories B4/B5 removed, FR14 narrowed to an advisory gauge band (B8), FR15/B6 portages made Author-drawn (ARCH D19). Paddling stays a first-class mode. The core was safe throughout, exactly as predicted, because paddling data enters via a provider seam (ARCH §6.4, §13.2).

**What the spike did *not* decide is whether paddling *routing* is in the desktop MVP.** The answer turned out to be "yes, but from USGS, not OSM" — which makes `WaterwayDataProvider` a real implementation with a different topology model (declared, not inferred from shared vertices), a different edge-scale notion (Strahler order), dedicated gauge-join keys on every edge, and a local-extract requirement. That is a substantial build, and none of it is shared with the cycling/hiking graph.

**Updated 2026-08-16 (SPIKE-19):** the named source has changed and the shape has not. USGS **retired the NHD on 1 October 2023** and no longer maintains NHDPlus HR, so the provider targets **3DHP** (ARCH **D27**). Everything SPIKE-04's answer rested on survives the succession — a real 148.2 km downstream route and five identifier-bound live gauges came out of the successor — with two corrections to the build: topology arrives as a **downstream pointer** (`dnhydrosequence`, inverted) rather than from/to nodes, and the edge carries **two** gauge-join keys rather than a single `reachcode`, which is no longer a flowline attribute at all. Neither changes the size of the build or this section's call.

**Decided (signed off 2026-08-16): multimodal schema + cycling/hiking graphs in desktop MVP; the paddling graph provider lands in Leg 3 alongside B8.** B1–B3's acceptance criteria are met by this — B1 requires that the mode be *selectable from the supported list* and the segment *saved with endpoints and mode*, not that every mode has a live graph. Paddling therefore appears as a first-class mode in the schema, the day composer, and the transition model from day one — the mode selector and multimodal day-composition schema ship in desktop MVP; **its router does not.** What waits for Leg 3 is `WaterwayDataProvider` itself: the 3DHP topology, gauge-join keys, and local-extract build. This keeps B8 (gauge band, already tagged Leg 3) and the 3DHP provider in the same tranche, where they share a data source.

The rejected alternative — building the 3DHP provider inside desktop MVP — would have roughly doubled the multimodal work for a mode whose advisory layer is already deferred.

### 1.4 The derived desktop-MVP story list *(added 2026-08-15, signed off 2026-08-16)*

§1.1 and §1.2 draw the scope line by *capability*. The PRD draws it by *story priority*. Neither is a build list on its own, and read together they contradict each other in both directions:

- **The PRD's `[MVP]` tag is not the desktop MVP.** Roughly half the `[MVP]` stories are field-execution or account work that §1.2 explicitly cuts — H2, H7, I1, I2, I2a, I3, I5, I6a, K1, K3, K4, M4.
- **§1.1 promises capabilities the PRD tags `[P1]`** — lodging (C7), historical weather (D3), narrative arc (E2), POI-themed trips (E3), narration trigger metadata (E4), GeoJSON export (E5), itineraries (F2), and travel speeds (B7).

This section resolves both directions into one list. **Where it disagrees with §1.1's capability table, this section governs.**

### 1.4.1 The 27 stories that carry over unchanged

Every story below is `[MVP]` in the PRD *and* survives §1.2's cuts. §1.4.2 then adds four and removes four promises, for **31 stories in total**.

| Epic | Stories | Covers |
|---|---|---|
| **A — Theme-driven routing** | A1, A2, A3, A4, A5, A6, A7, A8, A9 | climbing / traffic / surface / POI weights, realized-attribute bands, conflict + relaxation, shape, target distance, 1–2 via-nodes |
| **B — Multimodal composition** | B1, B2, B3 | mode-per-segment, day sequencing, transition nodes (see §1.3 on paddling's router) |
| **C — Multi-day logistics** | C1, C2, C3, C4, C5, C11 | duration, start/end/rest days, per-mode daily distance bounds, alternates, waypoints/regroup/rest stops, hazards & cruxes |
| **D — Metrics** | D1 | live planning dashboard (see the B7 call below) |
| **E — Curation** | E1 | node notes & media |
| **F — Outputs** | F1, F3 | per-day cue sheets, export contents & splitting (GPX/TCX/FIT) |
| **K — Platform** | K5, K8 | display & measurement preferences, reset planning controls |
| **M — Developer seams** | M1, M2, M3 | themes as data, `weights.at(position)`, one elevation interface |

### 1.4.2 The eight §1.1 promises the PRD tags P1 — decided 2026-08-16

| Story | §1.1 promised | Decision | Why |
|---|---|---|---|
| **B7** travel speeds | "live metrics dashboard" | **Promote, partially** | D1 is `[MVP]` and its AC reads "with FR16, moving time / elapsed time / ETA". D1 cannot ship without B7's model. Promote the *system default* and *custom Author pace* options (including the FR16a activity-upload path, §1.4.4 item 1); **drop "aggregated participant pace"** (needs accounts, out per §1.2). |
| **E2** narrative arc | "narrative arc" | **Promote** | Epic E is the PRD's stated thesis, and an arc-stage tag is an enum on nodes/segments plus map/timeline rendering. Cheap, and it is the thing the product is *for*. |
| **E4** narration trigger | "trigger-distance metadata (authored, not played)" | **Promote the authoring half only** | §1.1 already scoped this precisely. Attach audio to a POI and set its per-node trigger distance; **playback is field execution and stays out**. |
| **E5** GeoJSON export | "GeoJSON export" | **Promote** | F3 already builds the export pipeline; GeoJSON (RFC 7946) is the cheapest of the four writers, and L1's later auto-backup depends on it. |
| **C7** lodging | "lodging" | **Demote — drop from §1.1** | Needs an OSM lodging fetch and a map-overlay filter surface. Not on the generate → curate → export path. |
| **D3** historical weather | "historical weather" | **Demote — drop from §1.1** | Open-Meteo needs no key, so it is cheap, but it is Leg 3 work and B8's gauge band is already deferred to the same tranche. Ship them together. |
| **E3** POI-themed trips | "POI-themed trips" | **Demote — drop from §1.1** | Unlike E2, this is solver work — POIs become the route's organizing spine, not a tag. Materially different cost from the rest of Epic E. |
| **F2** itineraries | "itineraries" | **Demote — drop from §1.1** | Master + *tailored individual* itineraries require a roster and partial-attendance data, which require accounts. Structurally blocked by §1.2. |

Net: **+4 promoted (B7 partial, E2, E4 partial, E5), −4 demoted (C7, D3, E3, F2)** — 31 stories total. §1.4.3 adds a fifth obligation (A10) on top of this, for **32 stories total**.

### 1.4.3 Five obligations, now written up as stories

Each is required by §1.1 or the architecture. As of 2026-08-16, all five have a PRD story and acceptance criteria — **resolved**, not just proposed.

| Obligation | Source | Story |
|---|---|---|
| **Local trip save / open / list** | §1.1 "drift (SQLite) for trips" | The only prior workspace story was **G2 `[P1]`**, a portfolio surface with sync badges and roster management — too heavy for desktop MVP's single-device case. **G2a `[MVP]`** (PRD FR74a) now covers the plain thing: save a trip locally, reopen it, list what exists. |
| **Sidecar lifecycle + version check** | ARCH §7.3, §12.1; `packaging/TODO.md` | **M12 `[MVP]`** — spawn, health-poll to readiness, restart-once, graceful stop, orphan sweep, **including the Windows Job Object + `AttachConsole`/`CTRL_BREAK_EVENT` sequence** `packaging/TODO.md` flags as the one thing that would ship broken if forgotten, plus the client↔sidecar version comparison that refuses a mismatch. |
| **About / attribution surface** | ARCH §11.2, §12.4 | **K10 `[MVP]`** (PRD FR86, FR95) — CC BY credit for elevation, ODbL credit for the basemap, app + sidecar version, reachable from every surface that shows licensed data. §11.2's **missing attribution is a build failure**, not a polish item, carries through as K10's AC. Still absent from the Author Desktop wireframe itself (§2.4) — a design gap, not a requirements one, now that the story exists. |
| **Error & empty-state taxonomy** | §4, §6 item 8 | **M13 `[MVP]`** — the eight states in §4 route through one shared handling surface, stubbed before the first screen rather than retrofitted. |
| **First-run default map region** | ARCH §17 D32/Q10 | **A10 `[MVP]`** (PRD FR96) — an Author with nothing downloaded is prompted for a starting location (city + state, zip, or country + city), downloading a 100 km radius around it; declining defaults to a rectangular bbox over Buncombe County, NC. Originally drafted against the wrong persona (Character/H7, which §1.2 cuts from desktop MVP) and re-homed to Epic A on 2026-08-16. |

### 1.4.4 What the spikes decided that the PRD had not yet absorbed — all six now closed

This section originally listed six spike findings with build consequences that no requirement carried yet. As of 2026-08-16, the PRD and architecture have absorbed all six — kept here as a resolved record, not a live punch list, since the reasoning (why each mattered) is still useful.

1. ~~Activity upload is load-bearing for cycling ETAs, and no FR describes it.~~ **Resolved: FR16a** (`PRD:132`) adds the FIT/GPX upload path feeding FR16's custom/aggregated pace options, derived-metrics-only, FR78-consentable. SPIKE-05 measured cycling's *system default* pace at 31.4% error, falling to 7.5% with personal data; FR16 and B7's AC both carry this now.
2. ~~A6's diagnosis cannot be synchronous, and has no endpoint.~~ **Resolved: `POST /segments/diagnose` + `GET /segments/diagnose/{id}`** are in ARCH §7.2's endpoint table (ARCH D25) — the route returns immediately with its violations, the named conflict and relaxations follow async, exactly as SPIKE-02's 1.3–15.0 s vs. 27–218 ms measurement required.
3. ~~A5's band sliders need an envelope probe, which has no endpoint either.~~ **Resolved: `POST /segments/envelope`** is in ARCH §7.2 (ARCH D26) — a dedicated, cacheable probe distinct from `/segments/generate`, per SPIKE-03's 22%-vs-100%-feasible measurement.
4. ~~FR4's surface weight must be bipolar and the docs still say unipolar.~~ **Resolved:** FR4 (`PRD:112`) and A3's AC are now explicitly bipolar (0.0 avoid ↔ 2.5 indifferent ↔ 5.0 seek), set independently per class — matching what SPIKE-03 found necessary.
5. ~~Traffic stress inferred from highway class overstates rural traffic.~~ **Resolved 2026-08-16 (ARCH D33):** rural/low-signal roads are now the model's zero-stress baseline rather than inheriting a highway-class floor; only real `maxspeed`/`lanes` signals raise stress above it. Threaded through PRD FR3, A2's AC, and ARCH risk A17.
6. ~~Distance should be banded by default.~~ **Resolved:** FR8 and A8 (`PRD:116`, `PRD:328`) both read "banded by default" now, per SPIKE-03's +14.8% unbanded-drift measurement.

### 1.4.5 Four decisions this list cannot make for itself

Blocking, in the sense that building around a guess costs a rewrite. **All four are now resolved** — elevation (SPIKE-18, via prior art), the basemap (SPIKE-14, run 2026-08-15), the trip payload schema (**SPIKE-20**) and cue derivation (**SPIKE-21**), both run 2026-08-16. The last two were initially framed as calls rather than experiments; both turned out to need a spike after all, and both runs are the argument for that framing. SPIKE-20's build-changing findings (a missing staleness flag, and `WeightProfile` meaning three different things) surfaced only when the schema was implemented three times and edited, not when it was drafted. SPIKE-21's first implementation **failed a legibility ceiling declared in advance**, and what fixed it was two structural rules rather than the thresholds a design discussion would have argued about. **No unrun spike now gates the desktop MVP.**

- **Basemap tile source, licence, and Flutter map package — resolved.** Every Author Desktop screen is map-centric, and for an offline-first product this was a licensing question first and a library pick second. Both halves are now settled by **[SPIKE-14](Plotlines_Research_Spikes.md)** (run 2026-08-15). The service *contract* was already decided via the cycling-tour-planner POC (own-service-only, `z/x/y` range validation, bbox-scoped on-demand generation sharing one pipeline with offline bundles — PRD FR92–94, ARCH D21); the spike added the rest:
  - **Map package: `flutter_map` + `vector_map_tiles`, not `maplibre_gl`** (ARCH D22). The spike's own named candidate turned out to have **no Flutter desktop support at all**, and its successor advertises desktop on pub.dev while throwing `UnsupportedError` at widget construction. `client/pubspec.yaml` can now be filled in against a stack that was actually run on desktop.
  - **Tile source: the Protomaps Basemap, ODbL, OSM attribution required** (PRD FR95, ARCH D23) — filling the missing §11 tile row. Hotlinking is discouraged by the source, so Plotlines mirrors it; that is the same conclusion FR92 already forced.
  - **Tooling (ARCH Q9): we extract, we do not generate.** `pmtiles extract` pulls an 80 km bbox out of the published planet build in ~6 s. Planetiler is a later option for custom layers, not MVP infrastructure.
  - **Sizing (ARCH Q10): ~3.5 MB per 1,000 km² at z0–15** — 1.0 MB for a CI bbox, 22 MB for an 80 km square, 118 MB for a multi-day corridor.
  - **Both residuals closed the same day (2026-08-15), on a Windows Flutter install.** The stack builds and renders on **Windows** with no source change, measured across the same matrix on byte-identical inputs: on GPU hardware it is 2–3× faster per frame in the median and **no faster in the tail**, so the surviving cost is tile decode rather than drawing — and the client's memory budget is **~1 GB, not the ~700 MB** the software-rasterized Linux pass suggested (ARCH A16). **Labels are fixed in the style, not the renderer** (ARCH D24, A15): `vector_tile_renderer` lacks exactly two constructs the Protomaps themes use, and rewriting them restores street, path and place names at no measurable cost — so the client build should style from a **Plotlines-authored theme generated in the tile pipeline**, and `client/pubspec.yaml` and the tile service can both be filled in against that. Still open and never claimed: **macOS**, and the pre-release `vector_map_tiles` dependency (ARCH A14).
- **Elevation provider — resolved.** GEDTM30 via OpenTopography (PRD FR85, ARCH D20), validated by the cycling-tour-planner POC (`backend/ctp_core/elevation.py`) and tracked as **[SPIKE-18](Plotlines_Research_Spikes.md)** (resolved via prior art, not run fresh). The exact void/nodata/NaN fallback policy, the CC BY attribution obligation, and the 50 calls/24h free-tier limit are all recorded (PRD FR85–FR91, ARCH §6.5/§11.1, A13). `service/.env.example`'s *"Provider is not yet selected"* placeholder should be updated to name it once this lands in code. M3 `[MVP]` is now unblocked.
- **The trip payload schema — resolved.** [SPIKE-20](Plotlines_Research_Spikes.md) was added and **ran the same day (2026-08-16)**, and the answer is checked in: **[`docs/schemas/trip_payload.schema.json`](schemas/trip_payload.schema.json)** is one document serving `plotlines-core`'s return type, drift's `trip.payload`, the hosted JSONB column, and the Flutter domain classes — **with no adapter at any of the three boundaries** (ARCH D28). Proven by round-tripping a real four-day multimodal trip, solved on the SPIKE-01/02/03 graphs, core → drift → Dart → JSON with **zero field loss**; both producers emit byte-identical canonical files. Four consequences for the build, none of them cosmetic:
  - **`solve.stale` is a new field, and the reason it exists is the finding** (ARCH D30). The payload holds authored inputs and derived outputs together, so an Author edit invalidates geometry, metrics and roll-ups instantly; drift's `dirty` is about sync and cannot say it. Every screen that shows a number derived from a solve has to read this flag.
  - **The payload stores the Author-facing 0.0–5.0 weight profile, never the solver's internal form** (ARCH D29). The conversion between them is unwritten and `WeightProfile` currently means three different things across the PRD, ARCH §6.3, and the code — recorded as **risk A18**, and it lands with the first weight slider.
  - **G2a's trip list must project columns.** `SELECT *` across 20 saved week-scale trips costs **137 ms**; an `id`/`name`/`updated_at` projection costs **1.0 ms**. G2a also wants modes per row, which no column carries — add a denormalized `modes` column rather than decoding a payload per entry.
  - **Sizing, for §1.1's storage row and for SPIKE-15:** a week-long trip is ~1.2 MB of JSON (~280 KB gzipped); on the client, decode + domain build is 9.0 ms but re-serialization (22.7 ms) and the drift write (89 ms) are both past the frame budget.

  Three schema gaps are recorded rather than filled, each additive: FR14's paddling gauge band (waiting on SPIKE-19's identifier question), FR22's group-size tier, FR35's offline buffer distance.
- **Cue derivation — resolved.** [SPIKE-21](Plotlines_Research_Spikes.md) ran on 2026-08-16 and the algorithm F1 ships with is in **`core/plotlines_core/trips/cues.py`** (ARCH **D31** — it runs in the core, because it reads junction degree, `name`/`osmid` and `surface`, and costs 1.1–9.2 ms per route). Nine routes over the three shared graphs reduce 5,235 polyline vertices and 1,314 junctions to 367 cues at **0.87–2.86 derived cues/km**, inside a ceiling of 4.0 declared before the run. Three consequences for the build:
  - **The first implementation failed that ceiling**, and threshold tuning was not the fix. Two structural rules were: *staying on the same way is not a turn* (removed 199 of 509 surviving candidates) and *turns inside 40 m are one manoeuvre* (a further 31). The threshold sweep moves the answer by less than a third — worth knowing before anyone spends a day tuning angles.
  - **Density is judged on the derived half only.** Author content — hazards, portage, transition, alternate, nodes, start/finish — is a fixed ~11 cues that do not scale with distance, so a short route is ~2.8 cues/km before a single turn is derived. Nothing may thin an Author's hazard to hit a density target.
  - **F1's AC needs narrowing on two points** (ARCH **A19**): surface shifts are bounded by OSM tagging — 6 cues across 132 km, **none at all in Davis**, two in gravel-country Viroqua — and turn cues name a way only where OSM does, which is 46% of Boulder's edges. Both are stated in F1's AC as of this run. Related but separately assigned: F3's FIT writer went to **[SPIKE-16](Plotlines_Research_Spikes.md)**, which also decides whether FIT export runs in the core (as ARCH §6.1 has it) or on the device via the Garmin FIT SDK.

---

## 2. Repository structure — monorepo

**Decision: monorepo.** The two build artifacts (`plotlines-core` Python, the Flutter client) must version-lock or they produce platform-divergent routes (ARCH risk A8, §12.1). A monorepo makes that lock natural — one commit, one version, both artifacts — and keeps the pure-library boundary (P1) visible and enforceable in one place. Two repos would push version coordination into tags and submodules for no MVP benefit.

### 2.1 Proposed layout

```
plotlines/
├── core/                     # plotlines-core — pure Python library (P1)
│   ├── plotlines_core/
│   │   ├── graph/  elevation/  scoring/  routing/
│   │   ├── multimodal/  trips/  content/  export/
│   │   └── providers/        # interfaces only (ARCH §13.2)
│   ├── tests/
│   │   ├── fixtures/         # committed graph extracts (ARCH §14.1)
│   │   └── golden/           # golden-route expectations
│   └── pyproject.toml
├── service/                  # plotlines-service — FastAPI wrapper
│   ├── plotlines_service/    # sidecar + (later) hosted mode
│   └── tests/
├── client/                   # Flutter app (desktop first)
│   ├── lib/
│   │   ├── presentation/  state/  domain/  data/
│   │   └── ...
│   ├── design/               # imported Claude Design reference: wireframes, brand guide,
│   │   │                     # UI gallery, tokens, specimen cards (§2.4)
│   │   ├── tokens/  cards/  assets/
│   │   └── ...
│   ├── packages/
│   │   └── plotlines_ui/     # the design system as a Flutter package — a path
│   │                         # dependency of the app, not a reference document
│   └── test/
├── packaging/                # frozen-binary build, installers, signing
│   └── version.lock          # single source of truth for the paired version
├── docs/                     # PRD, ARCHITECTURE, SPIKES, this doc
│   └── schemas/              # trip_payload.schema.json — the one contract core,
│                             # drift and the Dart domain layer all read (SPIKE-20)
├── .github/workflows/        # CI (ARCH §14.5)
└── README.md
```

### 2.2 The version-lock mechanism

`packaging/version.lock` holds the one version string both artifacts stamp themselves with. The build reads it into the frozen sidecar and into the Flutter client at build time; the client checks the sidecar's reported version (via `/health`) against its own at runtime and refuses a mismatch (ARCH §12.1). This is the concrete implementation of A8's mitigation — write it once, at the start, so the two artifacts can never quietly diverge.

### 2.3 The P1 boundary as a CI gate

`core/` may not import `fastapi`. This is a CI lint (ARCH §14.5, risk A7), not a review convention. Put it in the workflow on day one — it is the cheapest possible defense of the principle the whole two-deployment model rests on, and it is nearly free before there's code to violate it.

### 2.4 The desktop UI reference — Claude Design wireframe

The MVP desktop UI targets the **Author Desktop** persona, and its wireframe lives in a Claude Design project. It is imported into the repo at **[`client/design/Plotlines Author Desktop.dc.html`](../client/design/Plotlines%20Author%20Desktop.dc.html)** as the **source-of-truth visual reference** the Flutter `presentation/` layer is built against — imported as reference, not as shipped code.

**This file is the current reference for the desktop-MVP story list (§1.4)'s five screens** — `00 New Route`, `01 Route Planner`, `02 Constraint Conflict`, `03 Node & Narrative`, `04 Cue Sheet + Export` — plus a trips library and settings screen the 2026-08-17 re-export added. The `client/lib/presentation/` build described in §8 was built against an *earlier* pass of this wireframe and extended past it where that pass fell short of §1.4's 32 stories (via-node UI, band controls, a real shape selector, rest days/regroup, attribution); the 2026-08-17 revision below closes most of that gap in the design itself, so reconciling the two is follow-up work, not yet done.

Two boundaries matter. First, **importing the wireframe and implementing it in Flutter are separate steps** — the setup run imports the reference; translating it into widgets is later work, reviewed on its own. Second, **the wireframe may show more than MVP builds** (§1.2 skips whole tiers); where the design depicts screens or components outside MVP scope, that is a mismatch to flag and scope deliberately, not to build silently.

**Second import, 2026-08-15 — the rest of the design system (partial).** The first pass took only the Author Desktop wireframe and flagged that the project also held a brand guide, a UI gallery, and a Flutter component package. `client/packages/plotlines_ui/` — the Flutter package, code not reference — landed in full: `PlotTheme.light/dark/highContrast`, a `PlotColors` theme extension, `PlotButton`/`Card`/`Badge`/`Dialog`/`ListTile`, and the brand widgets `NodeMarker`, `CueSheetRow`, `ElevationProfile`, `TripCard`. The Brand Guide and UI Gallery `.dc.html` files and the brand PNGs were referenced in this doc as landed but had not actually come through the Design MCP (both exceeded its 256 KiB per-read cap) — corrected below.

**Third import, 2026-08-17 — a full re-export closes the remaining gaps.** `Plotlines - Design.zip`, provided directly rather than through the Design MCP, landed everything the second pass was missing plus a **substantially revised Author Desktop**:

- All four `.dc.html` wireframes now exist in `client/design/`: Author Desktop, Brand Guide, UI Gallery, and (new) Field App — the last kept as reference for a future mobile milestone, still out of scope for desktop MVP (§1.2).
- Both brand PNGs (`assets/plotlines-logo.png`, `assets/plotlines-favicon.png`) landed whole.
- `client/packages/plotlines_ui/` is unchanged from the second import on every file this repo hasn't since patched — **and it now compiles**: `flutter analyze`/`flutter test` both pass, discharging the upstream "never been compiled" warning. The one outstanding item from the second import — fonts fetched from Google's CDN — is resolved for the shipped client (`plotlines_ui` now vendors Instrument Serif/Archivo/JetBrains Mono as `.ttf`s and reads them locally) though the reference `.dc.html`/`tokens/fonts.css` files still call out to Google, which is fine for reference documents.

**The wireframe's revision closes most of what the SPIKE-01/02/03 amendments (2026-08-14) had left stale.** Checked directly against the 2026-08-17 file: via-node UI, min/max band controls, a real three-way shape selector (`LOOP` / `OUT-BACK` / `P2P`), rest days, and an attribution surface (`CC BY`, `ODbL`, `OpenStreetMap` all appear) are now present, and the stale relaxation-chip copy bounding a weight instead of an attribute is gone. Two things remain open: a text search found no occurrence of "regroup" specifically (C5) — worth a visual check before concluding it's actually missing — and the window chrome still mocks a browser address bar (`plotlines.app/plan/new`), which desktop MVP's native app doesn't have. `client/design/README.md` carries the full table.

---

## 3. Build & version pipeline

The first-week pipeline, minimal but complete:

1. **`core` builds and tests as a normal Python package** — pure, fast, offline (committed fixtures, no live OSM).
2. **`service` wraps `core`** and runs its contract + lifecycle tests.
3. **`packaging` freezes `service`+`core` into a per-platform sidecar binary** (PyInstaller vs. Nuitka is Open Question Q4 — pick during the sidecar prototype), stamped with `version.lock`.
4. **`client` builds the Flutter desktop app**, stamped with the same version, bundling (or fetching — Q5) the sidecar binary.
5. **A signed installer** is produced per platform (signing per ARCH §12.3) and published to GitHub Releases.

**Sequencing note:** prototype the frozen sidecar on your primary desktop platform *first* — it's the easy case (no iOS constraints) and it validates the whole two-artifact model before any UI polish. This is the same "prove the sidecar early" guidance from ARCH §4.1, applied to desktop.

---

## 4. Error & empty-state taxonomy

The architecture is principled about *honest* failure but never enumerates the states. For desktop MVP, these are the ones a user will actually hit. Each gets one defined, consistent treatment — not an ad-hoc dialog invented at the call site. All of this follows the PRD's "quiet, honest state" values (PRD §2.6) and the ARCH cold-start handling (§7.3).

| State | Trigger | Treatment |
|---|---|---|
| **Sidecar starting** | Cold launch, graph still loading | The cycling-themed wait, escalating if slow (PRD Story C27 lineage); never a bare spinner or a hang |
| **Sidecar won't start** | Health-check timeout | Honest message + retry; the app doesn't pretend it's working |
| **Sidecar died mid-session** | Process crash | Transparent single restart; if that fails, degrade honestly — cached trips still viewable, generation unavailable, stated inline |
| **No route possible** | Constraints conflict | Named conflict + nearest relaxation with trade-off (PRD FR9); never a raw failure |
| **No data for area** | Region has no/thin OSM coverage | Clear "this area doesn't have routable data" — distinct from a conflict; don't return an empty map silently |
| **Elevation void / missing tile** | DEM gap | Silent zero-delta per ARCH §6.5 — *not* a user-facing error; logged once |
| **External provider unreachable** | Elevation/weather API down or rate-limited | Degrade honestly: route still generates (elevation void rule), weather shows last-cached age-stamped or "unavailable"; never block generation |
| **Export failed** | Write error / unsupported content combo | Explicit, actionable message; the generated route is never lost because an export failed |

The rule tying these together: **a failure in an optional enrichment (elevation, weather, export) never destroys the primary work (the route).** That's P5 and the honest-state value applied to the desktop error surface.

---

## 5. Config & secrets

Even desktop-only needs the elevation provider's API key. The minimal, correct handling:

- **The elevation API key lives in the sidecar's environment/config, never in the client and never in the repo.** The client never talks to the provider directly (ARCH §11.1) — only the sidecar does — so the key belongs there. The provider is OpenTopography (GEDTM30, PRD FR85); its free non-academic key is capped at **50 calls/24h** (FR87), so local dev should avoid hammering it — cache results locally rather than re-fetching on every test run.
- **Local config file, git-ignored**, with a committed `.example` template so a fresh clone knows what's needed. No secrets in source control, ever.
- **Weather (Open-Meteo) needs no key** (ARCH §11) — one less thing to manage.
- **No other secrets exist at MVP** — no DB credentials, no session signing keys, no OAuth tokens, because none of those tiers are built. This is a genuine benefit of the desktop-first scope: the secret surface is exactly one key.
- **Attribution is not config** — it's a build requirement (ARCH §11.2/§12.4), present regardless of keys.

---

## 6. First-week checklist

The concrete "open the empty repo and do this" order:

1. **Create the monorepo skeleton** (§2.1) and drop the four docs into `docs/`.
2. **Stand up `core/` with the P1 CI lint** (no `fastapi` import) before writing routing code (§2.3).
3. **Commit the first graph fixture** and write one golden-route test — establish the pattern before the solver grows (ARCH §14.1).
4. **Wire `version.lock`** and the client↔sidecar version check, even against a stub sidecar (§2.2). The seam matters more than the content this early.
5. ~~**Import the Author Desktop wireframe** from Claude Design into `client/design/` (§2.4) so `presentation/` has a reference to build against.~~ **Done** — the wireframe on 2026-08-13, the rest of the design system (brand guide, UI gallery, tokens, cards, and the `plotlines_ui` Flutter package) on 2026-08-15. See §2.4 for the three caveats that came with it.
6. **Prototype the frozen sidecar** on your desktop platform; resolve Q4 (freezer) and Q5 (bundle vs. download) from what you learn (§3).
7. **Run SPIKE-04 (paddling data)** in parallel — it's the one open scope decision (§1.3) and it doesn't block the cycling path.
8. **Stub the error taxonomy** (§4) as a single error-handling surface, so states are handled uniformly from the first screen rather than retrofitted.

Items 2–4 are the ones that are painful to retrofit and cheap to establish now (the P1 CI gate, the first golden test, the version-lock seam). Everything else — including the design import (5) and the sidecar prototype (6) — builds on them.

---

## 7. What this doc deliberately leaves to later

So the deferral is a choice, not a gap:

- **Observability beyond local logging.** MVP has local debug logging; anything more waits (P3 forbids telemetry by default). A local log file the user can find and share for bug reports is enough.
- **The two flagged Design decisions** — trigger overlap/priority (ARCH Q3) and medical-field surfacing (Q7) — belong to the field-execution and profile-sharing tiers, neither of which is in desktop MVP.
- **Accessibility** is addressed in the product/design docs, not here.
- **The hosted/Web/mobile setup** (Render, domain, Postgres, signing for silent update, mobile build pipelines) lands with those milestones, front-loaded into Leg 4 and the mobile work by design.

---

## 8. Open questions from the Author Desktop build *(added 2026-08-16, most rows resolved 2026-08-17)*

The `client/lib/` build against §2.4's wireframe surfaced real seams between what §1.4's 32 stories require and what `core`/`service` currently implement. Nine of the original eleven rows closed in a follow-up session (2026-08-17), which also verified every closure against the rebuilt frozen sidecar binary, not just a source run. What's left is recorded here so it isn't rediscovered as a surprise.

### Resolved 2026-08-17

| Gap | Resolution |
|---|---|
| **Loop / out-and-back generation** | `/segments/generate` now routes by `shape`: `routing/loops.py`'s `generate_loop` for loop, a new `generate_out_and_back` for out-and-back, `routing/solve.py`'s `generate_segment` unchanged for point-to-point. `generate_out_and_back` is new code, not a wrapper — its first version naively reversed the outbound node list for the return leg and **crashed on the first one-way street** (`KeyError` in a directed graph with no reverse edge); the fix solves the return leg as its own plain shortest path instead, which retraces the outbound road except where a one-way genuinely forces a different way back. All three shapes verified live against the Boulder fixture, including via-nodes. |
| **A5/A6's band engine only speaking loop** | No longer a live mismatch: `/segments/generate`, `/segments/envelope`, and `/segments/diagnose` all reach `routing/loops.py` now, so a band set diagnosed against a shape is the same shape Generate produces. |
| **`/days/compose`, `/trips/split`** | Both registered, calling `trips/compose.py` unmodified. Needed a JSON↔dataclass bridge for the ~15-class payload tree (`service/plotlines_service/payload_io.py`) — written generically via `typing.get_type_hints` reflection rather than one hand-written parser per class, with two real bugs found writing it: `Band`'s Python field names (`minimum`/`maximum`) don't match its wire names (`min`/`max`, silently producing `None`s until caught by a round-trip test), and `Day.to_dict()`/`Segment.to_dict()` aren't pruned the way `Trip.to_dict()` is, so a day round-tripped standalone through `/days/compose` comes back with explicit `"limits": null` — read literally, that overrode a dataclass's `default_factory=dict` with `None` and crashed `_breaches()`. Both fixed in the parser (a `null` is treated the same as an absent key, per the schema's own rule 3). C3 limit-breach detection verified live. |
| **F1 turn-by-turn cues** | New `POST /segments/cues`: re-solves the request (same trust model as `/segments/envelope`/`/segments/diagnose` — nothing about geometry is taken from the client) to get a graph-level walk, then calls `trips/cues.py`'s `derive_cue_sheet` unmodified. The cue sheet screen now calls this per segment and stitches days together with cumulative distance; on failure it falls back to the old authored-stops-only proxy list rather than showing nothing. |
| **F3 TCX writer** | `client/lib/data/export/tcx_writer.dart`, client-side like GPX/GeoJSON (`core/plotlines_core/export/` still has no writers at all). One real limitation stated in its own doc comment: `<Trackpoint><Time>` is schema-required but the payload has no per-vertex time, so times are backfilled from a nominal pace — a device-pacing fiction every TCX/FIT course file relies on, not a claim about actual timing. |
| **Surface weight → solver mapping** | `regenerateSegment` now sends a `surface` dial alongside `peaks`/`quiet`: `clamp((paved − avg(gravel, singletrack)) / 5, 0, 1)`. Documented as a real, lossy reduction, not a units conversion — the solver's scalar `surface` term can only ever penalise poor quality (`edge_cost`'s `profile.surface * (1.0 − quality)` is never negative), so it has no way to actively seek gravel, only to stop avoiding it. The mapping is the honest response given that ceiling, not a fix for it. |
| **`version.lock` → client stamp** | `kClientVersion`'s hand-kept constant is gone. `sidecar_manager.dart`'s `resolveClientVersion()` reads `packaging/version.lock` at runtime instead, via the same bundled-path-else-repo-relative-dev-fallback resolution `SidecarManager` already uses for the binary and cache dir — Flutter has no simple pre-build shell hook the way the sidecar's freeze script does, so reading at runtime (and caching after the first read) was the seamless fit rather than a generated-constant build step. |
| **Geocoding** | `GET /geocode?q=…` via `osmnx.geocode_to_gdf` (Nominatim). Verified against the **frozen** binary specifically, not just a source run — freezing a new network-calling dependency is exactly the kind of thing that silently breaks under PyInstaller. Wired into New Route's location search and left available for A10's first-run prompt to adopt. |
| **Basemap tiles** | See the 2026-08-17 entry already in the table above this section as of the previous pass — unchanged, kept for continuity: real Protomaps vector tiles for the Boulder fixture bbox, exploded from SPIKE-14's `boulder.pmtiles` to `client/assets/tiles/`. |

### Still open

| Gap | What exists today | What's missing |
|---|---|---|
| **A10's region-download pipeline** | The first-run prompt (city+state / zip / country+city, Buncombe County default) is built and gates first launch correctly; its location field can now resolve through the same geocoder `/geocode` uses | Downloading a 100 km OSM extract + DEM for an arbitrary chosen location isn't implemented — `core/plotlines_core/graph/loader.py` only loads an already-cached GraphML, with no `graph_from_bbox`/Overpass fetch path. The sidecar always serves the bundled Boulder, CO fixture (`spikes/SPIKE-00/cache`) regardless of what's chosen. Meaningfully bigger than the other rows in this section (a live multi-hundred-MB-scale OSM fetch plus DEM alignment for an arbitrary bbox) — deliberately not attempted in the same pass as the smaller items above. |
| **Windows sidecar lifecycle** | POSIX graceful stop (SIGTERM → SIGKILL) is implemented and was exercisable in this Linux sandbox | The Windows `AttachConsole` + muted Ctrl handler + `CTRL_BREAK_EVENT` sequence (§3, ARCH §7.3) needs Win32 FFI calls not written yet; `taskkill /f` is the interim stand-in. Untestable on this Linux dev machine regardless of effort spent — writing unverifiable platform-specific FFI code was judged worse than leaving it flagged. Same situation as SPIKE-14's macOS residual. |
| **F3/E5's FIT writer** | GPX, GeoJSON, and TCX are all real and client-side | FIT is explicitly gated on **SPIKE-16** (unresolved — also decides core vs. on-device Garmin SDK). Disabled in the export panel rather than silently omitted; the one export format this doc still declines to guess at. |

G2a, M12, M13, K5, K8, K10, A1-A9/A10, B1-B3, C1-C3/C11, D1, E1/E2/E4, F1/F3, E5 are all built and exercisable end-to-end as of this pass, verified against the rebuilt frozen sidecar binary and a live client launch, not only a source run.
