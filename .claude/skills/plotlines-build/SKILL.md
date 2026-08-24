---
name: plotlines-build
description: Use this skill when implementing, extending, or reviewing Plotlines user stories/features — backend, Flutter client, or routing/data-layer work. Orients build and frontend-dev agents to the product's story model (Candidate/Anchor/Passage/Arc/Set), the authoring pipeline (bbox → layers → notability → co-location → promotion → routing → narrative), and the doc set that is source of truth. Trigger this whenever a task references an FR number, a PRD story, "Author"/"Character" flows, trip authoring, layers/notability/co-location/promotion, reveal policy, or explore/compose modes — not just when someone says "read the PRD."
user-invocable: true
---

Plotlines is a multimodal adventure-trip planner built on a story metaphor: **Authors** curate and write a journey, **Characters** experience it in the field. Story is *structure*, not decoration — it determines what objects exist and how the app behaves. Before building any feature, understand which part of the model and pipeline below it touches.

## Source of truth

`docs/Plotlines_PRD_v2.md` is canonical. **Only `_v2` docs in `docs/` are current** — any PRD/architecture file without that suffix has been removed from the repo as superseded; do not trust a stray copy that resurfaces in a branch or old context, it carries a reversed model (routing-first, node-only geometry, single readiness flag — all wrong in v2).

- `docs/Plotlines_PRD_v2.md` — vision, brand values, story model (§4), authoring pipeline (§5), scope/non-goals (§6), full FR list (§8). Read the FR(s) for your story before writing code.
- `docs/Plotlines_ARCHITECTURE_v2.md` — the *how*. **§0 lists breaking changes vs v1** — check it before assuming an old architectural pattern still holds.
- `docs/Plotlines_Author_Flows_MVP.md` — Mermaid flow diagrams per feature area, each node traced to an FR. Every node carries a priority ([MVP]/[P1]/etc) — **the priority column is authoritative**, even over a flow being drawn. A drawn flow is not itself a scope claim.
- `docs/Plotlines_MVP_Redirection_Punchlist.md` — verification checklist for the v1→v2 recomposition; explicitly names which old documents/readings are wrong, not just stale. Check it for anything that overrides a naive PRD reading.
- `docs/Plotlines_Research_Spikes.md` — feasibility spikes. Several are already resolved with a recorded decision (e.g. mapping stack, elevation provider, trip payload schema, cue derivation algorithm) — check before assuming something is an open unknown.
- `docs/osm_reference.md` — OSM tag reference driving layer selection and the notability filter.
- `docs/schemas/trip_payload.schema.json` — canonical trip payload schema. Core (Python), Dart client, and JSON all round-trip against this with zero field loss — implement trip data against it, don't invent a parallel shape.

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

## The authoring pipeline (PRD §5)

`bbox (trip init) → layer selection → notability filter (salience score) → display → co-location analysis (named Author action, not ambient) → promotion → routing → narrative layering`

Every stage after Display is skippable — an Author who knows the area can hand-place a plot point and route to it directly; the pipeline exists to remove work, not to impose a wizard. Readiness is per-capability, not global (layer/POI indexing unlocks authoring before routing/elevation finishes enriching).

Two planning modes, switchable per day: **Explore** (Author sets distance/shape/weights, engine returns a matching route — distance is an input constraint) vs **Compose** (Author picks a set of places, engine connects them — distance is a reported outcome, not enforced). See PRD §5.8.

## Personas (PRD §3)

**Author** (plans/curates, editor as much as planner) · **Character** (experiences in the field, acts within the story — arrivals, branches, station decisions) · **Any User** (account-level concerns) · **Developer** (platform seams: layer/plugin contract, elevation/routing abstractions, per-capability readiness).

## Non-goals — don't build these in

No real-time turn-by-turn navigation (GPS-triggered narration/cue-sheet advance is in scope, live guidance is not), no gamification (no points/badges/dice/randomness — reveal is always authored and deterministic), no quantifying people (no cohesion/ability scores — group dynamics are Author prose and arrangement, never a metric). Full list: PRD §6.2.

## Design and UI work

For **any** visual/UI work — screens, components, colors, typography, map styling, icons, printed output — invoke the `plotlines-design` skill (`client/design/SKILL.md`) before writing code or producing artifacts. It owns brand tokens, the `plotlines_ui` Flutter package, and hard guardrails (Blaze buttons need ≥16 bold paper-text labels, Gold is fill-only never text, every map marker needs a distinct shape + internal mark not just color, numbers are always set in mono). Don't duplicate that content here or improvise brand decisions — it's a routing pointer, not a substitute for reading it.

## Workflow for picking up a story

1. Find the FR number(s) in `Plotlines_PRD_v2.md` §8 and read them in full, including any `[NEW v2.0]`/`[AMENDED v2.0]` note — several v2 requirements *contradict* the v1 reading rather than extend it.
2. Find the corresponding node(s) in `Plotlines_Author_Flows_MVP.md`; confirm the priority tag actually covers MVP before treating the feature as in-scope now.
3. Identify which story-model object(s) (Candidate/Anchor/role/Passage/Arc/Set) and pipeline stage the story touches — this determines what data shape and UI surface are correct.
4. Skim `Plotlines_MVP_Redirection_Punchlist.md` and `Plotlines_Research_Spikes.md` for anything that overrides a literal PRD reading or resolves a feasibility question you'd otherwise treat as open.
5. If trip data is involved, implement against `docs/schemas/trip_payload.schema.json` rather than a new shape.
6. If any UI is involved, invoke `plotlines-design` before writing markup/widgets.
