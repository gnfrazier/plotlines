# Plotlines — MVP Redirection Punch List

**Companion to:** `Plotlines_PRD_v2.md`, `Plotlines_ARCHITECTURE_v2.md`
**Purpose:** Verify that every concept recovered in the v1.0 → v2.0 recomposition is actually reflected in downstream artifacts and in the build. Work top to bottom; §1 blocks everything else.
**Audience:** An implementing model or engineer picking up Plotlines after the recomposition.

> **Superseded documents — do not consult.** `Plotlines_MVP_Scope_and_Setup.md` has been **removed from the repo** and is superseded by this punch list (build order, acceptance, verification) together with `Plotlines_PRD_v2.md` §5 and §8 (scope and requirements). It was written against the v1.0 model and carries the routing-first pipeline, the single-readiness-flag assumption, node-only geometry, and a Leg 7 plugin input contract — every one of which v2.0 reverses. If a copy resurfaces in a branch, a local checkout, or an earlier conversation, **it is wrong, not merely stale.** The same applies to `Plotlines_PRD.md` v1.0 and `Plotlines_ARCHITECTURE.md` v1.0: superseded by their v2 counterparts and retained only for the traceability appendices that cite them.

---

## How to use this document

Each item has a **check** (what to verify) and a **fail signal** (what it looks like when it silently didn't happen). The fail signals matter more than the checks — v1.0's losses were invisible precisely because the document read as complete.

Mark each item ☐ → ☑ only when the fail signal has been actively looked for and is absent. "I added an FR about it" is not sufficient for items in §1 or §2.

---

## §0 — Read this first: the failure mode being corrected

v1.0 lost these concepts through a systematic bias, not carelessness. **When two stories collapsed into one requirement, the testable mechanism survived and the intent did not.** "0.0–5.0 decimal scale" preserves cleanly in a sentence; "so the journey reads as a story" does not.

The practical rule when consolidating anything in this project:

> If a consolidation drops a *reason*, it has lost something, even when every mechanism is intact. Write the reason into the requirement or don't consolidate.

A second, related test — **the find-and-replace test.** If you could globally replace *Author → Planner*, *Character → Participant*, *plot point → waypoint*, *Passage → Segment* across the document and nothing breaks, the story frame has degraded back to vocabulary and the recomposition has been undone. Re-run this test after any significant editing pass.

### The second failure mode: lists read as complete

v1.0 lost meaning a second way, identified during the v2.0 review. **A short list of examples was repeatedly implemented as the complete set** — `historic=*`'s flat wildcard, the four "known over-triggering tags," the routability table, the Set tag list, the monument-plus-toilets role tuple. Each read as closed because **the rule that generated it was never written down.**

Plugins turn this from a limitation into a **silent failure**. A plugin brings `battlefield`, `manor_house`, `covered_bridge`. No entry exists. Co-location analysis runs, finds the co-location correctly, and **proposes nothing** — the flagship curation feature quietly not working with the extension mechanism built to feed it. Nothing errors. Nothing logs. The Author just sees fewer suggestions than they should and has no way to know why.

> **The rule:** an enumerated list in a requirement is a **seed set** unless it explicitly says otherwise, and **the rule behind the list must be stated alongside it.** If the rule isn't stated, the list will be implemented as the rule.

FR98, FR105, FR111, and FR128 were rewritten on this basis in v2.0. **Apply the same test to anything added later** — and especially to anything that reads as a lookup table, since that is the shape the failure takes.

---

## §1 — Blocking: four places where v2.0 *contradicts* v1.0

These are not additive. Downstream artifacts still carry the v1.0 reading and will silently win if not reconciled first.

☐ **1.1 — Readiness: global → per-capability**
*Check:* `ARCH §7.3` health semantics rewritten so `/health` reports readiness **per capability** (tile, layer-and-POI, routing, elevation) with progress, not one boolean. Sidecar orders layer/POI extraction **ahead of** elevation enrichment. Client enables surfaces from the flags and states a reason on every disabled control.
*Refs:* FR121, FR91 (amended), M12a, N2.
*Fail signal:* `/health` still returns a single `ready`; or the app blocks on trip creation for minutes; or a control that needs elevation fails on click instead of being visibly disabled with a reason.

☐ **1.2 — Distance: unconditional band → mode-dependent**
*Check:* FR8's "never dropped from the search's constraint set" is scoped to **explore mode**. Compose mode reports realized distance as an editing decision, never as a conflict or relaxation dialog.
*Refs:* FR8, FR8a, FR118, A0a, A8, A9a.
*Fail signal:* A compose-mode day whose anchors make it 94 miles triggers the A6 conflict-explanation path, or shows an error, or silently drops an anchor to hit the band.

☐ **1.3 — Web: planning scope ≠ reading scope**
*Check:* FR61's scoping applies to **Author planning only**. A Character-facing web reading surface with content equivalent to the app exists and is planned into Leg 4.
*Refs:* FR61, FR132, H13.
*Fail signal:* Any artifact or backlog item stating "web is limited to the core loop" without qualifying *planning*; or no Character web view in the Leg 4 scope.

☐ **1.4 — Geometry: nodes-and-edges → nodes, edges, and areas**
*Check:* The v1.0 scope call that all spatial objects are nodes or edges is reversed everywhere — data model, GeoJSON export, triggers, offline package, backup/restore.
*Refs:* FR108, FR126, FR43, FR68, L1, L4, O3.
*Fail signal:* Polygon anchors round-trip lossily through export/import; or area entry doesn't fire a trigger; or the data model has no polygon type.

---

## §2 — The eighteen recovered concepts

Cross-reference: `PRD v2.0 Appendix B`. Verify each is present in the architecture and the backlog, not only in the PRD.

☐ **2.1 Pipeline (layer → analysis → promotion → routing)** — FR97–FR110, §5, Epics N/O.
*Fail signal:* The architecture still describes planning as routing-first with POI density as the only path for places to enter a route.

☐ **2.2 Cluster / co-location analysis** — FR102–FR105a, N4.
*Fail signal:* No component owns it; or it's folded into the explore-mode interest weight; or it runs ambiently on viewport change instead of as a named Author action.

☐ **2.3 Plot point as a defined object** — §4.3, FR106, O1.
*Fail signal:* "plot point" appears anywhere as an undefined phrase, as it did in v1.0's FR45.

☐ **2.4 Setting (Sets)** — FR111–FR112, O7.
*Fail signal:* Route relations and `network=*` tags reach no component; the itinerary can't say "you're on the Virginia Creeper Trail now."

☐ **2.5 Area / polygon geometry** — see §1.4 above.

☐ **2.6 Stations (node-anchored activities)** — FR109, FR16b, FR130, O4.
*Fail signal:* Climbing or canyoneering appears anywhere in a *travel mode* list; or a station's duration doesn't reach the ETA calculation.

☐ **2.7 Reveal policy** — FR114–FR116, FR124, FR64a, O5, P1.
*Fail signal:* Content is readable from the trip view before its trigger; or a hazard can be set to hidden by any path; or print shows unrevealed plot-point content.

☐ **2.8 Character acting inside the story** — FR122–FR125, Epic P.
*Fail signal:* Every Character capability still sits outside the story commenting on it (feedback, notes, journal) with none acting within it.

☐ **2.9 Frodo principle (narrative register)** — FR133, F1, F2.
*Fail signal:* Itinerary or cue sheet has a separate "logistics" panel disjoint from the narrative. Read a rendered day aloud: if it reads as two documents, this failed.

☐ **2.10 Arc as structure** — FR38, O6.
*Fail signal:* Arc is a tag on points only; passages can't carry an arc role; arc doesn't participate in day composition or itinerary rendering.

☐ **2.11 Driving legs routed** — FR29, FR10, C13, B1.
*Fail signal:* Driving is absent from the traversal-mode list; or a drive to the trailhead produces a note rather than a route with a cue sheet.

☐ **2.12 Character web and print reading** — see §1.3 above.

☐ **2.13 Mode-legal routability** — FR128, A11.
*Fail signal:* No component consumes access tags, barriers, fords, or waterway obstacles as constraints. **This is a correctness bug, not a feature gap** — v1.0 shipped no passability guarantee in 96 requirements.

☐ **2.14 Plugin data-input as foundation** — FR100, FR101, Leg 2.5, N5.
*Fail signal:* The input contract is still in Leg 7 or still "shape left open"; or plugin-layer attribution doesn't reach exports and print.

☐ **2.15 Salience / notability filtering** — FR98, N3.
*Fail signal:* `historic=*` is still a flat wildcard. **Blocks 2.2** — cluster analysis over an unranked taxonomy proposes boundary-stone-near-ditch with the confidence of castle-near-waterfall.

☐ **2.16 Temporal availability** — FR129, N6.
*Fail signal:* No `opening_hours` or seasonality on candidates; C12's conflict detection can't see a Monday closure.

☐ **2.17 Compose mode** — see §1.2 above; FR117–FR119, A0.
*Fail signal:* Only one planning mode exists; or mode switching loses promoted anchors.

☐ **2.17a Role affinity, not role recipes** — FR100, FR105, N4/N4a; ARCH D47.
*Fail signal:* a core-side type→role lookup table exists; or a plugin layer's clusters come back with no suggested roles; or the station role has no path from analysis. **This is the §0 second failure mode in its highest-consequence location.**

☐ **2.17b Interest weight, not POI density** — FR5, A4; ARCH D46.
*Fail signal:* the weight still carries a POI *type* parameter (a duplicate of layer selection with no conflict rule); or the scorer maximizes POI *count* rather than salience; or `detour_budget` survives in `WeightProfile`.

☐ **2.18 Group dynamics as Author expertise** — **restored.** FR134–FR137; D5–D8; ARCH D50, D51.
A per-Character detail view, Author-private notes scoped to `(Author, Character)` and persisting across trips with a visible last-updated date, three-scope hard deletion, and group/sub-group on the **roster entry** with per-day and per-passage override.
*Fail signals:* notes are trip-scoped (throws away the cross-trip knowledge that is the entire point); group lives on `rider_profile` rather than `roster_entry` (a trip-specific fact following a person onto their next trip); `updated_at` is stored but not displayed; **any scored or structured form of a person** — cohesion, compatibility, ability index — appears anywhere; deletion is soft; or a note reaches any Character-facing surface.

---

## §2A — Architecture reconciliation

`Plotlines_ARCHITECTURE_v2.md` is complete. This section records what it resolved, what it *added* that the PRD did not anticipate, and the three places it is still unfinished.

### Resolved — the four §1 blockers now have an architectural answer

| §1 item | Architectural resolution |
|---|---|
| 1.1 Readiness | ARCH §8.3 — `/health` returns a `capabilities` map; startup ordered layers-then-elevation; ARCH D34 |
| 1.2 Distance | ARCH §7.7 — `target_distance=None` is first-class in compose; deviation never routes through `/segments/diagnose`; ARCH D35 |
| 1.3 Web | ARCH §8.2, §10.3 — `GET /read/{share_token}`, share-token-authorized so a Character needs no account |
| 1.4 Geometry | ARCH §7.8, §6.2, §11.6 — polygons in payload, triggers, export, drift; ARCH D37 |

### Three things the architecture surfaced that the PRD did not

☐ **2A.1 — The payload schema is a version bump with a migration, not an edit.** v2.0 replaces nodes with anchors-and-roles, adds polygons, moves arc onto passages, adds reveal/stations/bbox. **A v1 payload does not validate against the v2 schema.** ARCH §11.6 and D38 add `schema_version` to both the JSONB payload and the drift row, with forward-only migration and **reveal defaulting to always-visible** so no migration can accidentally hide an Author's existing content.
*Fail signal:* a v1 payload fails to deserialize in a way that reads as corruption; or migrated content defaults to on-arrival reveal.
*Do this:* test the migration against a **real** v1 payload, not a synthetic one (ARCH A24).

☐ **2A.2 — Attribution becomes dynamic, and this is v2.0's one real ongoing cost.** Plugin layers (FR100/FR101) mean arbitrary datasets with their own terms reaching exports and **printed** cue sheets, so a hardcoded credit list cannot be correct. ARCH §12.2 and D45: every layer declares its licence in the contract, **a layer with absent or unsatisfiable licence metadata does not load** (refused at registration, not warned at render), and the release gate becomes "does every loaded layer's attribution reach every surface that displays its data."
*Fail signal:* an unlicenced plugin layer loads with a warning; or the About surface enumerates a fixed list.

☐ **2A.3 — Candidate extraction is a heavier Overpass query than graph building.** SPIKE-04 §8 already could not complete a single region's pull from public Overpass without tiling and retries, and candidate extraction pulls far more tag classes over the same bbox. ARCH A23: bbox-scoped on-demand cache, prefer local extracts for repeatedly-used regions, **tile-and-retry as the baseline access pattern rather than a fallback.**
*Fail signal:* extraction hits public Overpass directly, un-tiled, on a multi-day bbox.

### Where the architecture absorbed v2.0 better than expected

Worth knowing, because it means less work than the PRD implies:

- **`ShapeDataProvider` already existed** (ARCH §14.2). The provider layer never accepted v1.0's node-or-edge scope call, so **area support is an extension, not a rewrite.** The architecture was more right than the requirements.
- **`content/` was already a package**, so the anchor/role model is a restructure of an existing home rather than a new one.
- **P8's canon-vs-layers separation is exactly the right shape for reveal state, arrivals, and choices** — they get their own tables and write paths for the same reason field notes do (ARCH D44). A useful consequence: those tables are append-only and owner-scoped, so **they do not participate in FR59's version check at all** — two devices belonging to one Character converge by union, with no conflict to resolve.
- **PostGIS is still not triggered** (ARCH §11.5). Clustering runs in the core over a local extract; the database never sees a candidate. "Spatial analysis" sounds like a database job and is not one here.

### Still open in the architecture

☐ **2A.4 — `WeightProfile` still names three different structures** across the PRD, the architecture, and `scoring/profile.py` (ARCH A18). D29 fixed what the *payload* stores; the conversion function has never been written. **v2.0 raises this from Medium to urgent** because compose mode gives weights a second, different job — flavouring rather than searching — and a second consumer of an ambiguous structure is how the ambiguity ships. *Fix: one mapping function in `scoring/`, and correct ARCH §7.3's field list to describe the implemented profile plus the Author-facing one it derives from.*

☐ **2A.5 — Q15: candidate rendering at bbox scale is unbudgeted.** A dense trip bbox may draw thousands of markers over a basemap already costing ~1 GB (ARCH A16). Clustering-for-display, zoom thresholds, or salience-gated rendering — undecided. **Re-measure A16 with candidates on screen, not just a route.**

☐ **2A.6 — Q3 widened.** The trigger engine now fires four effect kinds (hazard, reveal, narration, arrival). ARCH §6.2 specifies the **priority order**; the **thresholds** are still open.

---

## §3 — MVP build order

The v2.0-new stories that are **[MVP]**, in dependency order. Everything else in Epics N/O/P is [P1].

| # | Story | Blocks |
|---|---|---|
| 1 | **M12a** — per-capability `/health` | N2, and every authoring surface |
| 2 | **N1** — declare trip bbox at initiation | N3, N4, tiles, elevation |
| 3 | **N2** — author while terrain loads | the whole authoring session |
| 3.5 | **N0** — declare travel modes | **N3** — the layer picker has no defaults without it |
| 4 | **N3** — layer selection + candidate display + salience | N4, O1 |
| 5 | **O1** — promote a place, assign roles | O2, O3, O5, A0 |
| 6 | **O2** — role-level geometry offset | correct trigger placement |
| 7 | **O3** — area anchors + polygon triggers | rest-day authoring, export |
| 8 | **O5** — reveal policy (incl. hazard hard constraint) | P1, F1, H13 |
| 9 | **O6** — arc on anchors *and* passages | C3, F2 |
| 10 | **A0 / A0a** — explore-vs-compose + distance as outcome | E3, A8, A9a |
| 11 | **A11** — mode-legal routability | correctness of every route |
| 12 | **P1** — discover content by arriving | the reading half of the thesis |
| 13 | **Q1, Q2, Q3** — editing, cascades, staleness | every story above, on second contact |
| 14 | **K12 + K12a** — undo, reachability, empty states, first-run teaching | whether any of the above is usable |
| 15 | **M14** — string templates | localization, **and the last reveal-leak path** |

**N4 and N4a (cluster analysis and proposal review) are [P1], not MVP.** The MVP path through the curation workspace is layers → candidates → **promote directly** → roles; the analysis branch is assistance layered on top of a workspace that must already work without it. **An implementation in which promotion is only reachable through a proposal has inverted the dependency.** N4a specifically — but it is the story most likely to be built badly from an under-specified brief, because N4 describes an *analysis* and N4a is the only place the *interaction* is specified. Read PRD §5.4a's worked walkthrough before designing it, and treat ARCH Q15 (candidate rendering at bbox scale) as a prerequisite for its map half.

**Sequencing note:** items 1–5 are one connected substrate. Building O1 before N3 produces promotion with nothing to promote; building N3 before M12a/N1 produces a layer picker that blocks on elevation for minutes.

---

## §4 — Acceptance scenarios

Concrete end-to-end checks. Each exercises several requirements at once and fails visibly if any of them was skipped.

☐ **4.1 The national monument.** Promote one place with narrative + provision roles. Verify: one anchor, one arrival, one pin. The restroom and water appear in the pre-trip plan, on the printed cue sheet, and in water-carry distance. The statue's story does not appear anywhere until arrival. *(FR106, FR114, FR116, O1, O5, P1)*

☐ **4.2 The overlook spur.** Anchor at a parking lot; narrative role offset 400 m up a spur. Verify narration fires at the overlook, not in the parking lot. *(FR107, O2)*

☐ **4.3 The main street rest day.** Compose a rest day from an area anchor containing several provisions. Verify the polygon renders on map, timeline, cue sheet, and GeoJSON; entry fires a trigger once, not repeatedly on a boundary-hugging route. *(FR108, FR126, FR18, O3)*

☐ **4.4 The 94-mile day.** In compose mode, promote seven anchors that exceed the stated distance band. Verify the result is an editing prompt with drop/defer/split/widen/accept affordances — **not** an error, a conflict dialog, or a relaxation offer. *(FR118, A0a, A6)*

☐ **4.5 Explore → compose → explore.** Generate a route in explore, promote two places found on it, switch to compose, then loosen back to explore. Verify no work is lost in either direction and promoted anchors survive. *(FR119, A0)*

☐ **4.6 The paper copy.** Print a day containing provisions, hazards, and both revealed and unrevealed plot points. Verify every provision and hazard appears, the arc's shape appears, unrevealed content does not — **and the logistics do not read as a separate document from the narrative.** *(FR116, FR133, F1)*

☐ **4.7 The hidden hazard attempt.** Attempt, through every available path, to set a hazard or crux to revealed-on-arrival. Verify it is impossible — enforced in the model, not by UI absence alone. *(FR115, C11, O5)*

☐ **4.8 Airplane-mode reveal.** Download a package, disable all connectivity, ride the route. Verify reveals, narration, and hazard alerts all fire from raw GPS; verify unrevealed content is not browsable through file lists, search, export preview, or share sheets before its trigger. *(FR64, FR64a, FR124, H7, P1)*

☐ **4.9 The regroup.** Two Characters grant arrival visibility via the Author's profile request; one declines. Verify: consent flows through the *existing* request/response surface with no parallel mechanism; granted arrivals are visible to the **roster**, not the Author alone; the decliner's arrivals still appear in their **own** recap; default before any response is nothing shared. *(FR122, FR123, FR78a, P3, K2, D4a)*

☐ **4.10 The prohibited path.** Generate a route through an area containing `bicycle=no`, a gate, and a ford. Verify the route is passable, that a `bicycle=dismount` section is surfaced explicitly rather than silently included, and that a constraint forcing a materially worse route is named. *(FR128, A11)*

☐ **4.11 The boundary stone.** Run cluster analysis in a region dense with low-salience `historic=*` features. Verify proposals are dominated by genuinely notable co-locations, not milestones and boundary markers. *(FR98, FR102, FR103, N3, N4)*

☐ **4.12 The v1 payload migration.** Take a real v1.0 trip payload, migrate it, and verify: nodes become anchors with an inferred single role, **reveal defaults to always-visible on every migrated role**, arc tags land on anchors, passages start with no arc, and `schema_version` is set on both the JSONB and the drift row. *(ARCH §11.6, D38, A24)*

☐ **4.13 The unlicenced layer.** Register a plugin layer with absent licence metadata. Verify it **does not load** — refused at registration, not warned at render — and that a correctly-licenced layer's attribution reaches the About surface, an export, and a printed cue sheet. *(ARCH §12.2, D45)*

☐ **4.14 The cold curation session.** Create a trip with a large bbox on a machine with no cached elevation. Verify: layer selection, candidate display, cluster analysis, and promotion are all usable within seconds; `/health` reports `layers` ready and `routing` not-ready with a progress estimate; every routing control is visibly disabled with a stated reason; **nothing blocks and nothing fails silently on click.** *(ARCH §8.3, D34 — this is B1's regression test)*

☐ **4.15 The candidate cache wipe.** Promote several anchors, delete the candidate cache, change the notability ruleset version, and re-open the trip. Verify every anchor survives intact with its geometry, name, and provenance. **An anchor must never hold a dangling reference into a regenerable cache.** *(ARCH §4.2, D36)*

☐ **4.16 The spoken spoiler.** Enable device TTS readout and ride a route containing revealed content, unrevealed content, a hazard, and a role with authored audio. Verify: unrevealed content is **never spoken**; the hazard is spoken and preempts whatever was speaking; authored audio plays and TTS does not read the same text over it; TTS queues on the narration channel rather than talking over it; and with no platform voices installed the app says so rather than going quiet. *(PRD FR40a, H2a; ARCH §6.2, P11)*

☐ **4.17 The unknown plugin type.** Load a plugin layer whose types (`battlefield`, `manor_house`, `covered_bridge`) appear in **no** example anywhere in the PRD. Run co-location analysis. Verify clusters containing them are proposed **with role sets derived from their declared affinity**, ranked alongside OSM clusters, with no core change. *(PRD FR100, FR105; ARCH D47 — this is the §0 failure mode's regression test)*

☑ **4.18 The shrinking bbox.** Promote anchors near the edge of a trip bbox, then shrink it so some fall outside. Verify the Author is **shown which anchors are affected** and offered keep-bounds / adjust-bounds / remove-explicitly. **Nothing is silently discarded.** *(PRD FR120, N1; P5)*
  Re-verified against issue #154's fail signal: #154 touches `TripAreaScreen`/`tripBboxProvider` (region-ensure wiring, `_confirm()`'s bbox.center fix) but not `trip_bbox_shrink_prompt.dart`/`reviseTripBbox` themselves. `client/test/trip_bbox_shrink_prompt_test.dart` and `trip_bbox_revision_test.dart` (unmodified by #154, still green in the full 201-test `flutter test` run) cover the keep/adjust/remove-explicit paths and the no-silent-discard invariant directly.

☑ **4.19 The cold start.** Fresh install, no network. Verify the app opens on the Buncombe home region **with no prompt and no download of any kind**. Then create a trip: verify the location prompt is prefilled with the last-used value, that entering one **only centers the map**, and that the bbox comes from the Author's draw — never from a radius or an accepted default. *(PRD FR96, A10; ARCH D41)*
  Re-verified after issue #154 (the fail signal this item names is exactly what #154 fixed: every trip silently routing against the Boulder fixture, and no basemap outside it). `HomeRegion` is unchanged — still a compile-time constant, no override, no first-run prompt. The location prompt's `TripLocationChoice.bbox` (new, from `/geocode`) only ever feeds `TripAreaMap.initialCameraFit`, never `tripBboxProvider` — asserted in `trip_area_screen_test.dart` and `trip_library_screen_test.dart`. The bbox-from-draw invariant is asserted end to end in `trip_area_screen_test.dart`'s drag test, which also confirms `_confirm()` now forwards the drawn bbox's own center rather than the stale location-prompt center. Verification is automated-test-and-code-review plus a live smoke test of the real frozen sidecar binary (`/health`, `/regions`, `/tiles`) — not a manual click-through of the full Flutter desktop app, which this environment has no display for.

☐ **4.20 The slow plugin.** Enable a plugin layer that loads slowly, and one that fails on missing licence metadata. Verify built-in layers are usable immediately, the slow layer shows as *loading* in the picker without blocking the workspace, the failing layer **names itself and its reason** without blocking the others, and `/health` reports per-layer state. *(PRD N2, FR121; ARCH §8.3, D48)*

☐ **4.21 The date that means two days.** Set date format to `DD/MM/YYYY` and confirm display changes across itinerary, cue sheet, scheduled events, gauge age-stamps, and arrival timestamps. Then verify **no exported file, filename, payload field, or content digest contains anything but ISO 8601.** Switch to `inherit` on two devices with different locales and confirm each resolves locally while an explicit choice syncs. *(PRD FR79, K5; ARCH D49)*

☐ **4.22 The road that needs the good truck.** Route a driving leg to a trailhead over `smoothness=very_bad` and `4wd_only=yes` sections with a declared 2WD capability. Verify the leg **flags the sections and names the triggering signal**, in both the summary and the cue sheet, and that it **warns without excluding or rerouting**. Verify an unflagged leg is presented as *no contrary signal found*, never as *confirmed passable*. *(PRD FR29a, C13a; ARCH §7.4)*

☐ **4.23 The note that must never travel.** Write Author notes on three Characters. Then exercise **every outbound path**: each export format, print, the share link, the offline package, the group relay, a plugin `pushTrip`, the TTS readout, and the trip archive. Verify **no note appears in any of them**, asserting on bytes rather than code paths. Then enable archive inclusion via its separate confirmation and verify it names what it would expose before doing it. *(PRD FR135, D6; ARCH P11 *never-release*, A27)*

☐ **4.24 The resurrection.** Delete all notes on a Character while a second signed-in device is offline. Bring that device online **after** the deletion and sync. Verify the notes **do not come back**. Then run the all-records deletion across a Character with notes on four trips and verify the confirmation states the count and the trip span before it proceeds, that removal is complete rather than flagged, and that **the Character is still on every roster with trip content unchanged**. *(PRD FR135a, D6a; ARCH §11.7, D51 — a union-merge implementation passes every other test and fails only this one)*

☐ **4.25 The unshared field.** Open the detail view for a Character who has granted nothing, one who granted a subset, and one who volunteered an allergy unprompted. Verify an ungranted field reads as ***not shared*** and never as blank, that volunteered fields are surfaced prominently rather than beside requested ones, and that the no-grants case shows the request state rather than an empty view. *(PRD FR134, D5, K2)*

☐ **4.26 The privacy statement.** Reach it from About on **every** platform — desktop, mobile, Web signed-in, Web guest, and the share-token reading view. Verify it names reveal-is-not-security, arrival sharing's default of nothing shared, **Author notes and their deletability**, and the guest no-trace guarantee. *(PRD FR138, K11; ARCH §13.4)*

☐ **4.27 The six-edit session.** Make six edits in a row that invalidate derived work — change a passage mode, remove an anchor, reduce the day count, adjust a weight. Verify: **you are interrupted zero times**; a marker appears on each affected object and a count in the dashboard; the stale route stays **viewable**; an export attempt opens the **stale list** rather than erroring; **re-solve-all clears everything in one unconfirmed action**; print offers **no override path**. *(PRD FR140, FR140a, Q3; ARCH D52, D53)*

☐ **4.28 The mis-click and the real removal.** Promote an anchor and immediately remove it without writing anything — verify **no prompt**. Then remove one carrying roles and content — verify a prompt stating its scope. Then reduce a six-day trip to four where days 5 and 6 hold content — verify the prompt **names the passages, anchors, and events** and offers keep / adjust / merge / remove explicitly. *(PRD FR139, Q1, Q2)*

☐ **4.29 The orphaned anchors.** Remove a passage carrying five anchors. Verify the anchors **survive**, are findable in the curation workspace's anchors view filtered to unattached, are **not badged as errors**, **block nothing**, and can be re-attached to another passage. *(PRD FR139, Q2, N4a)*

☐ **4.30 The reachability enumeration.** For each object type — anchor attached, anchor unattached, passage, day, trip, Character note, group assignment, stale item — **name the surface it is found on and reach it**. A type with no named path fails. Run this whenever a new object type is added; it is the check that prevents another unattached-anchor hole. *(PRD FR142(b), K12)*

☐ **4.31 Undo what you just did.** Promote an anchor, remove a passage, restructure a day, change a reveal setting — undo each. Verify undo is session-scoped and **says so** rather than implying permanence; that **Author-note deletion is excluded and says so at the point of deletion**; and that derived work is **re-solved rather than undone** (re-solving is idempotent). *(PRD FR142(a), K12, D6a, Q3)*

☐ **4.32 The empty trip.** Open a trip with no days, a day with no passages, a bbox with no promoted anchors, and a roster with no Characters. Each **states a next action**, not just an absence. Verify these are distinct in presentation from *no clusters found* (a result) and from M13's states (failures). *(PRD FR142(c), K12)*

☐ **4.33 The cloned trip.** Clone a trip whose Characters granted profile fields and arrival visibility. Verify the clone carries **roster membership, group assignments, and the whole authored trip**; that **no grant and no arrival-visibility permission carries over** — every Character starts at nothing shared and must re-grant; that no Character-layer state (reveals, arrivals, choices, field notes) comes along; and that **Author notes are present without any rule having been applied**, since they are scoped to the person. *(PRD FR74, G2, K2; ARCH D50)*

☐ **4.34 The paddling day's layers.** Create a trip declaring paddling only, and another declaring cycling only. Verify the layer picker's initial state **differs** and **states which modes it derived from**. Then add a hiking passage to the cycling trip: verify it **succeeds, adds hiking to the trip, and is neither blocked nor warned**. Change the mode set and verify overridden days keep their overrides. *(PRD FR144, N0, FR97)*

☐ **4.35 The four clone scopes.** Run §4.33's cloned-trip check **once per scope**. Additionally: roster-only produces no days and no anchors and **runs trip initiation** (location, bbox, modes); authored-trip-only produces the full structure with an empty roster and **no dangling assignments** — group, gear, or meal — pointing at absent people. *(PRD FR74b, G2b)*

☐ **4.36 The template with no prose.** Enumerate every user-visible message template and assert each slot is typed. Verify **no template accepts `Role.content` or any authored text field**, that reason phrases resolve from the bounded enum table rather than call-site strings, and that the TTS path reads **template and resolved content separately**. **Run this even though the export byte assertions pass** — a composed sentence is built in Presentation, downstream of them, and they structurally cannot see it. *(PRD FR145, M14; ARCH D57, A30)*

☐ **4.37 Tell me once, but let me find it again.** Verify each teaching moment in the enumeration appears on its named surface, that dismissing hides it **for that trip only** and a new trip shows it again, that **every dismissed tip is reachable from inline help on its own surface**, and that **dismissing all of them leaves every control operable**. Verify live status text (*"routing available in about 3 minutes"*) is **not** dismissible and **not** in the enumeration. *(PRD FR142(e), K12a)*

☐ **4.38 The find-and-replace test.** Per §0. Run it after every significant editing pass — **and the seed-set test alongside it**: for every enumerated list touched, is the rule behind it stated?

---

## §5 — Downstream artifacts to update

☑ **5.1 `architecture.md`** — **done: `Plotlines_ARCHITECTURE_v2.md`.** See §2A below for what it changed and what it left open.

☐ **5.2 Wireframes** — the desktop planner wireframe now needs the layer picker, candidate map, cluster proposal review, and the promotion interaction. These did not exist when it was drawn. The mobile consumer wireframe needs reveal states and arrival.

☐ **5.3 OSM attribute mapping** — needs three passes, and it is now a **build input rather than reference material**:
- A **provision-oriented pass**. It currently lacks `amenity=toilets` entirely, plus `cafe`, `restaurant`, `pharmacy`, `shower`. **FR104's "toilet + water + shelter" cluster cannot be computed from the mapping as written.**
- The Candidate/Excluded column restructured as **defaults per (mode × day-type)** rather than global verdicts.
- **A role-affinity and salience-weight column per type** (FR100, FR105, ARCH D47). Without it the built-in OSM layers cannot be expressed as `LayerProvider` implementations, and the interface's own proof-of-realness test (ARCH §14.2) fails.
- **Add the driving-surface tags** — `surface`, `smoothness`, `tracktype`, `4wd_only`, `motor_vehicle` — which FR29a needs and the mapping does not carry.

☐ **5.4 MVP scope / setup doc** — reorder around the §3 build sequence; add Leg 2.5.

☐ **5.5 CLI scaffolding prompt** — regenerate against the new object model.

☐ **5.6 Accessibility audit scheduling.** FR142a puts a formal WCAG 2.2 AA audit at **Leg 6.75 — a gate, not a leg** — before any expansion beyond the Author desktop. Confirm it is in the roadmap as a scheduled deliverable rather than an aspiration, and that the desktop authoring surfaces have named owners for keyboard navigation, screen-reader semantics, and focus management. **Nothing currently specifies any of the three.**

☐ **5.7 Brand Guide** — Brand Values 8 (Reveal with intent) and 9 (No dice) are new and have voice implications.

---

## §6 — New spikes

☐ **SPIKE-A · Notability tuning.** Calibrate FR98's per-tag rules and `historic=*` sub-weighting against real extracts in NC, WI, and SoCal. Under- and over-filtering both fail visibly; correct values are likely regional. **Blocks cluster analysis quality.**

☐ **SPIKE-B · Cluster ranking.** How salience and tightness trade off; whether corridor proximity should dominate once a route exists; what a reviewable proposal count is for a large bbox. *(FR105a)*

☐ **SPIKE-C · Non-whitewater difficulty coverage.** Measure `sac_scale`, `trail_visibility`, `mtb:scale*`, `piste:difficulty` coverage in the target regions. **v1.0 generalized SPIKE-04's whitewater result to all technical terrain without testing it** — that generalization is unverified. *(FR14b, B9)*

☐ **SPIKE-D · Layer extraction and POI indexing timing.** Confirm extraction can complete fast enough to unlock authoring while elevation runs behind it, and that reordering the two is cheap in the sidecar. **Directly gates §1.1.**

☐ **SPIKE-E · Driving-mode routing and access advisory.** Confirm the OSMnx graph and existing solver handle driving to trailheads acceptably, and **measure `surface`/`smoothness`/`tracktype`/`4wd_only` coverage on approach roads in the target regions** — the advisory is only as honest as the tagging behind it. *(FR29, FR29a, C13, C13a; ARCH Q14)*

☐ **SPIKE-F · Anonymous web reading.** Share-token handling without leaking through referrers, history, or access logs; log retention for readers who never consented to an account; and **where reveal state lives for a reader with no account and no GPS.** Likely outcome is anonymous readers seeing the always-visible set only — but that is the decision to make. **Joint design, security, and product call. Gated to the web/hosted leg, not MVP, and final before any web presentation ships.** *(FR132, H13; ARCH Q17, A26)*

---

## §6A — Two CI gates to add before the first curation screen

Both are cheap, and both enforce a principle that a code review will not reliably catch.

☑ **6A.1 — No Presentation-layer access to `Role.content` outside `RevealResolver`.** *(Landed with M14/FR145 — `tools/ci/reveal_gate_lint.sh`, gate 1, wired into CI as the `reveal-gate-lint` job; verified against violating fixtures by `client/test/reveal_gate_lint_test.dart`.)* ARCH §15.3/§15.5 makes this the highest-value client test in v2.0. The violating path will be a print preview, an export corner, **or the TTS readout** — surfaces nobody exercises with unrevealed content present — and **a spoiled trip cannot be un-spoiled** (ARCH A22). Same enforcement shape as the existing `plotlines-core may not import fastapi` lint.

☐ **6A.2 — Byte-level assertions on reveal-aware export.** For every export format — GPX, TCX, FIT, GeoJSON, and any plugin `pushTrip` — assert that an unrevealed plot point's content **does not appear in the output bytes**. Assert on the bytes, not the code path. **The TTS path needs the equivalent assertion on the string handed to the speech engine.**

---

## §7 — Standing constraints

Not checkable once; hold across every decision.

- **No gamification.** No points, badges, achievements, unlockables, leaderboards, dice, or randomness. Every route, branch, and reveal is authored and deterministic. *(Brand Value 9, FR125)*
- **Hazards are never hidden.** No Author, no setting, no role, no trip type. Model-enforced. *(FR115)*
- **Default nothing shared.** Every consent decision starts closed and requires an explicit Character action. *(FR78, FR123)* **This survives cloning**: a clone never carries grants forward, or cloning becomes a consent-laundering path — last year's medical disclosure silently re-shared on this year's different trip. *(FR74)*
- **Attribution is a build failure.** Elevation CC BY, basemap ODbL, and every plugin layer's own terms — all owed, none substituting for another, all propagating to exports and print. *(FR86, FR95, FR101, K10)*
- **Not a nav device.** GPS triggers authored content and advances a glanceable cue sheet. No turn-by-turn, no wrong-turn recalculation, no follow-the-line. *(§6.2)*
- **Not a tracker.** Arrival events are discrete, sparse, authored-content-tied, consented, and revocable. If a design ever needs continuous position sharing, it has crossed the non-goal. *(§6.2, FR123)*
- **The analysis never decides.** Clusters propose; the Author promotes. Nothing enters a trip without an editorial act. *(FR102, FR110; ARCH P10)*
- **Every stage after display is skippable.** An Author who knows the area places a plot point and routes to it. The pipeline removes work; it never imposes a wizard. *(PRD §5; ARCH P10)*
- **Candidates are not canon.** They live in a regenerable, bbox-scoped cache keyed by layer set *and* ruleset version. Anchors **copy** what they need, never reference it. Deleting the cache must cost a re-extraction and never authored work. *(ARCH §4.2, D36)*
- **Reveal is enforced at one gate.** Render, export, print, offline package, and plugin push all pass through `RevealResolver`. Hazards are exempt **inside** the resolver, so the exemption exists in one place rather than being remembered in many. *(ARCH P11, D39)*
- **Arrivals are discrete by schema, not by discipline.** The endpoint accepts an anchor reference, never a bare coordinate, and no position table exists anywhere in the schema — deliberately. The gap between "post an event when a trigger fires" and "post position every 30 seconds" is one well-intentioned commit, and the schema is what prevents it. *(ARCH §8.5, D43, A25)*
- **Two authoring extents, never conflated.** The **shipped home region** (Buncombe County rect — a constant, no override, no prompt, **no download**) and the **trip bbox** (drawn by the Author, bounds candidates/clusters/tiles/elevation). The **offline corridor buffer** is Character-side and never appears in the authoring flow. Conflating the last two has Characters downloading a county to ride a corridor. **Every extent is justified by a trip, except the one that costs nothing.** *(ARCH D41, supersedes D32)*
- **A list is a seed set; state the rule beside it.** Per §0. Applies to notability rules, role affinity, Set detection, routability constraints, and anything added later that reads like a lookup table. *(PRD D-L)*
- **Affinity is declared by the layer, never inferred by the core.** A core-side type→role table is the §0 failure mode in the place it costs most: plugins silently produce no proposals. *(ARCH D47)*
- **Display formats never reach stored data.** Date, time, and unit preferences are render-time transforms. ISO 8601 is the sole stored, exported, filename, and digest form — a display format in a payload makes the content digest depend on who was looking. *(ARCH D49)*
- **Author notes never release.** Not withheld-then-released — **never**, in any state, by any path. A bug that promotes a note to *withheld* is as bad as one that renders it, because *withheld* implies a future release and a note has none. *(PRD FR135; ARCH P11)*
- **Delete means gone.** No soft-delete column on `author_note`, and deletion propagates as an explicit tombstone rather than as an absence — an absence gets union-merged back into existence by any device that never learned of it. *(PRD FR135a; ARCH §11.7, D51)*
- **Never put a number on a person.** No cohesion score, compatibility rating, or ability index anywhere in the schema or the UI. Group-dynamics knowledge enters as an Author's prose and as arrangement. A Character's *own* stated preferences and derived pace are a different thing and remain in scope. *(PRD D-N, non-goals §6.2)*
- **Orphaned authored work prompts; invalidated derived work goes stale.** Two mechanisms, never merged. Confirmation belongs where an action *destroys* something an Author made — never where it merely recomputes. *(PRD FR139, FR140; ARCH §7.10, D-O)*
- **Nothing recomputes on its own.** An edit marks derived work stale; re-solve is an explicit call. Eager recompute is the Riverpod layer's *default* behaviour unless someone chooses otherwise, so this needs watching rather than assuming. *(ARCH D52, A28)*
- **Two things sit deliberately outside the shared error surface** — compose-mode distance deviation and the stale list. Both are the same mistake in different clothes: routing either through M13 teaches the Author that ordinary editing produces errors. *(PRD FR118, FR140a; ARCH D53)*
- **A message is a template, not a sentence.** Every user-visible string resolves a fixed template against typed slots, with causes from a bounded phrase table. Runtime prose composition is out of scope **for a safety reason as much as a scope one**: a composed sentence is assembled in Presentation, downstream of the export byte assertions, and is therefore a path around the reveal gate that they cannot see. *(FR145; ARCH P11, D57, A30)*
- **Teaching is first-run and dismissible; explanatory copy is never permanent furniture.** A caption that states a rule usually exists because the interface failed to demonstrate it. Teaching is the honest home for such captions, not a licence to keep them. *(FR142(e))*
- **A capability with no path back to what it made is not usable.** Every new object type ships with its reachability path named. This is a rule, not a feature — the other three FR142 clauses are things you build; this one is a thing you check forever. *(PRD FR142(b), K12)*
- **WCAG 2.2 AA is the floor, not the target.** Field surfaces exceed it deliberately for outdoor legibility and gloved operation. At MVP it is a design-review checklist; the formal audit gates surface expansion. *(PRD FR142, FR142a)*
- **Advisories warn; constraints exclude.** Gauge bands (FR14), vehicle access (FR29a), and difficulty grades are **advisory** — they surface and warn, they never reroute. Routability (FR128) is a **constraint**. Keep the two categories apart; an advisory promoted to a constraint takes a judgment away from the Author, and a constraint demoted to an advisory ships an unridable route.
