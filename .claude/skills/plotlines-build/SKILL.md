---
name: plotlines-build
description: Use this skill when implementing, extending, or reviewing Plotlines user stories/features — backend, Flutter client, or routing/data-layer work. Orients build and frontend-dev agents to the product's story model (Candidate/Anchor/Passage/Arc/Set), the authoring pipeline (bbox → layers → notability → co-location → promotion → routing → narrative), the shipped curation modules, and the doc set that is source of truth — including the places where a measured spike has overtaken the docs. Trigger this whenever a task references an FR number, a PRD story, "Author"/"Character" flows, trip authoring, layers/notability/co-location/promotion, reveal policy, or explore/compose modes — not just when someone says "read the PRD."
user-invocable: true
---

Plotlines is a multimodal adventure-trip planner built on a story metaphor: **Authors** curate and write a journey, **Characters** experience it in the field. Story is *structure*, not decoration — it determines what objects exist and how the app behaves. Before building any feature, understand which part of the model and pipeline below it touches.

## Source of truth

`docs/Plotlines_PRD_v2.md` is canonical. **Only `_v2` docs in `docs/` are current** — any PRD/architecture file without that suffix has been removed from the repo as superseded; do not trust a stray copy that resurfaces in a branch or old context, it carries a reversed model (routing-first, node-only geometry, single readiness flag — all wrong in v2).

- `docs/Plotlines_PRD_v2.md` — vision, brand values, story model (§4), authoring pipeline (§5), scope/non-goals (§6), full FR list (§8), stories (§9), open items (§10). Read the FR(s) for your story before writing code.
- `docs/Plotlines_ARCHITECTURE_v2.md` — the *how*. **§0 lists breaking changes vs v1** — check it before assuming an old architectural pattern still holds. §4 is the curation tier; §17 is the decision log; §18 the open questions.
- `docs/Plotlines_Author_Flows_MVP.md` — Mermaid flow diagrams per feature area, each node traced to an FR. Every node carries a priority ([MVP]/[P1]/etc) — **the priority column is authoritative**, even over a flow being drawn. A drawn flow is not itself a scope claim.
- `docs/Plotlines_MVP_Redirection_Punchlist.md` — verification checklist for the v1→v2 recomposition; explicitly names which old documents/readings are wrong, not just stale. **§6 is the spike checklist and §6A the two CI gates.**
- `docs/Plotlines_Research_Spikes.md` — feasibility spikes, with full entries and the summary table. See "Spikes" below — this doc has teeth now, and one of its results *contradicts* the architecture.
- `docs/osm_reference.md` — **directional only.** For layer selection, role affinity, and the notability filter, `core/plotlines_core/curation/taxonomy.py` and the OSM wiki are source of truth; this markdown is a working reference that lags both.
- `docs/schemas/trip_payload.schema.json` — canonical trip payload schema. Core (Python), Dart client, and JSON all round-trip against this with zero field loss — implement trip data against it, don't invent a parallel shape.

## Spikes — and where a spike has overtaken a doc

Two series, and they are not interchangeable. The **numbered** spikes (SPIKE-00…21) predate v2.0 and settled the platform: mapping stack, elevation provider, trip payload schema, cue derivation. The **lettered** series (SPIKE-A…H) was written against the v2.0 rewrite and is the one that governs everything in the pipeline below. Index in punch-list §6; full entries in `Plotlines_Research_Spikes.md`; raw results under `spikes/SPIKE-<x>/results/RESULTS.md`.

| | Status |
|---|---|
| **SPIKE-A** notability calibration | Done — shipped `RULESET_VERSION 1.2.0`; values are **not** regional |
| **SPIKE-B** co-location cost + ranking | Done — cost is a non-issue; ranking function shipped |
| **SPIKE-C** non-whitewater difficulty coverage | Done — **split**: nordic reads, land schemas do not; see below |
| **SPIKE-D** extraction / POI indexing timing | Done — **negative**, see below |
| **SPIKE-E** driving-mode routing + access advisory | **Not run** |
| **SPIKE-F** anonymous web reading | **Not run** — gated to the web leg |
| **SPIKE-H** `LayerProvider` contract at Leg 2.5 | Done — contract holds; shipped code diverges from it |

**A spike can come back negative, and the docs are not always reconciled yet.** This is the reading habit the skill exists to install: where a doc statement and a measurement disagree, the measurement wins, and the doc is a bug to be fixed by whichever story owns it. Live divergences as of 2026-08-28:

- **ARCH §14.2's `LayerProvider` vs the shipped one.** ARCH specifies `fetch_candidates(bbox) -> list[Candidate]`, `licence -> LayerLicence`, `load_state() -> LayerLoadState`. `core/plotlines_core/curation/providers.py` ships the reduced `fetch(bbox, layers) -> list[RawFeature]`, `licence: str`. SPIKE-H validated **ARCH's** shape against real external sources — so work touching providers implements toward §14.2 rather than preserving what shipped.
- **Per-layer `/health` (N2) is unbuilt.** `per_layer` is a constant, 3 of 8 clauses pass, and **one failing layer 422s the whole extraction** — the exact inverse of PRD §5.1's rule that one layer failing never blocks the others. Root cause is the bare-list return above.
- **ARCH D34's stated reason is inverted.** It rests on "layers first, elevation second is a reordering of existing startup work (SPIKE-D confirms)" — an attribution written before the spike existed. FR121's *conclusion* survives (never block the app); its reason does not.
- **Risk A23 is backwards.** A candidate pull is ×0.43 the time of a graph build; the real cost is **×21 run-to-run variance** from public-Overpass throttling. Tiling is a *pessimisation* below ~2,500 km²; caching plus retry-with-backoff are the load-bearing mitigations.
- **`GRAPH_ESTIMATED_S = 8.0`** in `service/plotlines_service/app.py` against a measured 36.7–116.6 s graph build, and enrichment runs ×2.96 slower while the Author works. A fixed constant cannot be honest here — the indicator needs observed progress or a stated range.
- **Difficulty grading is split by schema, and land grades may not be aggregated (SPIKE-C).** `piste:difficulty` reads from OSM and rolls up to a leg — 86.4–100% coverage wherever a nordic piste exists. `sac_scale`, `trail_visibility`, `mtb:scale`, `:uphill` and `:imba` are shown **on the way that carries them and never summarised**: a leg grade is worst-of its ways, a worst-of over a sample is biased low by construction, and at real North American coverage 16–32% of such summaries are wrong and always too easy. FR14/B8's **Author declaration is the primary source** for land leg difficulty, not the fallback. Read both MTB scales and convert neither — `:imba` is the North American one (39.3% in Bentonville, 0.10% in the Tyrol) and `mtb:scale` the European one (the reverse). Every reading states its source and coverage; the silent case must never render as easy.
- **ARCH §4.3 says the notability ruleset "lives in a versioned config file."** It lives in `curation/taxonomy.py`. To add or change a tag rule, edit that and **bump `RULESET_VERSION`** — it is part of the candidate cache key.

## The story model (PRD §4)

```
Candidate (raw OSM/plugin feature, salience-scored, not yet in the trip)
  └─ promoted → Anchor (point or area; one per place)
       └─ role set: narrative | provision | station   (a set, not a type field)
            each role: own reveal policy, rendering, itinerary placement, optional geometry offset
Passage (mode + geometry + character, connects anchors; may carry its own arc role)
Arc (exposition → rising action → crux → climax → resolution; attaches to anchors AND passages)
Set (curated named place-identity a Passage/Anchor sits inside, e.g. a rail-trail or historic district)
```

**Promotion is the editorial moment** — an Author turning "what's out there" into "what this trip is about." Roles are independent: a hot spring can be narrative + provision + station on the *same* anchor with different reveal policies each. Reveal is a property of a *role*, never of a place — provision content (water, bail-out, hazards) is always visible; narrative content may be held for arrival; hazards are always visible with no exception (PRD §1.4–1.5).

**Candidates are cache; anchors are canon.** The candidate cache is keyed `(bbox, layer_set_version, filter_ruleset_version)` and is regenerable. A promoted anchor **copies** geometry, name, tags, and provenance rather than referencing the candidate — it must survive a cache wipe, a ruleset bump, and an upstream OSM edit. A dangling reference into the cache is the bug this separation exists to prevent (ARCH §4.2, P10).

## The authoring pipeline (PRD §5, ARCH §4)

`bbox (trip init) → layer selection → notability filter (salience score) → display → co-location analysis (named Author action, not ambient) → promotion → routing → narrative layering`

Every stage after Display is skippable — an Author who knows the area can hand-place a plot point and route to it directly; the pipeline exists to remove work, not to impose a wizard.

**Stages 1 and 3 run in `plotlines-core`, never the client** (ARCH §4.1) — a client-side implementation would make sidecar and hosted deployments produce *different proposals for the same bbox*. The client selects layers, displays candidates, and performs promotion. Both stages have shipped; extend them, don't reimplement them:

- `core/plotlines_core/curation/notability.py` — `score_notability`, Stage 1. Salience is a **score, not a verdict**; Stage 3 needs to know a castle outranks a boundary stone, not merely that both passed.
- `core/plotlines_core/curation/taxonomy.py` — tag rules, weights, and the **single primary role affinity** each type declares. A cluster proposes the union of the affinities present; Author override at promotion covers the rest (a hot spring is narrative by declaration, station by the Author's choice).
- `core/plotlines_core/curation/colocate.py` — `analyze_colocation` / `analyze_colocation_full`, `ColocationParams`, `reviewable_cap`, `by_corridor_proximity`, `diff_runs`. **Default rank is combined salience (noisy-OR) × tightness. Corridor proximity is a bulk filter axis and an opt-in resort — it is deliberately not in the rank**, because folding it in buried genuinely major off-route sights. Cap is `30 + 0.5 × route-km`, with the count beyond always reported, never truncated. Rejections are remembered per trip so a re-run doesn't re-propose them.

**Readiness is per-capability, and the capabilities are three independent gates** (PRD §5.0, ARCH B1): layer extraction + POI indexing unlock authoring, the **region graph** unlocks routing, elevation enrichment unlocks only elevation-dependent metrics. All three start at once. Don't reason from the old "elevation is the slow one" picture — measured on a real 704 km² bbox, extraction is 15.8–178.5 s (all of it network), the graph build is 36.7–116.6 s and is what routing actually waits on, elevation enrichment is **8.8 s**, and POI indexing is 2–51 ms and is not a cost at all.

Two planning modes, switchable per day: **Explore** (Author sets distance/shape/weights, engine returns a matching route — distance is an input constraint) vs **Compose** (Author picks a set of places, engine connects them — distance is a reported outcome, not enforced). See PRD §5.8.

## Personas (PRD §3)

**Author** (plans/curates, editor as much as planner) · **Character** (experiences in the field, acts within the story — arrivals, branches, station decisions) · **Any User** (account-level concerns) · **Developer** (platform seams: layer/plugin contract, elevation/routing abstractions, per-capability readiness).

## Non-goals — don't build these in

No real-time turn-by-turn navigation (GPS-triggered narration/cue-sheet advance is in scope, live guidance is not), no gamification (no points/badges/dice/randomness — reveal is always authored and deterministic), no quantifying people (no cohesion/ability scores — group dynamics are Author prose and arrangement, never a metric). Full list: PRD §6.2.

## Guardrails that are enforced, not advisory

- **Reveal is enforced at a boundary, never per screen** (ARCH P11). `tools/ci/reveal_gate_lint.sh` fails the build on Presentation-layer access to `Role.content` outside `RevealResolver` — the violating path is always a print preview, an export corner, or the TTS readout. A spoiled trip cannot be un-spoiled.
- **`plotlines-core` may not import fastapi** (P1) — same lint shape. If the core needs to know who the user is, the design is wrong.
- **Hazards are never subject to reveal policy**, enforced in the model — no Author setting can hide one.

## Design and UI work

For **any** visual/UI work — screens, components, colors, typography, map styling, icons, printed output — invoke the `plotlines-design` skill before writing code or producing artifacts. It owns brand tokens, the `plotlines_ui` Flutter package, and hard guardrails that are easy to violate by accident. Don't duplicate that content here or improvise brand decisions — it's a routing pointer, not a substitute for reading it.

## Workflow for picking up a story

1. Find the FR number(s) in `Plotlines_PRD_v2.md` §8 and read them in full, including any `[NEW v2.0]`/`[AMENDED v2.0]` note — several v2 requirements *contradict* the v1 reading rather than extend it.
2. Find the corresponding node(s) in `Plotlines_Author_Flows_MVP.md`; confirm the priority tag actually covers MVP before treating the feature as in-scope now.
3. Identify which story-model object(s) (Candidate/Anchor/role/Passage/Arc/Set) and pipeline stage the story touches — this determines what data shape and UI surface are correct.
4. **Check the spike record before trusting a doc claim in the curation or startup path.** Punch-list §6, then the spike's own `RESULTS.md`. If a doc statement and a measurement disagree, the measurement wins — implement to the measurement and note the doc edit your story owes.
5. Skim `Plotlines_MVP_Redirection_Punchlist.md` and PRD §10 (Open Items) for anything that overrides a literal PRD reading or resolves a question you'd otherwise treat as open.
6. If trip data is involved, implement against `docs/schemas/trip_payload.schema.json` rather than a new shape. If curation is involved, extend `core/plotlines_core/curation/` rather than starting a parallel implementation.
7. If any UI is involved, invoke `plotlines-design` before writing markup/widgets.
