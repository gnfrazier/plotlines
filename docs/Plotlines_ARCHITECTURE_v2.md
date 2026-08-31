---
title: Plotlines — Architecture Design
status: Draft
version: 2.0
companion: Plotlines_PRD_v2.md
---

# Plotlines — Architecture Design

**Status:** Draft · **Version:** 2.0 · **Companion docs:** `Plotlines_PRD_v2.md` (133 FRs / 16 epics — the source of truth for *what* and *why*), `Plotlines_MVP_Redirection_Punchlist.md` (verification of the v1.0→v2.0 recomposition), `Plotlines_Research_Spikes.md` (feasibility unknowns). This document covers *how*.

> **What changed in v2.0.** PRD v2.0 restored a set of concepts that v1.0 had reduced from structure to vocabulary — the curation pipeline, the anchor-and-role object model, area geometry, reveal policy, node-anchored activities, setting, compose mode, and mode-legal routability. Most of that lands on this architecture as **addition**, and the design absorbed it well: `ShapeDataProvider` (§13.2) was already the area seam, `content/` (§6.2) was already a package, and P8's canon-vs-layers separation is exactly the right home for reveal state and arrivals. **Four things are breaking changes, not additions**, and they are collected in §0 so they cannot be missed. A later pass added the roster and Author-note model (§11.1), destructive sync (§11.7), the edit-cascade boundary (§7.10), clone semantics (§11.8), and the usability foundation (§10.4) — all additive, and all absent from any earlier reading. Sections new in this revision are marked **[NEW v2.0]**; sections whose content changed are marked **[AMENDED v2.0]** with the prior reading stated.

---

## 0. Breaking Changes in v2.0 — read before anything else

Four places where v2.0 **contradicts** v1.0 of this document. An implementation carrying the v1.0 reading will silently win over the PRD unless these are reconciled first.

| # | Was (v1.0) | Is (v2.0) | Where |
|---|---|---|---|
| **B1** | `/health` returns a single readiness flag; a sidecar still enriching elevation is **not ready**, gating the whole app | `/health` returns **per-capability readiness**; layer/POI capabilities go ready first and unlock authoring while elevation enriches behind them | §7.3, §7.6, D34; PRD FR121, M12a |
| **B2** | `solve_segment`'s `target_distance` is banded by default and never dropped from the constraint set | Banded in **explore** mode; in **compose** mode it is `None` and the realized distance is a **reported outcome** | §6.7, §7.2, D35; PRD FR118 |
| **B3** | Nodes and edges are the only spatial objects; coordinates are points | **Areas are first-class.** Anchors and roles may be polygons; the trip payload, GeoJSON export, trigger engine, and local schema all carry polygon geometry | §6.8, §5.2, §10, D37; PRD FR108 |
| **B4** | Plugin **data-input** is a Leg 7 concern with a deliberately open contract | The data-input contract is **Leg 2.5 and specified**, because the layer picker and cluster analysis read it. Only the **output** contract stays open | §13, D40; PRD FR100 |

A fifth item is not a contradiction but a scope correction with the same urgency: **the routing core has never enforced mode-legal passability** (§6.9, PRD FR128). That is a correctness gap, not a missing feature.

---

## 1. Purpose & Reading Guide

This document describes the system's structure: its components, their boundaries, how data moves, and the decisions that shape those boundaries. It is not an implementation plan, a schedule, or a restatement of requirements. Where the PRD already decided *what*, this builds on it rather than re-arguing it.

**Reading order for a newcomer (human or LLM):**

1. **§0 (Breaking changes)** — what an older reading of this document gets wrong
2. §2 (Principles) — the rules everything else follows
3. §3 (Component Map) — what exists
4. **§4.5 (The Curation Tier)** — new in v2.0, and the stage that precedes routing
5. §5 (The Portability Problem) — the most consequential build decision
6. §6 (Field Execution) — the second, unique to Plotlines
7. §7–§12 — each tier and cross-cutting concern in detail. **§7.10 (authored vs. derived), §10.4 (the usability foundation), §11.7 (destructive sync) and §11.8 (clone semantics) are new in v2.0** and are the ones an older reading of this document does not contain at all
8. §17 (Decision Log) — why things are the way they are

**A note on the brand value "Organized and logical" (PRD §2.7).** That value has an architectural reading, not just a product one: structure has one clear home for each thing, boundaries are predictable, and decisions carry their rationale. This document tries to embody it. Where it names a boundary "load-bearing," a design that crosses it is wrong, not merely different.

**A note on the brand value "Reveal with intent" (PRD §2.8, new).** That value also has an architectural reading, and a sharper one: **reveal is a property of data, enforced at a boundary — never a presentation choice made per screen.** If any surface can decide for itself whether to show a role's content, the guarantee is gone. See P11.

---

## 2. Architectural Principles

These are load-bearing. A design that violates one is wrong, not merely different. P1–P9 carry from v1.0; **P10 and P11 are new in v2.0** and encode what the restored curation and reveal models require.

### P1 — The routing core is a pure library

The routing core (graph, scoring, elevation, multimodal solving, curation analysis, export) knows nothing about HTTP, users, accounts, sessions, or platforms. It takes inputs, returns results, and touches only the filesystem for its own caches. This is what lets the same code run on a laptop and on the server without a fork. If the core needs to know who the user is, the design is wrong — the caller resolves that and passes plain values down.

### P2 — Local-first means the network is an optimization, never a dependency

On Desktop and Mobile, every core capability works with the network unplugged. The network makes things *better*, never *possible*. Web is the deliberate, stated exception (PRD Leg 4) — an acknowledged different shape, and the *only* one.

### P3 — Server-side state is exceptional and enumerable

The hosted service does exactly five things. A sixth is a design event requiring an explicit decision, not a quiet addition:

1. Broker authentication (magic links, share tokens)
2. Hold the canonical copy of an account's trips for sync
3. Cache expensive external fetches (tiles, elevation) so they happen once for everyone
4. Run stateless compute for clients that cannot compute locally (Web, signed-in and guest)
5. Relay trip-scoped group messages between members of the *same trip*

**v2.0 note:** arrival events (PRD FR122–FR123) join item 5 as a fourth message kind. They do **not** constitute a sixth thing — see §8.1 and P9.

### P4 — Guest sessions leave no server-side trace

Not "minimal data." **None.** A guest's compute request is served and forgotten; their work lives in their own browser. A hard guarantee, not a best effort.

### P5 — The user's work is never silently destroyed

Conflicts surface. Overwrites are chosen, never inferred. Enforced structurally (§11.4's version-check protocol), not left to careful coding.

**v2.0 note:** this now covers **promoted anchors** explicitly. An afternoon of curation is the most expensive thing a user can lose, and PRD K8 requires that a planning reset clears the route without discarding anchors. Reset paths must be audited against this.

**And v2.0 finally gives this principle a positive form as well as a defensive one.** Four confirmation mechanisms were written before undo existed — orphan prompts (FR139), bbox shrink (FR120), note-deletion scope (FR135a), anchor protection on reset (FR81) — each enforcing P5 from the wrong side. **A confirmation asks the user to predict a consequence; undo lets them see it and change their mind** (§10.4, D54). All four stand as written for now; FR139's is the one to revisit once undo ships, and FR135a's never moves, because hard deletion is irreversible by design.

### P6 — Plugins extend; they do not modify

The core defines the schema and the extension points; a plugin fills in behavior at those points. A plugin that requires a change to core code is not a plugin — it is a core feature in a costume.

### P7 — External resources are borrowed, not owned

Every external API is a shared commons with real limits. Fetch once, cache with a TTL matched to actual volatility, never re-request what is held. Free-tier ceilings make this a functional constraint, not an etiquette preference.

### P8 — Authorship is canonical; everything else is a layer over it

The Author's plotline is the single source of truth for a trip. Character personalization, peer field notes, amendments, journals, **reveal state, in-story choices, and arrivals** are **layers** rendered over the canonical plotline — never edits to it. Incorporating any of these into the canon is an explicit Author action.

**v2.0 extends this in both directions.** *Below* the canon: **candidates are not canon either.** A candidate is data the trip *considered*; only promotion writes it into the plotline (P10). *Above* the canon: reveal state and arrivals are per-Character layers with their own tables and write paths, exactly like field notes — a Character's reveals can never mutate `trip.payload`.

**And one thing sits outside the canon/layer model entirely: Author-private Character notes** (FR135). Notes are neither canon nor a layer over it — they are **about a person, not about a trip**, scoped to `(Author, Character)` and persisting across every trip the pair share. They never enter `trip.payload`, never render on a Character-facing surface, and have no read path for their subject. **They are the inverse of reveal**: reveal governs *when* Author content reaches a Character; notes reach them *never*. That makes them a P11 concern (§2, P11) despite having nothing to do with triggers.

### P9 — Group messaging is trip-scoped, route-anchored, and advisory

The relay in P3.5 carries only messages between members of one trip, about that trip, anchored to points on its route. Not a chat system, not a social graph, not cross-trip. Recipients accept, decline, or ignore — nothing changes a Character's path without consent.

**v2.0 adds arrivals as a fourth kind and they satisfy every clause**: trip-scoped, anchored to an authored plot point, advisory (an arrival changes nothing for a recipient), and consented per-trip through the *existing* profile-grant mechanism. They are **discrete and event-driven, never a continuous position feed** — a design that streams position violates both P9 and the PRD's participant-tracking non-goal. See §8.5.

### P10 — Analysis proposes; the Author disposes *(new)*

Layer selection, notability filtering, salience scoring, and co-location analysis produce **proposals**. Nothing they produce enters a trip without an explicit Author promotion (PRD FR110). There is no path — not a default, not a convenience, not a "high confidence" threshold — by which an analysis result becomes trip content on its own.

Structurally: **candidates and clusters have a different home and a different lifetime from anchors.** Candidates live in a bbox-scoped, regenerable cache keyed to the layer selection that produced them; anchors live in `trip.payload`. A candidate can be recomputed and thrown away; an anchor is authored work. If a design ever writes an analysis output directly into the payload, it has violated P10 and, with it, the brand value the whole curation tier exists to serve.

The corollary matters as much: **every stage after candidate display is skippable.** An Author who knows the area promotes a candidate directly and routes to it. The pipeline removes work; it never gates it.

### P11 — Reveal is a property of data, enforced at a boundary *(new)*

Whether a role's content is visible to a Character is decided **once, at the point where content crosses to that Character** — not per screen, not per widget, not per export path.

Concretely: the offline package builder, the web reading surface, the print renderer, the cue-sheet generator, **the device-TTS readout (FR40a)**, and the export writers all obtain content through **one resolver** that takes a role and a Character's reveal state and returns either the content or its withheld placeholder. A surface that reads role content directly, bypassing the resolver, is a bug — and it is the specific bug that spoils a trip, because it will be a rarely-exercised path (a print preview, an export corner case, **an accessibility readout**) that nobody tested with unrevealed content.

**One category never crosses at all.** Author-private Character notes (FR135) are not content awaiting a trigger — they are content with **no Character-facing path in any state**. The resolver's contract is therefore not only *release-or-withhold* but also *never-release*, and notes are the only member of that class. Naming it here matters because a "withheld" item implies a future release, and a note has none: a bug that promotes a note to withheld-then-released is as bad as one that renders it directly.

Two hard clauses ride on this:

- **Hazards and cruxes are exempt, in the resolver.** The resolver returns hazard content unconditionally regardless of any role setting, any Author preference, or any trip configuration (PRD FR115). This is enforced in one place so it cannot be forgotten in many.
- **Reveal is a product guarantee, not a security boundary.** Unrevealed content ships to the device because reveal must work in airplane mode (PRD FR64a). The guarantee is that no ordinary UI path surfaces it early. A determined user inspecting their own device's storage will find it, and the documentation says so plainly rather than implying a protection that does not exist.

---

## 3. Component Map *[AMENDED v2.0]*

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          FLUTTER CLIENT (Dart)                            │
│                                                                          │
│  ┌────────────┐ ┌────────────┐ ┌───────────┐ ┌──────────┐ ┌───────────┐  │
│  │ UI / State │ │ Local Store│ │ Sync Agent│ │  Field   │ │  Plugin   │  │
│  │ (Riverpod) │ │  (drift)   │ │           │ │ Runtime  │ │ Registry  │  │
│  └────────────┘ └────────────┘ └───────────┘ └────┬─────┘ └───────────┘  │
│  ┌──────────────────────┐  ┌───────────────────┐  │                      │
│  │ Curation Workspace ★ │  │ Reveal Resolver ★ │  │                      │
│  │ layers · candidates  │  │  P11 — one gate   │  │                      │
│  │ clusters · promotion │  │  for all content  │  │                      │
│  └──────────┬───────────┘  └─────────┬─────────┘  │                      │
│             └──────────────┬─────────┴────────────┘                      │
│                            │                                             │
│              ┌─────────────┴──────────────────────┐                      │
│              │  Routing Client (facade, one URL)  │                      │
│              └─────────────┬──────────────────────┘                      │
│                                                                          │
│  ★ = new in v2.0                                                         │
│  Field Runtime = offline-only: GPS + polygon trigger engine, position-    │
│  aware cue state, narration playback, reveal firing, arrival recording,   │
│  dead-zone odometer, adaptive accuracy. NO network in its critical path.  │
└─────────────────────────────────┼────────────────────────────────────────┘
                                  │
             ┌────────────────────┴─────────────────────┐
             │                                          │
   Desktop / Mobile                                   Web
   (local sidecar)                             (network → hosted)
             │                                          │
┌────────────┴───────────────┐          ┌───────────────┴────────────────┐
│   LOCAL ROUTING SIDECAR    │          │        HOSTED (Render)         │
│   ─ FastAPI (loopback)     │          │  ┌──────────────────────────┐  │
│   ─ plotlines-core (lib)   │          │  │   FastAPI (public)       │  │
│   ─ Local caches on disk   │          │  │   ─ auth / sync / share  │  │
│   ─ Dart offline engine    │          │  │   ─ guest compute        │  │
│     (Mobile, simple P2P)   │          │  │   ─ group relay (P9)     │  │
│   ─ Candidate cache ★      │          │  │   ─ tile + elev cache    │  │
└────────────────────────────┘          │  └────────────┬─────────────┘  │
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
                                  │  OSM · USGS 3DHP · Protomaps ·         │
                                  │  [plugin data layers ★ — see §13]      │
                                  └────────────────────────────────────────┘
```

**Three structural insights carry the whole design** *(the third is new in v2.0)*:

1. **`plotlines-core` appears twice** — once in the local sidecar (Desktop/Mobile), once in the hosted service. Same library, same version, two deployments. The client talks to a FastAPI over HTTP in both cases; only the base URL differs.

2. **The Field Runtime is a distinct, offline-only client subsystem.** It never touches the routing sidecar or the network during a ride — it runs on raw GPS over downloaded data. §6 is devoted to it.

3. **The Curation Workspace sits *beside* the Routing Client, not behind it.** Layer selection, candidate review, cluster analysis, and promotion are a **pre-routing** activity that must be fully usable while elevation enrichment is still running (PRD FR121). If curation were reached through the routing client, it would inherit routing's readiness gate — which is precisely the coupling B1 exists to break. The Curation Workspace calls its own endpoints (§7.2) and depends on layer/POI readiness only.

**And one boundary worth naming explicitly:** the **Reveal Resolver** is the P11 gate. Every path that renders, exports, prints, or packages role content goes through it. It is drawn in the client because that is where all those paths converge, but the *withheld* decision is made against reveal state the client holds, and the offline package builder applies it server-side too (§12.4).

---

## 4. The Curation Tier *[NEW v2.0]*

This tier has no v1.0 ancestor. It is the architecture behind PRD §5's pipeline, Epics N and O, and the thesis that **routing is the fourth thing an Author does, not the first**.

### 4.1 The pipeline, and where each stage runs

```
Stage 0  Layer selection        client (config) ──> core (extraction params)
Stage 1  Notability filter      plotlines-core/curation/  ──> salience
Stage 2  Candidate display      client, from candidate cache
Stage 3  Co-location analysis   plotlines-core/curation/  ──> proposals
Stage 4  PROMOTION              client ──> trip.payload   ★ the canon boundary
Stage 5  Routing                plotlines-core/routing/
Stage 6  Narrative layering     client ──> trip.payload
```

**Stages 1 and 3 run in `plotlines-core`, not the client, for the same reason cue derivation does (D31).** Salience scoring and co-location analysis read tag payloads and geometry the client does not hold, and a client-side implementation would make sidecar and hosted deployments produce **different proposals for the same bbox** — which P1 exists to prevent. The client selects layers, displays candidates, and performs promotion; it does not compute salience or clusters.

### 4.2 The candidate cache — regenerable, and deliberately not canon

Candidates live in a **bbox-scoped, on-demand cache on local disk**, the same shape as the tile and elevation caches (FR94, §8.1). The cache key is `(bbox, layer_set_version, filter_ruleset_version)`.

This is P10 in the storage layout. Three properties follow, and each is load-bearing:

- **Regenerable.** Deleting the candidate cache costs a re-extraction, never authored work. Deleting an anchor costs an Author's judgment.
- **Invalidated by rule changes, not just data changes.** Changing the notability ruleset (FR98) changes every salience score, so the ruleset version is part of the key. Without it, an Author who adjusts a filter sees stale scores and never knows.
- **Never written to `trip.payload`.** A promoted anchor **copies** what it needs from its candidate — geometry, name, source tags, provenance — rather than referencing it. An anchor must survive a cache wipe, a ruleset change, and an upstream OSM edit. **A dangling reference into a regenerable cache is exactly the bug P10's separation exists to prevent.**

### 4.3 Notability filtering and salience

`plotlines-core/curation/notability.py` applies per-tag qualification rules and emits a salience score per candidate (PRD FR98). Two design points:

**The ruleset is versioned data, and it is not yet a config file** *(status corrected 2026-08-28)*. Per-tag rules — `historic=*` sub-weighted by value, `natural=tree` requiring a `denotation` *value*, `leisure=park` requiring a name or area threshold — ship as tables in `core/plotlines_core/curation/taxonomy.py`, versioned by `RULESET_VERSION` in `notability.py` and locked by golden candidate sets. **Prior reading: "live in a versioned config file, because they will need regional tuning and tuning must not be a code release."** The externalized form does not exist in the product: `notability_ruleset.v1.2.0.json` is a SPIKE-A *export* artifact under `spikes/SPIKE-A/results/`, not something the core loads. **The reason for externalizing it also measured away** — SPIKE-A found the correct values are **not regional** (one default ruleset held across NC, WI, and SoCal; what varies 10–30× is candidate *volume*, a ranking concern), so the tuning-without-a-release requirement that justified a config file has no established demand behind it. The versioning discipline that actually matters is preserved either way, because `RULESET_VERSION` is part of the candidate cache key (§4.2). **Externalize when a second consumer or a genuine field-tuning need appears — not before**; the "themes are data" discipline (D5) is the model when it does.

**Salience is a score, not a verdict.** A binary include/exclude cannot drive Stage 3: co-location analysis needs to know that a castle outranks a boundary stone, not merely that both passed. The v1.0 flat `historic=*` wildcard in `providers.py` (`TAGS = {"historic": True}`) is exactly the shape that makes clustering useless, and replacing it is a prerequisite for §4.4, not an enhancement to it.

**~~Unproven, and stated as such~~ — measured 2026-08-27 (SPIKE-A, §18 Q11).** The ruleset was calibrated against real extracts in three trip bboxes (NC, WI, SoCal). The A20 failure mode was real and found: the shipped `natural=tree` gate checked `denotation` presence, not value, and passed 4,149 San Gabriel street trees. Fixed (`Qualification.requires_value`), plus `historic=*` sub-weight and `natural=peak` corrections. One default ruleset — no regional dimension — now at `RULESET_VERSION 1.2.0`, with golden candidate sets locking its output. See `spikes/SPIKE-A/results/RESULTS.md`.

### 4.4 Co-location analysis

`plotlines-core/curation/colocate.py` finds spatial clusters across **heterogeneous layers** within the trip bbox and scores them by combined salience and tightness (PRD FR102–FR105a).

```python
def analyze_colocation(
    candidates: list[Candidate],
    bbox: BBox,
    params: ColocationParams,     # radius bands, min salience, cap
) -> list[ClusterProposal]: ...
```

Design points that are decisions, not defaults:

- **It runs as a named action over a fixed bbox, never ambiently over a viewport.** A viewport-driven analysis cannot be cached (the extent changes continuously), cannot be precomputed, and makes the machine volunteer opinions the Author did not ask for — which reads as noise, not help. Bbox-scoped is cheap, explicit, and cacheable alongside the candidates it reads.
- **It emits two proposal flavours from one algorithm.** Narrative clusters (high-salience features together) and provision clusters (utility features together) differ by the *layer classes* participating, not by a separate code path. A cluster containing both proposes both roles (FR105).
- **Proposals carry their contributing features and salience.** An Author must be able to judge a proposal, not trust it. A proposal that says "good spot" without saying *why* is unreviewable, and an unreviewable proposal will be accepted blindly or ignored entirely.
- **Rejections are remembered per trip.** A rejected cluster is recorded in the payload (a small rejection set, not the cluster itself) so a re-run does not re-propose it. Without this, every re-analysis re-surfaces everything the Author already declined, and the feature becomes annoying on second use.
- **It stays out of SQL.** Clustering runs in the core over an extract, client-side of the database, so **it does not trigger the PostGIS upgrade** (§11.5, A12). This is worth stating because "spatial analysis" sounds like a database job and is not one here.

**~~Cost is unmeasured~~ — measured 2026-08-27 (SPIKE-B, §18 Q12).** ~3,000 candidates over a real 8,800 km2 multi-day bbox (Blue Ridge Parkway, Asheville–Boone) with all six layers live cluster and rank in **~150 ms at ~1.5 MB**; a synthetic 30,000-candidate stress (denser than reality over a 200 km extent) is ~4 s / 16 MB. The clustering is a grid pre-pass (near-linear) then complete-linkage inside each component with a bounded worst case. **The cacheable-endpoint mitigation is more than sufficient — the analysis does not need bounding.** SPIKE-B also fixed the ranking function (`curation/colocate.py`): default sort is salience × tightness; **corridor proximity is a filter and an opt-in resort, not part of the default rank** (folding it in buried genuinely major off-route sights); the FR105a cap is `30 + 0.5 × route-km`. See `spikes/SPIKE-B/results/RESULTS.md`.
---

## 5. The Portability Problem

**The problem:** the routing core is Python (for the geospatial ecosystem). Flutter is Dart. Desktop and Mobile must run route generation *on the device* (P2). Therefore a Python runtime must ship inside a Flutter application across Windows, macOS, Linux, Android, and iOS.

The analysis carries forward unchanged:

- **Rewrite the core in Dart — rejected.** Discards the mature Python geospatial ecosystem (OSMnx, shapely/GEOS, rasterio/GDAL) with no equivalent in Dart. **v2.0 makes this worse to contemplate, not better**: the curation tier (§4) adds spatial clustering and tag analysis to the core's Python surface.
- **Embedded interpreter (in-process FFI) — rejected.** Cross-compiling the native dependency tree across five platforms under iOS's constraints is itself a research project.
- **Local sidecar process — chosen.** Ship the core as a standalone frozen binary the Flutter app launches as a child process, serving FastAPI on `127.0.0.1`.

**Why the sidecar wins:** one transport for the client; the FastAPI layer exercised on every platform; native packaging solved once per platform; process isolation.

**Costs:** frozen-binary size (150–300 MB per platform, now stacking on heavier offline packages — narration audio, multimodal data, **and unrevealed content**, §12.3); lifecycle management (§7.3); and the iOS exception.

### 5.1 The iOS exception — still the largest open risk

iOS prohibits spawning arbitrary child processes in sandboxed apps.

| Approach | Assessment |
|---|---|
| Embedded interpreter on iOS only | Contains the blast radius but makes iOS a genuinely different execution model — the fork this architecture exists to avoid. |
| iOS routes online-only (like Web) | Breaks the offline-generation guarantee on iOS specifically. |
| **Precompute-and-download** — iOS never generates routes locally, but downloads fully-computed plotlines for offline *execution* | **Strongest fit.** The field experience (§6) is about *executing* an authored plotline, not generating routes. |

**v2.0 strengthens this conclusion.** Authoring is now unambiguously a desktop-class activity — layer review, cluster analysis, and promotion over a full bbox are not phone work — so the iOS role is even more clearly execution-only than it was. **But it also raises the stakes on one thing:** the Field Runtime now carries reveal state and arrival recording (§6.7), so iOS must be a first-class *execution* target even if it is never a generation target.

**Recommendation:** prototype the frozen sidecar on Android early; treat iOS as precompute-and-download unless SPIKE-09 proves the Dart offline engine capable enough to serve iOS's simple-P2P need without the Python sidecar at all.

---

## 6. Field Execution — the Plotlines-specific tier *[AMENDED v2.0]*

This tier is the architecture behind PRD Epics I and **P** (new), GPS-triggered narration (FR49), the position-aware cue HUD (FR47/FR50/FR50a), adaptive accuracy (FR54a), the dead-zone odometer (FR54), and — new in v2.0 — **reveal on arrival (FR124), polygon triggers (FR126), in-story choices (FR125), and arrival events (FR122)**.

### 6.1 The Field Runtime rule: raw GPS in, no network in the critical path

Everything the Field Runtime needs during a ride comes from **raw GPS position** and **already-downloaded data**. The network is not in its critical path — not for narration, not for cue advancement, not for hazard alerts, and **not for reveal**.

Concretely, the Field Runtime holds, entirely on-device and offline:

- the downloaded plotline (routes, cues, anchors, roles, hazards, transitions)
- narration audio blobs keyed to **roles** with Author-set trigger distances (FR41)
- **unrevealed content, present but gated** (FR64a, P11)
- the current position estimate and the derived cue state
- a spatial index of trigger geometries — **points and polygons** (§6.2)
- **per-Character reveal state and the arrival log**, both local-first layers (P8)

It does **not** hold or need: a route solver, a tile fetcher, a candidate cache, or any hosted endpoint. If the Field Runtime ever needs the network to advance a cue, fire narration, **or reveal content**, the design is wrong.

### 6.2 Trigger engine *[AMENDED v2.0]* (FR41, FR49, FR53, FR124, FR126)

**Prior reading (v1.0): triggers are geofence-style proximity to a node.** v2.0 adds two things the v1.0 engine cannot express:

**Polygon triggers.** A role may be an area (FR108), and **entry into the polygon is the trigger event** (FR126). The spatial index therefore holds mixed geometry — circles around points and polygons — and the per-update query is "which trigger geometries now contain the position," which is a point-in-polygon test as readily as a radius test. Entry is **debounced with hysteresis on the boundary**, the same mechanism already used for point jitter, because a route that runs along a park edge would otherwise re-fire on every GPS wobble.

**Role-level geometry.** Triggers fire from a **role's** geometry, not its anchor's (FR107). An anchor in a parking lot whose narrative role sits 400 m up a spur must fire at the spur. The index is built over roles, not anchors — this is a one-word change with a real consequence, and getting it backwards produces narration in the parking lot, which is exactly the failure the offset exists to prevent.

**Trigger kinds and priority.** The engine now fires four effects, and the priority order is specified so the build does not invent it:

```
hazard alert      ── preempts everything, never queued, never suppressed (FR115)
reveal            ── unlocks content; silent unless it carries narration
narration         ── queues rather than overlaps
arrival record    ── silent, always fires on a narrative-role trigger
```

Two clauses matter. **Reveal and arrival fire independently of presentation**: a Stowed phone (§6.4) renders nothing, but reveal still unlocks and arrival is still recorded, so pulling the phone out later shows what was passed. And **hazard alerts are never subject to reveal state** — the resolver (P11) returns hazard content unconditionally, so a hazard cannot be gated behind an unfired trigger.

**Device-native TTS is a fifth speech source, not a fifth trigger** *[NEW v2.0, FR40a]*. When a Character enables readout, spoken text is produced by the **platform's own speech synthesis** — no Plotlines voice, no network service, no audio in the offline package. Three consequences for this tier:

- **It shares the narration channel, not a parallel one.** TTS output queues behind and is preempted by the same priority order above. Two independent speech paths would talk over each other, which is the exact failure §6.2's queueing exists to prevent.
- **It reads through the Reveal Resolver, never from `Role.content`** (P11). A TTS path that reads role text directly is the archetype of the A22 leak — it is a rarely-exercised accessibility surface, and it speaks the spoiler out loud. The §15.5 CI gate covers it.
- **Authored audio takes precedence.** Where a role carries Author narration (FR40), that audio plays and TTS does not read the same text over it. The Author's voice is the curated artifact; TTS is the fallback for text that has none.

Availability is a **device capability, not an app feature**: installed voices vary by platform, OS version, and the user's own downloads. The client reports honestly when voices are absent rather than failing silently (brand value 6), and the setting is per-device rather than synced (PRD K5).

### 6.3 Position-aware cue state (FR47, FR50, FR51)

Cue state derives from position projected onto the route polyline: current segment, current and next cue, remaining distance, remaining elevation, live ETA. All arithmetic over downloaded geometry; none of it routing, none of it network.

**This is the boundary that keeps Plotlines on the right side of its own non-goal.** The cue engine recomputes *distances and ETAs along a fixed authored route*. It never recomputes the *route*. A wrong turn surfaces as "off route" — not a new route.

**v2.0 additions to what the engine must account for:** **station durations** (FR16b) enter the ETA the way a scheduled event does — a three-hour crag is three hours, not an annotation — and **an in-story choice** (FR125) re-inlines the chosen branch's cues, which is the same re-projection an alternate toggle already performs (§6.5).

**Where the cue list comes from (SPIKE-21, D31).** `plotlines-core/trips/cues.py` produces it. Two properties this tier depends on: every cue carries `distance_along_m` against the *drawn* polyline, and cues on a retraced spur carry `retrace`. **v2.0 adds a third:** every cue carries its **reveal disposition**, so the Field Runtime renders a withheld plot point as a marker without content rather than omitting it or spoiling it (§6.7).

### 6.4 Device posture: Stowed vs. Mounted (FR50a)

- **Stowed** — screen off/dimmed, phone pocketed. GPS silently advances cue state and drives narration, hazard alerts, **reveals, and arrival recording**. **Nothing renders.**
- **Mounted** — screen on. The HUD auto-scrolls to the next cue live.

Posture follows screen state, manually overridable. Switching re-syncs the view to current position. Posture is a *render* concern layered over a posture-independent position/cue/reveal model — the model runs identically in both.

### 6.5 In-field amendments and choices *[AMENDED v2.0]* (FR55, FR56, FR125)

A Character amending in the field writes to a **local layer over the canonical plotline** (P8), never to the plotline itself.

**v2.0 adds in-story choices (FR125) as a second, distinct thing that looks similar and is not.** An **amendment** is a Character deviating from the plotline; a **choice** is a Character selecting among options the Author *authored*. Structurally:

| | Amendment (FR55/FR56) | Choice (FR125) |
|---|---|---|
| Origin | Character-created | Author-authored branch or station |
| Data needed | may require a solve | already downloaded |
| Publishable to group | yes (P9) | no — it is personal |
| Recorded in recap | as a deviation | as a story event (FR73) |

A choice is a **re-projection over downloaded geometry**, never a solve — which is what lets it work with the sidecar absent. Recording a choice writes to the same local layer as reveal state.

**No randomness anywhere in this path** (PRD Brand Value 9). Every branch and its consequences are authored. If a design introduces a chance element to a field decision, it has left the product.

### 6.6 The Dart offline engine (FR63) and its leverage on iOS

Simple point-to-point offline routing on Mobile uses a **Dart-native routing engine** over the downloaded map set — not the Python sidecar. If SPIKE-09 proves it capable enough, iOS can ship with no Python sidecar at all, collapsing §5.1 from a problem into a non-issue.

**v2.0 note:** the Dart engine's scope does **not** grow. Curation, salience, and clustering stay in Python (§4.1); the Dart engine remains a simple-P2P solver. An iOS device that cannot run the sidecar simply cannot author a trip — which is consistent with authoring being desktop-class work.

### 6.7 Reveal and arrival in the field *[NEW v2.0]*

**Reveal state is a per-Character, per-role local layer** (P8) — a set of `(role_id, revealed_at)` records in drift, synced when connectivity allows, never written into `trip.payload`.

Three properties are load-bearing:

- **Reveal is permanent once fired.** A revealed role stays revealed for that Character. There is no re-hiding, no expiry, no "unread" state — a story beat experienced is experienced.
- **Content ships unrevealed and is gated at the resolver** (P11, FR64a). It is in the offline package because reveal must work in airplane mode. The client renders a withheld role as *a marker with no content* — visible on the map and cue sheet as "something is here," which is what makes the pre-trip view honest without being a spoiler (PRD P1's AC).
- **A withheld role is not an absent role.** Distances, ETAs, and cue ordering all account for it. Omitting it from the cue sheet until arrival would make the remaining-distance readout wrong, and would leak the reveal by the numbers changing on arrival.

**Arrivals record locally and unconditionally** (FR122). Every narrative-role trigger writes an arrival to the local log regardless of any sharing decision, because the Character's own recap (FR73) depends on it. **Sharing is a separate, later step**: the Sync Agent posts arrivals to the group relay only if a grant exists (§8.5). The split matters — a Character who declines sharing still gets their own story back at the end.

---

## 7. Tier 1 — `plotlines-core` (Routing & Curation Library) *[AMENDED v2.0]*

### 7.1 Boundary

`plotlines-core` is a pure Python package: no FastAPI import, no request objects, no user IDs, no session concepts (P1). Its entire surface is functions over plain data.

```python
# The shape of the contract — not final signatures, but the right *shape*

def build_graph(bbox: BBox, mode: TravelMode, cache_dir: Path) -> Graph: ...

def enrich_elevation(graph: Graph, tiles: list[Path]) -> Graph: ...

def score_edges(graph: Graph, weights: WeightProfile) -> Graph: ...

# --- curation (new in v2.0, §4) ---

def extract_candidates(
    bbox: BBox,
    layers: LayerSelection,          # FR97 — which layers are live
    cache_dir: Path,
) -> list[Candidate]: ...

def score_notability(
    candidates: list[Candidate],
    ruleset: NotabilityRuleset,      # FR98 — versioned config, not code
) -> list[Candidate]: ...            # salience populated

def analyze_colocation(
    candidates: list[Candidate],
    bbox: BBox,
    params: ColocationParams,
) -> list[ClusterProposal]: ...      # FR102–FR105a — proposals only (P10)

# --- routing ---

def solve_segment(
    graph: Graph,
    start: Coord,
    end: Coord | None,
    via_anchors: list[AnchorRef],    # FR8a — was via_nodes: list[Coord]
    shape: RouteShape,
    weights: WeightProfile,
    target_distance: float | None,   # explore: banded (FR6/FR8). compose: None,
                                      # and realized distance is REPORTED (FR118)
    mode_constraints: ModeConstraints,  # FR128 — legality is not optional (§7.9)
    cpus: int,                       # a PARAMETER, never discovered (P1)
) -> Segment: ...

def compose_day(segments: list[Segment], transitions: list[Transition]) -> Day: ...

def split_trip(days: list[Day], limits: DayLimits) -> Trip: ...

def export_trip(trip: Trip, fmt: ExportFormat, contents: ExportContents,
                reveal: RevealView) -> bytes: ...   # P11 — export is a boundary
```

Two v2.0 signature changes are load-bearing rather than cosmetic:

- **`via_nodes: list[Coord]` became `via_anchors: list[AnchorRef]`.** A via point is now a reference to a promoted anchor with a role set, not a bare coordinate — because A9's conflict explanation must be able to name *the via-anchor* rather than "a coordinate," and because compose mode's whole input is the anchor set.
- **`export_trip` takes a `RevealView`.** Export is one of the paths P11 governs, and it is the *easiest one to forget*: a GPX export that embeds unrevealed plot-point notes as waypoint descriptions spoils the trip through a path nobody thinks to test.
- **All four format writers, FIT included, are in-core Python.** SPIKE-16 (2026-08-30) built a dependency-free FIT course writer — CRC-16 + container framing validated against 10 real Garmin activity files, a course that round-trips to the byte — and rejected the Dart-FFI-against-the-Garmin-SDK alternative that would have put one format on a different code path from GPX/TCX/GeoJSON and given sidecar and hosted deployments different FIT writers (see D-log below). FIT is not the odd-one-out format.

**What "plain data" means (D28, SPIKE-20).** `Segment`, `Day` and `Trip` are the dataclasses in `plotlines_core/trips/payload.py`, and their JSON form is specified by [`docs/schemas/trip_payload.schema.json`](schemas/trip_payload.schema.json) — simultaneously this function family's return type, drift's stored blob (§11.3), the hosted `trip.payload` (§11.1), and the Flutter domain layer's source. Where the schema and any implementation disagree, the schema wins.

**v2.0 grows that schema substantially** — anchors, role sets, polygon geometry, role offsets, arc on passages, station activities, sets, reveal dispositions, and the trip bbox. **This is a schema version bump with a migration, not an additive edit** (§11.6, D38).

### 7.2 Internal structure *[AMENDED v2.0]*

```
plotlines-core/
├── graph/          # OSMnx construction, caching, simplification
├── elevation/      # GeoTIFF reads, void handling
├── scoring/        # WeightProfile + the one multi-factor scoring function
├── routing/        # solve, shape handling, via-anchor constraints (FR8a),
│                   #   mode-legality constraints (FR128 — §7.9)
├── multimodal/     # per-mode graph building + water/technical params (§7.5)
├── curation/       # ★ NEW — layer extraction, notability ruleset, salience,
│                   #   co-location analysis (§4)
├── trips/          # payload types, day composition, transitions, splitting,
│                   #   speeds/ETA, cue derivation (cues.py — D31)
├── content/        # anchors, roles, arc, sets, reveal dispositions,
│                   #   trigger metadata  ← restructured in v2.0
└── export/         # GPX / TCX / FIT / GeoJSON writers (reveal-aware)
└── providers/      # pluggable data-source interfaces (§13)
```

**`curation/` is a new package, not flags threaded through `graph/` or `content/`.** It has a different lifetime from everything around it (regenerable cache, §4.2), a different consumer (an Author reviewing proposals, not a solver), and a different failure mode (a bad ruleset produces noise, not a wrong route). Merging it into `content/` would put canon and candidates in one package, which is P10 violated in the directory layout.

**`content/` is restructured, not extended.** In v1.0 it held "POI curation, narrative-arc tags, trigger-distance metadata" — three loose concerns over an undifferentiated node. In v2.0 it holds the **anchor/role object model** (§7.8), which is what those three concerns were always trying to be.

### 7.3 Scoring model — themes are data, not algorithms

Every theme is a `WeightProfile` instance fed to **one** multi-factor scoring function (PRD M1). Adding a theme is a config entry.

```python
@dataclass
class WeightProfile:
    climbing: float                    # FR2 ("peaks")
    traffic: float                     # FR3 ("cars")
    surface_pref: dict[str, float]     # FR4 — per class, 0.0 avoid – 5.0 seek,
                                        #   bipolar per class (SPIKE-03)
    interest: float                    # FR5 — salience bias, explore mode only.
                                        #   A SCALAR, not a per-type dict: layer
                                        #   selection supplies the *what* (§7.7)
    terrain_technicality: float = 0.0  # FR14 — land exposure/scramble
    # detour_budget: RETIRED in v2.0 — see D46
```

**`water_type` and `max_water_class` are gone (D19)** — no per-edge class rating exists in any usable source.

**`terrain_technicality` stays Author-declared — measured 2026-08-28 by SPIKE-C (#170), no longer merely unproven.** v1.0 generalized SPIKE-04's whitewater verdict to all technical terrain without testing it; FR14b reopened the question and SPIKE-C answered it over 57,422 ways in seven regions. **Of FR14b's four schemas only `piste:difficulty` supports a read-first capability** (86.4–100% wherever a nordic piste exists, in North America as much as in Austria). `sac_scale` peaks at **31.8%** in North America (White Mountains, `route=hiking` members) and **55.1%** even in the Tyrol, where the scale was invented; `mtb:scale` reaches 5.7% in Bentonville, `trail_visibility` 6.5% in the Methow. **And thin coverage here does not fail safe.** A leg's grade is *worst-of* its ways, so a worst-of over a sample is biased low by construction: at measured North American rates **16–32% of the leg grades this would print are wrong, every one of them too easy** (SPIKE-C §3). SPIKE-21's unknown-tag rule does not transfer — it produces silence because cue derivation is per-edge; difficulty aggregation is not. So `terrain_technicality` is the Author's declaration (FR14/B8) for hiking and MTB, published grading is read **per way and never aggregated**, and nordic reads for real. See `spikes/SPIKE-C/results/RESULTS.md`.

**v2.0 adds two extension paths, and they are different** (PRD FR130). A new **traversal mode** is a `WeightProfile` entry plus its domain parameters — the mechanism M1 already describes. A new **station activity** (climbing, canyoneering, jumaring) needs **no routing change at all**: it is an activity-type config entry consumed by `content/` and day timing, never by the scorer. Filing station activities as "more modes" is what made nine modes look like a scoping decision when it was a modeling gap.

**`poi_bonus` became `interest`, and `detour_budget` is retired** (D46). Three changes in one, all from PRD FR5's reformulation:

- **It is a scalar, not a per-type dict.** The Author's live layer set (FR97) already declares *what* matters; a type parameter on the weight was a second surface for the same intent, with no rule to resolve a conflict between them.
- **It biases toward salience, not count.** Density weighting maximizes *quantity*, and quantity correlates with boundary stones and street trees — the same failure that made the flat `historic=*` wildcard useless for clustering. Salience did not exist when `poi_bonus` was written; now it does, and the scorer can prefer better places rather than more of them.
- **`detour_budget` is gone.** With a single salience bias, a separate detour allowance was a second dial for one intent. Detour tolerance is expressed by the interest weight's magnitude against the distance band.

**It is explore-mode-only** (§7.7). In compose the promoted anchors are the spine and the weight is inactive — a scalar competing with an explicit editorial decision is incoherent. The useful consequence is that the two modes stop being *curated vs. uncurated* and become **salience judged by the machine vs. salience judged by the Author**: same data, same notion of good, different level of Author involvement. That also makes D-G's mode switching natural, since an explore route generated on salience is one whose good places are already worth promoting.

**Carried risk, now more urgent:** `WeightProfile` still names three different structures across the PRD, this document, and `scoring/profile.py` (A18). D29 fixed what the *payload* stores; the conversion function still does not exist. **v2.0 raises the priority** because compose mode gives weights a second, different job (flavouring rather than searching), and a second job over an ambiguous structure is how the ambiguity ships.

### 7.4 Multimodal routing (FR10–FR16) and its data dependency

Each travel mode builds its own graph (`multimodal/`): cycling and hiking over the road/path network, paddling over the waterway network. The scorer is mode-agnostic; graph construction and available edge attributes are mode-specific.

SPIKE-04 answered the paddling question and **the provider boundary is what saved the design**:

| | Answer | Source |
|---|---|---|
| Waterway network | **Yes** — connected, directed, uniformly attributed | **USGS 3DHP** (D27) |
| Gauge readings | **Yes**, including which reach a gauge governs | USGS Water Data APIs + NLDI |
| Access points | **Partial** | OSM + state GIS |
| Class ratings | **No** | none on acceptable terms |

**v2.0 adds driving as a traversal mode** (PRD FR29, FR10). Driving legs to trailheads and put-ins are **routed by the same engine in driving mode**, not recorded as notes — because the last mile to the put-in is often the day's most harrowing part, and v1.0 flattened it into a text field. This is the cheapest new mode in the list (the OSM road graph is already built; the weights are near-trivial), but it is **unmeasured** — SPIKE-E (§18) confirms the graph and solver handle it acceptably.

Train, shuttle, and flight legs remain **authored notes**, not routes. That distinction is the whole point of the correction.

**Driving carries a vehicle-access advisory** (PRD FR29a, C13a), and OSM supports it better than expected. The signals: `surface=*` (gravel, dirt, unpaved, compacted, ground), `smoothness=*` (`very_bad` → `impassable` — the strongest single indicator), `tracktype=grade1`–`grade5`, `4wd_only=yes`, `highway=track`, and `motor_vehicle=*`/`access=*`.

**It is modelled on FR14's gauge band, not on FR128's hard constraints.** The Author declares an expected vehicle capability; the engine flags where the route exceeds it, in the leg summary and on the cue sheet, naming the signal that triggered the flag. It **warns and surfaces; it never excludes or reroutes.** Two reasons, and both are the same reason FR14 is advisory: tag coverage is uneven, and whether a given vehicle makes a given road is a judgment the Author holds and the app does not. **A19's honesty clause applies** — an unflagged leg means *no contrary signal found*, never *confirmed passable*, and the surface says so.

### 7.5 Elevation — void handling

Unchanged from v1.0 and validated by the POC (FR85–FR91, SPIKE-18):

- value present → use it
- `nodata` sentinel → `0.0`
- **NaN nodata → `0.0`, checked explicitly via `isnan`** — `value == ds.nodata` misses NaN under IEEE 754. A real defect found and fixed in the POC.
- coordinate outside every open raster's bounds → `0.0`
- raster missing or unreadable → `0.0`

Every fallback **logged once per raster path**, never per coordinate. Each lookup reads a **single-pixel window**, bounds-checked before the read; datasets opened lazily and held for the process lifetime.

A route through a data void is slightly wrong; a route that hangs or throws is broken.

### 7.6 Why scoped weighting (FR36) is not a rewrite

`WeightProfile` resolves **per edge** via `weights.at(position)` (PRD M2). Scalar case returns the same object; scoped case returns the profile governing that position. The solver never learns the difference.

```python
def edge_cost(edge, position: float) -> float:
    profile = weights.at(position)   # scalar case: always the same object
    return apply(profile, edge)
```

### 7.7 Explore and compose — one solver, two postures *[NEW v2.0]*

PRD FR117–FR119 add a second planning mode. **This is not a second solver.**

| | Explore | Compose |
|---|---|---|
| `via_anchors` | empty or few | the promoted anchor set |
| `target_distance` | banded value (FR6/FR8) | **`None`** |
| `interest` (salience bias) | active | inactive |
| Weights do | define the search space | flavour connections between fixed anchors |
| Distance is | a constraint | a **reported outcome** (FR118) |

The core change is that `target_distance=None` is now a **first-class, expected input** rather than a degenerate case. The solver reaches the anchors and reports what it produced.

**SPIKE-01's via-node finding is reinterpreted, not overturned.** It measured distance error rising to +30.7% (Boulder) and +81.9% (Viroqua) at three via-nodes, and v1.0 recorded that as a UI-and-expectations defect. In compose mode it is **the correct behaviour**: the places determine the length. Every via was hit and every loop closed — the solver was never the problem. SPIKE-01 also measured a 1-via loop as **~6× faster** than an unconstrained one, because the via replaces an anchor the engine would otherwise search for, which suggests **compose mode is the cheaper posture**, not the more expensive one.

**What must not happen:** compose-mode distance deviation must not route through `/segments/diagnose` (§8.2) or the shared error surface (PRD M13). It is not a conflict. Presenting it as one re-teaches the Author that curation is a failure mode.

### 7.8 The anchor/role model in `content/` *[NEW v2.0]*

```python
@dataclass
class Anchor:
    id: str
    geometry: Point | Polygon        # FR108 — areas are first-class
    roles: list[Role]                # a SET, not a type field (FR106)
    provenance: Provenance           # candidate/cluster/hand-placed (§4.2 — copied)

@dataclass
class Role:
    kind: RoleKind                   # narrative | provision | station
    geometry: Point | Polygon | None # FR107 — optional offset from the anchor
    reveal: RevealPolicy             # always_visible | on_arrival (FR114)
    content: RoleContent             # text, media, audio, trigger distance
    arc: ArcStage | None             # FR38 — also valid on a Passage
    activity: StationActivity | None # FR109 — kind, duration, gear, difficulty
```

Four properties are the whole point:

- **One anchor per place, roles as a set.** The national monument is one object with narrative + provision roles — one arrival, one pin, two reveal policies. A type field cannot express it; two co-located objects duplicate the arrival.
- **Reveal lives on the role, not the anchor.** This is what makes the restroom always-visible while the statue waits (FR114).
- **Geometry is optional on the role and required on the anchor.** An anchor with no role offsets behaves exactly as a point — the common case costs nothing.
- **Provenance is copied, never referenced** (§4.2). An anchor survives a candidate-cache wipe.

**Arc attaches to `Passage` as well as `Role`** (FR38). The long grind to the pass *is* the rising action, and a model that tags only points cannot say so.

### 7.9 Mode-legal routability *[NEW v2.0]* — a correctness gap, not a feature

**v1.0 specified no passability guarantee anywhere in 96 requirements**, though the OSM attribute mapping carried a whole routability-constraint column. PRD FR128 closes it.

`routing/` consumes a `ModeConstraints` bundle during graph construction and scoring:

| Class | Tags | Treatment |
|---|---|---|
| Hard exclusion | `bicycle=no`, `foot=no`, `canoe=no`/`private`/`permit`, `bicycle=use_sidepath`, `bicycle=destination` | edge removed from the mode's graph |
| Surfaced constraint | `bicycle=dismount` | routable, but **flagged and cued** — never silently included |
| Barrier | `barrier=cycle_barrier`/`bollard`/`gate` (with the barrier's own access value) | pass/penalty/exclude per its access tag |
| Crossing | `ford=yes`, `ford=stepping_stones` | flagged; excluded for modes that cannot cross |
| Water obstacle | `waterway=weir`/`lock_gate`/`waterfall`/`hazard` | hard obstacle; prompts a portage (FR15) |
| Permission | `oneway:bicycle=no` (contraflow), `climbing:access=*` | honoured |

Two design points. **This runs at graph-build time, not scoring time**, for hard exclusions — an illegal edge should not be scorable at all, and a penalty large enough to avoid an edge is not the same as an edge that cannot be used. And **where a constraint forces a materially worse route, it is named** through A6's existing conflict path (FR9), because "the direct road is closed to bikes" is exactly the kind of thing an Author needs told rather than silently absorbed.

**Interaction with A17/D33:** these are *legality* constraints and are entirely separate from the traffic-stress model. A road being quiet and a road being legal are different questions, and conflating them is how a `tertiary` tag ends up meaning three things.
### 7.10 Authored versus derived — the edit-cascade boundary *[NEW v2.0]*

PRD FR139–FR141 close the last structural gap in v2.0: nearly every requirement was written **create-once**. The rule rests on one split, and every downstream behaviour follows from it.

**Authored work** — anything the Author typed, drew, promoted, or arranged: anchors, roles, reveal settings, content, arc stages, transition instructions, hazards, group assignments, notes.
**Derived work** — anything the core computed from it: routes, cue sheets, planning metrics, elevation profiles, distance-based day splits, candidate caches.

> **Orphaned authored work prompts. Invalidated derived work goes stale.**

Three consequences for this tier:

- **The core is not responsible for the prompt.** Orphan detection is a client-side traversal of the payload — *which anchors fall in these days, which transitions belong to this passage* — and the prompt is a Presentation concern. `plotlines-core` never learns that an edit happened; it is handed a payload and asked to solve. This preserves P1 exactly as it stands.
- **Staleness is a payload field, not a service state** (D30, D52). It survives a save, a reopen, a sync, and a dead sidecar, which is what makes an Author's multi-edit session safe: they can close the app mid-edit and the pending work is still pending when they return.
- **Nothing recomputes on its own.** Re-solve is an explicit call. An implementation that eagerly re-solves on edit is expensive, surprising mid-thought, and defeats the entire mechanism — the point of `solve.stale` is that the Author batches.

**One boundary must not be crossed** (D53): the **stale list is a distinct surface from M13's shared error surface**. Stale work is *pending work the Author caused deliberately*, and every item carries a one-action resolution. Routing it through M13's typed state enum would teach the Author that ordinary editing produces errors — the same defect as routing compose-mode distance deviation there (§7.7). Two things now sit deliberately outside M13, and both are the same mistake in different clothes.

---

## 8. Tier 2 — `plotlines-service` (FastAPI) *[AMENDED v2.0]*

### 8.1 One codebase, two deployment profiles

| | **Sidecar mode** (Desktop/Mobile) | **Hosted mode** (Render) |
|---|---|---|
| Bind | `127.0.0.1`, ephemeral port | `0.0.0.0`, public |
| Hostname | loopback | `api.<custom-domain>` — never `*.onrender.com` (§10.3) |
| Auth | None (loopback is the trust boundary) | Magic-link / same-site session cookie / guest |
| Database | None | Postgres |
| Routing endpoints | ✅ | ✅ |
| **Curation endpoints** ★ | ✅ | ✅ |
| Auth / sync / share / group-relay | ❌ not registered | ✅ |
| Tile + elevation **+ candidate** cache | Local disk | Shared server-side (candidate cache: local only, §4.2) |
| CORS | N/A | **N/A** — same-site |

Tile, elevation, **and candidate** caches follow an **identical bbox-scoped, on-demand pattern** (P7, FR94) — same policy, three payloads, not three designs.

Mode is selected by an env var at startup. Endpoints not valid for a mode are **not registered**, not merely guarded.

### 8.2 Endpoint surface *[AMENDED v2.0]*

```
# Curation — both modes ★ NEW v2.0 (§4)
GET    /layers                          # available layer catalog, incl. plugin layers
                                        #   with licence metadata (FR97, FR100, FR101)
POST   /candidates/extract              # bbox + layer selection → extraction job
GET    /candidates?bbox=…&layers=…      # scored candidates from the cache (FR98, FR99)
POST   /clusters/analyze                # bbox + params → cluster proposals (FR102–FR105a)
                                        #   named action, cacheable, never ambient

# Routing — both modes
POST   /regions                   # trip bbox → region key; 202, ARCH D25/D57 pattern.
                                  #   Poll GET /health's capabilities.routing.regions[key].
                                  #   Idempotent: the same (bbox, network_type) returns the
                                  #   same key without rebuilding (issue #154).
POST   /segments/generate         # mode + shape + weights + via-anchors → Segment.
                                  #   target_distance=None is the COMPOSE case (§7.7),
                                  #   and realized distance returns as an outcome,
                                  #   NOT as a band violation
POST   /segments/envelope         # attainable range per weighted attribute — band
                                  #   defaults (FR6, A5); ~10 solves, cacheable (D26)
POST   /segments/diagnose         # violated band set → async diagnosis; 202 + id (D25)
GET    /segments/diagnose/{id}    # poll: named conflict + verified relaxations
POST   /days/compose              # segments + transitions → Day
POST   /trips/split               # multi-day splitting
POST   /trips/{id}/export         # → GPX | TCX | FIT | GeoJSON, reveal-aware (P11)
GET    /geocode?q=…               # Nominatim via OSMnx

# Content — both modes (cache-backed)
GET    /tiles/{z}/{x}/{y}               # z/x/y range-validated before upstream work (FR93)
GET    /elevation?bbox=…                # never blocks, never raises (FR88, §7.5)
GET    /weather?lat=…&lon=…&date=…      # historical | forecast, age-stamped

# Health — both modes
GET    /health                          # ★ PER-CAPABILITY readiness (§8.3, B1)

# Accounts — hosted mode only
POST   /auth/magic-link
POST   /auth/magic-link/verify
GET    /trips                     # library (FR74/FR75)
PUT    /trips/{id}                # write, version-checked (FR59)
GET    /trips/{id}/version        # cheap version probe
POST   /trips/{id}/share          # → revocable token
DELETE /shares/{token}
GET    /profile
POST   /profile/requests          # Author requests fields AND permissions (FR78a, FR123)
PUT    /profile/grants            # Character grants/declines/volunteers (FR78)
GET    /roster/{trip_id}          # ★ roster w/ group + subgroup (FR136)
PUT    /roster/{trip_id}/{account_id}   # ★ group assignment, incl. day/passage overrides
GET    /notes/{subject_account_id}      # ★ Author-private notes (FR135). Returns ONLY
                                        #   notes authored by the caller. There is no
                                        #   endpoint by which a subject reads their own.
PUT    /notes/{subject_account_id}
DELETE /notes/{note_id}                 # ★ hard delete, one note (FR135a)
DELETE /notes/subject/{account_id}      # ★ hard delete, all notes on one Character
DELETE /records/subject/{account_id}    # ★ hard delete, everything the caller holds
                                        #   about this Character, across all trips

# Group relay (P9) — hosted mode only, trip-scoped
POST   /trips/{id}/notes          # pin a field note (FR56a)
GET    /trips/{id}/notes          # notes for approaching members
POST   /trips/{id}/amendments     # publish an amendment (FR56)
POST   /trips/{id}/feedback       # trip-scoped feedback + votes (FR42)
POST   /trips/{id}/arrivals       # ★ arrival events, grant-gated (FR122–123, §8.5)
GET    /trips/{id}/arrivals       # roster-visible arrivals for this trip

# Reading — hosted mode only ★ NEW v2.0
GET    /read/{share_token}        # Character-facing web journey view (FR132),
                                  #   reveal-aware (P11)
```

**`/candidates/extract` is a job, not a synchronous call.** Extraction over a multi-day bbox across many layers is not a request an Author waits on inline, and it is the operation §8.3's readiness model is built around.

**`/clusters/analyze` is separate from `/candidates` for the same reason `/segments/envelope` is separate from `/segments/generate` (D26):** it is expensive, cacheable, and triggered by a distinct user intent. Folding it into candidate retrieval would make every map pan pay for analysis nobody asked for — and would make it ambient, which §4.4 rejects.

**Conflict diagnosis stays asynchronous** (D25): a satisfiable solve is 27–218 ms against 1.3–15.0 s to diagnose. **And compose-mode distance deviation never enters this path** (§7.7) — it is not a conflict.

**Auth is magic-link only.** No `/auth/passkey/*`, no `/auth/qr-authorize`.

### 8.3 Per-capability readiness *[AMENDED v2.0 — breaking, B1]*

**Prior reading (v1.0): "Health returns readiness, not liveness"** — one flag, and a sidecar still loading a graph is not ready.

That was right when routing was the first thing an Author did. Under PRD FR121 the Author works during elevation enrichment, so a single flag either blocks the authoring session for minutes or lies about routing being available.

```
GET /health →
{
  "app_version": "...", "sidecar_version": "...",
  "capabilities": {
    "tiles":     {"ready": true,
                  "archive": "a1b2c3d4e5f60718"},                  # ← home-region PMTiles fingerprint (issue #155)
    "layers":    {"ready": true,                                   # ← unlocks curation
                  "per_layer": {"osm_historic": "ready",
                                "osm_amenity":  "ready",
                                "plugin_battlefields": "loading",
                                "plugin_manors": "failed:licence_missing"}},
    "routing":   {"regions": {                                     # ← D57, issue #154
                    "7aee30aebeddc034": {"ready": false, "reason": "building graph",
                                         "progress": 0.42, "eta_s": 5},
                    "a51f9c2e0d8b7461": {"ready": true}}},
    "elevation": {"ready": false, "reason": "elevation_source_not_configured:tracked_in_148"}
  }
}
```

Seven rules:

- **Nothing waits behind anything else** *(amended 2026-08-28 — SPIKE-D)*. Authoring depends only on layer/POI extraction, routing only on the region graph, elevation-dependent metrics only on enrichment — **three independent gates, started together**. **Measured on a real 704 km² trip bbox: extraction 15.8–178.5 s, region graph 36.7 s (116.6 s at 1,799 km²), enrichment 8.8 s** — of which sampling and grade computation are 110 ms. **Prior reading: "startup order is layers-and-POI first, elevation second… a reordering of existing startup work, cheap in the sidecar."** That was pointed at the wrong pair. Elevation is the cheapest of the three and never the half worth hiding; the expensive, *unpredictable* one is extraction, and the one routing actually waits on is the graph. **POI indexing is 2–51 ms, so the entire first phase is network.** See `spikes/SPIKE-D/results/RESULTS.md`.
- **`layers.ready` is `any`, not `all`.** The capability is ready once any layer is usable. An `all()` would let one slow plugin re-impose exactly the global flag B1 removes.
- **The client enables surfaces from these flags and states a reason on every disabled control.** Never a silent failure on click; never a spinner over the whole app. This is the "honest state" brand value made mechanical.
- **Layer readiness is per layer, not one flag** (PRD N2). A plugin dataset may be large or remote, so `capabilities.layers` carries per-layer state: built-in OSM layers go ready while a plugin layer loads, the picker shows that layer as loading rather than blocking the workspace, and **one layer failing never blocks the others** — the failure names the layer and the reason. This is B1's rule applied one level down: any long operation standing between the Author and their work gets the same treatment, and a layer set is exactly such an operation once plugins exist.
  **Not implemented as of 2026-08-28 — SPIKE-D measured the shipped app at 3 of 8 of this contract's clauses.** `capabilities.layers.per_layer` is the constant `{layer: "ready" for layer in sorted(LAYERS)}`, so there is no seam at which a layer could report `loading` or `failed:licence_missing` — the two values the example above prints. Worse, `GET /candidates` wraps one provider call in one `try` and returns **422 for the whole request** when a single layer's provider raises: six built-in layers plus one failing plugin returns zero candidates, which is the exact inverse of this rule. **The cause is a divergence from §14.2, not a gap in it.** That contract already specifies a per-layer `fetch_candidates(bbox)` and a `load_state() -> LayerLoadState`; the shipped `core/plotlines_core/curation/providers.py` collapsed both into one multi-layer `fetch(bbox, layers) -> list[RawFeature]`, leaving per-layer state and per-layer failure with nowhere to live. **Reconciling `providers.py` with §14.2 is story N2**; `spikes/SPIKE-D/plugin_layers.py` is a working sketch of the reconciled shape.
- **Routing readiness is per region, not one flag** (D57, issue #154). D41's trip bbox is the Author's own authoring extent, so "routing" is never one process-wide state any more — it's keyed by the region id `POST /regions` returned, empty until an Author has drawn a bbox. `elevation` stays a single fixed not-ready entry across every region (gated on FR87/#148, never attempted) rather than settling per region, since no region's elevation ever comes up in this codebase yet.
- **Version mismatch still refuses to run** (A8, §13.1). Per-capability readiness changes *what is ready*, never *whether the pair is compatible*.
- **`tiles.archive` is a content fingerprint, not a readiness signal** *(issue #155)*. A short digest of the committed home-region PMTiles archive the sidecar serves basemap tiles from. `vector_map_tiles` renders each vector tile to a PNG and caches it on disk with a 30-day TTL; nothing in that key tied a cached render to the archive that produced it, so replacing or re-extracting the archive kept serving month-old (often blank) tiles. The desktop client folds this digest into its raster tile-cache folder name (`basemapTileCacheFolder`), and a zero-feature tile is refused as retryable rather than frozen as a background-only render — see `client/lib/presentation/map/vector_tile_provider.dart`.

**Unchanged and still important:** the Field Runtime depends on the sidecar not at all — a dead sidecar degrades to "can't generate," never "can't ride."

### 8.4 Sidecar lifecycle (Desktop/Mobile)

```
App start
  ├── Find free port (bind :0, read assigned port, release)
  ├── Spawn sidecar with --port=N --mode=sidecar --cache-dir=…
  ├── Poll GET /health for PER-CAPABILITY readiness (§8.3)
  │     └── surface honestly; never a silent hang
  ├── App runs; sidecar is a child process
  ├── Sidecar dies mid-session → detect → restart once → if that fails,
  │     degrade honestly (cached plotlines viewable/executable,
  │     new generation unavailable, stated inline)
  └── App exit → graceful stop → hard kill after grace → orphan sweep next launch
        └── POSIX:   SIGTERM → SIGKILL; child spawned into its own session
            Windows: AttachConsole + CTRL_BREAK_EVENT → TerminateProcess;
                     CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
                     held in a Job Object
```

**The Windows form is not optional.** Windows cannot deliver SIGTERM; `TerminateProcess()` runs no handler, severing in-flight requests. The only catchable stop is a console control event, and the client is a GUI process with no console. The verified sequence: spawn with `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`; `AttachConsole(pid)`, mute the client's own Ctrl handling with `SetConsoleCtrlHandler(NULL, TRUE)`, `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid)`, `FreeConsole()`, restore; hard-kill after grace. Orphan handling: Windows has no process groups to sweep and never reparents, so hold the sidecar in a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (SPIKE-00 §3).

**v2.0 adds one lifecycle consequence:** a sidecar that dies **during candidate extraction** loses regenerable work only (§4.2). Restart re-extracts; nothing authored is lost. This is worth stating because it is the one long-running operation in the system and the instinct to protect it is misplaced — the protection is the cache key, not the process.

### 8.5 Arrivals as a fourth relay kind *[NEW v2.0]*

Arrivals (FR122–FR123) are added to the P9 relay rather than given their own mechanism. They satisfy every P9 clause:

| Kind | FR | Anchored to | Mutates recipient? | Consent |
|---|---|---|---|---|
| Field note | FR56a | a point on the route | No | — (roster-wide) |
| Route amendment | FR56 | a route segment | Only on explicit Accept | — |
| Trip feedback | FR42 | a route/segment/POI | No | — |
| **Arrival** ★ | FR122–3 | **an authored plot point** | **No** | **per-trip grant (FR78a)** |

Four properties keep this inside the participant-tracking non-goal:

- **Discrete and event-driven, never a stream.** An arrival posts when a narrative trigger fires. There is no periodic position upload, no "last seen," no interpolation between arrivals. A design that adds any of those has crossed the non-goal.
- **Consent reuses `profile_grant`** (§11.1) — no parallel mechanism, no second consent surface. The Author requests arrival visibility as one more field; the Character grants or declines; default is nothing shared.
- **Roster-visible, not Author-only.** The use case is regroup — *"three of us are already at the overlook"* — which fails if it routes through an Author who is riding. Same reasoning that made field notes peer-to-peer (D8).
- **Store-and-forward like every other relay kind** (§9.3). Arrivals recorded offline post when connectivity returns; the UI is honest that it shows what has reached the device.

**Timestamp display is an Author option per trip**, applied at render. The timestamp is always stored — it is needed for the recap regardless — so this is a presentation setting, not a data one.

---

## 9. Group Relay — the P9 tier

### 9.1 What it is, and what it refuses to be

The relay carries four message kinds (§8.5), all scoped to a single trip and its roster.

It **refuses** to be: cross-trip, free-form, or coercive. These refusals are P9 made concrete. A request to add a general messaging channel, a cross-trip feed, a friend graph, **or continuous position sharing** is a P9 violation and a design event, not a feature.

### 9.2 Peer-to-peer within the roster, no Author relay required

Field notes and arrivals post **peer-to-peer within the trip roster** — the Author may be riding and unreachable, so routing everything through the Author would defeat the purpose. The Author is a recipient like any other, with the added power to curate a note into the canonical plotline (**FR56b/O8**) or dismiss it for the group.

### 9.3 Delivery and the offline reality

Members are frequently offline mid-ride. The relay is **store-and-forward**: published offline, held by the Sync Agent, posted when connectivity returns. The UI is honest that it shows what it has, not necessarily everything posted this instant. This is P2 applied to messaging.

### 9.4 Near-simultaneous edits

No automatic merge (P5). Each amendment is an independent proposal; recipients Accept/Decline individually. There is no shared mutable "group route" to race over, because canonical state is the Author's plotline (P8) and amendments are layers over it. This is the structural reason the group feature needs no conflict-resolution UI.

---

## 10. Tier 3 — Flutter Client *[AMENDED v2.0]*

### 10.1 Layering

```
┌──────────────────────────────────────────────┐
│ Presentation — screens, widgets, HUD,        │
│                curation workspace ★          │
├──────────────────────────────────────────────┤
│ State — Riverpod providers                   │
├──────────────────────────────────────────────┤
│ Domain — Trip, Day, Passage, Anchor ★, Role ★│
│          WeightProfile, RiderProfile,        │
│          FieldNote, Amendment,               │
│          RevealState ★, Arrival ★,           │
│          AuthorNote ★, RosterEntry ★         │
│          (pure Dart, no I/O)                 │
├──────────────────────────────────────────────┤
│ Data                                         │
│  ├── RoutingClient    → HTTP (local|hosted)  │
│  ├── CurationClient ★ → HTTP, layer/POI only │
│  ├── RevealResolver ★ → P11, one gate        │
│  ├── TripRepository   → drift (local) + sync │
│  ├── FieldRuntime     → offline GPS engine   │
│  ├── GroupRelayAgent  → §9, store-and-forward│
│  ├── PluginRegistry   → §13                  │
│  └── SecureStore      → integration tokens   │
└──────────────────────────────────────────────┘
```

**Which domain classes are payload and which are not** (extending SPIKE-20's finding): `Trip`, `Day`, `Passage`, `Anchor`, `Role`, and `WeightProfile` deserialize from `trip.payload`. `RiderProfile` is account-scoped. `FieldNote`, `Amendment`, **`RevealState`, and `Arrival`** are **layers over the canon** (P8) with their own tables and write paths — a reveal can never live inside the trip blob, exactly as a field note cannot. **`RosterEntry`** is trip-scoped and Character-visible. **`AuthorNote` is neither canon nor a layer**: it is about a person rather than a trip, account-scoped, cross-trip, and has **no Character-facing read path in any state** (P8, P11).

**`CurationClient` is deliberately separate from `RoutingClient`**, though both are HTTP facades over the same service. They have different readiness dependencies (§8.3): curation needs layers ready, routing needs elevation ready. One client would make that distinction invisible at the call site and re-couple the two — which is B1 reintroduced through the client instead of the sidecar.

**Orphan detection and the stale list are Presentation and State concerns, not core ones** (§7.10). Detecting which anchors fall inside days about to be removed is a traversal of the payload the client already holds; the core never learns that an edit happened. **The stale list is its own surface, separate from the shared error surface** (D53).

**`RevealResolver` is the P11 gate** and sits in the Data layer beside the repositories, because that is where every content path passes. Presentation must never read `Role.content` directly. **This is the single highest-value lint or architecture test in the v2.0 client** (§15.3).

**`RoutingClient` is still the linchpin** — base URL only, and any `if (kIsWeb)` above the Data layer is a design smell. **`FieldRuntime` is still the second pillar**, sitting beside `RoutingClient` rather than behind it, because the field experience must run with the sidecar dead and the network gone.

### 10.2 Storage, by platform *[AMENDED v2.0]*

| Platform | Trips | Reveal / arrivals ★ | Tiles / elevation / audio / **candidates** | Tokens |
|---|---|---|---|---|
| Desktop | drift (SQLite) | drift | App-support dir | OS keychain |
| Mobile | drift (SQLite) | drift | App-support dir | Keychain / Keystore |
| Web (signed-in) | Server (Postgres) | Server | Browser HTTP cache | Session cookie |
| Web (guest) | IndexedDB | IndexedDB | Browser HTTP cache | — |

One `TripRepository` interface, multiple implementations; sync is a property of the implementation, so guest mode cannot accidentally sync. **The candidate cache is Desktop/Mobile only** — Web curation reads from the hosted service per request, since a browser is not the right home for a bbox-scale candidate set.

### 10.3 The Web session and the custom domain

Web's signed-in session is an `HttpOnly; Secure; SameSite=Lax` cookie scoped to a shared parent domain:

```
app.<domain>   →  Flutter Web static build
api.<domain>   →  plotlines-service (hosted mode)
cookie: Domain=.<domain>; HttpOnly; Secure; SameSite=Lax
```

**Why a custom domain is architectural, not cosmetic.** `SameSite` is evaluated on the registrable domain (eTLD+1). Render's `*.onrender.com` hostnames are on the Public Suffix List, making `onrender.com` an eTLD — so `app.onrender.com` and `api.onrender.com` are cross-*site*, the session cookie becomes third-party, and it is **silently blocked by Safari and Firefox while working in Chrome**. A custom domain makes it first-party and **deletes the entire CORS-credentials surface**.

A custom domain is a prerequisite for the Web milestone; Safari and Firefox verification is a release exit criterion. **Rejected:** a Bearer token in web storage (XSS-readable). **Fallback:** serve the Flutter Web build from FastAPI itself — one origin, same-site by construction.

**The same domain carries magic-link sender reputation (SPIKE-13).** The magic-link email sends from `login@<domain>` on this same registrable domain, with SPF, provider-published DKIM, and a DMARC policy ramping `p=quarantine`→`p=reject`. So the custom-domain decision is made once for two purposes — the first-party session cookie and transactional-email deliverability — not twice. SPIKE-13 also found magic-link-only is not safe as the *sole* path (ARCH D9): K1 ships with an in-product re-send (link TTL ≥ 15 min, to outlast greylisting), an identity-checked support-issued-link runbook, and delivery-webhook telemetry. Provider: Postmark, dedicated transactional stream (SES is the documented alternative, but its multi-week IP warmup makes it a schedule commitment rather than a late swap-in).

**v2.0 adds a second Web surface with a different auth shape:** the Character-facing reading view (`GET /read/{share_token}`, FR132) is **share-token-authorized, not session-authorized**, so a Character can read a journey without an account. Sharing a token is not sharing a session — the token grants read access to one trip's reveal-filtered content and nothing else, and is revocable (`DELETE /shares/{token}`).

**How the token is carried, and what an accountless reader is served, are settled by SPIKE-F (#175) and recorded as D59** (closing Q17, amending A26). The token is **not left in the URL**: `GET /read/{share_token}` exchanges it once for an opaque `__Host-pl_read` cookie (`HttpOnly; Secure; SameSite=Strict`, `Max-Age` = token TTL) and 302-redirects to a tokenless `/j/{opaque}`; SPIKE-F measured a path- or query-carried token leaking into the access log *and* into every subresource's `Referer`, while a URL fragment removes it from the wire but not from browser history or a copied link. Reading-view responses carry `Referrer-Policy: no-referrer`. The anonymous reader is resolved as a Character with a **permanently empty revealed set** — held plot points render as a withheld placeholder that keeps the arc stage but not the content (FR116), hazards and provisions unconditional — and the projection takes no identity argument, so there is no trusted-reader path (A22). Access logs for an accountless reader are two-tier: edge/CDN ≤72 h operational only, application logs written through a field allowlist (route template, no token, no `Referer`, no cookie, client IP truncated to /24) ≤30 d.

### 10.4 The usability foundation *[NEW v2.0]*

PRD FR142 adds four clauses that are **entirely client concerns** — the core learns nothing about any of them.

**Undo is a bounded ring of payload snapshots, not a command stack.** This is unusually cheap here and the reason is D28: `trip.payload` is already **one canonical, serializable blob with a deterministic form** — sorted keys, compact separators, fixed polygon winding. Undo is therefore `List<String>` with a cap, not inverse operations per feature. Most applications cannot do this; Plotlines already did the hard part for a different reason.

Three boundaries:

- **Session-scoped and cleared on trip close**, and **the app says so** rather than implying permanence.
- **Covers authored work only.** Derived work is not undone but **re-solved**, because re-solving is idempotent — there is nothing to reverse (§7.10, D52).
- **Excludes anything already destroyed elsewhere.** `author_note` deletion is a hard delete with a tombstone (§11.7, D51) and is **irreversible by design**; it must not appear in the undo stack, and the point-of-deletion confirmation says so.

**Reachability is a rule, not a feature** (FR142b). Every object type ships with a named path to it. The other three clauses are built once; this one is checked forever, and it is the clause that prevents another unattached-anchor hole (§4.2, PRD Q2).

**Accessibility targets WCAG 2.2 Level AA** — the current W3C Recommendation, also ISO/IEC 40500:2025 — applied through **platform accessibility APIs** rather than as web criteria: Flutter `Semantics`, VoiceOver/TalkBack, dynamic type, reduced motion, platform contrast. WCAG 3.0 is a Working Draft and is **not** the target; its Bronze level approximates 2.2 AA, so meeting AA now is the head start rather than a detour.

**AA is a floor, not a ceiling.** The field surfaces exceed it deliberately — oversized glove-friendly targets (FR52) and outdoor contrast modes (FR79) exist for a physical constraint WCAG has no concept of, namely direct sunlight on a bar-mounted phone.

**At MVP this is a design-review checklist, not a release gate** (D56). A formal audit is **Leg 6.75 — a gate before any expansion beyond the Author desktop** (FR142a), because every added surface multiplies remediation cost and the desktop authoring client is simultaneously where an Author spends the most time and where **nothing currently specifies keyboard navigation, screen-reader semantics, or focus management**.

### 10.5 Display preferences and size classes (FR79)

Size class derives from **viewport at runtime**, not platform identity. Each class holds its own layer set; first entry to an unused class seeds from that class's default. Contrast defaults per surface (Mobile→Outdoor, Desktop→Indoor) with a synced manual override.

---

## 11. Data Architecture *[AMENDED v2.0]*

### 11.1 Postgres schema (hosted mode only)

```
account(id, created_at)
  -- no password column (absent, not unused)
  -- magic-link email is transient, never stored

session(token_hash, account_id → account, expires_at, revoked_at)

trip(id, account_id → account, name, version, updated_at,
     payload JSONB, schema_version, deleted_at)
  -- version = the FR59 comparison key: monotonic int, bumped on write
  -- schema_version ★ NEW — the payload schema revision (§11.6, D38)
  -- payload = the CANONICAL plotline (P8): passages, days, transitions,
  --           weight profiles, ANCHORS + ROLES, arc, sets, reveal
  --           dispositions, station activities, trip bbox, hazards

share(token_hash, trip_id → trip, created_at, revoked_at, expires_at)
  -- v2.0: also authorizes the read-only web journey view (FR132, §10.3)

rider_profile(account_id → account, fields JSONB, updated_at)

-- ★ NEW v2.0 — Author-private, and the inverse of the reveal boundary
author_note(id, author_account_id → account, subject_account_id → account,
            body TEXT, created_at, updated_at)
  -- Scoped to (Author, Character), NOT to a trip: the knowledge is about the
  --   person and persists across trips (FR135, D-N).
  -- updated_at is DISPLAYED, small, beside the field — a three-year-old claim
  --   about someone's climbing is worse than none if its age is invisible.
  -- Reachable by exactly one account_id. There is no read path for the subject,
  --   no path into trip.payload, and no path into any Character-facing surface.
  -- HARD DELETE only (FR135a). No soft-delete column, deliberately — see §11.7.

roster_entry(trip_id → trip, account_id → account,
             group_label TEXT, subgroup_label TEXT,
             overrides JSONB,          -- per-day / per-passage assignment
             created_at)
  -- ★ Group lives HERE, not on rider_profile: a person is in different groups
  --   on different trips, and a profile field would follow them onto the next.
  -- Character-VISIBLE, unlike author_note.

profile_request(id, trip_id → trip, requested_fields TEXT[],
                requested_permissions TEXT[], created_at)
  -- ★ requested_permissions: arrival visibility (FR123) and any future
  --   consent of the same shape. Requesting never grants.

profile_grant(id, owner_account_id → account, trip_id → trip,
              granted_fields TEXT[],
              granted_permissions TEXT[],   -- ★ allowlist, same discipline
              volunteered_fields TEXT[],
              created_at, revoked_at)
  -- Empty arrays = nothing shared. This is the DEFAULT.
  -- No "share all" flag — only enumerated lists.

-- Group relay (P9) — trip-scoped layers over the canon (P8)
field_note(id, trip_id → trip, author_account_id → account,
           anchor_lat NUMERIC, anchor_lon NUMERIC,
           body TEXT, created_at, curated_at, dismissed_at)
amendment(id, trip_id → trip, author_account_id → account,
          passage_ref, payload JSONB, severity, safety_note TEXT, created_at)
feedback(id, trip_id → trip, author_account_id → account,
         target_ref, body TEXT, created_at, curated_at)
feedback_vote(feedback_id → feedback, account_id → account, value SMALLINT)

-- Per-Character layers over the canon (P8) — ★ NEW v2.0
reveal_state(account_id → account, trip_id → trip, role_ref,
             revealed_at)
  -- permanent once written; no un-reveal path exists
arrival(id, account_id → account, trip_id → trip, anchor_ref, role_ref,
        arrived_at, shared BOOLEAN)
  -- shared = whether a grant existed when it synced (§8.5).
  -- Unshared arrivals still sync for the owner's own recap (FR73).
story_choice(id, account_id → account, trip_id → trip, branch_ref,
             chosen_ref, chosen_at)
  -- FR125 — in-story choices, personal, never published to the roster
```

**Schema decisions worth defending:**

- **`granted_fields`/`granted_permissions`/`volunteered_fields` are allowlists, never denylists.** A new sensitive field or permission added later is automatically *not* shared with existing grantees. A denylist would leak it the day it ships. **v2.0 extends this discipline to permissions specifically**, because arrival visibility is the first non-profile consent and the temptation to model it as a boolean on the trip is real — a boolean is a denylist with one entry.
- **`reveal_state`, `arrival`, and `story_choice` are per-Character tables, not payload fields.** This is P8: a Character's experience of a plotline can never mutate the plotline. It is also what lets two Characters on the same trip have different reveal states, which they will.
- **`arrival.shared` records the grant state at sync time, not a live join.** A Character who revokes a grant later does not retroactively erase what the roster already saw; a Character who grants later does not retroactively publish. Both are the honest behaviour and neither falls out of a live join.
- **`trip.payload` is JSONB, group and per-Character tables are separate.** Canon and layers have different homes and different write paths.
- **`schema_version` is new and non-optional** (§11.6).

### 11.2 What is deliberately absent

- **No password column** (magic-link only).
- **No email on `account`.**
- **No guest table** (P4).
- **No analytics/telemetry tables** (P3).
- **No cross-trip social tables** (P9).
- **No passkey/credential tables.**
- **No candidate or cluster tables** ★ — candidates are a regenerable local cache (§4.2), never server state. Persisting them would make analysis output look like canon, which is P10 violated in the schema.
- **No position table** ★ — arrivals are discrete events. There is nowhere in this schema to put a position stream, deliberately.
- **No scoring of people** ★ — no cohesion, compatibility, ability-index, or rating column anywhere on `roster_entry` or `author_note`. Group-dynamics knowledge is prose (`author_note.body`) and arrangement (`roster_entry.group_label`). There is nowhere in this schema to put a number describing a person to other humans, deliberately (PRD D-N).
- **No soft-delete on `author_note`** ★ — FR135a requires deletion to remove data rather than flag it hidden. A `deleted_at` column would make "delete" a lie, and this is the one table where that matters most.

### 11.3 Local schema (drift, Desktop/Mobile)

```
trip(id, name, version, updated_at, payload, schema_version, modes,
     dirty, server_version)
  -- dirty: changed since last successful sync?
  -- server_version: input to FR59's check
  -- modes: denormalized for G2a's list (SPIKE-20)

field_capture(id, trip_id, kind, anchor, body, media_ref, private, synced)

pending_relay(id, trip_id, kind, payload, created_at)
  -- store-and-forward queue for §9.3; kind now includes 'arrival'

reveal_state(trip_id, role_ref, revealed_at, synced)      -- ★ NEW
arrival(id, trip_id, anchor_ref, role_ref, arrived_at, shared, synced)  -- ★ NEW
story_choice(id, trip_id, branch_ref, chosen_ref, chosen_at, synced)    -- ★ NEW

author_note(id, subject_account_id, body, created_at, updated_at, synced)  -- ★ NEW
  -- Author-private (FR135). Not trip-scoped; persists across trips.
  -- Hard-deleted, never flagged (§11.7). No Character-facing read path exists.
roster_entry(trip_id, account_id, group_label, subgroup_label, overrides, synced)
pending_delete(id, kind, target_ref, requested_at)   -- ★ tombstone queue (§11.7)
  -- The first DESTRUCTIVE sync operation. Without an explicit delete record,
  --   a device that never learned of the deletion resurrects the note on
  --   next sync — resurrecting data someone asked to have removed.
```

`payload` is TEXT holding the same canonical JSON as §11.1. Two rules SPIKE-20 measured:

- **List surfaces project columns; they never `SELECT *`.** drift's `select(trips)` returns the payload with every row: **137 ms** for 20 week-scale blobs against **1.0 ms** for an `id`/`name`/`updated_at` projection.
- **`dirty` is about sync, not staleness.** A passage whose authored inputs changed carries `solve.stale` **inside** the payload (D30). **v2.0 widens `solve.stale`'s reach** (D52): it now covers every class of derived work an edit can invalidate — routes, cue sheets, planning metrics, elevation profiles, and distance-based day splits — rather than routes alone. This is a **reach change, not a mechanism change**, which is the point: PRD FR140's staleness model needed no new machinery.

**v2.0 adds a third:** **reveal, arrival, and choice tables are written by the Field Runtime with no network and no sidecar**, so they must be cheap and crash-safe. A reveal that fires and is not durably recorded before the app is killed re-fires next session, which spoils nothing but does replay narration — annoying rather than harmful, and worth a synchronous write.

### 11.4 The version-check protocol (FR59)

```
ON OPEN
  local.server_version  vs  GET /trips/{id}/version
    ├── equal        → proceed
    └── server newer → PROMPT: keep both (save-as) | take server copy

ON SAVE  ← the check most implementations omit
  re-probe /trips/{id}/version immediately before PUT
    ├── unchanged since open → PUT, bump version
    └── changed since open   → PROMPT (same two choices)
```

Two devices can open the same version, both pass the open-check, then both save — an open-only check lets the second write silently destroy the first. Implemented as a conditional write (`PUT` carrying the expected version; `409 Conflict` if it moved) so check and write cannot race.

**v2.0 note:** per-Character layers (`reveal_state`, `arrival`, `story_choice`) are **append-only and owner-scoped**, so they do not participate in this protocol at all. There is no conflict to resolve — two devices belonging to the same Character converge by union. This is a direct benefit of keeping them out of the payload.

### 11.5 Stock Postgres now; PostGIS is a gated upgrade

The hosted database is **stock PostgreSQL** — no PostGIS at MVP. It holds the canonical trip as JSONB, brokers auth, and relays trip-scoped messages. All genuinely geospatial work happens in `plotlines-core` or the Field Runtime, **never in SQL** (P1).

**v2.0 checked this against the curation tier and it holds.** Co-location analysis (§4.4) runs in the core over a local extract, not in SQL — the database never sees a candidate. Field-note and arrival proximity is computed client-side by the Field Runtime, which already holds the route.

**The trigger is unchanged:** *"a spatial query needs to run in SQL, server-side."* The most likely first occurrence remains a **push-based group relay** (Q6): if the server must decide who is near a note in order to notify them, that is `ST_DWithin` with a GiST index. Enabling PostGIS on Render is one line on a paid instance, so committing to stock Postgres now costs nothing later.

### 11.6 Payload schema versioning *[NEW v2.0]*

**The v2.0 model is not an additive edit to `trip_payload.schema.json`.** Anchors and roles replace an undifferentiated node; geometry gains polygons; arc moves onto passages; reveal dispositions and station activities are new; the trip bbox is new. A v1.0 payload does not validate against the v2.0 schema.

Three rules, and the first is the one that gets skipped:

- **`trip.payload` carries `schema_version`, and so does the drift row.** A payload without one is v1. Without this field, a v1 payload silently fails to deserialize in a way that reads as corruption rather than as a version mismatch.
- **Migration is forward-only and explicit.** A v1 payload's nodes migrate to anchors with a single role inferred from their type (POI/waypoint → narrative or provision), reveal defaulting to always-visible so nothing is accidentally hidden by a migration. Arc tags migrate onto anchors; passages start with no arc.
- **The schema still wins over any implementation** (D28), and canonical form (sorted keys, compact separators, `allow_nan=False`, `null` never written, SI units, `[lon, lat]` at 7 dp) is unchanged — **including for polygons**, which must serialize in a fixed ring order and winding so the content digest stays stable across Python and Dart.

**Dates and times are canonical too, and this is new in v2.0.** PRD FR79 adds a user-facing time and date format preference that **inherits the device's settings by default with explicit overrides**. That preference is a **render-time transform and nothing else**: `trip.payload`, every export, every filename, and the content digest carry **ISO 8601 only**. A display format that reaches stored or exchanged data reintroduces the ambiguity ISO exists to remove — `01/02/03` meaning three different days depending on who wrote it — and would make the digest depend on who was looking. `inherit` also resolves at render time rather than being frozen at install, so the setting syncs while its resolution stays per-device.
### 11.7 Deletion is the first destructive sync operation *[NEW v2.0]*

Everything the Sync Agent does today is **create-or-update**: trips, profiles, field captures, reveal state, arrivals, choices. FR135a introduces the first operation that **removes data and must propagate that removal**, and it needs a verb the sync layer does not currently have.

Four requirements, and the first two are where a naive implementation goes wrong:

- **Hard delete, not soft.** FR135a requires the data gone, not flagged hidden. There is deliberately no `deleted_at` on `author_note` (§11.2) — a soft delete would make the confirmation dialog a lie, on the one table where honesty is the entire point.
- **Deletion is a tombstoned operation in the sync queue, not an absence.** A device that never learns of a deletion still holds the note, and a naive union-merge would **resurrect it on next sync** — the classic distributed-delete failure, and here it resurrects data a person asked to have removed. The queue carries an explicit delete record; the tombstone itself is prunable once every known device has acknowledged.
- **An offline device completes the deletion on reconnect** (FR135a), including the cascade case where `DELETE /records/subject/{id}` removed notes across many trips.
- **Scope is computed and shown before confirmation**, not after. "This removes 14 notes across 4 trips, going back to 2024" is the difference between an informed action and an unrecoverable accident.

**No other data class gets this treatment yet**, and that is a deliberate boundary rather than an omission: notes are the only data Plotlines holds *about* a person *by someone other than that person*, which is what makes deletion an obligation here and merely a convenience elsewhere.

### 11.8 Clone semantics — an enumerated copy, not a deep copy *[NEW v2.0]*

PRD FR74 specifies what a clone carries. The distinction is a **schema-level** one, not a UI one, and the temptation to implement it as a deep copy of everything trip-scoped is exactly the bug.

| Copied | Not copied |
|---|---|
| `trip.payload` in full — bbox, layers, anchors, roles, reveal settings, passages, days, arc | **`profile_grant`** — grants **and** granted permissions |
| `roster_entry` — membership, group, sub-group | `reveal_state`, `arrival`, `story_choice` |
| *(`author_note` needs no rule — it is keyed to `(author, subject)`, not to a trip)* | `field_note`, `amendment`, `feedback` |

**`profile_grant` is the clause that matters, and it is a hard exclusion.** FR78 makes sharing per-trip and revisable *by design*; copying grants would make cloning a **consent-laundering path** — a Character who disclosed a medical condition for last year's supported tour would silently be re-sharing it on this year's different trip, having done nothing. Every Character re-grants per trip.

**Clone has a selectable scope** (FR74b): whole trip, roster only, authored trip only, or per-part. The allowlist above is the *whole-trip* scope; narrower scopes copy a subset of it. **The grants exclusion holds in every scope — there is no scope in which consent is inherited.** Two scope-specific rules: where a scope drops people, **everything keyed to them drops with them** (group assignments, shared gear, meal responsibilities) rather than being left as dangling references; and a **roster-only clone has no trip content, so it runs trip initiation normally** — location prompt, bbox, and mode declaration (FR96, FR120, FR144) — since there is nothing to inherit them from.

Two implementation notes follow. **Enumerate what is copied rather than excluding what isn't** — an allowlist, the same discipline as `granted_fields` (§11.1), so that a table added later is *not* copied by default. And **`author_note` coming along for free is a consequence of D50's scoping**, not a rule anyone wrote — useful confirmation that scoping notes to the person rather than the trip was correct.

**Travel circles (FR143) are Later and deliberately not schema'd here.** When built, a circle is a **living list** of accounts with its own table; a trip's `roster_entry` rows are **materialized from it at trip creation and are thereafter independent**, because a roster in flight carries grants, group assignments, and gear responsibilities that must not shift underneath an Author. A circle change **offers** itself to upcoming trips; it never propagates silently. Circles carry membership only — never grants, per the clause above. Noted now so nothing is designed that would make materialization awkward later.

---

## 12. External Integrations *[AMENDED v2.0]*

All follow P7: fetch once, cache with a volatility-matched TTL, never re-request what is held.

| Service | Used for | Cache TTL | Attribution |
|---|---|---|---|
| **Elevation** — GEDTM30 via OpenTopography (free tier 50 calls/24h — FR87, D20) | Elevation enrichment | Long | **CC BY — required** |
| **Basemap tiles** — Protomaps Basemap (OSM-derived, PMTiles extracted per bbox, mirrored — D23, FR95) | Map rendering | Long | **Required — ODbL.** `© OpenStreetMap` |
| **Weather** (Open-Meteo) | Historical + forecast | Forecast short, historical long | **CC BY 4.0 — required** |
| **Geocoding** (Nominatim via OSMnx) | Location search | Medium | OSM / ODbL |
| **OSM Overpass** (via OSMnx) | Graph + **candidate layers** ★ | Long | OSM / ODbL |
| **USGS 3DHP** (waterway network, layer **50** `Flowline`; D27) | Paddling graph | Long | US public domain |
| **USGS Water Data APIs + NLDI** | Gauge readings, gauge→reach | Values short, linkage long | US public domain |
| **Plugin data layers** ★ (FR100) | Candidate layers for curation | Per-layer, declared | **Per-layer, declared and enforced (§12.2)** |

**Paddling class ratings have no source** — Author-declared, not fetched (SPIKE-04).

**Operational notes that cost an afternoon each if rediscovered rather than read:** 3DHP flowlines are **layer 50** (layer 1 returns HTTP 500 with body `json`, which reads like transport failure), and **`featuretypelabel` must never be used to filter for real water** — every major paddling river tested is typed `Waterbody Connector`. Filter on `streamorder`. **Migration scheduled:** USGS WaterServices is decommissioned Q1 2027; build against `api.waterdata.usgs.gov` from the first line of code.

**v2.0 adds substantial OSM load.** Candidate extraction pulls far more tag classes over a trip bbox than graph building alone. Two mitigations, both already established patterns: extraction reads from the **same bbox-scoped on-demand cache** as tiles and elevation (§4.2), and — per §13.2's rule for `WaterwayDataProvider` — it should read from a **local extract rather than the public Overpass instance** wherever a region is used repeatedly. SPIKE-04 §8 could not complete a single region's pull from public Overpass without tiling and retries; candidate extraction is a heavier query than that one.

### 12.1 Elevation cache — the two-phase model

```
Phase 1 (MVP)   each device / Web / Guest → elevation provider directly
                ⚠ free-tier daily ceiling is a hard wall; EXPLICITLY DISPOSABLE

Phase 2 (later) device → hosted cache → (miss) → elevation provider
                ✅ one fetch serves everyone
```

The client talks to elevation through the **same interface** in both phases (PRD M3), so Phase 2 changes a base URL and a cache-lookup step, not the client. Build the indirection from the first milestone.

### 12.2 Attribution is a build artifact *[AMENDED v2.0]*

CC BY and ODbL sources require attribution wherever their data appears: a visible credit in the app's info surface, and attribution embedded in exported files where the format permits. **A missing attribution is a build failure, not a polish item.**

**v2.0 makes this harder in a way that needs a mechanism, not discipline.** A plugin ecosystem (FR100) means arbitrary third-party datasets with their own terms flowing into exports and **printed** cue sheets. Attribution can no longer be a fixed list compiled into the About surface.

Three rules follow:

- **Every layer declares its licence and attribution in the data-input contract** (FR101, §13.2). A layer whose licence metadata is absent or unsatisfiable **does not load** — refused at registration, not warned about at render.
- **Attribution is derived from the loaded layer set at render time**, not hardcoded. The About surface, exports, and print all enumerate what is actually in use.
- **The build check becomes dynamic too.** The release gate is no longer "does the About surface contain these three strings" but "does every loaded layer's attribution reach every surface that displays its data." **This is the one place v2.0's plugin decision creates real ongoing cost**, and it is a licence obligation rather than a preference.

### 12.3 Offline package size (FR64) — a real budget *[AMENDED v2.0]*

Plotlines' offline package is heavier than CTP's ever was: routes + basemap buffer + narration audio + node media, across multiple modes. **v2.0 adds unrevealed content**, which ships with the package because reveal must work in airplane mode (FR64a, P11).

That addition is modest for text and meaningful for media: an Author who authors ten revealed plot points with audio ships all ten regardless of what a Character will reach. SPIKE-10 measures a realistic multi-day package; the buffer-distance control (FR35) and download UX may need tiering depending on the result.

**Note the distinction from the trip bbox.** The authoring bbox (FR120) is large and lives only on the Author's machine, bounding candidates, tiles, and elevation for planning. The Character's package is bounded by the **corridor buffer** around the finished route (FR35/FR64). Conflating them would have Characters downloading a county to ride a corridor — see D41.

---

## 13. Distribution, Updates & the About Surface

### 13.1 Desktop is two artifacts, not one

The desktop app is the Flutter client **plus** the frozen Python sidecar binary. Any update mechanism must treat them as a **single versioned unit** — a mismatched pair produces platform-divergent routes (A8).

- **Client and sidecar versions are pinned together and checked at runtime** via `/health` (§8.3). The app refuses to run a mismatched pair and fails honestly. **Per-capability readiness does not change this** — readiness is about *what is warm*, compatibility is about *whether the pair is valid*.
- **An update never clobbers a running sidecar.** The updater hooks into §8.4's lifecycle rather than inventing its own.

### 13.2 Delivery model — manual releases for MVP, seam for later

| Model | Cost | Fit |
|---|---|---|
| **Manual download + install** ✅ **MVP** | Near zero; keeps client+sidecar in lockstep inherently | The right MVP answer |
| **In-app update check** | A static version manifest + a prompt | The natural next step |
| **Full auto-update (silent)** | Code signing, update feed, delta patching for a 150–300 MB binary | **Not MVP** |

**The seam to build now:** the app knows its own version and treats client+sidecar as one pinned unit from day one.

### 13.3 Code signing is not optional

Unsigned desktop apps hit Gatekeeper and SmartScreen warnings. SPIKE-00 sharpened where that bites on Windows: SmartScreen gates *shell* launches, not `CreateProcess`, so the **spawned sidecar is unaffected even unsigned and carrying Mark-of-the-Web**. The exposure is the installer, which is the artifact that must be signed. An Apple Developer account (with notarization) and a Windows code-signing certificate are **costs to budget from the first public release**.

### 13.4 The About surface *[AMENDED v2.0]*

| Element | Status | Notes |
|---|---|---|
| **Data attribution & licenses** | **Required, all platforms** | CC BY (elevation, weather), ODbL (basemap, OSM), **and every loaded plugin layer's own terms (§12.2)** — enumerated dynamically, not hardcoded. Build failure if absent. |
| **App + sidecar version** | **Strongly wanted** | Needed for A8 debugging; matches `/health`. |
| Release notes | Optional | A linked `CHANGELOG` suffices for MVP. |
| **Privacy statement** | **Required, all platforms** ★ | **Elevated from optional in v2.0** (FR138). Reachable from About on **every** surface including Web guest and the share-token reading view (§10.3), which reach people who may have no account at all. States plainly: what is on the device vs. the server; that **reveal is a product guarantee, not a security boundary** (FR64a); what arrival sharing does and does not do, defaulting to nothing shared; **that an Author may keep private notes about Characters, visible only to that Author, persisting across trips, deletable on request** (FR135, FR135a); that guest sessions leave no server-side trace (P4); and — added by SPIKE-F / D59 — **what a reader with no account leaves behind on the share-token reading view**: a short-lived operational log line (no account, no name, IP truncated), edge/CDN logs kept ≤72 h and application logs ≤30 d, and the share link carrying no readable token after first load. **Author notes are what made this required** — they are the first data Plotlines holds *about* a person *by someone other than that person*. Not legal boilerplate; it says what is true, briefly, in the app's voice. |
| Support / general info | Optional | Contact or docs link. |

**The "wherever the data appears" nuance:** attribution must be *reachable* on the lightest surfaces too — Web-guest, and **the new share-token reading view (§10.3)**, which displays basemap and elevation data to someone who may have no account at all. A footer link suffices; omission does not.

---

## 14. Plugin Architecture *[AMENDED v2.0 — breaking, B4]*

**Prior reading (v1.0): both plugin directions were Leg 7, with the interface deliberately not locked.**

That was defensible when plugins were an enhancement. It is not defensible now: **plugin datasets are the substrate the layer picker (FR97) and co-location analysis (FR102) read.** The contract's shape is determined by what those two surfaces need from a feature. Deferring it does not leave it open — it leaves the core loop's input format undesigned while everything above it is built on assumptions.

**v2.0 splits the two directions across two legs.**

### 14.1 Two directions, two legs

| Direction | Runs in | Leg | Why |
|---|---|---|---|
| **Data input** (POI layers, historical markers, battlefields, traffic, trail/water conditions, paddling network) | **Python (`plotlines-core`)** | **2.5 ★** | Feeds candidate extraction and the routing graph. This is also how uncertain multimodal data enters. |
| **Output** (Garmin, Coros, Wahoo, RideWithGPS) | **Flutter (Dart)** | 7 | Holds the user's OAuth token; must reach the vendor API from the device. Routing it through the server would make the service a credential custodian for every user. |

### 14.2 Python-side provider interfaces

```python
class EdgeDataProvider(Protocol):
    def annotate_edges(self, graph: Graph, bbox: BBox) -> Graph: ...

class NodeDataProvider(Protocol):
    def fetch_nodes(self, bbox: BBox, categories: list[str]) -> list[Node]: ...

class ShapeDataProvider(Protocol):
    def fetch_shapes(self, bbox: BBox, kinds: list[str]) -> list[Shape]: ...

class WaterwayDataProvider(Protocol):
    def fetch_waterways(self, bbox: BBox) -> WaterwayGraph: ...

class LayerProvider(Protocol):                      # ★ NEW v2.0 — FR100
    """A curation data layer: candidates for the pipeline (§4)."""
    @property
    def licence(self) -> LayerLicence: ...          # FR101 — required, enforced
    @property
    def taxonomy(self) -> TypeTaxonomy: ...         # each type declares a PRIMARY
                                                     #   role affinity + a salience
                                                     #   weight (FR100, FR105, D47)
    def fetch_candidates(self, bbox: BBox) -> list[Candidate]: ...
                                                     # point AND area geometry
    def load_state(self) -> LayerLoadState: ...     # per-layer readiness (§8.3, D34)
```

**`ShapeDataProvider` already existed and is the reason area support is an extension rather than a rewrite.** v1.0's PRD scoped areas out; this document's provider layer never did. That is a case of the architecture being more right than the requirements, and it is worth noticing: the seam survived a requirement that contradicted it.

**`LayerProvider` is new because `NodeDataProvider` is not sufficient.** A curation layer must supply four things a node provider does not: a **licence** (enforced at registration, §12.2); a **taxonomy in which every type declares a primary role affinity and a salience weight** (§4.3, §4.4, D47); **both point and area geometry** in one call; and **its own load state**, since a remote dataset must not block the workspace (§8.3). Bolting these onto `NodeDataProvider` would break every existing implementer.

**Affinity is what makes §4.4 generic rather than recipe-driven, and it is the difference between plugins working and plugins silently not working.** Without a declared affinity, co-location analysis can only propose role sets for tuples someone thought to enumerate: a plugin brings `battlefield` and `manor_house`, the analysis finds the cluster correctly, and proposes nothing. **Affinity is single-valued with Author override at promotion** — a layer author declares one thing per type rather than reasoning about a matrix, and an Author is not made to adjudicate detail irrelevant to their story.

**The core's own OSM lookups implement these same interfaces** — which is the proof the interfaces are real. **v2.0 extends this test to `LayerProvider`:** the built-in OSM sightseeing/amenity/natural/historic layers must be expressed *as* `LayerProvider` implementations, not as a privileged internal path. If they cannot be, the interface is wrong, and we learn it at Leg 2.5 rather than at Leg 7.

**That test ran — SPIKE-H (#160), 2026-08-28 — and the contract holds.** The real `OsmLayerProvider` and `TAXONOMY`, wrapped in the shape above, produced **290 real candidates across all six built-in layers**, and two real, unlike external sources (NPS and NC Highway Historical Markers, live ArcGIS MapServer REST) implemented the same protocol with no core special-casing. `load_state()` was exercised against a genuine upstream failure — a real `404 Layer not found` reported as `failed:…` with **every other layer, built-in and plugin, unaffected** — which is the §8.3 behaviour the shipped app currently inverts. **One bend is recorded rather than fixed:** `fetch_candidates(bbox)` takes no `layers` argument, so read literally it wants six provider instances, while `OsmLayerProvider` answers all six layers in **one** Overpass call regardless of how many are asked for. A shared-fetch wrapper reconciles the two. This is an artifact of the built-in source being batched, not a defect in the protocol — a real plugin is one dataset and one provider, and never meets it. See `spikes/SPIKE-H/results/RESULTS.md`.

**The shipped `providers.py` does not implement this contract yet, and that gap is load-bearing.** `core/plotlines_core/curation/providers.py` collapses `licence -> LayerLicence` to `licence: str`, drops `taxonomy` and `load_state()`, and replaces `fetch_candidates(bbox) -> list[Candidate]` with a multi-layer `fetch(bbox, layers) -> list[RawFeature]`. Because that signature returns a bare list, per-layer state and per-layer failure have nowhere to live — which is the direct cause of one failing layer returning 422 for the whole extraction (§8.3). **SPIKE-H validated the contract above as the target; reconciling `providers.py` with it is story N2**, and `spikes/SPIKE-H/` carries a working prototype of the reconciled shape against real upstreams.

**`WaterwayDataProvider` implementation notes (D27, SPIKE-19).** Implement against USGS 3DHP (network) and USGS Water Data APIs + NLDI (gauge, reach linkage), not OSM. `WaterwayGraph` edges need **two join keys — `mainstemid` and a reach code** — because measured over 112 real-time gauges in three regions, `mainstemid` binds 77.8% and a reach code 80.6%, they fail on *different* sites, and together reach 94.4%. `mainstemid` is a geoconnex.us URI in **two disjoint registries** (0 of 933 ids overlap) — match the full URI, never normalise the prefix. Topology comes from `hydrosequence`/`dnhydrosequence`, built by **inverting `dnhydrosequence`** (one-to-many at confluences); `uphydrosequence` names only the main path and would silently drop every tributary.

### 14.3 Dart-side output interface

```dart
abstract class OutputIntegration {
  String get id;
  String get displayName;
  Future<void> authenticate();          // OAuth, token → SecureStore
  Future<void> pushTrip(Trip trip, RevealView reveal);  // ★ P11 applies here too
}
```

**`pushTrip` takes a `RevealView`.** Pushing a trip to Garmin is a content-crossing boundary exactly like an export, and it is a path nobody will think to test with unrevealed content.

This seam is for *pushing an already-built trip to a third-party service* — not for building the FIT bytes. All four file-format writers, FIT included, are in-core Python on the `export_trip` path (§7.1, D58); an `OutputIntegration.pushTrip` that needs a FIT payload calls the core writer, it does not carry its own.

Tokens go to `SecureStore` — never to drift, never to the server.

### 14.4 The boundary that must not be crossed

A plugin may not require a change to core code. If it does, the extension point is missing or wrong — fix the extension point, do not special-case the plugin.

---

## 15. Testing Strategy *[AMENDED v2.0]*

### 15.1 The routing core — golden-route tests

**Golden-route testing** is the primary safeguard: fixed inputs must produce a stable, known route. A change that alters a golden route is either a bug or a deliberate scoring change reviewed and updated on purpose — never silently.

- **Graph fixtures are committed, not fetched.** Deterministic, offline, fast, and it keeps CI off the shared commons (P7).
- **Scoring is unit-tested per factor.**
- **The two seams have explicit tests:** `weights.at(position)` in scalar and scoped cases; the elevation interface resolving identically in both phases.
- **Void and failure paths are tested.**

**v2.0 adds four core test areas:**

- **Golden candidate sets and golden clusters.** The same bbox + layer selection + ruleset version must produce the same candidates with the same salience, and the same cluster proposals in the same rank order. **This is the curation tier's golden-route equivalent**, and it is the only thing that catches a ruleset tweak silently changing what an Author is shown.
- **Compose-mode solves.** `target_distance=None` with a via-anchor set returns a route reaching every anchor and reports realized distance — and **does not emit a band violation** (§7.7).
- **Mode-legality.** A fixture region containing `bicycle=no`, a gate, and a ford must produce a passable route; `bicycle=dismount` must appear as a flagged cue rather than a silent inclusion (§7.9).
- **Reveal-aware export.** Every export format, with an unrevealed plot point present, must not contain its content. **Assert on the bytes**, not on the code path — this is the failure mode P11 exists to prevent, and it will hide in a format nobody exercises.
- **★ Author notes never appear anywhere.** The same byte-level assertion, applied to notes across every export format, print output, share link, offline package, and group-relay payload. Notes are the *never-release* class (P11), so **any appearance anywhere is a failure**, and the trip archive (FR70) is the likeliest escape route — it is the artifact an Author is most likely to hand to someone else.
- **★ No template accepts authored text.** Assert that no message template declares a slot typed as `Role.content` or any authored text field, and that reason phrases resolve from the bounded enum table rather than from call-site strings (D57). **This is the reveal-leak path the export-path byte assertions structurally cannot catch** (A30).
- **★ Clone copies the allowlist and nothing else, per scope.** Clone a trip whose Characters hold grants and permissions, then assert **on the rows**: `profile_grant` has none for the new trip, `reveal_state` / `arrival` / `story_choice` / `field_note` / `amendment` / `feedback` are empty, `roster_entry` carries membership and groups, and `author_note` is reachable without having been copied (D50, D55). Add a table to the schema and re-run: it must **not** appear in the clone.
- **★ Undo excludes what cannot be undone.** Note deletion must not enter the undo stack, and the point-of-deletion confirmation must say so (D54, D51). Undo state clears on trip close.
- **★ Stale gating on the way out.** A stale route must be viewable, **not exportable, and not printable** (D52). Assert that an export attempt yields the stale list rather than a file, that re-solve-all clears every item in one action **without a confirmation**, and that print offers no override path at all.
- **★ Orphan prompts fire on authored content only.** Removing an anchor promoted but never written to applies without a prompt; one carrying roles or content prompts with its scope (FR139). The natural bug is prompting on object *type*, which makes tidying a mis-click feel like a negotiation.
- **★ Delete propagation, including the resurrection case.** A note deleted on one device must not reappear when a second device that was offline at deletion syncs afterward (§11.7). **Test with the offline device syncing *after* the delete** — a union-merge implementation passes every other test and fails only this one, and what it resurrects is data someone asked to have removed.

### 15.2 The service — contract and lifecycle

- **Endpoint contract tests** confirm request/response shapes and — critically — that **mode-gated endpoints are not registered in the wrong mode**: a sidecar-mode instance must have no `/auth/*` or `/groups/*` routes to attack. A security property, so tested rather than trusted.
- **Sidecar lifecycle tests** exercise port-in-use, slow cold start, mid-session death and restart, and the orphan sweep after ungraceful exit.
- **★ Per-capability readiness tests** (§8.3): with elevation deliberately slow, `/health` reports layers ready and routing not-ready, and the curation endpoints answer while `/segments/generate` is still gated. **This is B1's regression test** and the thing that stops a well-meaning refactor collapsing the flags back into one boolean.

### 15.3 The client — layers, the offline guarantee, and the reveal gate

- **Domain layer is pure Dart and unit-tested directly** — including the anchor/role model and the canon/layer separation (P8).
- **The `RoutingClient` one-transport property is tested**, catching any `if (kIsWeb)` above the Data layer.
- **The offline guarantee (P2) is a test, not a hope:** the Field Runtime must advance cue state and fire triggers with the network disabled *and* the sidecar absent.

**v2.0 adds three, and the first is the highest-value test in the client:**

- **★ The reveal gate is architecturally enforced.** No Presentation-layer code may read `Role.content` directly; all access goes through `RevealResolver` (P11, §10.1). Enforce as a lint or architecture test — the same discipline as CI's `plotlines-core may not import fastapi` check (§15.5). **A code-review hope is not sufficient here**, because the violating path will be a print preview or an export corner nobody looks at twice.
- **★ Polygon triggers.** Entry into an area anchor fires once; a route running along the boundary does not re-fire (§6.2).
- **★ Reveal and arrival fire while Stowed.** With rendering suspended, a reveal still unlocks and an arrival is still recorded (§6.4, §6.7). The natural bug is wiring these to the render loop, and it fails silently for exactly the Character who pocketed their phone as designed.

### 15.4 What MVP does not need

No exhaustive UI-widget coverage, no cross-platform end-to-end automation, no load testing (the single-instance MVP is not load-bound). Field-execution and multimodal testing scale up when those features are built; a spike that proves out becomes the seed of that feature's suite.

### 15.5 CI posture

CI runs the core and service suites on every change and enforces the P1 boundary as a hard check: **`plotlines-core` may not import `fastapi`** (A7). **v2.0 adds a second such gate: no Presentation-layer import of role content outside `RevealResolver`** (§15.3). Both are the cheapest possible enforcement of a principle the design depends on.

---

## 16. Risks (Architectural)

Carried risks are abbreviated where unchanged; **v2.0 additions are A20–A25.**

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| A1 | **iOS cannot spawn the sidecar** — threatens offline generation on iOS | **HIGH** | Prototype the frozen sidecar on Android early; treat iOS as precompute-and-download; SPIKE-09 may dissolve it. v2.0 lowers the *authoring* stake (authoring is desktop-class) and raises the *execution* stake (reveal and arrivals now live in the Field Runtime). |
| A2 | **Paddling data quality** | **HIGH → partly realised** | SPIKE-04/SPIKE-19: network and gauge solid (USGS); class ratings do not exist. Provider isolation absorbed a change of national data product without touching the core. Residual is **timing**: tested regions still read `workunitid = NHD`, so re-open when elevation-derived hydrography lands. |
| A3 | **Field Runtime battery cost** | **HIGH** | Adaptive-accuracy controller (FR54a); SPIKE-07 measures the saving. **v2.0 adds reveal and arrival triggers to the same budget** — they ride the existing proximity check rather than adding a second one, but SPIKE-07 should measure with them present. |
| A4 | **Backgrounded GPS-triggered audio** may not survive screen-lock | **HIGH** | SPIKE-06 on real hardware before the field tier is committed. |
| A5 | Frozen binary (150–300 MB) stacks on heavier packages | Medium | Strip deps; budget via SPIKE-10; **v2.0 adds unrevealed content to the package** (§12.3). |
| A6 | Sidecar lifecycle bugs | Medium | §8.4's explicit protocol. |
| A7 | `plotlines-core` drifts toward web-awareness | Medium | CI lint. |
| A8 | Two core deployments drift to different versions | Medium | Version-pin; surface both in `/health`; refuse to run mismatched. |
| A9 | Phase-2 elevation-cache transition needs a client rewrite | Medium | Build the indirection from M1. |
| A10 | **Web ships on `*.onrender.com`** → sessions silently break in Safari/Firefox | Low probability, **HIGH impact** | Custom domain is a hard prerequisite; Safari *and* Firefox in the exit criteria. |
| A11 | **Group relay drifts toward a social platform** | Medium | P9 stated as refusals; **v2.0 adds continuous position sharing to the refusal list** (§9.1) — arrivals are the seam most likely to be "improved" into tracking. |
| A12 | Server-side spatial query appears without PostGIS | Low | Deployment trigger; contained change. **v2.0 confirms curation does not trigger it** (§11.5). |
| A13 | **OpenTopography free-tier limits** gate Phase-1 elevation and the "core app stays free" posture | Medium | Tracked (FR87, D20); a paid tier anywhere requires re-licensing elevation first. |
| A14 | **Desktop map stack depends on a pre-release** (`vector_map_tiles` 9.0.0-beta.11); the last stable silently drops every road | Medium | Pin the exact beta; treat a renderer upgrade as a **visual-regression event**, not a version bump. Fallback: raster tiles through the same FR92 contract. |
| A15 | ~~No basemap labels render~~ — **resolved (SPIKE-14, D24)** | Low | Plotlines-authored theme generated from the mirrored Protomaps theme. Two limits carried: `["get","name"]` is local-name-only; the `pois` layer's per-feature zoom threshold needs a static `minzoom` call. |
| A16 | **Desktop memory ~1 GB with a basemap on screen** | Medium | Budget near 1 GB; re-measure on a release build. Lever: tile-cache bounds. **Re-measured with candidates on screen (SPIKE-G, 2026-08-29): ~1.15 GB** — SPIKE-14's ~1 GB basemap client + ~3 MB for the salience-gated candidate layer at its ~2,800-candidate display ceiling + ~150 MB tile/transient headroom. **The candidate layer is not a material memory cost** under the recommended render strategy (bounded widget count + flat dot/vertex arrays); the ~1 GB basemap figure is still the number to re-measure on a release build, and **tile-cache bounds remain the lever**. |
| A17 | ~~Traffic-stress model overstates rural traffic~~ — **resolved (D33)** | Low | Rural/low-signal roads are the zero baseline; `maxspeed`/`lanes` raise stress above it. |
| A18 | **`WeightProfile` names three different structures** across PRD, this document, and `scoring/profile.py` | Medium **→ raised in v2.0** | D29 fixed what the payload stores. The conversion function still does not exist, and **compose mode now gives weights a second job** (flavouring rather than searching), so the ambiguity has two consumers instead of one. Write the mapping as one function in `scoring/` and correct §7.3's field list. |
| A19 | **Cue sheets promise surface shifts OSM tagging often cannot supply** — six across 132 km; Davis (34.4% tagged) produced none | Medium | State the limit in F1's AC; show tag coverage beside the sheet; longer term allow Author annotation. **FR4's `singletrack` class has no `surface` source at all.** |
| **A20** ★ | **Notability ruleset is unvalidated, and cluster quality depends entirely on it.** Over-filtering hides the castle; under-filtering floods the map and makes proposals noise | ~~HIGH~~ **MITIGATED** | **SPIKE-A ran 2026-08-27 (#158)** and calibrated the ruleset against NC/WI/SoCal extracts — the under-filtering failure was real (4,149 street trees in one bbox) and is fixed. Golden candidate sets (`core/tests/test_curation_golden.py`) now make a regression visible. Residual: fine salience ordering among mid-band types is a SPIKE-B tuning question. |
| ~~**A21** ★~~ | ~~**Co-location analysis cost is unmeasured** over a realistic multi-day bbox with many layers live~~ | ~~Medium~~ **MEASURED / MITIGATED** | **SPIKE-B, 2026-08-27 (#169).** ~150 ms / 1.5 MB for a real 8,800 km2 six-layer multi-day bbox; ~4 s / 16 MB for a 30k-candidate synthetic stress. Grid pre-pass (near-linear) + bounded complete-linkage. Affordable outright — the cacheable endpoint (§8.2) is headroom, not a crutch. `core/tests/test_curation_colocate.py` locks the behaviour; residual is the *salience* signal feeding the rank (flat in mountain terrain — SPIKE-A's deferred `natural=peak` prominence sub-scaling), not the cost. |
| **A22** ★ | **Reveal leaks through an untested path** — a print preview, an export format, a share sheet, a plugin push | **HIGH** | P11's single resolver; the CI gate in §15.5; **byte-level assertions on every export format** (§15.1). This is a HIGH because the failure is invisible in development and unrecoverable in the field: a spoiled trip cannot be un-spoiled. |
| **A23** ★ | **Candidate extraction depends on a public endpoint whose latency varies ×21 and which can withdraw service.** *(Mechanism corrected and severity raised 2026-08-28 — SPIKE-D.)* **Prior reading: "a heavier query than graph building" — measured backwards.** A candidate pull is **×0.43 the time and ×0.78 the bytes** of a graph build over the same bbox, and the gap widens with area (×0.12 / ×0.24 at 1,799 km²): a graph pull asks for every way with full node geometry, a candidate pull for a few tag families with `out center`. The exposure is not query weight but **throttling variance** — the identical 176 km² query took **8.8 s and 185.9 s an hour apart** — and single-endpoint dependence. During SPIKE-D one uncached multi-day pull ran **past 30 minutes without returning**, after which `overpass-api.de` **refused TCP from that host for the rest of the session**, with two mirrors at 500/502 and Geofabrik at 502/503. | ~~Medium~~ **HIGH** | **Bbox-scoped on-demand cache (§4.2) is the first mitigation, not the third** — a warm re-read is **1.75 s against 15.8 s** and is the only measurement with no run-to-run variance. Then **retry-with-backoff**, which is what every slow observation actually needs. Then **multiple endpoints, coverage-checked rather than liveness-checked**: `overpass.osm.ch` answers 200 promptly and holds only Switzerland, so a failover list ordered by liveness would silently report an Author's whole trip area as empty — the same class of silent substitution issue #154 was filed over on the routing side. **Tiling is a pessimisation below ~2,500 km², not the baseline**: extraction scales *sub-linearly* (43 s/1,000 km² at 70 km² → 8 s/1,000 km² at 8,815 km²), a tiled 2×2 was slower than whole-bbox in both runs, and osmnx already auto-splits above `settings.max_query_area_size` unasked. **Local extracts for repeatedly-used regions (§12) remain the only mitigation that removes the variance rather than absorbing it — still unmeasured.** See `spikes/SPIKE-D/results/RESULTS.md` §2. |
| **A23a** ★ | **[NEW 2026-08-28 — SPIKE-D]** **Two unbounded waits in `osmnx` are inherited by the product**, which is why A23's multi-endpoint mitigation **cannot be implemented as a URL swap**. `_get_overpass_pause` does not parse the status page — it takes **line index 4** and branches on its first word; against an instance reporting `Rate limit: 0` that line is the header `"Currently running queries (…)"`, which it reads as *the server is busy with my query*, so it sleeps 5 s and **calls itself**, forever. Observed: 20 minutes in `hrtimer_nanosleep`, 3 s of CPU, **no query ever sent**. Separately, `_overpass_request`'s 429/504 handler sleeps 55 s and recurses with **no attempt limit**, so a pull against a busy instance does not fail — it spins. `OsmLayerProvider.fetch` calls `osmnx.features_from_bbox`, which reads a single `settings.overpass_url` and goes through both. | Medium | Wrap extraction in a hard deadline so "still going" becomes a result (`spikes/SPIKE-D/common.py:Deadline` is the pattern); detect an unparseable status page and pace ourselves instead of trusting the library's limiter (`common._osmnx_can_pace`); own the endpoint list rather than inheriting a single setting. |
| **A24** ★ | **Payload schema migration.** v2.0 is not additive; a v1 payload does not validate | Medium | `schema_version` on payload and drift row (§11.6); forward-only migration with reveal defaulting to always-visible so no migration can accidentally hide content. **Test the migration against a real v1 payload, not a synthetic one.** |
| **A27** ★ | **An Author note reaches a Character.** Notes are the *never-release* class (P11) — no trigger, no state, no path — so any appearance is a leak, and of something written about a person in confidence | **HIGH** | Notes live outside `trip.payload` in an account-scoped table with **no read path for the subject** (§11.1). The §15.5 CI gate covers content access generally; the byte-level export assertions (§15.1) extend to notes, since **the trip archive (FR70) is the likeliest escape route** and is the artifact an Author is likeliest to hand to someone else. Archive inclusion is off by default and separately confirmed |
| **A29** ★ | **Clone carries `profile_grant` forward.** Deep-copying everything trip-scoped is the obvious implementation, and it silently re-shares a Character's disclosures onto a trip they never consented to | **HIGH** | D55's allowlist — enumerate what is copied, never exclude what isn't, so a table added later is not copied by default. §15.2 asserts on the cloned rows directly. **The failure is invisible in testing unless someone looks for it**: the clone works, the trip plans fine, and nobody notices until a Character asks why their medical note is on a trip they didn't share it for |
| **A28** ★ | **Eager re-solve on edit.** The natural implementation of an edit-aware planner recomputes immediately, which is expensive, surprising mid-thought, and defeats the batching `solve.stale` exists for | Medium | D52's passive level is a requirement, not a preference; §15.1's stale-gating tests assert that an edit marks rather than recomputes. Watch for it in the Riverpod layer, where a naive provider dependency makes eager recompute the *default* behaviour rather than a choice |
| **A26** ★ | **The anonymous web reading surface leaks reader identity or trip content.** A bearer token in a URL, plus access logs, plus a reveal model with no home for an accountless reader | Medium | **Mitigation decided 2026-08-30 — SPIKE-F (#175), D59, Q17 closed.** Token never persists in the URL: it is exchanged once for an opaque `__Host-` `HttpOnly; Secure; SameSite=Strict` cookie, with `Referrer-Policy: no-referrer` on the reading view (SPIKE-F measured the path/query carriers leaking the token into the access log and every subresource `Referer`). Logs are two-tier — edge/CDN ≤72 h, application logs written through a field allowlist (route template, no token/`Referer`/cookie, IP → /24) ≤30 d. Reveal has no gap: the anonymous reader is the empty revealed set permanently and the projection takes no identity argument, so there is no trusted-reader flag to become the A22 path. Unchanged structural mitigations: the token is revocable and scoped to one trip's reveal-filtered content (§10.3); web guests persist no preferences (§11.2). **Residual to verify at build:** `share.revoked_at` propagation to minted cookies, and that the chosen CDN can bound access-log retention to the stated window |
| **A25** ★ | **Arrivals get "improved" into position tracking.** The gap between "post an event when a trigger fires" and "post position every 30 s" is one well-intentioned commit | Medium | P9's refusal list (§9.1); no position table exists in the schema, deliberately (§11.2); the endpoint accepts an anchor reference, never a bare coordinate — **the schema is the enforcement**, not the review. |

---

## 17. Decision Log

D1–D33 carry from v1.0 (abbreviated below where unchanged). **D34–D45 are new in v2.0.**

### Carried decisions (summary)

| # | Decision |
|---|---|
| D1 | Local sidecar process for the routing core on Desktop/Mobile |
| D2 | `plotlines-core` is a pure library with no web awareness |
| D3 | Field Runtime is a distinct, offline-only client tier beside `RoutingClient` |
| D4 | Field cue engine recomputes distances/ETAs, never the route |
| D5 | Themes are `WeightProfile` data, one scorer |
| D6 | "Fewest turns" removed from the scoring model |
| D7 | Canon vs. layers (P8) |
| D8 | Group relay is trip-scoped, route-anchored, advisory, peer-to-peer (P9) |
| D9 | Magic-link-only auth — with a re-send + support-issued-link recovery fallback, not a password (SPIKE-13) |
| D10 | Store-and-forward group messaging |
| D11 | `trip.payload` as JSONB; group tables separate |
| D12 | `granted_fields`/`volunteered_fields` are allowlists |
| D13 | Conditional write (`409 Conflict`) for the save-time version check |
| D14 | Plugins split across two runtimes (Dart output, Python data-input) |
| D15 | Custom domain + same-site `SameSite=Lax` cookie |
| D16 | Manual GitHub Releases for desktop at MVP, with a version seam |
| D17 | Stock Postgres at MVP; PostGIS is a gated upgrade |
| D18 | Golden-route testing + committed graph fixtures; P1 enforced as a CI gate |
| D19 | Paddling difficulty is advisory, not a routing constraint (SPIKE-04) |
| D20 | Single fused elevation source (GEDTM30/OpenTopography), no fallback |
| D21 | Client-owned tile-service contract |
| D22 | `flutter_map` + `vector_map_tiles` for the desktop map, not `maplibre_gl` |
| D23 | Protomaps Basemap, ODbL, mirrored to Plotlines-controlled storage |
| D24 | Plotlines authors its own basemap theme by scripted transform |
| D25 | Conflict diagnosis is a separate, async endpoint pair |
| D26 | `POST /segments/envelope` — dedicated probe for band-slider defaults |
| D27 | Paddling network from USGS 3DHP; `WaterwayGraph` carries two join keys |
| D28 | One checked-in schema is the contract for `trip.payload` |
| D29 | The payload stores the Author-facing weight profile, never the solver's form |
| D30 | `solve.stale` records when the derived half no longer matches the authored half |
| D31 | Cue derivation runs in `plotlines-core`, not the client |
| D32 | Region/bbox selection is distinct shapes, not one model — **superseded by D41** |
| D33 | Rural/low-signal roads are the traffic-stress model's zero baseline |

### New in v2.0

| # | Decision | Rationale | Alternatives rejected |
|---|---|---|---|
| **D34** *(amended 2026-08-28 — SPIKE-D)* | **`/health` reports per-capability readiness. Capabilities are independent, not ordered: extraction gates authoring, the region graph gates routing, enrichment gates elevation-dependent metrics** *(breaking — B1)* | PRD FR121 has the Author working during acquisition, and a single readiness flag either blocks the session or lies. **The ordering half of this row — layer/POI extraction ahead of elevation enrichment — was measured and did not hold.** Extraction is 15.8–178.5 s; elevation enrichment is **8.8 s**. Elevation was never the half worth hiding, and this row's original rationale ("a reordering of existing startup work, not new work") described work that does not need reordering. **The decision survives on stronger grounds than it was made on:** extraction's *variance* (×21 run to run) is what makes a global flag untenable, and the capability that stays not-ready longest is the **region graph** (36.7 s at 704 km², 116.6 s at 1,799 km²) — neither of the two this row originally ordered. See `spikes/SPIKE-D/results/RESULTS.md` | One flag (blocks authoring for an unpredictable interval — the thing the requirement exists to prevent); reporting ready-when-up (lies about routing, and the first solve fails or hangs); **gating routing on elevation** (measured false — routing waits on the graph build, which `RegionState.graph_state` already has right; a reader of the pre-amendment FR121 would have wired it to the wrong capability); ordering the capabilities at all (three independent gates started together is both simpler and what the code already does) |
| **D35** | **`target_distance=None` is a first-class compose-mode input; realized distance returns as a reported outcome, never a band violation** *(breaking — B2)* | PRD FR118. In compose the anchors determine the length — that is the correct behaviour, not a failure. SPIKE-01's +30.7%/+81.9% at three via-nodes is thereby reinterpreted rather than overturned: every via was hit and every loop closed, and a 1-via loop was ~6× *faster* | Enforcing the band in compose (drops an anchor the Author chose, or fails a request that should succeed); routing deviation through `/segments/diagnose` (teaches the Author that curation is a failure mode, and pays 1.3–15.0 s for a non-conflict); a second solver for compose (one anchor list, one call — D5's discipline) |
| **D36** | **Curation runs in `plotlines-core/curation/`, not the client; candidates live in a regenerable bbox-scoped cache, never in `trip.payload`** | Salience and clustering read tags and geometry the client does not hold, and a client-side implementation would make sidecar and hosted produce **different proposals for the same bbox** (P1). The cache separation is P10 in the storage layout: candidates are considered, anchors are authored | Client-side clustering (two implementations, two answers, and the Dart side cannot read OSM tags it never fetched); persisting candidates server-side (makes analysis output look like canon — P10 violated in the schema); anchors referencing candidate rows (a dangling reference into a regenerable cache — an anchor must survive a cache wipe and an upstream OSM edit) |
| **D37** | **Areas are first-class geometry across payload, triggers, export, and local schema** *(breaking — B3)* | PRD FR108. A rest day on a main street or in a historic district is inexpressible as a point, and polygon *entry* is a different trigger from point proximity. **`ShapeDataProvider` already existed** (§14.2), so the provider layer needed no change — the architecture was more right than v1.0's requirements | Point-plus-radius as an area approximation (a historic district is not a circle, and the approximation is worst exactly where the boundary matters); areas as presentation-only overlays (then they cannot trigger, which is half the point) |
| **D38** | **`trip.payload` gains `schema_version`; v1→v2 migration is forward-only and explicit, with reveal defaulting to always-visible** | The v2.0 model replaces nodes with anchors-and-roles, adds polygons, moves arc onto passages, and adds reveal/stations/bbox. A v1 payload does not validate. Without a version field the failure reads as corruption rather than a version mismatch. Reveal defaults to visible so **no migration can accidentally hide content** | Additive-only schema evolution (cannot express roles replacing nodes); inferring version from shape (fragile, and wrong exactly when a payload is partially migrated); defaulting migrated content to on-arrival reveal (a migration that silently hides an Author's existing notes is the worst possible default) |
| **D39** | **Reveal is enforced at one resolver (P11), and every content-crossing boundary — render, export, print, package, plugin push — goes through it; hazards are exempt inside the resolver** | The failure mode is a rarely-exercised path leaking content, and a spoiled trip cannot be un-spoiled (A22). One gate is testable; N gates are hopeful. Hazard exemption lives inside the resolver so it cannot be forgotten in many places (FR115) | Per-surface reveal checks (the export corner nobody tests is where it leaks); encrypting unrevealed content on device (implies a security guarantee that does not exist — FR64a states it plainly instead); withholding unrevealed content from the package (breaks airplane-mode reveal, which is the whole point) |
| **D40** | **The plugin data-input contract ships in Leg 2.5 with a new `LayerProvider` interface; only the output contract stays open in Leg 7** *(breaking — B4)* | Plugin datasets are the substrate the layer picker and cluster analysis read; the contract's shape is determined by what those surfaces need. `NodeDataProvider` is insufficient — a curation layer must supply a licence (enforced at registration), a sub-weightable taxonomy, and point *and* area geometry in one call | Keeping both directions in Leg 7 (builds the core loop on an undesigned input format); extending `NodeDataProvider` (breaks every existing implementer for three additions it was never shaped for); a licence field that warns rather than refuses (an unsatisfiable licence flowing into printed output is a legal exposure, not a lint) |
| **D41** | **Two authoring extents, not four** *(supersedes D32)*: a **shipped home region** (Buncombe County rect — a constant, not a default: no override, no first-run prompt, **no eager download**), and a **trip bbox** drawn at initiation on a map centered by a single location prompt prefilled with the last-used value. Plus the **offline corridor buffer**, which is Character-side and never appears in the authoring flow. **The invariant is that no *second, different* extent exists for analysis — not that the trip bbox is immutable**: it is revisable, with shrink prompting on affected anchors and never discarding authored work (P5) | D32 carried three cases including a first-run 100 km radius download. Under the v2.0 pipeline every extent should be justified by a trip, and that one was not — it fetched tiles and elevation for a region the user had not said they would use, before they had done anything. Making Buncombe a constant removes a first-run settings state to persist, migrate, and sync, and lets it be a compile-time asset. The location prompt centers the map and **never becomes the bbox by inference**, which would be the FR5 duplicate-surface problem again | A first-run prompt with an eager radius download (an extent nothing justified, and a decision before the user has context); making the home region overridable (a settings state, a migration, and a sync field, for a map view that a trip immediately replaces); the location prompt implying a bbox by radius (two ways to set one thing); reusing the corridor buffer as the authoring extent (the buffer does not exist until a route does, and curation precedes routing — the ordering makes this impossible, not merely awkward) |
| **D42** | **Mode-legal routability is enforced at graph-build time for hard exclusions, and surfaced as flagged cues for soft ones** | PRD FR128 closes a correctness gap: v1.0 specified no passability guarantee in 96 requirements, though the OSM mapping carried a whole routability column. An illegal edge should not be *scorable*; a penalty large enough to avoid an edge is not the same as an edge that cannot be used. `bicycle=dismount` is routable but must never be silent | Modelling legality as a large scoring penalty (a sufficiently desperate solve still takes the illegal edge, and the Author is never told); treating dismount as an exclusion (over-restrictive — a 40 m dismount is normal and useful); leaving it to the Author to notice (they cannot; the tags are not visible on a rendered route) |
| **D43** | **Arrivals are a fourth P9 relay kind, consented through `profile_grant`, roster-visible, and discrete-by-schema** | PRD FR122–FR123. Reusing the profile request/response mechanism means **no new consent machinery and no second consent surface**. Roster visibility rather than Author-only follows the same reasoning that made field notes peer-to-peer (D8) — regroup fails if it routes through an Author who is riding. The endpoint accepts an anchor reference, never a bare coordinate, so **the schema is what prevents drift into tracking** (A25) | A separate arrival-sharing toggle (a second consent surface for the same kind of decision — the thing FR78a exists to avoid); Author-only visibility (defeats the regroup use case that motivates the feature); a position endpoint with arrival as a special case (that is participant tracking with extra steps, and crosses the PRD non-goal) |
| **D44** | **Reveal state, arrivals, and story choices are per-Character tables (P8 layers), never payload fields** | Two Characters on one trip have different reveal states, and a Character's experience must never mutate the Author's canon. A useful consequence falls out: these tables are **append-only and owner-scoped**, so they do not participate in FR59's version-check protocol at all — two devices belonging to one Character converge by union, with no conflict to resolve | Reveal state in the payload (mutates canon per Character — P8 violated, and sync conflicts on every trigger); reveal state client-only and unsynced (a Character switching devices mid-trip loses their story, and the recap is wrong) |
| **D45** | **Attribution is derived from the loaded layer set at render time, and a layer with absent or unsatisfiable licence metadata does not load** | A plugin ecosystem means arbitrary datasets with their own terms flowing into exports and printed cue sheets, so a hardcoded credit list cannot be correct. Refusing at registration rather than warning at render is the only point where the decision is still cheap | A static attribution list (wrong the moment a plugin loads); a warning on unlicenced layers (the warning is ignored and the unattributed data reaches print, which is a licence breach rather than a bug); attribution only on the About surface (the obligation is "wherever the data appears," which includes exports and paper) |

| **D46** | **`poi_bonus` becomes a scalar `interest` weight biasing toward salience; `detour_budget` is retired** | PRD FR5's reformulation. The type parameter duplicated layer selection with no conflict rule, and density biased toward *quantity* — which means boundary stones and street trees, the same failure that made the flat `historic=*` wildcard useless for clustering. Salience did not exist when `poi_bonus` was written. `detour_budget` was a second dial for one intent once the bias became scalar. Also relieves A18: one fewer ambiguous field | Keeping the per-type dict (two surfaces for *what matters*, and an Author can set them in contradiction); deleting the weight entirely (leaves explore mode with four dials, none of which say anything about *places* — and abandons the legitimate *"forty-mile loop past good stuff, I don't want to review anything"* workflow that clustering does not serve); keeping `detour_budget` alongside the interest weight (two dials, one intent) |
| **D47** | **Every type in a layer's taxonomy declares one primary role affinity plus a salience weight; clusters propose the union of affinities present. Single-valued, with Author override at promotion** | Without it, §4.4 can only propose role sets for tuples someone enumerated — so a plugin bringing `battlefield` and `manor_house` produces a correct cluster and no proposal, the curation feature silently not working with the extension mechanism built to feed it. Single-valued because a layer author should declare one thing per type rather than reason about a matrix, and an Author should not adjudicate detail irrelevant to their story. **Also gives the station role its first path from analysis**, which the recipe form never had. **SPIKE-B (#169) exercised this end to end**: a synthetic plugin layer declaring `battlefield`/`manor_house`/`covered_bridge` → narrative and `crag` → station clustered alongside OSM candidates and produced correct role-set unions (incl. a `provision+station` proposal) with no core change — the §0 failure mode's regression test. **SPIKE-H (#160) then proved it on real data one layer deeper**: 290 real OSM candidates merged with 82 real NPS candidates — **372 in, 30 cluster proposals out, zero changes to `colocate.py`** — of which **14 mix an NPS candidate with a non-NPS one** (the same real overlooks, reported independently by both sources, clustering unprompted) and **2 carry the `station` affinity** from a real `Mile Marker` type the plugin taxonomy declared. The station path this row claims is no longer only synthetic | Multi-valued affinity per type (a matrix for every layer author, and role sets an Author must prune rather than extend); a core-side type→role table (breaks for every plugin, and is the exact v1.0 enumeration failure); inferring affinity from the layer name (guesswork, and wrong for any mixed layer) |
| **D48** | **Layer readiness is per layer inside `capabilities.layers`, not one flag** | A plugin dataset may be large or remote (PRD N2). One flag means the slowest layer gates the workspace — B1 reintroduced one level down. Per-layer state lets built-in OSM layers unlock curation immediately, shows a loading layer as loading, and **prevents one failing layer from blocking the others**, which matters more as the plugin ecosystem grows | One layers flag (the slowest plugin gates all authoring); blocking on all layers before showing any (same, with a worse first impression); failing the whole layer capability when one layer fails (one bad plugin disables curation entirely) |
| **D54** | **Undo is a bounded ring of canonical payload snapshots, session-scoped, covering authored work only** | PRD FR142(a). D28 already made `trip.payload` one canonical serializable blob with a deterministic form, so undo is `List<String>` with a cap rather than inverse operations per feature — most applications cannot do this cheaply and Plotlines already did the hard part for another reason. Derived work is **re-solved, not undone**, because re-solving is idempotent (§7.10). `author_note` deletion is **excluded and irreversible by design** (D51) | A command stack with per-feature inverse operations (far more code, and every new object type adds an undo obligation); undo across sessions (unbounded storage, and it collides with sync — two devices with divergent undo stacks have no defined merge); including note deletion (would make FR135a's hard-delete promise a lie) |
| **D55** | **Clone copies an enumerated allowlist; `profile_grant` is a hard exclusion** | PRD FR74. Sharing is per-trip and revisable *by design* (FR78), so copying grants makes cloning a **consent-laundering path**: last year's medical disclosure silently re-shared on this year's different trip, the Character having done nothing. An allowlist rather than a denylist means a table added later is **not** copied by default — the same discipline as `granted_fields`. `author_note` follows for free from D50's scoping, which is confirmation the scoping was right | Deep-copying everything trip-scoped (the obvious implementation, and it launders consent); a denylist (a table added later is copied by default, and the leak ships the day it does); copying grants "because the same people are on the trip" (they are, but the trip is different, and that is exactly what per-trip consent means) |
| **D56** | **WCAG 2.2 AA through platform accessibility APIs; a design-review checklist at MVP, with a formal audit gating expansion beyond the Author desktop** | PRD FR142(d), FR142a. 2.2 AA is the current W3C Recommendation and ISO/IEC 40500:2025; WCAG 3.0 is a Working Draft whose Bronze level approximates AA, so meeting AA now is the head start rather than a detour. **AA is a floor** — field surfaces exceed it for a physical constraint WCAG has no concept of (sunlight on a bar-mounted phone). The audit gates surface expansion because each added surface multiplies remediation cost, and desktop authoring is both the most-used surface and the one where nothing specifies keyboard navigation, screen-reader semantics, or focus management | Targeting WCAG 3.0 (a Working Draft; counts, names, and structure can still change); AAA (not achievable product-wide, and not what any regulation references); a release gate at MVP (either theatre or a reason not to ship); no named standard at all (leaves a UI agent to invent one, which was the question that surfaced this) |
| **D50** | **Author-private Character notes are scoped to `(Author, Character)` and persist across trips; group assignment lives on `roster_entry`, not `rider_profile`.** Notes have **no Character-facing read path in any state** — the *never-release* class in P11 | PRD FR135, FR136, D-N. The knowledge is about the person, not the trip, so trip-scoping it discards the thing that makes it useful next year. Group is the opposite: a person is in different groups on different trips, so a profile field would follow them onto the next one. `updated_at` is **displayed** because a three-year-old claim about someone's climbing is worse than none if its age is invisible | Trip-scoped notes (throws away the cross-trip knowledge that is the point); group on `rider_profile` (a trip-specific fact following a person across trips); notes as a canon or layer object (they are about a person, not a trip, and would acquire a trip-shaped read path they must never have); **any scored form** — cohesion, compatibility, ability index — which puts a number on a person for other humans to read |
| **D51** | **Deletion of Author notes is hard, scoped at three levels, and propagates as an explicit tombstone — the first destructive sync operation in the system** | PRD FR135a. A `deleted_at` column would make the confirmation dialog a lie on the one table where honesty is the entire point. A deletion that is merely an *absence* gets **resurrected** by union-merge on any device that never learned of it — the classic distributed-delete failure, here resurrecting data a person asked to have removed. Scope is shown before confirmation because "14 notes across 4 trips since 2024" is the difference between an informed act and an unrecoverable accident | Soft delete (dishonest, on the table where that matters most); relying on absence to propagate (resurrects deleted notes); trip-scoped deletion only (cannot honour a request from someone no longer on any trip); coupling note deletion to roster removal (two independent decisions) |
| **D52** | **`solve.stale`'s reach widens to every class of derived work; staleness is passive while planning, blocking on export with a resolvable list, and blocking with no override on print** | PRD FR140. The mechanism already existed (D30) and needed only more reach — routes, cue sheets, metrics, elevation profiles, day splits. Passive while planning because an Author making six edits in a row should be stopped zero times (Brand Value 4). **Re-solve-all is unconfirmed** because it destroys nothing: confirmation belongs where an action removes authored work, and requiring it to recompute is bookkeeping. Print blocks harder than export because a stale GPX is corrected by the next sync while a stale printed cue sheet goes in a jersey pocket and is believed for eight hours | Auto-recompute on edit (expensive, surprising mid-thought, and it defeats the batching the mechanism exists for); a prompt per invalidation (turns ordinary editing into a negotiation); allowing stale export with a marker (the marker is on the app, the cue sheet is in the pocket); blocking on-screen viewing too (makes an editing session a series of forced solves) |
| **D53** | **The stale list is a distinct surface from M13's shared error surface** | Stale work is **pending work the Author caused deliberately**, and every item carries a one-action resolution. M13's enum is for failures. Routing staleness there teaches the Author that ordinary editing produces errors — precisely the defect that keeps compose-mode distance deviation out of it (§7.7). **Two things now sit deliberately outside M13, and they are the same mistake in different clothes** | Adding stale states to M13's enum (the obvious implementation, wrong for the reason above); a modal on every stale transition (violates D52's passive level); no surface at all, relying on per-object markers (an Author hunting nine stale items across nine days is exactly the tedium the list removes) |
| **D49** | **Date and time display preference is a render-time transform only; ISO 8601 remains the sole stored, exported, filename, and digest form.** `inherit` resolves at render time rather than being frozen at install | PRD FR79. A display format reaching stored or exchanged data reintroduces exactly the ambiguity ISO exists to remove, and would make the content digest depend on who was looking. Render-time resolution of `inherit` is what lets the *setting* sync while its *resolution* stays per-device — the behaviour users expect from a machine-local preference | Storing the resolved format (freezes a locale decision at install and breaks on device change); allowing a locale format in exports (a GPX whose dates mean different days to different readers); syncing the resolved value rather than `inherit` (imposes one machine's locale on another) |
| **D57** | **`POST /regions` acquires a routable graph (and, best-effort, a bbox-scoped tile cache) for the Author's own trip bbox, keyed on `(bbox, network_type, graph_ruleset_version)`; `nearest_node` refuses to snap farther than a bounded tolerance.** Elevation stays unattempted for every region — a fixed not-ready `capabilities.elevation`, gated on FR87 (#148) *(new — issue #154, applies D41 to routing/tiles)* | D41 established the trip bbox as the Author's real authoring extent, but routing and tile-serving kept using one committed Boulder fixture regardless — silently, since an unguarded nearest-node snap returns *a* node however far away the query point is. `POST /regions` is D25's 202-and-poll shape applied one layer down: idempotent, cache-keyed, non-blocking. Promoting `spikes/shared/regions.py`'s graph pipeline (not its Terrarium DEM fetcher — a second elevation source, which D20 forbids) into `core/plotlines_core/graph/` keeps P1 intact. Tiles are best-effort within region build (§8.2's `GET /tiles/{z}/{x}/{y}`) because a bbox outside the configured tile source's coverage is an honest per-request 404, not a reason to fail routing | A per-region readiness flag with no snap guard (still returns a wrong-region route, just for a *shorter* time before the Author notices); baking Terrarium elevation into region build (a second elevation source alongside GEDTM30, which D20 forbids — see FR87/#148 for the real path); an unbounded snap tolerance (defeats the guard's purpose — the whole failure mode is "the nearest node is always accepted"); hotlinking a public Protomaps mirror as the on-demand tile source's default (FR95 needs a Plotlines-controlled mirror, tracked separately in #139 — the extractor takes a configurable upstream so a dev URL works, but ships defaulting to the committed local archive only) |
| **D58** | **FIT export stays in `plotlines-core`, in dependency-free Python, on the same `export_trip` code path as GPX/TCX/GeoJSON. Dart-FFI-against-the-Garmin-FIT-SDK is rejected. Reconsider only on a device-measured fidelity gap (`spikes/SPIKE-16/HARNESS.md`)** *(new — SPIKE-16 / issue #163, 2026-08-30)* | SPIKE-16 built the writer — file header, definition/data framing, CRC-16, the 7-message course sub-profile, the semicircle / `(m+500)*5` / `m*100` encodings — in ~90 lines with no dependency, and validated it two ways a validator does not: its CRC-16 + container framing reproduce the stored header **and** trailing file CRC on **10/10 real Garmin activity files**, and a generated course round-trips to the byte across the five required `course_point` types. The FFI arm buys no measured fidelity, and the offline verdict is falsifiable by exactly one finding — a type or note the FFI arm renders on-device that the Python arm cannot. FR45's "where the target format supports them" is, for FIT, *every marker type at the format level*; the per-device draw table is `HARNESS.md`, which needs hardware the offline arm did not have | Dart FFI against the official Garmin FIT SDK (puts one of four formats on a different code path, gives sidecar and hosted **different FIT writers**, adds a native per-platform dependency to a binary already carrying GDAL/GEOS — **risk A5** — takes on the SDK redistribution + notice obligation the published-protocol re-implementation does not incur, and moves an export writer — the archetypal reveal leak path, A22 — outside the core boundary the reveal gate is easiest to enforce at); a track-with-names instead of real `course_point` messages (fails FR45 — head units reject or ignore it); shipping FIT as GPX/GeoJSON-only (FR44 names FIT explicitly) |
| **D59** | **An anonymous share-token reader is served the always-visible set only; revealed content requires an account. The token is exchanged once for an opaque `__Host-` session cookie (`HttpOnly; Secure; SameSite=Strict`, `Max-Age` = token TTL); reading-view responses carry `Referrer-Policy: no-referrer`. Access logs for an accountless reader are two-tier: edge/CDN ≤72 h operational only, application logs written through a field allowlist (route template, no token, no `Referer`, no cookie, IP truncated to /24) ≤30 d** *(new — SPIKE-F / issue #175, 2026-08-30; closes Q17, amends A26)* | PRD FR132/FR116/FR138. **Token carrier:** SPIKE-F measured all four options against a live server — path and query put the token in the access log *and* in the `Referer` of every subresource; a URL fragment keeps it off the wire but not out of browser history or a copied link, and still needs JS to read it and exchange it anyway. Exchange-for-cookie confines the token to one request, converts it to a value the page's JS cannot read, and `SameSite=Strict` keeps it off cross-site navigation — the same reasoning as D15, one auth shape down. The §10.3 token contract is unchanged: still revocable (`DELETE /shares/{token}`, checked on every `/j/{opaque}` hit), still scoped to one trip's reveal-filtered content. **Reveal model:** the "nowhere for reveal state to live" gap closes with no new machinery — the reader *is* the empty revealed set, permanently, and `anonymous_view(payload)` takes **no identity argument** so there is no trusted-reader flag to become the A22 spoiler path. An `on_arrival` plot point renders as a withheld placeholder that keeps its `kind` and `arc` stage — FR116's "the arc's shape" requires the position to survive even though the content does not. Hazards (role and passage-level) and provisions are unconditional | A bearer token that stays in the URL (leaks through `Referer`, history, logs, and any copied link — the whole of A26); a URL fragment as the carrier (off the wire, but still in history and the clipboard, and it does not remove the exchange step, only hides it); giving the reading view its own reveal path that "trusts" the share token to release held content (re-implements reveal outside the one resolver — D39 — and the trusted-reader parameter is exactly how the export corner leaks); omitting withheld plot points entirely rather than showing a placeholder (a hole in the list cannot carry the arc's shape FR116 requires, and it reads as broken rather than as held); keeping full edge-log retention (a standing identity-adjacent record of people who never consented to an account — P4's spirit one surface out) |

---

## 18. Open Architectural Questions

| # | Question | Gated by / needed by |
|---|---|---|
| Q1 | **iOS routing strategy** — precompute-and-download, or Dart-engine-only with no iOS sidecar? | **SPIKE-09**, then the Mobile milestone |
| ~~Q2~~ | ~~Paddling data source~~ **Resolved by SPIKE-04/SPIKE-19.** Network from USGS 3DHP, gauge from USGS Water Data APIs + NLDI, access points from OSM plus state GIS, **class ratings from nowhere** | Done |
| Q3 | **Trigger overlap/priority thresholds** (§6.2) — queueing and preemption for dense stretches. **v2.0 widens this**: the engine now fires four effect kinds (hazard, reveal, narration, arrival), and the priority order is specified but the *thresholds* are not | Before the field-execution build |
| ~~Q4~~ | ~~Frozen-binary tool~~ **Resolved by SPIKE-00: PyInstaller `--onedir`** | Done |
| ~~Q5~~ | ~~Sidecar in installer or downloaded?~~ **Resolved by SPIKE-00: bundle in the installer** | Done |
| Q6 | **Group-relay transport** — polling vs. push. **v2.0 sharpens the stakes**: arrivals are the kind where latency is most visible (regroup is a *now* question), and push is also what would first trigger PostGIS (A12) | **SPIKE-11**, before the group tier |
| Q7 | **Medical/allergy volunteered-field handling** — prominence to the Author, and group-visibility default | Before profile-sharing build |
| Q8 | **Plugin distribution** — pub.dev + PyPI, or a bundled registry? **v2.0 splits this**: the *output* side stays Leg 7, but **data-layer distribution is now a Leg 2.5 question** and needs an answer sooner | Leg 2.5 (data layers) / Leg 7 (outputs) |
| ~~Q9~~ | ~~Tile-generation tooling~~ **Resolved by SPIKE-14: we do not generate tiles.** `pmtiles extract` pulls a bbox from the published Protomaps build over HTTP range requests — 80 km square in 5.9 s / 76 requests / 22 MB | Done |
| ~~Q10~~ | ~~Region/bbox selection strategy~~ **Resolved by D32, extended by D41 to four shapes** | Done |
| ~~**Q11** ★~~ | ~~**Notability ruleset values** — the per-tag qualification rules and `historic=*` sub-weighting are guesses until measured, and cluster quality depends entirely on them~~ **Resolved 2026-08-27 by SPIKE-A (#158).** Calibrated against real extracts in three trip-sized bboxes (Asheville NC, Lower Wisconsin Riverway, San Gabriel foothills — `spikes/SPIKE-A/results/RESULTS.md`). Two structural fixes: `Qualification.requires_value` (a bare-presence gate let 4,149 San Gabriel street trees through on `denotation=avenue`); `natural=peak` weight 0.8→0.55 (no attribute gates a knoll from a summit in mountain terrain). `historic=*` sub-weights extended from the values that actually appear (`district` 0.9, `yes` 0.05, +10 more); `man_made=bridge` gated to a heritage/wiki signal (name ≠ notability); added `leisure=nature_reserve` and `amenity=place_of_worship`. **Verdict: one default ruleset, no regional dimension** — the gates hold in all three regions; what varies 10–30× is candidate *volume*, which is SPIKE-B/Q15's problem. Ruleset ships as versioned tables in `curation/taxonomy.py` under `RULESET_VERSION`, locked by golden candidate sets *(corrected 2026-08-28: `notability_ruleset.v1.2.0.json` is a spike **export** under `spikes/SPIKE-A/results/`, not a file the core loads — see §4.3)* (`core/tests/fixtures/golden_candidates/`, `core/tests/test_curation_golden.py`). `RULESET_VERSION` → `1.2.0`. | Done |
| ~~**Q12** ★~~ | ~~**Cluster ranking function** — how salience and tightness trade off; whether corridor proximity should dominate once a route exists; what a "reviewable count" is for a 200 km bbox~~ **Resolved 2026-08-27 by SPIKE-B (#169).** Default rank = combined salience (noisy-OR of member saliences) × a tightness multiplier (floor 0.72). **Corridor proximity does NOT dominate and is not in the default rank** — measured against PRD §5.4a's worked pass, an `exp(-d/decay)` factor in the score buried Wiseman's View (a real Linville Gorge destination, ~6 km off the paved Parkway) under tight roadside-viewpoint pairs. Corridor proximity is instead a bulk *filter* axis (N4a) and an opt-in *resort* (`by_corridor_proximity`, which an Author with a route will almost always want). **Reviewable count:** proposals run ~1 per 18 km2, so a 20,000 km2 bbox yields ~1,100 — the cap is mandatory. `cap = 30 + 0.5 × route-km` (30 floor covers §5.4a's ~40; a 250 km tour caps at ~155), with the count beyond it always returned, never truncated. Shipped in `core/plotlines_core/curation/colocate.py` (`ColocationParams` carries the tuned values as config). See `spikes/SPIKE-B/results/RESULTS.md`. | Done |
| ~~**Q13** ★~~ | ~~**Non-whitewater difficulty coverage** — `sac_scale`, `trail_visibility`, `mtb:scale*`, `piste:difficulty`. **v1.0 generalized SPIKE-04's whitewater verdict to all technical terrain without testing it**; FR14b reopens it~~ **Resolved 2026-08-28 by SPIKE-C (#170).** 57,422 ways / 12,735 km over seven regions — the three shared fixtures, one mode-popular North American region per mode (White Mountains / Bentonville / Methow Valley), and the schema homeland (Tyrol) as the upper bound, without which a continent-wide zero is unreadable. Every figure reported against four denominators, widest to narrowest, and a `read`/`opportunistic`/`absent` band declared **before** the run. **Only `piste:difficulty` clears it, and it clears everywhere** (Methow 100%, Whites 86.4%, Tyrol 97.2% — and North American piste *density* is within 1.5–2.2× of the Tyrol's, so this is the same case, not a thin version of it). Best land results: `mtb:scale:imba` **39.3%** (Bentonville singletrack), `sac_scale` **31.8%** (Whites, curated) — both `opportunistic`. **The same-place controls close the question:** on Bentonville's 4,238 MTB-eligible ways `surface` is at 74.4% and `name` at 59.7% while `mtb:scale` is at 0.76%, so the ways are richly attributed and the schema is simply not the one that community uses. **Two findings beyond coverage.** (1) *Thin coverage produces confident understatement, not silence* — worst-of aggregation is biased low by construction, 16–32% of shown leg grades wrong at real rates, always easy; the harm-derived floor (≈32–38%) independently corroborates the pre-declared 70% band. (2) *The MTB scales are regional mirror images* — `mtb:scale:imba` 39.3% in Bentonville / 0.10% in the Tyrol, `mtb:scale` 29.5% in the Tyrol / 0.19% in Bentonville — so a single-schema implementation is wrong on one continent by construction. **FR14b narrows to three clauses; `terrain_technicality` stays Author-declared (§7.4).** See `spikes/SPIKE-C/results/RESULTS.md`. | Done |
| **Q14** ★ | **Driving-mode routing** — does the existing OSM graph and solver handle trailhead approaches acceptably, or does it need its own weights and constraints? | **SPIKE-E**, before C13 |
| ~~**Q15** ★~~ | ~~**Candidate rendering at bbox scale** — a dense trip bbox may draw thousands of markers over a basemap already costing ~1 GB (A16). Clustering-for-display, zoom thresholds, or salience-gated rendering?~~ **Resolved 2026-08-29 by SPIKE-G (#161).** A candidate layer priced over SPIKE-14's warm-frame anchors at SPIKE-A's real densities (`avl`/`lwr`/`sgv` = 715/72/**1,208** candidates, 79/20/100 polygon area anchors), swept over four zooms on a software-raster floor and a GPU target. **Naive** (one hit-testable widget marker per candidate) breaks the 16.7 ms frame budget — `sgv` overview p95 **33.5 ms** on GPU, 50–75 ms on software raster. **Zoom-thresholding** blanks the overview, the one zoom co-location analysis runs over (hard fail FR99/N3). **Clustering-for-display** fits the frame budget comfortably but aggregates salience into a count glyph and makes a map tap ambiguous — fails FR99 ("salience visible") and N4a ("tap the cluster, select its card / promote from the map"). **Recommendation: salience-gated rendering** — the top-K in-viewport candidates by salience as hit-testable widget markers (**K ≈ 300 on GPU**, *derived* as `(warm-frame headroom − 3 ms area/dot allowance) ÷ per-marker frame cost`, ~0 on the software-raster floor), the rest as a salience-styled `CustomPainter` dot field (not widgets, not individually hit-tested; ~50× cheaper/frame, ~180× cheaper in memory). Keeps salience visible by construction, supports promote-from-map and exact tap→card, fits every zoom on GPU with headroom. **Grid clustering is the backstop** below the trip-overview zoom and above the **~2,800-candidate GPU display-density ceiling** (the shipped notability ruleset stays well under it in a trip bbox; the pre-calibration v1.1.0 flood of 5,453 does not). **Selection latency tracks the live *widget* count, not density** — the naive `MarkerLayer` rebuild-on-tap is ~55 ms (`sgv` z10), salience-gated ~20 ms; `list→map` is O(1) and density-independent everywhere. **Areas (FR108)** are cheap on GPU (~1–2 ms/frame for every anchor in a dense bbox), dominant on the software-raster floor. This is a recommendation on a model calibrated to SPIKE-14's measurements; the two-platform Flutter re-measurement is specified in `spikes/SPIKE-G/HARNESS.md`. A16 restated (~1.15 GB — see the risk row). See `spikes/SPIKE-G/results/RESULTS.md`. | Done |
| ~~**Q16** ★~~ | ~~**The utility-amenity layer is incomplete.** The OSM attribute mapping does not contain `amenity=toilets` at all, nor `cafe`/`restaurant`/`pharmacy`/`shower`. **FR104's "toilet + water + shelter" provision cluster cannot be computed from the mapping as written**~~ **Resolved 2026-08-27 — the mapping pass, not a spike.** `docs/osm_reference.md` was always a directional working reference, not a source of truth or an allowlist; that is now stated at its head. The machine-readable taxonomy (`core/plotlines_core/curation/taxonomy.py`) gained `provision`-affinity rows for `toilets`, `water_point`, `shower`, `cafe`, `restaurant`, `fast_food`, `pharmacy`, `bicycle_repair_station`, and `compressed_air` — sourced from the OSM wiki `Key:amenity` — so both of FR104's worked clusters ("toilet + drinking water + shelter"; "café + restroom + bike repair station") now resolve to a single `provision` affinity for D47's union rule. `RULESET_VERSION` → `1.1.0`. `bench`/`waste_basket` deferred to SPIKE-A: real provisions, but in FR98(b)'s over-triggering density class with no qualifying attribute, so their inclusion is a calibration question, not a mapping one. | Done |
| ~~**Q17** ★~~ | ~~**Anonymity of the Character-facing web reading surface** (FR132, §10.3). Three strands: a share token in a URL leaks through referrers, browser history, and access logs; CDN and server logs are a retention surface for readers who never consented to an account; and **reveal state has nowhere to live for an anonymous reader** — no account, no device GPS, nothing to fire a reveal~~ **Resolved 2026-08-30 by SPIKE-F (#175).** All three strands settled and recorded as **D59**. Token: **exchanged once for an opaque `__Host-` `HttpOnly; Secure; SameSite=Strict` cookie**, `Referrer-Policy: no-referrer` — measured against a live server, path/query carriers leak the token into the access log *and* every subresource's `Referer`; a fragment stays off the wire but not out of history/clipboard and still needs the exchange step. Logs: two-tier, **edge/CDN ≤72 h**, **app logs allowlisted (route template, no token/`Referer`/cookie, IP → /24) ≤30 d**; FR138's privacy statement updated to say so. Reveal: the anonymous reader **is the empty revealed set, permanently** — `anonymous_view(payload)` takes no identity argument, `on_arrival` plot points render as a withheld placeholder that keeps `kind` + `arc` stage (FR116's "arc's shape"), hazards and provisions unconditional. Prototype + assertions in `spikes/SPIKE-F/`. | Done |

---

## Appendix A: Glossary

| Term | Meaning |
|---|---|
| **`plotlines-core`** | The pure Python routing **and curation** library. No web awareness (P1). |
| **`plotlines-service`** | FastAPI wrapping the core. Runs as local sidecar *or* hosted. |
| **Sidecar** | The `plotlines-service` child process on the user's own device. |
| **Field Runtime** | The offline-only client tier that executes a downloaded plotline: GPS and polygon triggers, cue state, narration, **reveal, arrivals**, dead-zone odometer (§6). Depends on neither the sidecar nor the network. |
| **Curation Workspace** ★ | The client tier for layer selection, candidate review, cluster analysis, and promotion (§4). Depends on layer/POI readiness only, never on elevation. |
| **Candidate** ★ | A scored feature from a live data layer, in a regenerable bbox-scoped cache. **Considered, not included** (P10). |
| **Anchor** ★ | A promoted place in `trip.payload`, carrying a **role set** and point or polygon geometry (§7.8). |
| **Role** ★ | narrative (**plot point**) / provision / station. Each carries its own reveal policy, content, and optional geometry offset. |
| **Passage** ★ | The traversal between anchors — mode, geometry, character. Formerly "segment". May carry an arc stage. |
| **Set** ★ | A curated named place-identity (trail, network, reserve, pass) — the *setting* (FR111). |
| **Reveal Resolver** ★ | The single P11 gate every content-crossing boundary passes through. Hazards exempt, inside the resolver. |
| **Explore / Compose** ★ | The two planning modes (§7.7). Explore: distance in, route out. Compose: places in, distance out. |
| **Travel circle** ★ *(Later)* | A named, **living** list of people an Author plans for repeatedly. A trip's roster **materializes** from it at creation and is thereafter independent; changes are **offered** to upcoming trips, never propagated silently (§11.8). |
| **Authored vs. derived** ★ | Authored work is what the Author typed, drew, promoted, or arranged; derived work is what the core computed from it. **Orphaned authored work prompts; invalidated derived work goes stale** (§7.10). |
| **Stale list** ★ | The surface listing derived work invalidated by edits, opened by an export or print attempt, with per-item resolve and a single unconfirmed re-solve-all. **Distinct from M13's error surface** (D53). |
| **Author note** ★ | Free-text knowledge an Author holds about a Character, scoped to `(Author, Character)` and persisting across trips. **Never releases to its subject** — the P11 *never-release* class. Hard-deletable at three scopes. |
| **Roster entry** ★ | A Character's trip-scoped membership record carrying group and sub-group, with per-day and per-passage overrides. Character-visible, unlike notes. |
| **Canon vs. layers** | The Author's plotline is canonical (P8); personalization, notes, amendments, feedback, **reveal state, arrivals, and choices** are layers over it. |
| **Group relay** | The trip-scoped, route-anchored, advisory channel for field notes, amendments, feedback, **and arrivals** (P9). |
| **`WeightProfile`** | The data structure defining a routing theme. In explore it defines the search space; in compose it flavours connections between fixed anchors. |
| **Stowed / Mounted** | The two device postures (§6.4). Stowed renders nothing but still triggers reveals and arrivals. |
| **Version check** | The open-time *and* save-time comparison against the server's trip version (§11.4). |

---

## Appendix B: PRD v2.0 → Architecture v2.0 Mapping

Where each restored PRD concept lands in this document.

| PRD concept | FRs | Architecture home |
|---|---|---|
| Curation pipeline | FR97–FR110 | §4; `curation/` §7.2; endpoints §8.2; D36 |
| Layer selection & plugin layers | FR97, FR100, FR101 | §4.1, §14.1–14.2 (`LayerProvider`), §12.2; D40, D45 |
| Notability & salience | FR98 | §4.3; golden candidate sets §15.1; A20, Q11 |
| Co-location analysis | FR102–FR105a | §4.4; `/clusters/analyze` §8.2; A21, Q12 |
| Anchors & role sets | FR106, FR110 | §7.8; payload §11.6; D36 |
| Role geometry offsets | FR107 | §7.8; trigger engine §6.2 |
| Area / polygon geometry | FR108, FR126 | §7.8, §6.2, §11.6; `ShapeDataProvider` §14.2; D37 |
| Stations | FR109, FR16b, FR130 | §7.3 (second extension path), §7.8, §6.3 (ETA) |
| Arc on passages | FR38 | §7.8 |
| Sets / setting | FR111–FR112 | `content/` §7.2; layer sources §12 |
| Reveal policy | FR114–FR116, FR124, FR64a | **P11**; §6.7; resolver §10.1; export §7.1, §15.1; D39; A22 |
| Explore / compose | FR117–FR119 | §7.7; `/segments/generate` §8.2; D35 |
| Trip bbox & lazy elevation | FR120, FR121, FR91 | §8.3 (per-capability `/health`), §4.2; D34, D41 |
| Arrivals | FR122–FR123 | §8.5, §9; `arrival` table §11.1; D43; A25 |
| In-story choices | FR125 | §6.5; `story_choice` table §11.1; D44 |
| Mode-legal routability | FR128 | §7.9; `ModeConstraints` §7.1; D42 |
| Temporal availability | FR129 | `Candidate` attrs §4.2; conflict detection with FR28 |
| Driving as a routed mode | FR29, FR10 | §7.4; Q14 / SPIKE-E |
| Character web & print reading | FR132, FR116 | `/read/{share_token}` §8.2, §10.3; attribution §13.4; **anonymity gate Q17 / SPIKE-F / A26** |
| Role affinity | FR100, FR105 | `LayerProvider.taxonomy` §14.2; §4.4; D47 |
| Interest weight (FR5 reformulated) | FR5 | `WeightProfile` §7.3; §7.7; D46 |
| Startup & two extents | FR96, FR120 | §4.2, §8.3; D41 |
| Per-layer readiness | FR97, FR121 | §8.3; D48 |
| Drive-leg access advisory | FR29a | §7.4; Q14 / SPIKE-E |
| Time & date format | FR79 | §11.6 canonical form; D49 |
| String templates | FR145 | P11; D57; A30; lint §15.5 |
| Travel modes at initiation | FR144 | D58; layer defaults §4.1 |
| Usability foundation | FR142, FR142a, FR142(e) | §10.4; D54, D56 |
| Clone & travel circles | FR74, FR143 | §11.8; D55; A29 |
| Editing & lifecycle | FR139–FR141, FR140a | §7.10 authored-vs-derived; `solve.stale` §11.3; D52, D53; A28 |
| Roster, groups & Author notes | FR134–FR137 | `author_note` / `roster_entry` §11.1; P8, P11; destructive sync §11.7; D50, D51; A27 |
| Privacy statement | FR138 | §13.4 — required on all platforms, reachable from About |
| Frodo principle (narrative register) | FR133 | A rendering requirement — client Presentation layer; no architectural seam beyond the resolver |

---

*End of Plotlines Architecture v2.0.*
