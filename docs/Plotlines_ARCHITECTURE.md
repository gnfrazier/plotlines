---
title: Plotlines — Architecture Design
status: Draft
version: 1.0
companion: Plotlines_PRD.md
---

# Plotlines — Architecture Design

**Status:** Draft · **Version:** 1.0 · **Companion docs:** `Plotlines_PRD.md` (89 FRs / 95 stories — the source of truth for *what* and *why*), `Plotlines_Research_Spikes.md` (feasibility unknowns to prove before building). This document covers *how*.

This is a clean-sheet architecture for a new repository. It draws on hard-won structure from the Cycle Tour Planner proof-of-concept — the pure-library core, the sidecar model, the same-site session, the fetch-once caching discipline — but it is not a port. Where Plotlines' scope changed the shape of the problem (multimodal routing, field execution, peer field-intel, request/response sharing), the architecture is rebuilt to fit, not patched to cope.

---

## 1. Purpose & Reading Guide

This document describes the system's structure: its components, their boundaries, how data moves, and the decisions that shape those boundaries. It is not an implementation plan, a schedule, or a restatement of requirements. Where the PRD already decided *what*, this builds on it rather than re-arguing it.

**Reading order for a newcomer (human or LLM):**

1. §2 (Principles) — the rules everything else follows
2. §3 (Component Map) — what exists
3. §4 (The Portability Problem) — the most consequential build decision
4. §5 (Field Execution) — the second, unique to Plotlines
5. §6–§11 — each tier and cross-cutting concern in detail
6. §16 (Decision Log) — why things are the way they are

**A note on the brand value "Organized and logical" (PRD §2.7).** That value has an architectural reading, not just a product one: structure has one clear home for each thing, boundaries are predictable, and decisions carry their rationale. This document tries to embody it. Where it names a boundary "load-bearing," a design that crosses it is wrong, not merely different.

---

## 2. Architectural Principles

These are load-bearing. A design that violates one is wrong, not merely different. They are the through-line from CTP that survives unchanged, plus two new ones Plotlines' scope demands (P8, P9).

### P1 — The routing core is a pure library

The routing core (graph, scoring, elevation, multimodal solving, export) knows nothing about HTTP, users, accounts, sessions, or platforms. It takes inputs, returns routes, and touches only the filesystem for its own caches. This is what lets the same code run on a laptop and on the server without a fork. If the core needs to know who the user is, the design is wrong — the caller resolves that and passes plain values down.

### P2 — Local-first means the network is an optimization, never a dependency

On Desktop and Mobile, every core capability works with the network unplugged. The network makes things *better* (fresher forecast, synced trips, a tile someone already fetched), never *possible*. Web is the deliberate, stated exception (PRD §4, Leg 4) — an acknowledged different shape, and the *only* one.

### P3 — Server-side state is exceptional and enumerable

The hosted service does exactly five things. A sixth is a design event requiring an explicit decision, not a quiet addition:

1. Broker authentication (magic links, share tokens)
2. Hold the canonical copy of an account's trips for sync
3. Cache expensive external fetches (tiles, elevation) so they happen once for everyone
4. Run stateless compute for clients that cannot compute locally (Web, signed-in and guest)
5. Relay trip-scoped group messages (field notes, route amendments, feedback) between members of the *same trip*

Item 5 is new for Plotlines and is deliberately narrow — see P9. Anything beyond these five — analytics, telemetry, a general-purpose backend, a social graph — is out of scope by default.

### P4 — Guest sessions leave no server-side trace

Not "minimal data." **None.** A guest's compute request is served and forgotten; their work lives in their own browser. A hard guarantee, not a best effort — which is why guest compute is stateless rather than merely un-authenticated.

### P5 — The user's work is never silently destroyed

Conflicts surface. Overwrites are chosen, never inferred. Guest work is offered a home on sign-in, not discarded. Enforced structurally (§10.4's version-check protocol), not left to careful coding.

### P6 — Plugins extend; they do not modify

The core defines the schema and the extension points; a plugin fills in behavior at those points. A plugin that requires a change to core code to work is not a plugin — it is a core feature in a costume, and should be built as one.

### P7 — External resources are borrowed, not owned

Every external API (elevation, weather, geocoding, and any multimodal data source) is a shared commons with real limits. Fetch once, cache with a TTL matched to actual volatility, never re-request what is held. Free-tier ceilings make this a functional constraint, not an etiquette preference.

### P8 — Authorship is canonical; everything else is a layer over it *(new)*

The Author's plotline is the single source of truth for a trip. Character personalization (weighting within Author-set bounds), peer field notes, amendments, and journals are **layers** rendered over the canonical plotline — never edits to it. A Character's personal variant does not mutate the Author's route; a field note does not change anyone's cues; an amendment a Character accepts updates *their* path, not the plotline. Incorporating any of these into the canon is an explicit Author action. This is what keeps the story straight (PRD §2.7) and keeps sharing safe (PRD §2.1). Structurally: canonical trip data and layer data have separate homes and separate write paths.

### P9 — Group messaging is trip-scoped, route-anchored, and advisory *(new)*

The relay in P3.5 carries only messages between members of one trip, about that trip, anchored to points on its route. It is not a chat system, not a social graph, not cross-trip. Recipients accept, decline, or ignore — nothing changes a Character's path without consent (PRD §2, non-goals; FR56/FR56a). If a design would let messages cross trips, carry arbitrary content, or mutate a recipient's state without their action, it violates P9.

---

## 3. Component Map

```
┌────────────────────────────────────────────────────────────────────────┐
│                          FLUTTER CLIENT (Dart)                          │
│                                                                        │
│  ┌────────────┐ ┌────────────┐ ┌───────────┐ ┌──────────┐ ┌──────────┐ │
│  │ UI / State │ │ Local Store│ │ Sync Agent│ │  Field   │ │ Plugin   │ │
│  │ (Riverpod) │ │  (drift)   │ │           │ │ Runtime  │ │ Registry │ │
│  └────────────┘ └────────────┘ └───────────┘ └────┬─────┘ └──────────┘ │
│        │              │              │            │           │        │
│        └──────────────┴──────────────┴────────────┴───────────┘        │
│                                │                                       │
│              ┌─────────────────┴──────────────────┐                    │
│              │  Routing Client (facade, one URL)  │                    │
│              └─────────────────┬──────────────────┘                    │
│                                                                        │
│  Field Runtime = offline-only: GPS trigger engine, position-aware      │
│  cue state, narration playback, dead-zone odometer, adaptive-accuracy  │
│  controller. Runs from raw GPS with NO network in its critical path.   │
└─────────────────────────────────┼──────────────────────────────────────┘
                                  │
             ┌─────────────────────┴────────────────────┐
             │                                          │
   Desktop / Mobile                                   Web
   (local sidecar)                             (network → hosted)
             │                                          │
┌────────────┴───────────────┐          ┌───────────────┴────────────────┐
│   LOCAL ROUTING SIDECAR    │          │        HOSTED (Render)         │
│   ─ FastAPI (loopback)     │          │                                │
│   ─ plotlines-core (lib)   │          │  ┌──────────────────────────┐  │
│   ─ Local caches on disk   │          │  │   FastAPI (public)       │  │
│   ─ Dart offline engine    │          │  │   ─ auth / sync / share  │  │
│     (Mobile, simple P2P)   │          │  │   ─ guest compute        │  │
└────────────────────────────┘          │  │   ─ group relay (P9)     │  │
                                        │  │   ─ tile + elev cache    │  │
                                        │  └────────────┬─────────────┘  │
                                        │  ┌────────────┴─────────────┐  │
                                        │  │   plotlines-core (lib)   │  │
                                        │  └──────────────────────────┘  │
                                        │  ┌──────────────────────────┐  │
                                        │  │   Postgres               │  │
                                        │  └──────────────────────────┘  │
                                        └────────────────────────────────┘
                                                       │
                                  ┌────────────────────┴───────────────────┐
                                  │       EXTERNAL (borrowed, cached)      │
                                  │  Elevation · Weather · Geocoding ·     │
                                  │  OSM · [multimodal data — see §13]     │
                                  └────────────────────────────────────────┘
```

**Two structural insights carry the whole design:**

1. **`plotlines-core` appears twice** — once in the local sidecar (Desktop/Mobile), once in the hosted service. Same library, same version, two deployments. The client talks to a FastAPI over HTTP in both cases; only the base URL differs. This is why §4 matters.

2. **The Field Runtime is a distinct, offline-only client subsystem** with no analogue in CTP. CTP's mobile story ended at "view a downloaded route." Plotlines executes in the field: GPS-triggered narration, a position-aware cue HUD, dead-zone dead-reckoning, adaptive location accuracy. This runtime never touches the routing sidecar or the network during a ride — it runs on raw GPS over downloaded data. §5 is devoted to it because it is the second-hardest and most Plotlines-specific part of the build.

---

## 4. The Portability Problem

**The problem:** the routing core is Python (for the geospatial ecosystem). Flutter is Dart. Desktop and Mobile must run route generation *on the device* (P2). Therefore a Python runtime must ship inside a Flutter application across Windows, macOS, Linux, Android, and iOS. This is the hardest packaging constraint in the project, and the local-first guarantee stands or falls on it.

The analysis CTP did here remains correct, so the conclusion carries forward rather than being re-derived. Summarized:

- **Rewrite the core in Dart — rejected.** Discards the mature Python geospatial ecosystem (OSMnx, shapely/GEOS, rasterio/GDAL) with no equivalent in Dart. For Plotlines this is *worse* than it was for CTP, because multimodal routing will lean on more of that ecosystem, not less.
- **Embedded interpreter (in-process FFI) — rejected.** Cross-compiling and linking the heavy native dependency tree (numpy, scipy, GDAL/GEOS) inside an embedded interpreter across five platforms, under iOS's no-JIT and code-signing constraints, is itself a research project with late, workaround-free failure modes.
- **Local sidecar process — chosen.** Ship the core as a standalone frozen binary the Flutter app launches as a child process, serving FastAPI on `127.0.0.1`. The client talks to it over HTTP exactly as it talks to the hosted service.

**Why the sidecar wins (unchanged from CTP, still decisive):** the client has *one transport* — local vs. hosted is a config difference, not a code path; the FastAPI layer is exercised on every platform; native-dependency packaging is solved once per platform by a tool built for it; and process isolation means a segfault in GEOS kills the sidecar, not the app.

**Costs, stated plainly:** frozen-binary size (150–300 MB per platform, now stacking on Plotlines' larger offline packages — narration audio and multimodal data — see §11); process-lifecycle management (§7.3); and the iOS exception below.

### 4.1 The iOS exception — still the largest open risk

iOS prohibits spawning arbitrary child processes in sandboxed apps, so the sidecar model does not translate directly. The three honest options are unchanged from CTP, but Plotlines shifts which one is most attractive:

| Approach | Assessment for Plotlines |
|---|---|
| Embedded interpreter on iOS only | Contains the blast radius but makes iOS a genuinely different execution model — the fork this architecture exists to avoid. |
| iOS routes online-only (like Web) | Breaks the offline-generation guarantee on iOS specifically. |
| **Precompute-and-download** — iOS never generates routes locally, but downloads fully-computed plotlines for offline *execution* | **Strongest fit for Plotlines.** The field experience (§5) is about *executing* an authored plotline — following cues, hearing narration — not *generating* routes. A Character rarely generates on iOS; they download the Author's plotline and ride it. Local generation (FR63's simple P2P) is the only casualty, and it is the least-used mobile path. |

The reason this option is more attractive for Plotlines than it was for CTP: Plotlines' mobile role is execution-first by design. The phone is a passive companion (PRD §2.4). The offline package (FR64) already contains everything needed to execute; local route *generation* on iOS is genuinely marginal. Precompute-and-download concedes little and keeps iOS on the same data model as everyone else.

**Recommendation:** prototype the frozen sidecar on Android early (Android permits child processes and validates the model); treat iOS as precompute-and-download unless SPIKE-09 (the Dart offline engine, §5.6) proves capable enough to serve iOS's simple-P2P need *without* the Python sidecar at all — which would resolve the exception cleanly. That interaction is called out in §5.6.

---

## 5. Field Execution — the Plotlines-specific tier

This tier has no CTP ancestor. It is the architecture behind PRD Epic I (field execution), the GPS-triggered narration (FR49), the position-aware cue HUD (FR47/FR50/FR50a), adaptive accuracy (FR54a), and the dead-zone odometer (FR54). It is governed by one hard rule.

### 5.1 The Field Runtime rule: raw GPS in, no network in the critical path

Everything the Field Runtime needs to do its job during a ride comes from **raw GPS position** and **already-downloaded data**. The network is not in its critical path — not for narration, not for cue advancement, not for hazard alerts. This is a direct structural consequence of P2 and PRD FR47/FR49, and it is what makes the pocketed-companion model trustworthy where connectivity dies.

Concretely, the Field Runtime holds, entirely on-device and offline:

- the downloaded plotline (routes, cues, nodes, hazards, transitions) — from the offline package (FR64)
- narration audio blobs, keyed to nodes with Author-set trigger distances (FR41)
- the current position estimate and the derived "where am I on the cue sheet" state
- a spatial index of trigger geometries for cheap proximity checks

It does **not** hold or need: a route solver, a tile fetcher, or any hosted endpoint. If the Field Runtime ever needs to call the network to advance a cue or fire narration, the design is wrong.

### 5.2 Trigger engine (FR41, FR49, FR53)

Narration and hazard alerts fire on **geofence-style proximity** to a node, at that node's Author-set trigger distance. The engine:

1. Maintains a spatial index (e.g. an R-tree or a simple grid over the route corridor) of trigger geometries — one per narration node and hazard.
2. On each position update, queries the index for triggers whose radius now contains the position.
3. Fires the matched trigger's effect (play audio / raise a hazard alert) exactly once per approach, with hysteresis so GPS jitter near a boundary does not re-fire.

**Trigger overlap and priority** (the design question flagged in the PRD Open Items): when multiple triggers fire in a short span, the engine applies a priority order — **hazard alerts preempt narration; narration queues rather than overlaps** — so a dense stretch does not talk over itself. This is the one behavior in the Field Runtime that needs a deliberate policy rather than a default; it is specified here so the build does not invent it ad hoc. (See §17, still an open tuning question for exact thresholds.)

### 5.3 Position-aware cue state (FR47, FR50, FR51)

Cue "where am I" state is derived from position against the route polyline: the engine projects the current position onto the route, finds the current segment, and resolves the current and next cue. From that it computes remaining distance, remaining elevation, and — using the mode/terrain speed model (FR16) — a live ETA (FR51). All of this is arithmetic over downloaded geometry; none of it is routing, and none of it is network.

**This is the boundary that keeps Plotlines on the right side of its own non-goal.** The cue engine recomputes *distances and ETAs along a fixed authored route*. It never recomputes the *route*. There is no wrong-turn recalculation, no "follow the line" rerouting. A wrong turn simply means the projection finds the Character off-route, which surfaces as "off route" — not a new route. If a change request would have the cue engine generate a replacement path, it belongs in the routing tier and behind the amendment flow (§5.5), not here.

### 5.4 Device posture: Stowed vs. Mounted (FR50a)

The same position/cue state renders in two postures over one underlying model:

- **Stowed** — screen off/dimmed, phone pocketed. GPS silently advances cue state and drives narration/hazard alerts. **Nothing renders**; no frames are drawn for a screen no one is watching. This is the battery-cheap default.
- **Mounted** — screen on, handlebar/bow-bag. The HUD auto-scrolls to the next cue live.

Posture follows screen state, manually overridable. Switching posture re-syncs the view to the current position, so pulling the phone from a pocket shows the correct current cue immediately. Structurally, posture is a *render* concern layered over a posture-independent position/cue model — the model runs identically in both; only the presentation differs. This keeps auto-scroll (a Mounted-only behavior) from ever wasting work while Stowed.

### 5.5 In-field amendments (FR55, FR56)

A Character amending in the field (toggling a pre-planned alternate, or drawing a modification) writes to a **local layer over the canonical plotline** (P8), never to the plotline itself. The amendment updates the Character's own local map, elevation, and cue state, persists locally, and syncs when connectivity returns. Toggling a pre-planned alternate is cheap — the alternate's cues are already downloaded, so it is a re-projection, not a solve. Drawing a free modification on Mobile uses the Dart offline engine (§5.6) for the changed portion only.

Publishing an amendment to the group is a §8 (group relay) concern, not a Field Runtime one — the Runtime hands a completed amendment to the Sync Agent, which relays it under P9. Recipients' acceptance updates *their* layer, not the canon.

### 5.6 The Dart offline engine (FR63) and its leverage on iOS

Simple point-to-point offline routing on Mobile (FR63) uses a **Dart-native routing engine** over the downloaded map set — not the Python sidecar. This exists because the sidecar is heavy and, on iOS, may not exist at all (§4.1).

This creates a genuinely useful architectural option: **if the Dart offline engine (validated in SPIKE-09) is capable enough to serve Mobile's simple-P2P need on its own, iOS can ship with no Python sidecar** — routing generation on iOS becomes "download precomputed plotlines from the hosted core for anything complex; use the Dart engine for on-device improvisation." That collapses the iOS exception (§4.1) from a problem into a non-issue. The dependency runs the other way too: if the Dart engine underperforms, iOS falls back to precompute-and-download and Android keeps the sidecar. This is why SPIKE-09's result gates the iOS decision.

---

## 6. Tier 1 — `plotlines-core` (Routing Library)

### 6.1 Boundary

`plotlines-core` is a pure Python package: no FastAPI import, no request objects, no user IDs, no session concepts (P1). Its entire surface is functions over plain data.

```python
# The shape of the contract — not final signatures, but the right *shape*

def build_graph(bbox: BBox, mode: TravelMode, cache_dir: Path) -> Graph: ...

def enrich_elevation(graph: Graph, tiles: list[Path]) -> Graph: ...

def score_edges(graph: Graph, weights: WeightProfile) -> Graph: ...

def solve_segment(
    graph: Graph,
    start: Coord,
    end: Coord | None,
    via_nodes: list[Coord],          # FR8a — mandatory pass-through points
    shape: RouteShape,               # loop | out_and_back | point_to_point
    weights: WeightProfile,
    target_distance: float | None,
    cpus: int,                       # a PARAMETER, never discovered (P1)
) -> Segment: ...

def compose_day(segments: list[Segment], transitions: list[Transition]) -> Day: ...

def split_trip(days: list[Day], limits: DayLimits) -> Trip: ...

def export_trip(trip: Trip, fmt: ExportFormat, contents: ExportContents) -> bytes: ...
```

`cpus` is a parameter, not something the library discovers (PRD Developer story M7). The caller decides — `floor(cores/2)` on device, a fixed value on the server. The library never learns where it runs.

### 6.2 Internal structure

```
plotlines-core/
├── graph/          # OSMnx construction, caching, simplification
├── elevation/      # GeoTIFF reads, void handling
├── scoring/        # WeightProfile + the one multi-factor scoring function
├── routing/        # solve, shape handling, via-node constraints (FR8a)
├── multimodal/     # per-mode graph building + water/technical params (§6.4)
├── trips/          # day composition, transitions, splitting, speeds/ETA
├── content/        # POI curation, narrative-arc tags, trigger-distance metadata
├── export/         # GPX / TCX / FIT / GeoJSON writers
└── providers/      # pluggable data-source interfaces (§13) — interfaces only
```

The two additions over CTP's structure are `multimodal/` and `content/`. They are separate packages, not flags threaded through the others, because multimodal parameters and curation metadata are first-class in Plotlines, not decorations on a cycling router.

### 6.3 Scoring model — themes are data, not algorithms

The core scoring principle survives from CTP and is now more valuable, because Plotlines has *more* weights and *more* modes. Every theme is a `WeightProfile` instance fed to **one** multi-factor scoring function (PRD Developer story M1). Adding a theme is a config entry; adding a mode-specific weight extends the profile structure, never the scorer.

```python
@dataclass
class WeightProfile:
    climbing: float                    # PRD FR2 ("peaks")
    traffic: float                     # FR3 ("cars")
    surface_pref: dict[str, float]     # FR4 — paved / gravel / singletrack
    poi_bonus: dict[str, float]        # FR5 — Author-set POI type + density
    detour_budget: float               # max multiple of shortest-path distance
    # --- multimodal extensions (FR14) ---
    terrain_technicality: float = 0.0  # land exposure/scramble
```

**`water_type` and `max_water_class` are gone (D19).** They were FR13's flatwater↔whitewater
weight and FR14's class ceiling, and both score against a per-edge difficulty rating that
SPIKE-04 found does not exist in any usable source. Keeping them as inert fields would
repeat exactly the mistake D6 rejected with `turn_count`. Re-adding them, if American
Whitewater licensing or OSM adoption ever supplies the data, is two fields and a scoring
clause — the structure is unchanged, which was the point of D5.

`terrain_technicality` stays, but note it has **not** been validated the way the water
terms were: SPIKE-04 was a paddling spike and did not measure `sac_scale` / `mtb:scale`
density. Treat it as unproven, not proven.

**Deliberate departures from CTP's scoring model, driven by the PRD rescope:**

- **"Fewest turns" is gone.** CTP had a `turn_count` weight and a fifth fixed theme for it; the Plotlines PRD removed it (PRD §4.3). The profile has no turn term. This is a real deletion, not a rename — carrying it forward would reintroduce scope the rebrand cut.
- **Climbing and traffic are single continuous weights** ("peaks", "cars"), not flat-vs-climbing / quiet-vs-direct theme pairs. Fewer knobs, more range.
- **"Art/history" is not a theme.** It is `poi_bonus` with an Author-set POI type (FR5).
- **The profile carries multimodal terms.** Terrain technicality extends the same structure the scorer already consumes — so multimodal routing is not a parallel scorer (PRD M1's explicit requirement). The water terms were removed with D19; the mechanism they demonstrated is unaffected, and that is what M1 actually requires.

### 6.4 Multimodal routing (FR10–FR16) — and its data dependency

Each travel mode builds its own graph (`multimodal/`): cycling and hiking over the road/path network, paddling over the waterway network. The scorer is mode-agnostic — it consumes a `WeightProfile` and a graph — but the *graph construction* and the *available edge attributes* are mode-specific.

**This was the architecture's single biggest unknown. SPIKE-04 has now answered it, and the provider boundary is what saved the design.** Cycling/hiking graphs come from OSM, which is proven. The paddling graph is not one source but four questions, and they came back differently (`spikes/SPIKE-04/results/RESULTS.md`):

| | Answer | Source |
|---|---|---|
| Waterway network | **Yes** — connected, directed, uniformly attributed | **USGS NHDPlus HR**, not OSM |
| Gauge readings | **Yes**, including which reach a gauge governs | USGS Water Data APIs + NLDI |
| Access points | **Partial** — thin in OSM, denser but per-state in agency GIS | OSM + state GIS |
| Class ratings | **No** — zero graded features in all three regions tested | none on acceptable terms |

**The load-bearing consequence: OSM is not sufficient, so `WaterwayDataProvider` is a real implementation and not a formality.** Paddling's network comes from a different source than cycling's, with a different topology model (declared `fromnode`/`tonode` rather than inferred shared vertices) and a different notion of edge scale (Strahler stream order rather than a mapper's river-versus-stream call). Had paddling been hardcoded into the core alongside cycling, that difference would now be a rewrite. It is a provider swap instead.

**The absent class ratings did not change this design — they removed one capability from the PRD.** What cannot be built is *edge exclusion* by class band, because no per-edge class exists to compare against. **The PRD took that call on 2026-08-14: FR13 retired, stories B4 and B5 removed, FR14 narrowed to an advisory gauge band.** Recorded here as D19, because it also removed two `WeightProfile` fields (§6.3).

### 6.5 Elevation — void handling

Elevation reads must never block a solve. A missing tile or a data void yields a zero delta for that coordinate (logged once per tile), never an exception and never a mid-solve network fetch. A route through a data void is slightly wrong; a route that hangs is broken. Unchanged from CTP, and still correct.

### 6.6 Why scoped weighting (FR36) is not a rewrite

`WeightProfile` is resolved **per edge** via a `weights.at(position)` lookup (PRD Developer story M2). In the scalar case (a single tour-level profile), every edge resolves to the same object. In the scoped case (tour default → day override → segment override, FR36), an edge resolves to the profile governing its position. The solver never learns the difference:

```python
def edge_cost(edge, position: float) -> float:
    profile = weights.at(position)   # scalar case: always the same object
    return apply(profile, edge)
```

Build `weights.at()` returning a constant from the first milestone, and scoped weighting later becomes a change to *one function*, not the solver. This is why FR36 is an iteration, not a rewrite.

---

## 7. Tier 2 — `plotlines-service` (FastAPI)

### 7.1 One codebase, two deployment profiles

`plotlines-service` wraps `plotlines-core` in FastAPI and runs in two modes that differ by **configuration, not code**:

| | **Sidecar mode** (Desktop/Mobile) | **Hosted mode** (Render) |
|---|---|---|
| Bind | `127.0.0.1`, ephemeral port | `0.0.0.0`, public |
| Hostname | loopback | `api.<custom-domain>` — never `*.onrender.com` (§9.3) |
| Auth | None (loopback is the trust boundary) | Magic-link / same-site session cookie / guest |
| Database | None | Postgres |
| Routing endpoints | ✅ | ✅ |
| Auth / sync / share / group-relay | ❌ not registered | ✅ |
| Tile + elevation cache | Local disk | Shared server-side |
| CORS | N/A | **N/A** — same-site (§9.3) |

Mode is selected by an env var at startup. Endpoints not valid for a mode are **not registered** — not merely guarded. A sidecar has no `/auth/*` or `/groups/*` routes to attack.

### 7.2 Endpoint surface

```
# Routing — both modes
POST   /segments/generate         # mode + shape + weights + via-nodes → Segment
POST   /days/compose              # segments + transitions → Day
POST   /trips/split               # multi-day splitting
POST   /trips/{id}/export         # → GPX | TCX | FIT | GeoJSON, selectable contents
GET    /geocode?q=…               # Nominatim via OSMnx

# Content — both modes (cache-backed)
GET    /tiles/{z}/{x}/{y}
GET    /elevation?bbox=…
GET    /weather?lat=…&lon=…&date=…      # historical | forecast, age-stamped

# Accounts — hosted mode only
POST   /auth/magic-link
POST   /auth/magic-link/verify
GET    /trips                     # library (FR74/FR75)
PUT    /trips/{id}                # write, version-checked (FR59)
GET    /trips/{id}/version        # cheap version probe
POST   /trips/{id}/share          # → revocable token
DELETE /shares/{token}
GET    /profile
POST   /profile/requests          # Author requests fields (FR78a)
PUT    /profile/grants            # Character grants/declines/volunteers (FR78)

# Group relay (P9) — hosted mode only, trip-scoped
POST   /trips/{id}/notes          # pin a field note (FR56a)
GET    /trips/{id}/notes          # notes for approaching members
POST   /trips/{id}/amendments     # publish an amendment (FR56)
POST   /trips/{id}/feedback       # trip-scoped feedback + votes (FR42)
```

**Auth is magic-link only.** CTP's passkey/WebAuthn/QR cascade is gone (PRD §4.3, FR57) — no `/auth/passkey/*`, no `/auth/qr-authorize`. This is a deliberate simplification carried from the PRD, not an omission.

### 7.3 Sidecar lifecycle (Desktop/Mobile)

The failure modes that actually bite in the field are specified, not assumed:

```
App start
  ├── Find free port (bind :0, read assigned port, release)
  ├── Spawn sidecar with --port=N --mode=sidecar --cache-dir=…
  ├── Poll GET /health until ready (timeout generous — cold graph load is slow)
  │     └── on timeout → surface honestly with the cycling-themed wait
  │                       messages (PRD FR48/Story C27 lineage); offer retry;
  │                       never a silent hang
  ├── App runs; sidecar is a child process
  ├── Sidecar dies mid-session → detect → restart once → if that fails,
  │     degrade honestly (cached plotlines still viewable/executable,
  │     new generation unavailable, stated inline)
  └── App exit → graceful stop → hard kill after grace → orphan sweep next launch
        └── POSIX:   SIGTERM → SIGKILL; child spawned into its own session
            Windows: AttachConsole + CTRL_BREAK_EVENT → TerminateProcess;
                     child spawned CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
                     and held in a Job Object (see below — not a detail)
```

**The graceful stop is platform-specific, and the Windows form is not optional.**
Windows cannot deliver SIGTERM: `TerminateProcess()` — which is what a naive port of
the line above calls, and what both `Popen.terminate()` and `send_signal(SIGTERM)` do
there — is an unblockable kill that runs no handler, so a request in flight is severed
rather than finished. The only stop a Windows child can catch is a console control
event, and **the client is a GUI process with no console**, so it cannot simply send
one: the call fails with `ERROR_INVALID_HANDLE`. The verified sequence is

1. spawn with `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW` — the sidecar then owns a
   console with no visible window, so it is addressable and nothing flashes on screen;
2. `AttachConsole(pid)`, mute the client's own Ctrl handling with
   `SetConsoleCtrlHandler(NULL, TRUE)` (the event reaches every process on that
   console), `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid)`, then `FreeConsole()`
   and restore;
3. hard-kill after the grace period.

The sidecar handles the event as `SIGBREAK` (implemented). **Orphan handling differs in
the same way:** Windows has no process groups to sweep and never reparents, so a dead
PPID proves nothing and the next-launch sweep cannot be the only defence — hold the
sidecar in a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, the one mechanism
that reaps the child even when the client crashes without running cleanup. Measured
and reproducible in SPIKE-00: `spikes/SPIKE-00/results/WINDOWS.md` §3.

**Health returns readiness, not liveness.** A sidecar that is up but still loading a graph is not ready, and the client must know the difference. Note the field-execution consequence: **the Field Runtime (§5) does not depend on the sidecar at all** — a Character executing a downloaded plotline needs no sidecar running, which is exactly why a dead sidecar degrades to "can't generate" but never "can't ride."

### 7.4 Guest compute — enforcing P4

Guest requests are served with no session, no ID, no row, no log line containing request content. The only guest state anywhere on the server is the rate-limiter's in-memory per-IP counter, which holds a count and a timestamp, lives in process memory, and evaporates on restart. If a future change would require persisting anything keyed to a guest, that change violates P4 and needs an explicit decision.

### 7.5 Rate limiting

In-memory per-IP counter (e.g. `slowapi`), calibrated threshold with progressive cool-off, single instance, no Redis. **Correct only on a single instance** — if the service scales horizontally, each instance counts independently and the effective limit multiplies. This is the accepted simplification, written as a deployment invariant: **one instance, or redesign the limiter.** The trigger to revisit is "a second instance exists," not "abuse was observed."

---

## 8. Group Relay — the P9 tier

This tier is new for Plotlines and implements Epic I's peer intel (field notes, amendments) and Epic H's trip feedback, all under P9. It is the one place server-side state is written on behalf of Character-to-Character interaction, so its boundaries are drawn tightly.

### 8.1 What it is, and what it refuses to be

The relay carries three message kinds, all scoped to a single trip and its roster:

| Kind | FR | Anchored to | Mutates recipient? | Lifecycle |
|---|---|---|---|---|
| **Field note** | FR56a | a point on the route | No — advisory only | Author-anchored: persists until the Author curates or dismisses |
| **Route amendment** | FR56 | a route segment | Only on explicit Accept | Until superseded or the trip ends |
| **Trip feedback** | FR42 | a route/segment/POI | No | Until the Author curates |

It **refuses** to be: cross-trip (a note on trip A never reaches trip B), free-form (messages are anchored and typed, not a chat stream), or coercive (nothing changes a Character's path without their Accept). These refusals are P9 made concrete. A request to add a general messaging channel, a cross-trip feed, or a friend graph is a P9 violation and a design event, not a feature.

### 8.2 Peer-to-peer within the roster, no Author relay required

The critical design point from the PRD (FR56a): field notes post **peer-to-peer within the trip roster** — the Author may be riding the trip and unreachable, so routing everything through the Author would defeat the purpose. The relay delivers a member's note to other members directly; the Author is a recipient like any other, with the added power to curate a note into the canonical plotline (P8) or dismiss it for the group.

### 8.3 Delivery and the offline reality

Members are frequently offline mid-ride. The relay is therefore **store-and-forward**: a note or amendment published offline is held by the Sync Agent locally and posted when connectivity returns; a member approaching a noted location sees notes that have reached their device, age-stamped (FR56a/I9b), and the UI is honest that it shows what it has, not necessarily everything posted this instant. This is P2 applied to messaging — connectivity improves timeliness, it is not required for the field experience to function.

### 8.4 Near-simultaneous edits

When several members publish amendments near-simultaneously, the relay does not attempt automatic merge (consistent with P5's rejection of silent reconciliation). Each amendment is an independent proposal; recipients see each and Accept/Decline individually. There is no shared mutable "group route" that concurrent edits race over — because canonical state is the Author's plotline (P8), and amendments are layers over it, not writes to it. This is the structural reason the group feature does not need a conflict-resolution UI. (SPIKE-11 validates the propagation behavior before this is built.)

---

## 9. Tier 3 — Flutter Client

### 9.1 Layering

```
┌──────────────────────────────────────────────┐
│ Presentation — screens, widgets, HUD         │
├──────────────────────────────────────────────┤
│ State — Riverpod providers                   │
├──────────────────────────────────────────────┤
│ Domain — Trip, Day, Segment, WeightProfile,  │
│          RiderProfile, FieldNote, Amendment  │
│          (pure Dart, no I/O)                 │
├──────────────────────────────────────────────┤
│ Data                                         │
│  ├── RoutingClient   → HTTP (local | hosted) │
│  ├── TripRepository  → drift (local) + sync  │
│  ├── FieldRuntime    → offline GPS engine §5 │
│  ├── GroupRelayAgent → §8, store-and-forward │
│  ├── PluginRegistry  → §13                   │
│  └── SecureStore     → integration tokens    │
└──────────────────────────────────────────────┘
```

**`RoutingClient` is the linchpin** — it holds a base URL (`http://127.0.0.1:{port}` on Desktop/Mobile, the hosted origin on Web) and nothing above the Data layer knows which. Any `if (kIsWeb)` above the Data layer is a design smell. **`FieldRuntime` is the second pillar**, and deliberately sits *beside* `RoutingClient`, not behind it: the field experience must run with the sidecar dead and the network gone, so it depends on neither.

### 9.2 Storage, by platform

| Platform | Trips | Tiles / elevation / audio | Tokens |
|---|---|---|---|
| Desktop | drift (SQLite) | App-support dir | OS keychain |
| Mobile | drift (SQLite) | App-support dir | Keychain / Keystore |
| Web (signed-in) | Server (Postgres) | Browser HTTP cache | Session cookie |
| Web (guest) | IndexedDB | Browser HTTP cache | — |

One `TripRepository` interface, multiple implementations; Web's is server-backed, guest's is IndexedDB and never syncs. The interface does not expose sync as a callable operation — sync is a property of the implementation, so guest mode cannot accidentally sync. Narration audio is a Mobile/Desktop concern (part of the offline package); Web does not carry it.

### 9.3 The Web session and the custom domain

Web's signed-in session is an `HttpOnly; Secure; SameSite=Lax` cookie scoped to a shared parent domain, with the client static build and the API on sibling subdomains:

```
app.<domain>   →  Flutter Web static build
api.<domain>   →  plotlines-service (hosted mode)
cookie: Domain=.<domain>; HttpOnly; Secure; SameSite=Lax
```

**Why a custom domain is architectural, not cosmetic.** `SameSite` is evaluated on the registrable domain (eTLD+1), not the origin — so `app.<domain>` and `api.<domain>` are different origins but the *same site*, making the cookie first-party. Render's default `*.onrender.com` hostnames are on the Public Suffix List, which makes `onrender.com` an eTLD — so `app.onrender.com` and `api.onrender.com` are cross-*site*, the session cookie becomes third-party, and it is **silently blocked by Safari and Firefox while working in Chrome**. That is a failure invisible to a Chrome-only test. A custom domain makes the cookie first-party and **deletes the entire CORS-credentials surface** (no `SameSite=None`, no `Access-Control-Allow-Credentials`, no origin allowlist to misconfigure) rather than mitigating it.

So: a custom domain is a prerequisite for the Web milestone, and verifying session persistence in Safari and Firefox — not only Chrome — is a release exit criterion. **Rejected alternative:** a Bearer token in `localStorage`/`IndexedDB` is readable by any XSS, a permanent security downgrade to dodge a one-time config task. **Fallback:** if a custom domain is ever unavailable, serve the Flutter Web build *from FastAPI itself* — one origin, same-site by construction.

### 9.4 Display preferences and size classes (FR79)

Size class derives from **viewport at runtime**, not platform identity — a resized desktop window genuinely crosses classes. Each class holds its own layer set; first entry to an unused class seeds from that class's default, never copying the other's (a dense desktop config would flood a phone). Contrast defaults per surface (Mobile→Outdoor, Desktop→Indoor) with a synced manual override. Both sets sync per account; guests keep them in browser storage, unsynced.

---

## 10. Data Architecture

### 10.1 Postgres schema (hosted mode only)

```
account(id, created_at)
  -- no password column (absent, not unused — cannot be reintroduced quietly)
  -- magic-link email is transient (§10.2), never stored on the account

session(token_hash, account_id → account, expires_at, revoked_at)
  -- Web only; HttpOnly/Secure/SameSite=Lax on the shared parent (§9.3)
  -- token_hash, never the raw token

trip(id, account_id → account, name, version, updated_at,
     payload JSONB, deleted_at)
  -- version = the FR59 comparison key: monotonic int, bumped on write
  -- payload = the CANONICAL plotline (P8): segments, days, transitions,
  --           weight profiles, curated nodes, narration metadata, hazards

share(token_hash, trip_id → trip, created_at, revoked_at, expires_at)

rider_profile(account_id → account, fields JSONB, updated_at)

profile_request(id, trip_id → trip, requested_fields TEXT[], created_at)
  -- FR78a: the Author's per-trip request. Requesting never grants.

profile_grant(id, owner_account_id → account, trip_id → trip,
              granted_fields TEXT[],     -- FR78: explicit allowlist
              volunteered_fields TEXT[], -- FR78: fields the Author didn't ask for
              created_at, revoked_at)
  -- Empty granted array = nothing shared. This is the DEFAULT.
  -- No "share all" flag — only enumerated field lists.

-- Group relay (P9) — all trip-scoped, all layers over the canon (P8)
field_note(id, trip_id → trip, author_account_id → account,
           anchor_lat NUMERIC, anchor_lon NUMERIC,  -- plain coords, not PostGIS (§10.5)
           body TEXT, created_at, curated_at, dismissed_at)
amendment(id, trip_id → trip, author_account_id → account,
          segment_ref, payload JSONB, severity, safety_note TEXT, created_at)
feedback(id, trip_id → trip, author_account_id → account,
         target_ref, body TEXT, created_at, curated_at)
feedback_vote(feedback_id → feedback, account_id → account, value SMALLINT)
  -- votes bounded to the trip roster; no cross-trip aggregation
```

**Schema decisions worth defending:**

- **`granted_fields`/`volunteered_fields` are allowlists, never denylists.** A new sensitive profile field added later is automatically *not* shared with existing grantees, because it is in no one's array. A denylist would leak it the day it ships. This is P5 applied to schema, and it matters more in Plotlines because volunteered fields can include medical/allergy data (FR78) — the safest default is the only acceptable one.
- **`trip.payload` is the canonical plotline as JSONB, and group-relay tables are separate.** This is P8 in the schema: canon and layers have different homes and different write paths. A field note can never accidentally mutate `trip.payload`; incorporating one is an explicit Author write to the trip.
- **`profile_request` and `profile_grant` are trip-scoped, not global.** The request/response sharing model (FR78/FR78a) is per-trip: a Character shares with an Author *for a trip*, revisable, not a standing global grant.

### 10.2 What is deliberately absent

- **No password column** (magic-link only). Absent, not unused.
- **No email on `account`** — magic-link email is held in memory long enough to send, then discarded. Nothing to breach.
- **No guest table** (P4).
- **No analytics/telemetry tables** (P3).
- **No cross-trip social tables** — no follows, no friends, no global feed (P9).
- **No passkey/credential tables** — the PRD dropped WebAuthn (FR57).

### 10.3 Local schema (drift, Desktop/Mobile)

Mirrors `trip` plus sync tracking, and adds local-first layer and field-capture tables:

```
trip(id, name, version, updated_at, payload, dirty, server_version)
  -- dirty: changed since last successful sync?
  -- server_version: last version seen on the server; input to FR59's check

field_capture(id, trip_id, kind, anchor, body, media_ref, private, synced)
  -- FR72: journals, photos, voice — device-first, then synced (Epic J)

pending_relay(id, trip_id, kind, payload, created_at)
  -- store-and-forward queue for §8.3: notes/amendments published offline
```

### 10.4 The version-check protocol (FR59)

The mechanism behind P5. It runs at **two** points, and the second is the one implementations forget:

```
ON OPEN
  local.server_version  vs  GET /trips/{id}/version
    ├── equal        → proceed
    └── server newer → PROMPT: keep both (save-as) | take server copy
                       (never auto-merge, never auto-overwrite)

ON SAVE  ← the check most implementations omit
  re-probe /trips/{id}/version immediately before PUT
    ├── unchanged since open → PUT, bump version
    └── changed since open   → PROMPT (same two choices)
```

Two devices can open the same version, both pass the open-check, then both save — an open-only check lets the second write silently destroy the first. The save-time probe is the only thing preventing exactly the loss P5 forbids. Implemented as a conditional write (`PUT` carrying the expected version; server returns `409 Conflict` if it has moved) so the check and the write cannot race.

### 10.5 Stock Postgres now; PostGIS is a gated upgrade

The hosted database is **stock PostgreSQL** — no PostGIS at MVP. This is deliberate, and it follows from what the database actually does (P3): it holds the canonical trip as a JSONB blob, brokers auth, and relays trip-scoped messages. All genuinely geospatial work — graph building, routing, elevation, scoring, projecting a position onto a route — happens in `plotlines-core` (Python/GEOS) or the Field Runtime (Dart), **never in SQL** (P1). The database is a sync-and-relay store, not a query engine; it runs no spatial joins and computes no geometry.

Coordinates are therefore stored as plain numeric columns (or inside JSONB), not as PostGIS `GEOGRAPHY`/`GEOMETRY` types. Field-note proximity ("which notes am I near?") is computed **client-side** by the Field Runtime, which already holds the route and the notes (§5.2) — the server hands over a trip's notes as plain rows and the device decides what's near. No `ST_DWithin`, no spatial index, no extension dependency.

**PostGIS is a documented future upgrade, gated on a specific trigger, not a default.** The trigger is *"a spatial query needs to run in SQL, server-side."* The most likely first occurrence is a **push-based group relay** (§8, Open Question Q6): if the server — rather than the client — must decide who is near a field note in order to notify them, that is a server-side `ST_DWithin` with a GiST index, and PostGIS earns its place. Cross-trip spatial discovery ("public plotlines near a location") would also qualify, but that sits in the cross-trip territory the PRD's non-goals currently exclude.

Render supports this upgrade cleanly: PostGIS is an available extension enabled with a one-line `CREATE EXTENSION postgis` on a paid instance (the free tier lacks the superuser rights to enable it — not a constraint here, since a production database is already budgeted). Committing to stock Postgres now therefore costs nothing later: the day a server-side spatial query appears, enabling PostGIS and migrating the affected columns is a contained change, not a re-platform. Until that day, carrying the extension would be a dependency the design does not use — which is exactly the kind of accidental scope P8 and the "Organized and logical" value (PRD §2.7) exist to prevent.

---

## 11. External Integrations

All follow P7: fetch once, cache with a volatility-matched TTL, never re-request what is held.

| Service | Used for | Cache TTL | Attribution |
|---|---|---|---|
| **Elevation** (GeoTIFF DEM) | Elevation enrichment | Long (terrain is static) | **CC BY — required** |
| **Weather** (Open-Meteo) | Historical + forecast | Forecast: short. Historical: long/bundled | **CC BY 4.0 — required** |
| **Geocoding** (Nominatim via OSMnx) | Location search | Medium | OSM / ODbL |
| **OSM Overpass** (via OSMnx) | Graph + POI tags | Long (OSMnx handles) | OSM / ODbL |
| **USGS NHDPlus HR** (waterway network) | Paddling graph | Long (hydrography is static) | US public domain — credit requested |
| **USGS Water Data APIs + NLDI** (gauge readings, gauge→reach) | Paddling feasibility (FR14) | Gauge values: short. Reach linkage: long | US public domain — credit requested |

**Paddling class ratings have no source** and are therefore not in this table — SPIKE-04
found none available on acceptable terms (`spikes/SPIKE-04/results/RESULTS.md` §2). Class
is Author-declared, not fetched.

**Migration already scheduled:** USGS WaterServices (`waterservices.usgs.gov`) is
decommissioned in Q1 2027. Build against `api.waterdata.usgs.gov` — the OGC API - Features
successor, verified equivalent by SPIKE-04 §5 — from the first line of code.

### 11.1 Elevation cache — the two-phase model

Per the rescope (PRD FR62, Leg 4), the shared cache is deferred; the two-phase shape is preserved so the transition is a config change, not a rewrite:

```
Phase 1 (MVP)   each device / Web / Guest → elevation provider directly
                ⚠ works because users are few; the free-tier daily ceiling
                  is a hard wall; EXPLICITLY DISPOSABLE — do not build on it

Phase 2 (later) device → hosted cache → (miss) → elevation provider
                ✅ one fetch serves everyone; enables a packaged default region
```

The client must talk to elevation through the **same interface** in both phases (PRD Developer story M3), so Phase 2 changes a base URL and a cache-lookup step, not the client. Build the indirection from the first milestone even though Phase 1 does not need it — the alternative is a client rewrite later.

### 11.2 Attribution is a build artifact

CC BY sources (elevation, weather) require attribution wherever their data appears: a visible credit in the app's info surface, and attribution embedded in exported files where the format permits (e.g. GPX `<metadata>`). Treat a missing attribution as a **build failure**, not a polish item — it is a license condition.

### 11.3 Offline package size (FR64) — a real budget

Plotlines' offline package is heavier than CTP's ever was: routes + basemap buffer + **narration audio** + node media, across potentially multiple modes. This stacks on the frozen-sidecar binary size (§4). SPIKE-10 measures a realistic multi-day package; the buffer-distance control (FR35) and download UX may need constraints or tiering depending on its result. This is called out here so package size is budgeted, not discovered.

---

## 12. Distribution, Updates & the About Surface

Neither desktop code delivery nor the About surface existed in the CTP POC, because it never shipped to real users. Both are first-class for Plotlines and are specified here.

### 12.1 Desktop is two artifacts, not one

The desktop app is the Flutter client **plus** the frozen Python sidecar binary (§4). Any update mechanism must treat them as a **single versioned unit**, because a client running against a mismatched sidecar produces platform-divergent routes — that is risk A8, and it is the constraint that shapes everything in this section.

Two rules follow, and they hold regardless of which delivery model is chosen:

- **Client and sidecar version are pinned together and checked at runtime.** The versions are surfaced in `/health` (§7.3); the app refuses to run a client against a mismatched sidecar and fails honestly, the same way it handles a cold-start timeout. A partial update that swapped one artifact but not the other must be detected, not silently tolerated.
- **An update never clobbers a running sidecar.** If the app is mid-generation, the updater waits for or cleanly terminates the child process via the existing lifecycle (§7.3's graceful-stop → hard-kill → orphan-sweep, in that section's platform-specific form), then applies the update. The updater hooks into that lifecycle rather than inventing its own.

### 12.2 Delivery model — manual releases for MVP, seam for later

Three models, in increasing order of effort. The recommendation is the first, built so the second can be added without rework.

| Model | What it is | Cost | Fit |
|---|---|---|---|
| **Manual download + install** ✅ **MVP** | Cut a release; users download a new installer (GitHub Releases is the natural home) and run it | Near zero infrastructure; keeps client+sidecar in lockstep *inherently* because they ship in one installer | The right MVP answer — no update server, no dependency on the hosted service |
| **In-app update check** | On launch the app reads a small static version manifest (static JSON — GitHub Pages or the hosted service), compares to its own version, and links to or fetches the newer installer | A trivial static manifest; wrappers exist (Sparkle/WinSparkle, or Flutter's `auto_updater`) | The natural next step once there are enough users to care about adoption speed |
| **Full auto-update (silent)** | Fetch, stage, and apply in the background, Chrome-style | Code signing (required), an update-feed server, delta patching to tame the 150–300 MB binary (§4), rollback handling | **Not MVP.** The sidecar's size makes this materially harder than a typical Flutter app |

**The seam to build now:** the app knows its own version and treats client+sidecar as one pinned unit from day one (§12.1). Given that, adding the in-app *check* later is a new manifest read and a prompt — not a rework. This is the same "build the indirection before it's needed" discipline used for the elevation cache (§11.1) and scoped weights (§6.6).

### 12.3 Code signing is not optional

Even for manual installs, unsigned desktop apps hit Gatekeeper (macOS) and SmartScreen (Windows) warnings that alarm users and depress adoption. SPIKE-00 sharpened where that bites on Windows: SmartScreen gates *shell* launches — a user double-clicking a downloaded file — not `CreateProcess`, so the **spawned sidecar is unaffected even unsigned and even carrying Mark-of-the-Web** (verified). The exposure is the installer, which is therefore the artifact that must be signed; the sidecar inherits trust by being installed rather than downloaded. An Apple Developer account (with notarization on macOS) and a Windows code-signing certificate are **costs to budget from the first public release**, not polish for later. Silent auto-update (§12.2, third model) *requires* signing; manual install merely suffers badly without it.

### 12.4 The About surface — partly required, partly chosen

An About/info surface is **mandatory on every platform that displays licensed data**, because §11.2 already commits Plotlines to showing CC BY attribution "wherever the data appears" and treats a missing attribution as a build failure. So the question is not *whether* to have an About surface — that is settled — but *what else it carries*. Breaking it apart by obligation:

| Element | Status | Notes |
|---|---|---|
| **Data attribution & licenses** | **Required, all platforms** | CC BY credits for elevation and weather; OSM/ODbL attribution; Plotlines' own license. This is the §11.2 license condition — a build failure if absent. |
| **App + sidecar version** | **Strongly wanted (desktop especially)** | Needed anyway for A8 mismatch debugging; the About box is the natural home for what §7.3 surfaces via `/health`, and it feeds the §12.2 update flow. |
| **Release notes / "what's new"** | Optional | A repo `CHANGELOG` linked from About suffices for MVP; surface in-app only when the update *check* (§12.2) arrives. |
| **Privacy statement** | Optional but on-brand | A short statement of the PRD's posture — no email stored, guest leaves no trace, magic-link only — makes the "honest state" value (PRD §2.6) visible. Cheap; recommended. |
| **Support / general info** | Optional | Contact or docs link. |

**The "wherever the data appears" nuance:** attribution must be *reachable* on the lightest surfaces too, not only on a full About page. Web-guest shows weather and elevation but is a stripped-down surface, so the credit must still be reachable there — an About link in a footer or menu is sufficient, but it cannot be omitted just because guest has no full settings screen. This is the one place the About requirement touches a surface that might otherwise be built without it.

---

## 13. Plugin Architecture

Per PRD Leg 7 (FR84, deliberately open) and P6: **data elements live in the core schema; interface and business logic live in the plugin.** The interface shape is intentionally not locked — this section is the mechanism, not a final contract.

### 13.1 Two directions, matching the PRD's redefinition

The PRD redefined plugins as a clean two-way interface: **data inputs** that enhance routing, and **outputs** to other platforms. These do not share an execution environment, and forcing them into one would be an error:

| Direction | Runs in | Why there |
|---|---|---|
| **Data input** (traffic, POI, trail/water conditions, paddling network) | **Python (`plotlines-core`)** | Must feed the routing graph *during* scoring. A source that cannot influence edge cost is a map overlay, not a data provider. **This is also how uncertain multimodal data (§6.4) enters** — a whitewater or gauge source is a data-input plugin. |
| **Output** (Garmin, Coros, Wahoo, RideWithGPS) | **Flutter (Dart)** | Holds the user's OAuth token; must reach the vendor API from the user's own device. Routing it through the server would make the service a credential custodian for every user — a liability the PRD declines. |

### 13.2 Python-side provider interfaces

The core defines these and ships zero implementations beyond OSM defaults:

```python
class EdgeDataProvider(Protocol):
    def annotate_edges(self, graph: Graph, bbox: BBox) -> Graph: ...

class NodeDataProvider(Protocol):
    def fetch_nodes(self, bbox: BBox, categories: list[str]) -> list[Node]: ...

class ShapeDataProvider(Protocol):
    def fetch_shapes(self, bbox: BBox, kinds: list[str]) -> list[Shape]: ...

class WaterwayDataProvider(Protocol):        # Plotlines addition
    """Paddling network, put-ins/take-outs, portages, class, gauge."""
    def fetch_waterways(self, bbox: BBox) -> WaterwayGraph: ...
```

The core's own OSM lookups (lodging, POI types) **implement these same interfaces** — which is the proof the interfaces are real. If the built-in OSM path cannot be expressed as a provider, the interface is wrong, and we learn that at M1, not at M9.

`WaterwayDataProvider` is the seam SPIKE-04's answer plugs into, and the answer is now known: **implement it against USGS NHDPlus HR (network) and the USGS Water Data APIs + NLDI (gauge, reach linkage) — not OSM** (§6.4). Two consequences for its shape:

- **`WaterwayGraph` edges need a `reachcode`.** It is the identifier USGS gauges are indexed by, so carrying it turns "which gauge governs this segment" into a lookup rather than a spatial nearest-neighbour guess — which is wrong precisely at confluences and below dams. Dropping it costs nothing until FR14, then costs a re-fetch of the whole network.
- **It reads from a local extract, not a live service.** SPIKE-04 §8 could not complete a single region's pull from the public Overpass instance without tiling and retries. Same rule as §14.1's committed graph fixtures, for the same reason.

### 13.3 Dart-side output interface

```dart
abstract class OutputIntegration {
  String get id;
  String get displayName;
  Future<void> authenticate();          // OAuth, token → SecureStore
  Future<void> pushTrip(Trip trip);     // → vendor API, direct from device
}
```

`PluginRegistry` discovers implementations; the UI renders whatever is registered; the core app has no compile-time knowledge of any vendor. **Tokens go to `SecureStore` (Keychain/Keystore) — never to drift, never to the server.**

### 13.4 The boundary that must not be crossed

A plugin may not require a change to core code. If it does, the extension point is missing or wrong — fix the extension point, do not special-case the plugin. This is P6 as a build rule, and the difference between a plugin architecture and a plugin-shaped pile of conditionals.

---

## 14. Testing Strategy

Testing is an architectural concern here, not a downstream chore, because two parts of this system fail in ways that are silent and expensive to retrofit: the routing core (a refactor can quietly change what route a rider gets) and the sidecar lifecycle (works on the developer's machine, breaks on a user's). The strategy below is scoped to what MVP actually needs — it is not a call for exhaustive coverage everywhere.

### 14.1 The routing core — golden-route tests

`plotlines-core` is pure (P1), which makes it the most testable part of the system and the part where a silent regression does the most damage. The primary safeguard is **golden-route testing**: a fixed set of inputs (a cached graph fixture, a start/end, a `WeightProfile`, a shape) must produce a stable, known route. A change that alters a golden route is either a bug or a deliberate scoring change that must be reviewed and the golden updated on purpose — never silently.

- **Graph fixtures are committed, not fetched.** Tests run against small, checked-in graph extracts, never live OSM/Overpass calls — so the suite is deterministic, offline, and fast, and a test failure means *our* code changed, not that the world did. This also keeps CI from hammering the shared commons (P7).
- **Scoring is unit-tested per factor.** Each `WeightProfile` term (climbing, traffic, surface, POI, and the multimodal extensions) has a test proving that raising it measurably shifts the route in the expected direction — the testable form of the PRD's own weight ACs.
- **The two seams have explicit tests.** `weights.at(position)` returns a constant in the scalar case and the right profile in the scoped case (§6.6); the elevation interface resolves through the same contract in both phases (§11.1). These are the seams the whole "iteration, not rewrite" claim rests on, so they are proven, not assumed.
- **Void and failure paths are tested, not just happy paths.** Elevation voids yield a zero delta rather than an exception (§6.5); an infeasible constraint set produces a named conflict rather than a raw error (FR9). These are correctness requirements, so they are tests.

### 14.2 The service — contract and lifecycle

`plotlines-service` needs two kinds of test:

- **Endpoint contract tests** confirm each route's request/response shape, and — critically — that **mode-gated endpoints are not registered in the wrong mode** (§7.1): a sidecar-mode instance must have no `/auth/*` or `/groups/*` routes to attack. This is a security property, so it is tested, not trusted.
- **Sidecar lifecycle tests** exercise the failure modes in §7.3 that actually bite in the field: port-in-use, health-check timeout on a slow cold start, a sidecar that dies mid-session and is restarted, and the orphan sweep after an ungraceful exit. These are the tests most projects skip and most regret skipping.

### 14.3 The client — layers and the offline guarantee

- **Domain layer is pure Dart and unit-tested directly** — `Trip`, `Day`, `WeightProfile`, `RiderProfile`, and the layer/canon separation (P8) have no I/O and test cleanly.
- **The `RoutingClient` one-transport property is tested:** the client behaves identically against a local base URL and a hosted one, proving the §4 payoff and catching any `if (kIsWeb)` that leaks above the Data layer.
- **The offline guarantee (P2) is a test, not a hope:** the Field Runtime (§5) must advance cue state and fire triggers with the network disabled *and* the sidecar absent — the airplane-mode case is a first-class test scenario, because it is the core field promise.
- **The version-check protocol (§10.4) is tested at both points**, including the two-devices-open-the-same-version race that the save-time probe exists to catch. That race is the exact bug P5 forbids, so it gets an explicit test.

### 14.4 What MVP does not need

Stated so effort lands where it matters: no exhaustive UI-widget coverage, no end-to-end automation across platforms, no load/performance testing (the single-instance, few-users MVP is not load-bound — §7.5), and no test infrastructure for the Web/hosted/group tiers that MVP does not build. Field-execution and multimodal testing scale up when those features are built; the spikes (`Plotlines_Research_Spikes.md`) are where their hardest unknowns get exercised first, and a spike that proves out becomes the seed of that feature's test suite.

### 14.5 CI posture

CI runs the core and service suites on every change and enforces the P1 boundary as a hard check: **`plotlines-core` may not import `fastapi`** (risk A7). That lint is a CI gate, not a code-review hope — it is the cheapest possible enforcement of the principle the whole two-deployment model depends on.

---

## 15. Risks (Architectural)

Risks introduced *by this design* — distinct from the product risks in the PRD and the feasibility unknowns in the spikes doc (though several are linked).

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| A1 | **iOS cannot spawn the sidecar** (§4.1) — threatens offline generation on iOS | **HIGH** | Prototype the frozen sidecar on Android early; treat iOS as precompute-and-download; **SPIKE-09 may dissolve this** if the Dart engine serves iOS's simple-P2P need (§5.6). Do not assume it away. |
| A2 | **Paddling data may not exist** at the quality multimodal-MVP assumes (§6.4) | **HIGH → partly realised** | **SPIKE-04 ran (2026-08-14).** Network and gauge data are solid (USGS); **class ratings do not exist** in open data and the authoritative source prohibits reuse. The architecture is unharmed — the isolation behind `WaterwayDataProvider` (§13.2) is exactly what absorbed it — but one PRD acceptance criterion (B4/B5 class-band enforcement) cannot be met from open data. Residual risk moves to the **PRD scope call**, not the design. |
| A3 | **Field Runtime battery cost** — continuous GPS for a full day (§5) | **HIGH** | Adaptive-accuracy controller (FR54a): coarse tier while stowed, high accuracy only near a trigger or when the screen is active. **SPIKE-07 measures the real saving.** |
| A4 | **Backgrounded GPS-triggered audio** may not survive screen-lock across OS versions (§5.2) | **HIGH** | Platform-specific background-execution setup; **SPIKE-06 proves it on real iOS/Android hardware before the field tier is committed.** |
| A5 | Frozen Python binary (150–300 MB) stacks on heavier offline packages (audio + multimodal) | Medium | Accepted; strip deps; consider post-install sidecar download rather than bundling; budget package size via SPIKE-10. |
| A6 | Sidecar lifecycle bugs (orphans, port collisions, zombies) | Medium | §7.3's explicit protocol: PID file, orphan sweep, readiness health check, bounded restart. |
| A7 | `plotlines-core` drifts toward web-awareness | Medium | P1 enforced by lint/CI: `plotlines-core` may not import `fastapi`. A CI check, not a code-review hope. |
| A8 | Two `plotlines-core` deployments (sidecar + hosted) drift to different versions → platform-divergent routes | Medium | Version-pin the sidecar to the service release; surface both versions in `/health` so a mismatch is visible. Desktop updates ship client+sidecar as one unit and refuse to run mismatched (§12.1). |
| A9 | The Phase-2 elevation-cache transition needs a client rewrite because Phase 1 hardcoded direct calls | Medium | §11.1: build the interface indirection from M1. One afternoon now versus a rewrite later. |
| A10 | **Web ships on `*.onrender.com`** → sessions silently break in Safari/Firefox, fine in Chrome (§9.3) | Low probability, **HIGH impact** | Custom domain is a hard prerequisite for the Web milestone; exit criterion verifies Safari *and* Firefox. Invisible to a Chrome-only test. |
| A11 | **Group relay drifts toward a social platform** (§8) — scope creep past P9 | Medium | P9 stated as refusals in §8.1; any cross-trip, free-form, or coercive message is a design event. SPIKE-11 validates propagation before build. |
| A12 | **Server-side spatial query appears without PostGIS** — e.g. push-based note proximity (Q6) needs `ST_DWithin` and the DB is stock Postgres (§10.5) | Low | Written as a **deployment trigger**, not a guess: "a spatial query needs to run in SQL server-side" → enable PostGIS (`CREATE EXTENSION`, one line on Render paid) and migrate the affected columns. Contained change, not a re-platform. |

---

## 16. Decision Log

Decisions made *in this document* (PRD decisions are logged in the PRD; feasibility questions live in the spikes doc).

| # | Decision | Rationale | Alternatives rejected |
|---|---|---|---|
| D1 | **Local sidecar process** for the routing core on Desktop/Mobile | One HTTP transport for all platforms; native deps solved by a packaging tool; process isolation | Dart rewrite (kills the geospatial ecosystem, worse for multimodal); embedded interpreter (GDAL/GEOS on 5 platforms is a research project) |
| D2 | **`plotlines-core` is a pure library** with no web awareness | Same code runs local and hosted without a fork | A service-only core forbids offline; a client-only core forbids Web |
| D3 | **Field Runtime is a distinct, offline-only client tier** beside `RoutingClient`, not behind it | The field experience must run with the sidecar dead and network gone (P2) | Folding field execution into the routing client — a dead sidecar would kill the ride |
| D4 | **Field cue engine recomputes distances/ETAs, never the route** | Keeps Plotlines on the right side of its own "no real-time route guidance" non-goal | A cue engine that reroutes — becomes turn-by-turn nav, the thing the PRD declines |
| D5 | **Themes are `WeightProfile` data, one scorer; multimodal weights extend the same profile** | Adding a theme or a mode weight is config, not a new algorithm | Bespoke per-theme or per-mode solvers — parallel places for bugs |
| D6 | **"Fewest turns" removed from the scoring model** | The PRD rescope cut it; carrying it forward reintroduces cut scope | Keeping the `turn_count` weight "just in case" |
| D7 | **Canon vs. layers (P8)** — canonical plotline in `trip.payload`; personalization, notes, amendments, feedback in separate tables/layers | Keeps the story straight; makes sharing safe; removes the need for a group-route conflict UI | A single mutable trip object everyone edits — concurrent-edit races and silent canon mutation |
| D8 | **Group relay is trip-scoped, route-anchored, advisory, peer-to-peer (P9)** | Delivers time-sensitive field intel when the Author may be unreachable, without becoming a social platform | Author-hub-only relay (fails when the Author is riding); a general chat channel (violates the non-goal) |
| D9 | **Magic-link-only auth** | The PRD rescoped auth down from the passkey cascade | Passkey/WebAuthn/QR (dropped by the PRD); passwords (never) |
| D10 | **Store-and-forward group messaging** | Members are offline mid-ride; connectivity improves timeliness, is not required (P2) | Requiring connectivity to post/receive — breaks in exactly the places the intel matters |
| D11 | **`trip.payload` as JSONB; group tables separate** | Trips are read/written whole and reconciled whole (FR59); canon and layers need separate write paths (P8) | Normalized geometry (join cost, unused query power); mixing layers into payload (breaks P8) |
| D12 | **`granted_fields`/`volunteered_fields` are allowlists** | A future sensitive field (incl. medical/allergy) is not shared by default | Denylist (leaks new fields on ship day); a `share_all` flag |
| D13 | **Conditional write (`409 Conflict`)** for the save-time version check | The check and the write cannot race | Check-then-write — the race window is the exact bug FR59 prevents |
| D14 | **Plugins split across two runtimes** (Dart output, Python data-input); paddling data enters as a data-input plugin | Each runs where its data must live: OAuth on-device, edge scoring in the graph, uncertain multimodal data behind a provider seam | A single plugin runtime (forces OAuth through the server); hardcoding paddling into the core (couples the solver to an uncertain data source) |
| D15 | **Custom domain + same-site `SameSite=Lax` cookie**; `*.onrender.com` disqualified for deployed Web | `onrender.com` is on the Public Suffix List → its subdomains are cross-*site* → the session cookie becomes third-party, blocked by Safari/Firefox but not Chrome. A custom domain makes it first-party and deletes the CORS-credentials surface | Cross-site `SameSite=None` + CORS (breaks in Safari/Firefox); Bearer token in web storage (XSS-readable downgrade); reverse proxy (heavier than a domain) |
| D16 | **Manual GitHub Releases for desktop at MVP**, with client+sidecar shipped as one pinned unit and a seam for a later in-app update check | Zero update infrastructure; single installer keeps the two artifacts in lockstep inherently; the version seam makes an in-app check a later addition, not a rework (§12.2) | Full silent auto-update (code signing + feed server + delta patching for a 150–300 MB binary — not MVP); no update story at all (drift and stale installs) |
| D17 | **Stock Postgres at MVP; PostGIS is a gated upgrade** | The DB is a sync-and-relay store, not a query engine — all geospatial work is upstream in the core/Field Runtime (P1). Carrying PostGIS now is an unused dependency | PostGIS from day one (unused until a server-side spatial query exists — §10.5, trigger A12) |
| D18 | **Golden-route testing + committed graph fixtures** as the core's primary safeguard; P1 boundary enforced as a CI gate | A pure core makes silent scoring regressions the main risk; golden routes catch them and committed fixtures keep the suite deterministic and offline (§14) | Live-graph tests (non-deterministic, hammer the commons); relying on review to catch scoring drift |
| D19 | **Paddling difficulty is advisory, not a routing constraint** — PRD stories **B4 and B5 removed** and FR13 retired (2026-08-14) | **SPIKE-04 determined they were too hard to build**, and specifically that the difficulty half is not buildable *at all* on available data rather than merely expensive: enforcing an ability band requires a class rating on every candidate edge, and one graded feature exists across the 41,937 km² tested (58 across North America). The authoritative source, American Whitewater, prohibits reuse and offers no API, so this is a licensing problem with a lead time, not an engineering backlog item. Building the input without the data would have shipped a control that silently does nothing. What survives is the half that *is* grounded: an Author-set gauge band checked against a real USGS reading (FR14/FR14a, story B8), and Author-drawn portages (FR15/B6) | Shipping B4/B5 with Author-declared class as the only input (a routing filter over a field one person typed in, applied to edges with no class at all — worse than absent, because it looks like a safety feature); deferring paddling out of MVP entirely (the network and gauge halves are real and work); scraping American Whitewater (prohibited) |

---

## 17. Open Architectural Questions

| # | Question | Gated by / needed by |
|---|---|---|
| Q1 | **iOS routing strategy** — precompute-and-download, or Dart-engine-only with no iOS sidecar? | **SPIKE-09** (Dart offline engine capability), then the Mobile milestone |
| ~~Q2~~ | ~~**Paddling data source** — OSM-sufficient, or a third-party `WaterwayDataProvider`?~~ **Resolved by SPIKE-04 (2026-08-14): OSM is not sufficient.** Network from USGS NHDPlus HR, gauge from the USGS Water Data APIs + NLDI, access points from OSM plus per-state GIS, **class ratings from nowhere**. See §6.4, §13.2, and `spikes/SPIKE-04/results/RESULTS.md`. | Done — the residual is a PRD scope call, not an architectural one |
| Q3 | **Trigger overlap/priority thresholds** (§5.2) — exact queueing and preemption rules for dense narration/hazard stretches | Before the field-execution build; a tuning question, not a structural one |
| ~~Q4~~ | ~~**Frozen-binary tool** (PyInstaller vs. Nuitka vs. platform-specific)~~ **Resolved by SPIKE-00: PyInstaller `--onedir`.** Revisit trigger in `packaging/TODO.md` | Done |
| ~~Q5~~ | ~~**Sidecar ships in the installer, or downloads on first run?**~~ **Resolved by SPIKE-00: bundle in the installer.** Revisit trigger in `packaging/TODO.md` | Done |
| Q6 | **Group-relay transport** — simple polling vs. push; how notes reach approaching members promptly without draining battery | **SPIKE-11**, before the group tier |
| Q7 | **Medical/allergy volunteered-field handling** — how prominently surfaced to the Author, and its group-visibility default (a privacy call flagged in the PRD) | Before profile-sharing build |
| Q8 | **Plugin distribution** — pub.dev + PyPI, or a bundled registry? | Leg 7 |

---

## Appendix: Glossary

| Term | Meaning |
|---|---|
| **`plotlines-core`** | The pure Python routing library. No web awareness (P1). |
| **`plotlines-service`** | FastAPI wrapping the core. Runs as local sidecar *or* hosted. |
| **Sidecar** | The `plotlines-service` child process on the user's own device. |
| **Field Runtime** | The offline-only client tier that executes a downloaded plotline in the field: GPS triggers, cue state, narration, dead-zone odometer (§5). Depends on neither the sidecar nor the network. |
| **Canon vs. layers** | The Author's plotline is canonical (P8); personalization, notes, amendments, and feedback are layers rendered over it, never edits to it. |
| **Group relay** | The trip-scoped, route-anchored, advisory message channel for field notes, amendments, and feedback (P9). |
| **`WeightProfile`** | The data structure defining a routing theme; multimodal weights extend it. One structure, one scorer. |
| **Stowed / Mounted** | The two device postures of the cue HUD (§5.4). Stowed renders nothing; Mounted auto-scrolls. |
| **Size class** | large/fullscreen vs. compact/phone, derived from viewport at runtime, not platform identity. |
| **Version check** | The open-time *and* save-time comparison against the server's trip version (§10.4). |
