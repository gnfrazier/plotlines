---
name: plotlines-constraints
description: Plotlines' standing constraints — the project-wide invariants (punch-list §7, plus the accepted OSM acquisition and licensing policy) that hold across every decision and mostly will not surface as a test failure when violated. Use this whenever implementing, reviewing, or designing any Plotlines change, and especially anything touching reveal or hazards, consent / sharing / cloning, Author notes or deletion, arrival and position data, attribution and licensing, OSM data acquisition or third-party endpoints, privacy claims about what leaves the device, the candidate cache, layer role-affinity, enumerated lists or lookup tables, recompute / stale-vs-orphan editing, error surfaces, message templates, display-format vs stored data, scoring people or group dynamics, gamification, or advisory-vs-constraint calls. Check the change against the relevant invariants before calling the work done.
user-invocable: true
---

These are the standing constraints from `docs/Plotlines_MVP_Redirection_Punchlist.md` §7, plus the acquisition, licensing, and privacy invariants accepted with the OSM acquisition review on 2026-09-03 (marked where they appear). Unlike an acceptance scenario, **none of them is checkable once.** They are invariants that hold across every implementation, review, and design decision, and most of them **do not fail loudly** — a violation ships as a quietly wrong behaviour, not a red test, unless someone wrote the test that catches it. That is why they live in a skill: so the check happens every time, not only when someone remembers.

## How to use this

This is a review gate, not a document to read once and forget. Before treating any Plotlines change as done — yours or one you are reviewing — identify which of the groups below the change touches and check it against those invariants. If the change is in the curation, reveal, consent, editing, or messaging path, at least one group almost certainly applies.

When a constraint here and a literal PRD/ARCH reading disagree, this skill wins for the invariant itself; when a constraint and a **measured spike** disagree, the measurement wins and both are a doc bug (see `plotlines-build`). Each entry names its FR / ARCH refs so you can read the origin.

---

## Story integrity and determinism

**No gamification.** No points, badges, achievements, unlockables, leaderboards, dice, or randomness anywhere. Every route, branch, and reveal is authored and deterministic — a Character who rides the same trip twice gets the same story. If a design introduces a random draw or a score-to-unlock, it has crossed a brand line, not added a feature. *(Brand Value 9, FR125)*

**The analysis never decides.** Co-location clusters *propose*; the Author *promotes*. Nothing enters a trip without an editorial act. A flow in which promotion is only reachable through an accepted proposal has inverted the dependency — direct promotion (layers → candidates → promote → roles) must always work without the analysis branch. *(FR102, FR110; ARCH P10)*

**Every stage after display is skippable.** An Author who knows the area drops a plot point and routes to it — no wizard, no forced pipeline. The pipeline (layers → notability → co-location → promotion → routing) exists to *remove* work, never to impose a sequence. If any stage becomes mandatory to reach the next, that is the violation. *(PRD §5; ARCH P10)*

---

## Reveal and safety

**Hazards are never hidden.** No Author, no setting, no role, no trip type can set a hazard or crux to revealed-on-arrival. Model-enforced, not UI-absence-enforced — the model rejects it on every path. A spoiled trip cannot be un-spoiled, but a hidden hazard is a safety failure, which is worse. *(FR115, C11)*

**Reveal is enforced at one gate.** Render, export, print, offline package, and plugin push all pass through `RevealResolver`. Hazards are exempt *inside* the resolver, so the exemption exists in exactly one place instead of being re-remembered at every surface. `tools/ci/reveal_gate_lint.sh` fails the build on Presentation-layer access to `Role.content` outside the resolver; §6A.2 adds byte-level assertions that unrevealed content is absent from every export format's output bytes (and from the string handed to the speech engine). The violating path is always a print preview, an export corner, or the TTS readout. *(ARCH P11, D39; §6A)*

**A message is a template, not a sentence.** Every user-visible string resolves a fixed template against typed slots, with cause phrases drawn from a bounded table — never composed from call-site strings at runtime. This is a **safety** constraint as much as a scope one: a sentence assembled in Presentation is downstream of the export byte assertions and is therefore a path around the reveal gate that those assertions structurally cannot see. No template accepts `Role.content` or any authored text field. *(FR145; ARCH P11, D57, A30)*

---

## Consent and privacy

**Default nothing shared.** Every consent decision starts closed and requires an explicit Character action to open. **This survives cloning** — a clone never carries a grant or an arrival-visibility permission forward, because if it did, cloning becomes a consent-laundering path: last year's medical disclosure silently re-shared on this year's different trip. *(FR78, FR123, FR74)*

**Author notes never release.** Not withheld-then-released — **never**, in any state, by any path (export, print, share link, offline package, group relay, plugin `pushTrip`, TTS, trip archive). A bug that promotes a note to *withheld* is as bad as one that renders it, because *withheld* implies a future release and an Author note has none. Assert on output bytes, not code paths. *(FR135; ARCH P11)*

**Delete means gone.** No soft-delete column on `author_note`. Deletion propagates as an explicit tombstone, not as an absence — an absence gets union-merged back into existence by any device that never learned of the delete. An implementation that passes every other consent test and fails only "the notes come back after an offline device syncs" has this wrong. *(FR135a; ARCH §11.7, D51)*

**Never put a number on a person.** No cohesion score, compatibility rating, or ability index anywhere in the schema or the UI. Group-dynamics knowledge enters only as an Author's prose and as arrangement (grouping, pairing, sequencing). A Character's *own* stated preferences and their derived pace are a different thing and stay in scope. *(PRD D-N, non-goals §6.2)*

**Not a tracker.** Arrival events are discrete, sparse, tied to authored content, consented, and revocable. If a design ever needs continuous position sharing, it has crossed a non-goal. *(§6.2, FR123)*

**Arrivals are discrete by schema, not by discipline.** The arrivals endpoint accepts an anchor reference, never a bare coordinate, and **no position table exists anywhere in the schema** — deliberately. The gap between "post an event when a trigger fires" and "post position every 30 seconds" is one well-intentioned commit; the schema is what prevents it. *(ARCH §8.5, D43, A25)*

---

## Attribution, licensing, and data acquisition

*(The four below come from the OSM acquisition review and its licensing addendum, accepted 2026-09-03, rather than from §7 — but they are the same kind of rule: invariants that hold across every change and fail quietly. Read `docs/Plotlines_OSM_Acquisition_Review.md` for the full plan.)*

**Attribution is a build failure — and the gate covers every payload, not every *layer*.** Elevation (CC BY), basemap (ODbL), and every plugin layer's own terms are all owed, none substitutes for another, and all must propagate to exports and print. A layer with absent or unsatisfiable licence metadata **does not load** — refused at registration, not warned at render. The About surface enumerates loaded layers dynamically; it is never a hardcoded credit list. The live hole to watch: `curation/attribution.py`'s `assert_attribution_complete` and `web/about.py`'s `assert_about_attribution_complete` both enumerate loaded `LayerProvider`s, so **the routing graph is credited only by accident**, inheriting the basemap's ODbL line — which stops being true the moment a non-OSM basemap is offered. One gate, every payload, including the graph. *(FR86, FR95, FR101, K10; ARCH §12.2, D45; addendum L6, #269)*

**Mirror the source; never hotlink a third party.** This is settled policy for basemap tiles and mechanical — `tiles/mirror.py` raises `HotlinkRefused`. The same policy governs OSM: bulk acquisition moves to mirrored Geofabrik extracts clipped per bbox, and only small, user-initiated, hard-capped Overpass use survives. "Small and polite" is not a standard — the caps are four assertable numbers (bbox area **below** `max_query_area_size` so a query can never subdivide, concurrency 1, a per-day budget that fails closed with an honest message, **no automatic retry**: a user-initiated action that fails is re-initiated by the user or not at all). **The OSM half of this gate is Phase 5 and does not exist yet**, so during the whole migration window the rule is held by review — and a docstring full of excellent policy reasoning sitting above an endpoint list is precisely how that list grew. Identify ourselves in every outbound request: a Plotlines `User-Agent` with a contact URL, never a library's default. *(§4, §10; addendum P4, P5, P6)*

**ODbL share-alike triggers on public use, not on handing over a file.** Making a derived database available over a network is Publicly Use — so hosted web, and arguably trip sharing, cloning, and the anonymous reading view **today**, implicate §4.4/§4.6, not just a future export. The cheap structural move, worth keeping intact: OSM-derived fields stay **separably identifiable** from Plotlines-authored fields (a per-feature source/provenance discriminator on the candidate record and on the promoted node), so an offer-the-database obligation can be met by exporting the OSM layer rather than the whole trip store. Retrofitting that after Authors have data is the expensive version. *(addendum L2, L3; Q4 → #253)*

**A trip records which snapshot it was built from.** A trip pins its OSM build and does not shift under the Author mid-planning — and the pin is **written into the payload** (`Provenance` in `trips/payload.py`), not just held in ops. Without it a trip built from a stale pin is indistinguishable from a fresh one, and an export carrying "contains OSM data, snapshot 2026-09-01" is a stronger §4.3 notice than a bare credit. `Provenance` is declared but never constructed today, while the client already reads it. *(addendum L7; #270, #277)*

**Say truthfully what leaves the device.** The privacy statement (`client/lib/domain/privacy_statement.dart`, mirrored in `web/about.py`, pinned by tests on both sides, reachable from every surface) currently says planning sends nothing anywhere. It does: drawing a bbox sends it to a volunteer-run third party, and `/geocode` sends the Author's typed place name to Nominatim. A user-facing accuracy claim about data egress is a constraint, not copy — when the behaviour changes, the sentence changes in the same commit. *(FR138, K10; addendum P1)*

---

## Navigation scope

**Not a nav device.** GPS triggers authored content and advances a glanceable cue sheet. No turn-by-turn, no wrong-turn recalculation, no follow-the-line guidance. GPS-triggered narration and cue-sheet advance are in scope; live guidance is not. *(§6.2)*

---

## Data-model discipline

**Candidates are not canon.** Candidates live in a regenerable, bbox-scoped cache keyed by layer set *and* ruleset version. A promoted anchor **copies** the geometry, name, tags, and provenance it needs — it never holds a reference into the cache. Deleting the cache must cost a re-extraction and never authored work. *(ARCH §4.2, D36)*

**Display formats never reach stored data.** Date, time, and unit preferences are render-time transforms only. ISO 8601 is the sole stored, exported, filename, and content-digest form. A display format in a payload makes the content digest depend on who was looking at it. *(ARCH D49)*

**Two authoring extents, never conflated.** The **shipped home region** (Buncombe County rectangle — a compile-time constant, no override, no prompt, no download) and the **trip bbox** (drawn by the Author; bounds candidates, clusters, tiles, elevation). The **offline corridor buffer** is Character-side and never appears in the authoring flow. Conflating the last two has Characters downloading a county to ride a corridor. Every extent is justified by a trip, except the one that costs nothing. *(ARCH D41, supersedes D32)*

**A list is a seed set; state the rule beside it.** An enumerated list in a requirement is a seed set unless it explicitly says otherwise, and the rule that generated the list must be written down next to it — if the rule is not stated, the list gets implemented *as* the rule. Applies to notability rules, role affinity, Set detection, routability constraints, and anything added later that reads like a lookup table. With plugins this turns a limitation into a *silent* failure: an unlisted type produces no proposals, no error, no log. *(§0; PRD D-L)*

**Affinity is declared by the layer, never inferred by the core.** A core-side type→role lookup table is the §0 failure mode in its highest-consequence location: plugin layers silently produce zero proposals because no entry exists for their types. Each layer declares its own role affinity in the contract; a cluster proposes the union of the affinities present, and the Author overrides the rest at promotion. *(ARCH D47; FR100, FR105)*

---

## Editing model

**Orphaned authored work prompts; invalidated derived work goes stale.** Two mechanisms, never merged. A confirmation prompt belongs only where an action *destroys* something an Author made — removing a passage that carries anchors and content, cutting days that hold content. It never belongs where an action merely *recomputes* a route. *(FR139, FR140; ARCH §7.10, D-O)*

**Nothing recomputes on its own.** An edit marks derived work stale; re-solving is an explicit call, and re-solve-all clears every stale marker in one unconfirmed action. Eager recompute is the Riverpod layer's *default* unless someone opts out, so this needs active watching, not assuming. *(ARCH D52, A28)*

**Two things sit deliberately outside the shared error surface** — compose-mode distance deviation and the stale list. Routing either through the shared error/M13 path teaches the Author that ordinary editing produces errors. A 94-mile compose day is an editing outcome with drop/defer/split/widen/accept affordances, not a conflict dialog; a stale export attempt opens the stale list, not an error. *(FR118, FR140a; ARCH D53)*

---

## Interface

**Teaching is first-run and dismissible; explanatory copy is never permanent furniture.** A caption that states a rule usually exists because the interface failed to demonstrate that rule. Dismissing a tip hides it for that trip only; a new trip shows it again; every dismissed tip stays reachable from inline help on its own surface; dismissing all of them leaves every control operable. Live status text ("routing available in about 3 minutes") is not teaching — not dismissible, not in the enumeration. *(FR142(e); K12a)*

**A capability with no path back to what it made is not usable.** Every new object type ships with its reachability path named — the surface it is found on, and how to reach it. This is a rule you check forever, not a feature you build once: the unattached-anchor hole is what happens when it is skipped. Run the enumeration whenever a new object type is added. *(PRD FR142(b), K12)*

**WCAG 2.2 AA is the floor, not the target.** Field surfaces exceed it deliberately for outdoor legibility and gloved operation. At MVP it is a design-review checklist; the formal WCAG 2.2 AA audit is a scheduled gate (Leg 6.75) before any expansion beyond the Author desktop, with named owners for keyboard navigation, screen-reader semantics, and focus management. *(PRD FR142, FR142a)*

---

## Advisory vs constraint

**Advisories warn; constraints exclude.** Gauge bands (FR14), vehicle-access signals (FR29a), and difficulty grades are **advisory** — they surface and warn, they never reroute or exclude. Mode-legal routability (FR128) is a **constraint** — it excludes. Keep the two categories apart: an advisory promoted to a constraint takes a judgment away from the Author; a constraint demoted to an advisory ships an unridable route. An unflagged advisory reads as "no contrary signal found," never as "confirmed passable." *(FR14, FR29a, FR128; ARCH §7.4)*

**Thin coverage produces confident understatement, not silence — so every reading states its source and coverage.** This is the measured half of the rule above, and it is why the honesty payload is not optional decoration. SPIKE-C: a leg grade is worst-of its ways, a worst-of over a sample is biased low **by construction**, and at real North American tagging rates 16–32% of aggregated land grades would be wrong and *all of them too easy* — so nordic `piste:difficulty` aggregates and `sac_scale` / `trail_visibility` / `mtb:scale*` never do, with the Author's declaration the **primary** source for land difficulty rather than the fallback. SPIKE-E found the same shape in vehicle access: a 35%-surveyed gravel approach reporting "no signal exceeds 2WD" is the confidently-wrong state, and it lands at 18.8% against a pre-declared 10% ceiling. The sparse state must be structurally incapable of rendering as the complete one. *(FR14b, FR29a, B8, B9, C13a; ARCH §7.4)*

---

## The two §0 tests these rest on

Several constraints above are instances of the two failure modes §0 identifies. Re-run both after any significant editing pass on the docs or the model:

- **Find-and-replace test.** If you could globally swap *Author → Planner*, *Character → Participant*, *plot point → waypoint*, *Passage → Segment* and nothing breaks, the story frame has degraded back to vocabulary and the recomposition is undone. Story is structure — it determines what objects exist and how the app behaves.
- **Seed-set test.** For every enumerated list touched: is the rule behind it stated alongside it? If not, the list will be implemented as the rule — and with plugins that becomes a silent failure, not a visible limit. *(FR98, FR105, FR111, FR128 were rewritten on this basis.)*
