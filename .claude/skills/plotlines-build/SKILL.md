---
name: plotlines-build
description: Use this skill when implementing, extending, or reviewing Plotlines user stories/features — backend, Flutter client, or routing/data-layer work. Orients build and frontend-dev agents to the product's story model (Candidate/Anchor/Passage/Arc/Set), the authoring pipeline (bbox → layers → notability → co-location → promotion → routing → narrative), the shipped curation modules, and the doc set that is source of truth — including the places where a measured spike has overtaken the docs. Also carries the working agreement for issue work: which tests to write and run, branch/commit/PR conventions, what to do with a defect found mid-stream, and how to record the outcome on the project board. Trigger this whenever a task references an FR number, a PRD story, "Author"/"Character" flows, trip authoring, layers/notability/co-location/promotion, reveal policy, explore/compose modes, or OSM data acquisition (Overpass, Geofabrik extracts, the tile/data mirror, geocoding) — not just when someone says "read the PRD."
user-invocable: true
---

Plotlines is a multimodal adventure-trip planner built on a story metaphor: **Authors** curate and write a journey, **Characters** experience it in the field. Story is *structure*, not decoration — it determines what objects exist and how the app behaves. Before building any feature, understand which part of the model and pipeline below it touches.

## Source of truth

`docs/Plotlines_PRD_v2.md` is canonical. **Only `_v2` docs in `docs/` are current** — any PRD/architecture file without that suffix has been removed from the repo as superseded; do not trust a stray copy that resurfaces in a branch or old context, it carries a reversed model (routing-first, node-only geometry, single readiness flag — all wrong in v2).

- `docs/Plotlines_PRD_v2.md` — vision, brand values, story model (§4), authoring pipeline (§5), scope/non-goals (§6), full FR list (§8), stories (§9), open items (§10). Read the FR(s) for your story before writing code.
- `docs/Plotlines_ARCHITECTURE_v2.md` — the *how*. **§0 lists breaking changes vs v1** — check it before assuming an old architectural pattern still holds. §4 is the curation tier; §17 is the decision log; §18 the open questions.
- `docs/Plotlines_Author_Flows_MVP.md` — Mermaid flow diagrams per feature area, each node traced to an FR. Every node carries a priority ([MVP]/[P1]/etc) — **the priority column is authoritative**, even over a flow being drawn. A drawn flow is not itself a scope claim.
- `docs/Plotlines_MVP_Redirection_Punchlist.md` — verification checklist for the v1→v2 recomposition; explicitly names which old documents/readings are wrong, not just stale. **§6 is the spike checklist, §6A the two CI gates, §7 the standing constraints (see the `plotlines-constraints` skill), and §3A the dependency-ordered MVP build queue** — if you are picking the *next* thing to build rather than a named issue, §3A is the ordering, not the board's raw Todo list.
- `docs/Plotlines_Research_Spikes.md` — feasibility spikes, with full entries and the summary table. See "Spikes" below — this doc has teeth now, and one of its results *contradicts* the architecture.
- `docs/Plotlines_OSM_Acquisition_Review.md` + `docs/Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md` — **accepted 2026-09-03.** How Plotlines acquires OSM data for the routing graph, candidates, and geocoding, and what is owed for it. This is the standing decision that Overpass comes **out of the hot path** in favour of mirrored Geofabrik extracts clipped per bbox. Read it before touching `graph/regions.py`, `curation/providers.py`, or `/geocode`. Execution is filed in six epics — Phase 0 **#254** (stop the load now, no dependencies), Phase 1 **#264** (the mirror), Phase 2 **#268** (SPIKE-I/SPIKE-J), Phase 3 **#272** (the transport swap), Phase 4 **#279** (hosted), Phase 5 **#283** (the policy gate).
- `docs/osm_reference.md` — **directional only.** For layer selection, role affinity, and the notability filter, `core/plotlines_core/curation/taxonomy.py` and the OSM wiki are source of truth; this markdown is a working reference that lags both.
- `docs/schemas/trip_payload.schema.json` — canonical trip payload schema. Core (Python), Dart client, and JSON all round-trip against this with zero field loss — implement trip data against it, don't invent a parallel shape.

## Spikes — and where a spike has overtaken a doc

Two series, and they are not interchangeable. The **numbered** spikes (SPIKE-00…21) predate v2.0 and settled the platform: mapping stack, elevation provider, trip payload schema, cue derivation — though the series is still live (SPIKE-17 ran 2026-09-01). The **lettered** series (SPIKE-A…J) was written against the v2.0 rewrite and is the one that governs everything in the pipeline below. Index in punch-list §6 and §3A; full entries in `Plotlines_Research_Spikes.md`; raw results under `spikes/SPIKE-<x>/results/RESULTS.md`.

| | Status |
|---|---|
| **SPIKE-A** notability calibration | Done — shipped `RULESET_VERSION 1.2.0`; values are **not** regional |
| **SPIKE-B** co-location cost + ranking | Done — cost is a non-issue; ranking function shipped |
| **SPIKE-C** non-whitewater difficulty coverage | Done — **split**: nordic reads, land schemas do not; see below |
| **SPIKE-D** extraction / POI indexing timing | Done — **negative**, see below |
| **SPIKE-E** driving-mode routing + access advisory | Done 2026-08-31 — solver passes, **graph configuration fails**; see below |
| **SPIKE-F** anonymous web reading | Done 2026-08-30 — decision spike, closed as ARCH **D59**; still gated to Leg 4 |
| **SPIKE-G** candidate/proposal rendering at bbox scale | Done 2026-08-29 — closed ARCH Q15; see below |
| **SPIKE-H** `LayerProvider` contract at Leg 2.5 | Done — contract holds, and the shipped code has since converged on it |
| **SPIKE-17** community edge-data + API normalisation | Done 2026-09-01 — positive; **two §14.2 revisions owed**, see below |
| **SPIKE-I / SPIKE-J** local-extract parity; freeze matrix | **Filed (#265 / #266), not run** — Phase 2 of the acquisition plan; they gate the transport swap |

Two reading notes on the index itself. Punch-list §6's SPIKE-H entry still says *"the series is A–F and H; there is no SPIKE-G"* — that was written 2026-08-28 and **SPIKE-G was created the next day**; §3A carries it. And SPIKE-F is a *decision* spike: its harness is the specification for the Dart `RevealResolver` work at H13, not a throwaway.

**A spike can come back negative, and the docs are not always reconciled yet.** This is the reading habit the skill exists to install: where a doc statement and a measurement disagree, the measurement wins, and the doc is a bug to be fixed by whichever story owns it. Live divergences as of 2026-09-03:

- **Acquisition: the shipped OSM transport is the one being removed.** `graph/regions.py` and `curation/providers.py` hotlink volunteer-operated Overpass hosts per trip bbox, under a `User-Agent` that names someone else's library — the exact behaviour `tiles/mirror.py` makes mechanically impossible for basemap tiles. The acquisition review is accepted; **do not build new work onto the public-Overpass path**, and treat A23's mitigations as interim. Phase 0 (#254) is unblocked and dependency-free.
- **The privacy statement is currently false, and it is false about this.** `client/lib/domain/privacy_statement.dart` (mirrored in `core/plotlines_core/web/about.py`, pinned by tests on both sides) says planning sends nothing anywhere; drawing a bbox sends it to a third party in Germany or Lithuania, and `/geocode` sends the Author's typed place name to Nominatim. Any FR138/K10 work must fix the sentence, not preserve it (addendum P1).
- **SPIKE-E: `network_type="drive"` is a download filter, not a routing choice.** It drops `highway=track` **and** `highway=service` before a way reaches the graph, so driving mode routes to 265 m short of a real trailhead and **reports success**. Two shipped defects filed — **#205** (`cues.route_polyline` edge spans do not tile the route; 13.9–26.4% unattributed) and **#206** (`graph/regions.py` downloads neither `4wd_only` nor `motor_vehicle` and cannot carry node-tagged `barrier`, leaving `_BARRIER_DEFAULTS` unreachable for every mode). Driving's flat 60 km/h time model is off by −44.6% on a rough approach. At driving's `directness=0.95` the other weights are decoration — do not tune them expecting a route change.
- **ARCH D34's stated reason is inverted.** It rests on "layers first, elevation second is a reordering of existing startup work (SPIKE-D confirms)" — an attribution written before the spike existed. FR121's *conclusion* survives (never block the app); its reason does not.
- **SPIKE-17 hands ARCH §14.2 two revisions, due before Leg 7 publishes the contract.** The annotation Protocols need `licence` (a real conformant feed — 511 NY — declares none, and D45 says it must not load; §14.2 has nowhere to refuse it) and `load_state()` (without it an unreachable source is indistinguishable from "no hazards here", which for an advisory reads as all-clear). Edge annotations live under `advisory:` and **nothing in core reads them** — that is what keeps FR14/FR29a advisory rather than FR128 constraint; keep it that way.
- **Risk A23 is backwards.** A candidate pull is ×0.43 the time of a graph build; the real cost is **×21 run-to-run variance** from public-Overpass throttling. Tiling is a *pessimisation* below ~2,500 km²; caching plus retry-with-backoff are the load-bearing mitigations — and per the acquisition review they *absorb* the variance rather than remove it, which is why the mirror exists. **#287 closes A23/A23a and punch-list 2A.3 once SPIKE-I measures the extract.**
- **Rendering has a measured ceiling (SPIKE-G).** Candidates render as salience-gated markers (K≈300 on the GPU) with a canvas-dot tail and a grid-cluster backstop; the GPU display-density ceiling is **~2,800 candidates**, and A16's memory figure is restated at ~1.15 GB with the candidate layer immaterial. The live harness is `spikes/SPIKE-G/HARNESS.md`. The whole model is calibrated against the osmnx-era data path, so **#276 re-validates it** (with SPIKE-A's golden sets and SPIKE-21's cue derivation) after the transport swap.
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
- `core/plotlines_core/curation/providers.py` + `registry.py` — the **§14.2 shape has landed**: `LayerProvider` is a four-member structural Protocol (`taxonomy`, `licence -> LayerLicence`, `fetch_candidates(bbox)`, `load_state() -> LayerLoadState`), with `SharedOsmFetch` reconciling the one bend SPIKE-H recorded (six built-in layers, one Overpass call). The registry refuses a layer with absent or unsatisfiable licence metadata **at registration** (`failed:licence_unsatisfiable`, never queried), reports `per_layer` / `per_layer_detail` for `/health`, and **returns what it did get instead of 422-ing the whole request**. The legacy `OsmLayerProvider.fetch(bbox, layers)` still exists for backward compatibility — write new work against `LayerProvider`.

**Other seams that have shipped since — point at them rather than starting a parallel implementation:** `cache_layout.py` (the one bbox-scoped cache key/dir definition for tiles, elevation, and the reserved candidate slot — FR94), `tiles/mirror.py` (hotlink refusal, `classify_upstream`, `--allow-unmirrored-tiles`, `basemap_attribution`), `curation/attribution.py` (`attributions_for` / `assert_attribution_complete`), `elevation/` (provider interface + void policy; the OpenTopography acquisition itself is still gated on #148/FR87), `scoring/profile.py` (`Weights` / `WeightScope`, `weights.at(position)` per-edge lookup), `trips/spine.py` (E3 compose spine), `trips/dashboard.py` (D1, three scopes + the FR16 time model), `export/fit.py` (the dependency-free FIT writer; reveal applied before the first byte), `web/session.py` (`SessionCookiePolicy` — hosted mode requires `--web-domain`), and `client/lib/data/sidecar_*.dart` (M12 spawn / health-poll / restart-once / orphan-sweep / paired version).

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
- **Never hotlink a third-party data host.** `tiles/mirror.py` raises `HotlinkRefused` if the extractor is pointed at one; the equivalent gate for the OSM path is Phase 5 (#284), so **until it lands the rule is held by review, not by a test** — which is exactly the window in which an endpoint list grows under pressure (addendum P6). A default-endpoint-list regrowth test and a non-default-`User-Agent` test are Phase 0 work and testable today.
- **Attribution failure is a build failure, and the gate must reach every payload.** `curation/attribution.py::assert_attribution_complete` and `web/about.py::assert_about_attribution_complete` enumerate loaded `LayerProvider`s; the basemap's ODbL line is merged in from `mirror.basemap_attribution` and elevation's CC BY from `elevation/region_asset.py`. **The routing graph is in neither half** — its credit is currently inherited from the basemap by accident (#269 brings it under the gate).

## Standing constraints

Two dozen project-wide invariants (punch-list §7) hold across every change and mostly **will not fail loudly** when violated. They live in the `plotlines-constraints` skill — invoke it before calling any change done, not only when a task sounds like reveal or consent work.

## Design and UI work

For **any** visual/UI work — screens, components, colors, typography, map styling, icons, printed output — invoke the `plotlines-design` skill before writing code or producing artifacts. It owns brand tokens, the `plotlines_ui` Flutter package, and hard guardrails that are easy to violate by accident. Don't duplicate that content here or improvise brand decisions — it's a routing pointer, not a substitute for reading it.

## Workflow for picking up a story

0. **Read the issue itself first** — body, every `- [ ]` checkbox, and the acceptance-criterion clauses. Those checkboxes are what the board Status is judged against at the end, so they are the actual scope; the PRD tells you what they *mean*, not what they are. Then **branch before you edit** (see "Branch, commit, PR").
1. Find the FR number(s) in `Plotlines_PRD_v2.md` §8 and read them in full, including any `[NEW v2.0]`/`[AMENDED v2.0]` note — several v2 requirements *contradict* the v1 reading rather than extend it.
2. Find the corresponding node(s) in `Plotlines_Author_Flows_MVP.md`; confirm the priority tag actually covers MVP before treating the feature as in-scope now.
3. Identify which story-model object(s) (Candidate/Anchor/role/Passage/Arc/Set) and pipeline stage the story touches — this determines what data shape and UI surface are correct.
4. **Check the spike record before trusting a doc claim in the curation or startup path.** Punch-list §6, then the spike's own `RESULTS.md`. If a doc statement and a measurement disagree, the measurement wins — implement to the measurement and note the doc edit your story owes.
5. Skim `Plotlines_MVP_Redirection_Punchlist.md` and PRD §10 (Open Items) for anything that overrides a literal PRD reading or resolves a question you'd otherwise treat as open.
6. If trip data is involved, implement against `docs/schemas/trip_payload.schema.json` rather than a new shape. If curation is involved, extend `core/plotlines_core/curation/` rather than starting a parallel implementation.
7. **If the story fetches OSM data — graph, candidates, or geocoding — read the acquisition review first.** The transport is mid-migration and the target is a mirrored, clipped extract, not a public endpoint.
8. If any UI is involved, invoke `plotlines-design` before writing markup/widgets.
9. **Write or update the tests as part of the change, not after it** — see "Tests" below. A story is not implemented until its behaviour is asserted somewhere.
10. **If you find a defect that isn't this story's**, don't silently fix it and don't drop it — see "Something you found mid-stream".
11. Before calling it done, run the change past `plotlines-constraints`, and run the full suite plus the lint gates green.
12. **Commit on the branch and open a PR** that closes the issue (see "Branch, commit, PR").
13. When you finish **or stop** work on the issue, set its **Plotlines Project** board Status (`Dev Complete` only if every item is done, otherwise `In Progress`) and post an outcome comment. See "GitHub issues — status and completion" below.

## Tests

**Every change carries its tests in the same commit.** New behaviour gets new tests; changed behaviour gets its existing tests updated rather than deleted or `skip`ped; a fixed defect gets a regression test that **fails against the old code** — say so in the PR when you've confirmed that.

Where they live, and what to run — these are exactly the CI jobs in `.github/workflows/ci.yml`, so a green local run means a green PR:

| | Tests | Command |
|---|---|---|
| core | `core/tests/test_*.py` | `cd core && uv run --frozen pytest` |
| service | `service/tests/test_*.py` | `cd service && uv run --frozen pytest` |
| client | `client/test/*_test.dart` | `cd client && flutter test` |

Plus three gates that need no toolchain and are cheap to run before you push:

- `tools/ci/reveal_gate_lint.sh` — the reveal gate **and** the no-authored-text-in-a-template gate (§6A.1, FR145).
- `grep -rnE '^\s*(import fastapi|from fastapi)' core/plotlines_core/` must find nothing (P1).
- `PYTHONPATH=core python3 spikes/SPIKE-20/run.py --check-committed` — the payload fixtures still validate against the schema and every FR-map pointer resolves. (CI writes it as `python`; locally only `python3` is on `PATH`.)

Golden data lives in `core/tests/golden/` and fixtures in `core/tests/fixtures/`. **A golden diff is a finding to explain, never a file to regenerate** until you can say why it moved — the notability goldens are SPIKE-A's calibration, and #276 exists because that calibration has to be re-earned when the data path changes underneath it.

Two conventions worth keeping, both learned the hard way in this repo:

- **Assert the observable output, not the executed line.** `payload.py` reported 95% coverage while a mutation flipping `or`→`and` made a whole field vanish from the emitted payload with all 890 tests green (#235 B1). The answer was a field-presence oracle that builds a populated instance of every payload dataclass and asserts, one field at a time, that it survives `to_dict()`. Coverage that never asserts on the emitted bytes/keys is coverage you did not earn.
- **Never write a test count into a name or a label.** Nobody updates it, it drifts within a PR or two, and then it reads as an assertion the repo is quietly failing — CI's job names carried `867 / 123 / 1154` against actual counts of `890 / 147 / 1234` before they were stripped (#235 C). Suites report their own totals; the issue comment is the right place for a count, because it is dated.

## Branch, commit, PR

Issue work happens on a branch and lands as a PR. **Never commit to `main`.**

1. **Branch off current `main`**, named `<kind>/<issue-number>-<slug>` — `kind` is one of `feat` / `fix` / `bug` / `chore` / `spike`, matching the issue's own nature (`feat/214-compose-itinerary-client`, `fix/235-code-review-findings`, `bug/232-instrument-region-build`, `spike/17-community-edge-data`).
2. **Commit in meaningful units.** A subject line in the imperative, then a body that says **why** — the constraint that forced the shape, the measurement behind a number, the alternative rejected and on what grounds. This repo's commit bodies are where the reasoning lives; a one-line "fix bug" commit throws away the part that will be needed in six months. Multi-part work lands as multiple commits (defects first, then coverage, then hygiene) rather than one squashed blob.
3. **Open the PR with `gh pr create`**, base `main`. Body: `Closes #N`, then what changed and what it was measured against. Where you have numbers — coverage, test counts before/after, timings — put them in a table and make sure every one is *measured, not estimated*. If anything is deferred, name it and link its issue.
4. **Do not merge.** Merging, and any force-push or history rewrite, is the user's call. Pushing the branch and opening the PR is the end of the agent's lane.

## Something you found mid-stream

Working one story routinely turns up a defect that belongs to another. Neither silently fixing it nor mentioning it in passing is right — SPIKE-E surfaced two shipped defects and they became #205 and #206, which is the pattern to copy.

1. **Search first — assume it's already filed.** `gh issue list --state all --search "<symptom or symbol>"`, and search the closed ones too; a reopened or duplicated issue costs the user more than a missed one.
2. **If it exists**, add what you learned as a comment — the new reproduction, the measurement, the second call site — rather than opening a rival issue.
3. **If it doesn't, file it.** Title states the defect and its consequence in one line ("Bug: `cues.route_polyline`'s `RouteEdge` spans do not tile the route — up to 26% of every route belongs to no edge"). Body: the offending code with a file:line reference, a **minimal reproduction**, what it measures on real data if you have that, and *why it matters* — which requirement or invariant it breaks. Label it (`bug` / `enhancement` / `documentation`, plus the priority label `mvp` / `p1` / `later` and a surface label `desktop` / `web` / `mobile` when it's surface-specific).
4. **Link both ways and stay in your lane.** Reference the new issue from the story you're working and from the PR. Fix it in your PR **only if the story cannot be completed without it**, and say so explicitly in both; otherwise leave it filed and keep the scope you were given.

A doc that a measurement has overtaken is the same situation: the doc edit is owed by whichever story owns it, so name it in the PR or file it — don't leave it in the transcript only.

## GitHub issues — status and completion

**Use the `gh` CLI for every GitHub operation** — issues, comments, labels, PRs, and the project board. Don't hand-assemble REST/GraphQL URLs or push the user toward the web UI when `gh` covers it; `gh api graphql` is the fallback only for the few project-board mutations `gh` has no porcelain for. If `gh` isn't authenticated, say so and stop — don't fall back to raw `git`+API guesswork.

Every Story issue is tracked on the **Plotlines Project** board (`gh project` number **1**, owner **`gnfrazier`**) via its **Status** field. Set that Status whenever you stop work on an issue, so the user can see where it stands without reading the whole thread:

- **All items done → `Dev Complete`.** Every acceptance-criterion clause is satisfied, every `- [ ]` checkbox in the issue body is checked, nothing was deferred, stubbed, or left as a `TODO`, the three suites and the four gates in "Tests" are green, and the PR is open. **Green means you ran them** — not that the change looked safe.
- **Anything left → `In Progress`.** One clause unmet, one checkbox open, a sub-item blocked on a decision or another issue, a spike divergence noted but not resolved — any of these. `In Progress` is the user's cue to revisit, so it is the right state for any worked issue that is not wholly finished. Never leave a worked issue at `Todo`.

The board's options are `Todo / In Progress / Dev Complete / In QA/UAT / Done`. `In QA/UAT` and `Done` are the user's to set — the build agent goes no further than `Dev Complete`. Leave the issue **open** either way: `Dev Complete` is a board state, not issue closure — the PR's `Closes #N` does that when the user merges. Branching, committing, pushing the branch, and opening the PR are part of working an issue and need no separate permission; **merging is not**.

### Recording the outcome

1. **Post a comment on the issue.** Keep the existing `**Dev complete — <story>**` shape: new/changed files, which FR clauses are covered, test count, the PR link, any issue filed along the way, and anything skipped. If the Status is going to `In Progress`, the comment **must enumerate exactly what remains and why**, so the revisit has a starting point.
2. **Set the board Status.** This `gh` version has no `--value` flag, so use the node-ID form (stable across the board's life):

   ```bash
   PROJECT_ID=PVT_kwHOAUDf284BgF6X                     # Plotlines Project
   STATUS_FIELD=PVTSSF_lAHOAUDf284BgF6XzhaUEnc         # "Status" single-select
   OPT_IN_PROGRESS=47fc9ee4
   OPT_DEV_COMPLETE=78a2be76

   ISSUE=<N>
   # ensure the issue is on the board, then get its item id:
   gh project item-add 1 --owner gnfrazier --url "https://github.com/gnfrazier/plotlines/issues/$ISSUE" 2>/dev/null || true
   ITEM_ID=$(gh project item-list 1 --owner gnfrazier --format json --limit 400 \
     | jq -r --argjson n "$ISSUE" '.items[] | select(.content.number==$n) | .id')

   gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" \
     --field-id "$STATUS_FIELD" --single-select-option-id "$OPT_DEV_COMPLETE"   # or "$OPT_IN_PROGRESS"
   ```

   If those IDs ever stop resolving (board recreated), re-read them:
   `gh project field-list 1 --owner gnfrazier` for the field id, then
   `gh api graphql -f query='{ node(id:"<field-id>"){ ... on ProjectV2SingleSelectField { options { id name } } } }'`.
   A newer `gh` also accepts the friendly form: `gh project item-edit --owner gnfrazier 1 --url <issue-url> --field Status --value "Dev Complete"`.
