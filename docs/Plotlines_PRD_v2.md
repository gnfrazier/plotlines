# Plotlines — Product Requirements Document

**Version:** 2.0 (recomposed — story model restored)
**Status:** Draft for Design engagement
**Supersedes:** Plotlines PRD v1.0 (clean-sheet); Cycle Tour Planner PRD v2.1 (referenced for traceability only)

> **What changed in v2.0 and why.** v1.0 was consolidated for consistency and concision, and in the process the story frame was reduced from *structure* to *vocabulary*. Authors, Characters, plot points, and narrative arc survived as labels applied to a conventional route-planner object model — a document that would have survived a global find-and-replace back to Planner / Participant / Route / Tag with nothing broken. v2.0 restores the concepts that were diluted or dropped: the layer→analysis→promotion→routing pipeline, the anchor-and-role object model, area geometry, reveal policy, node-anchored activities, setting, and the Character's ability to act inside the story rather than only read it. **Appendix B** records each recovered concept and how it was lost. **Appendix C** logs the decisions made during recomposition. Requirements new in this revision are marked **[NEW v2.0]**; requirements whose meaning changed are marked **[AMENDED v2.0]** with the prior reading stated, because several of them *contradict* v1.0 rather than extend it.

---

## 1. Vision

### 1.1 The concept

Planning a journey is much like planning to write a story. You have your **characters** — the friends who are going with you. The **setting** — where you are going and what you will see. Then the **plot** — a route to follow.

Creating a good story has an arc to it: establishing the characters, adding key points that make things interesting, navigating some struggle or obstacle to overcome, and reaching a conclusion where the characters arrive at a stopping point.

Plotlines enables multimodal adventure trips that include cycling, hiking, paddling, cross-country skiing, climbing, packrafting, riverboarding, canyoneering, and jumaring — different ways to get yourself from here to there. Getting there is part of the fun; sometimes the last mile to the trailhead or put-in is the most harrowing moment of the day, so routes for auto trips and notes for train and plane transport are easy to access.

Trip **Authors** bring their expertise, deep knowledge of how group dynamics influence an experience, and personal flair to the adventure. From a rest stop at a historic clock tower, to a cycling leg with a bit of hiking to a scenic overlook, to a rest day where the lodging is convenient to hot springs, a sauna, and a supermarket — Authors are the most important people in creating the outline of the story.

When **Characters** embark on the journey, they sync the plan to their mobile app, view it on a webpage, or print a paper copy of the routes, itineraries, cue sheets, POI notes, and the Author's plot points. Characters export daily routes to their preferred navigation device or application — Garmin, Coros, RideWithGPS, or anything else that accepts GPX, FIT, or TCX.

### 1.2 The thesis

The hard, generic parts of trip logistics are already solved by tools like RideWithGPS, and export interop is the intended bridge to them, not a gap to close. Plotlines earns its place by doing what those tools do *not* do — **curation** and **theme-driven route weighting** — and wrapping them in a narrative frame where the route is something an Author *writes* and a Character *reads*.

Curation is the senior partner. An Author works from real geographic data — OpenStreetMap features, plus whatever specialist datasets a plugin brings in — sees what is actually out there, and makes **editorial judgments** about which places are worth reaching. The route connects those judgments. Weighting shapes the character of the travel between them.

### 1.3 What v1.0 got backwards

v1.0 modelled planning as *routing first*: set weights, receive a route, and let POI density bias the solve. That inverts the concept. In Plotlines an Author **looks at the land, decides what matters, and routes to it** — the route is downstream of an editorial decision, not upstream of it.

Both directions are real workflows, and v2.0 supports both explicitly as **explore** and **compose** modes (§5.7, FR117–FR119). What v1.0 lacked was the compose direction and every object it requires: candidates, co-location analysis, the promotion moment, and a promoted thing that is more than a pin with a note on it.

### 1.4 The Frodo principle

Day-to-day practicalities — water, toilets, food, shelter, bail-outs — must be present, findable, and *not* narratively disruptive. Knowing where the next water source is on a long hot section reduces cognitive load and anxiety. Being dumped out of the story into a logistics panel to find it does the opposite.

> *There is no point in the story where Frodo asks Samwise to wait up a minute while he takes a leak.*

Provisions are woven into the same register as the narrative, not broken out beside it. This is a **rendering constraint** on itineraries, cue sheets, node cards, and print — see FR133.

### 1.5 Anxiety and joy

The two things a journey's content does for a Character are opposites, and they need opposite treatment:

- **Reduce anxiety.** Where is water. Where is the bail-out. How far to shelter. This content must be visible from the moment the trip is downloaded — in advance, on paper, always.
- **Spark joy and curiosity.** The waterfall around the bend. The ruin in the trees. This content can be held back so that arriving *is* the experience.

A single place routinely does both. A national monument has a statue worth revealing and a restroom that must never be a surprise. This is why reveal is a property of a **role**, not of a place — see §4 and FR114.

Hazards and technical cruxes are exempt from all of it: **always visible, always, regardless of any Author setting** (FR115). A surprise strainer is not a story beat.

---

## 2. Brand Values

These values are the filter for every requirement. A feature that doesn't serve one of them is a candidate for cutting, not adding.

1. **Authorship over configuration.** The Author is a creator, not a form-filler. Planning should feel like composing a journey, and the Author's expertise and voice should be visible in the result. *The strongest expression of this value is work Plotlines takes off the Author — surfacing the castle beside the waterfall so they don't have to hunt for it — not another dial.*
2. **Curation over parity.** Plotlines is not trying to match every logistics feature of existing platforms. It curates — places, themes, the shape of a day — and hands off the rest through clean export.
3. **The journey is a story.** Routes have arc, context, setting, and highlights. A Character experiences the Author's narrative, not just a GPX track. Story is *structure* here, not decoration: it determines what objects exist, what an Author does, and what a Character receives and when.
4. **Quiet in the field.** In-field software should be calm: work offline without nagging, degrade gracefully, respect the device's battery, and never interrupt a ride with a modal.
5. **Portable and vendor-neutral.** A Character's device, head unit, or preferred platform is their choice. Plotlines exports cleanly and never traps a journey inside itself.
6. **Honest state.** The app always tells the truth about what it knows — how fresh a forecast is, whether data is synced, what's downloaded, what's still loading — plainly and without alarm. *An Author is told which capabilities are ready and which are still warming up, rather than being blocked or lied to.*
7. **Organized and logical.** Keeping the story straight serves everyone. Structure is coherent and predictable — segments sequence sensibly, data has one clear home, decisions carry their rationale, and both Author and Character always know where they are and what comes next.
8. **Reveal with intent.** *[NEW v2.0]* Every piece of content is either reducing anxiety or sparking curiosity, and the Author decides which. Practical content is always visible. Narrative content may be held for arrival. Safety content is never hidden by anyone, for any reason.
9. **No dice.** *[NEW v2.0]* Plotlines borrows the *shape* of a story, not the mechanics of a game. There are no points, achievements, unlockables, randomness, or chance-driven events. Every route and every reveal is authored and deterministic. The story frame earns its keep by making the Author's craft visible and the Character's experience sequenced — not by gamifying the outdoors.

---

## 3. Personas

**Author (Planner).** Designs adventures. Brings domain expertise across one or more travel modes and deep knowledge of how group dynamics shape an experience. **Works as an editor as much as a planner**: selects data layers, reads the land, judges which places are worth reaching, promotes them, decides what is revealed and what is known in advance, and routes between them. Sets the logistics that matter for a group and publishes a journey others can experience. May also participate as a Character in their own trip.

**Character (Adventurer/Participant).** Experiences an authored adventure in the field. Downloads the journey for offline use, follows curated routes and cue sheets, **acts within the story** — arriving at plot points, choosing between authored branches, deciding whether to take on a station's activity — personalizes within the bounds the Author allows, exports to their own devices, and captures their own experience along the way. Reads the journey on mobile, on the web, or on paper.

**Any User.** Either role, acting on account-level concerns: profile, preferences, authentication, sync, storage, display.

**Developer.** Builds and maintains the platform. Concerned with the architectural seams that keep Plotlines simple to extend — themes as data, the layer/plugin data contract, clean elevation and routing abstractions, per-capability readiness, and a maintainable client/backend split.

---

## 4. The Story Model

*[NEW v2.0 — this entire section. v1.0 had one spatial noun ("node") wearing four hats, which is why plot point, setting, and node-anchored activity had nowhere to live.]*

### 4.1 Candidate

A feature from a live data layer that has passed the notability filter. **Not yet part of the trip.** Carries geometry, source layer, tag payload, notability verdict, and a salience score.

Thousands exist within a trip's bounding box. They are what the map displays during authoring. A Candidate is *considered*, not *included* — the distinction v1.0 had no object for, because in v1.0 POIs entered a route by scoring inside a solve and there was never an editorial moment.

### 4.2 Anchor

A place the Author has **promoted** into the trip. One anchor per place. An anchor holds:

- **Geometry** — a point, or an area (§4.4).
- **A role set** — one or more of **narrative**, **provision**, **station** (§4.3). Roles are a *set*, not a type field.
- **Provenance** — the Candidate(s) or cluster it came from, or hand-placement.

The role set is what makes a national monument expressible: one anchor, one arrival, carrying a **narrative** role (the statue, its history, the audio, revealed on arrival) *and* a **provision** role (restrooms, drinking fountains, a café, visible from the moment the trip is downloaded and counted in water-carry distances). Same place, opposite reveal policy, no duplication.

### 4.3 Roles

Each role carries its own **reveal policy**, **rendering**, **itinerary placement**, and **optional geometry offset**.

**Narrative role — the plot point.** *Plot points are the point in Plotlines.* A place carrying story weight. Holds: arc role (§4.6), authored text and media, optional audio narration, trigger distance or trigger geometry, and an **intended experience** — look-at-it, stop-and-read, walk-fifteen-minutes, spend-an-afternoon. Reveal is the Author's choice.

**Provision role.** A place serving a bodily or logistical need: water, toilets, food, shelter, resupply, repair, shower, bail-out. Does not advance the story — **keeps the story from breaking**. Feeds water-carry distance, resupply spacing, and the services register of the cue sheet. Always visible by default.

**Station role.** A place where the group *stops travelling and does something with duration*: a crag, a hot spring, a sauna, a summit scramble, a swimming hole, a canyon descent. Holds activity type, expected duration, gear requirements, and an Author-declared difficulty. This is what climbing, canyoneering, and jumaring actually are — **activities performed at or from a place, not modes of travel** — and it is why a nine-mode concept never fit a three-mode model.

A hot spring on a rest day is plausibly all three: provision (it's why you stopped), station (you soak for two hours), narrative (the Author has something to say about it).

### 4.4 Geometry — points *and* areas

*[AMENDED v2.0 — reverses the v1.0 scope call that everything is a node or an edge.]*

Anchors and roles may be **areas**, not only points. A historic district, an arboretum, a main-street shopping block, a nature reserve, a park. Areas are first-class in three places:

- **Cluster definition** — an area can *be* the cluster boundary rather than a point plus a radius.
- **Triggering** — entry into a polygon is a trigger event, distinct from proximity to a point.
- **Rest-day authoring** — "spend the afternoon on Main Street" is an area containing provisions, not a pin.

**Role-level offset.** A role may sit at an offset from its anchor. The overlook is 400 m up a spur from the parking lot; the put-in is 80 m from the restroom. Without offsets, a trigger distance measured from the wrong point fires the narration in the parking lot.

### 4.5 Passage

The traversal between anchors: a mode, a geometry, and a character (surface, traffic, effort). What v1.0 called a segment.

A Passage may carry an **arc role** of its own. The long grind up to the pass *is* the rising action. v1.0 could only tag points, which meant the story could only happen at places and never on the road between them — wrong for an activity where the road between them is most of the experience.

### 4.6 Arc

The story's shape across a day or a trip: **exposition → rising action → crux → climax → resolution**. Arc roles attach to anchors *and* passages, are visible on map and timeline, and are what makes a day read as a journey rather than a list of stops.

Arc is **structure, not a label**. In v1.0 it was a [P1] tagging feature; in v2.0 it participates in day composition, itinerary rendering, and reveal decisions.

### 4.7 Set — the setting

A **named place-identity** that a Passage or Anchor sits inside: the Virginia Creeper Trail, Pisgah National Forest, a rail-trail's former railway line, a mountain pass, a historic district, a national cycle network.

Sets are derived from data that someone else already authored — route relations (`type=route`), `network=*`, `leisure=nature_reserve`, `boundary=*`, `disused:railway=*`, `mountain_pass=yes`. The Author **curates** them rather than composing them.

This is the concrete form of "setting," which was entirely absent from v1.0. It is also the cheapest good narrative material in the system, because it is free, already named, and locally true.

### 4.8 Relationships at a glance

```
Trip
 ├─ BBox (declared at initiation; bounds layers, clusters, tiles, elevation)
 ├─ Layer selection (per trip, overridable per day)
 │    └─ Candidates ── notability filter ──> salience
 │         └─ Co-location analysis ──> cluster proposals
 │              └─ PROMOTION (the editorial moment)
 └─ Day
      ├─ Arc
      ├─ Anchor (point or area)
      │    ├─ narrative role  (plot point) ─ reveal: Author's choice
      │    ├─ provision role              ─ reveal: always
      │    └─ station role                ─ reveal: Author's choice
      │         └─ each role: optional geometry offset, own content
      └─ Passage (mode, geometry, character)
           ├─ arc role (optional)
           └─ Set (curated place-identity)
```
---

## 5. The Authoring Pipeline

*[NEW v2.0 — this entire section. The pipeline is the product. v1.0 described stage 5 and called it planning.]*

**Every stage after Stage 2 is skippable.** An Author who knows the area places a plot point on a castle they already know about and routes to it. The analysis exists to remove work, never to impose a wizard.

### 5.0 Trip initiation — the bounding box

The Author **draws a bounding box** when the trip is created, on a map centered by a single location prompt — prefilled with the last-used value, freely editable, and doing nothing but centering the map. That one extent bounds POI extraction, cluster analysis, tile download, and elevation coverage, so clustering has a bounded, precomputable domain.

**The invariant is that there is never a *second, different* extent for analysis — not that the bbox is fixed.** It is revisable throughout authoring: enlarging re-extracts only the added area, and shrinking prompts with the promoted anchors that would fall outside, never silently discarding authored work. *(FR120, FR96.)*

**Elevation loads lazily behind the Author.** Enrichment is a blocking, minutes-long operation, and the Author is productive during that window — selecting layers, reviewing clusters, promoting anchors. Readiness is therefore **per-capability, not global**: layer extraction and POI indexing complete first and unlock authoring; routing and elevation-dependent metrics unlock when enrichment finishes, with an honest, non-nagging indicator in the meantime. *(FR121 — this changes FR91 and ARCH §7.3 rather than extending them.)*

### 5.1 Stage 0 — Layer selection

The Author picks which data layers are live: the OSM base taxonomy (historic, tourism, natural, man-made, leisure, amenity subsets), plus whatever a plugin brings — historical markers, castles, manor houses, Revolutionary War battle sites, whatever fits the trip.

**Defaults vary by mode and day type, and are data, not code.** A sauna is correctly excluded from a riding day's sight layer and correctly included on a rest day's amenity layer. The Candidate/Excluded verdict in the OSM attribute mapping is a *default per (mode × day-type)*, never a global truth. *(FR97.)*

**Layer loading is itself non-blocking, per layer.** A plugin dataset may be large or remote, so the picker shows each layer's own state: built-in OSM layers are usable while a plugin layer is still loading, and one layer failing never blocks the others or the workspace. This is §5.0's readiness rule applied one level down — any long operation standing between the Author and their work gets the same treatment. *(FR121, N2.)*

### 5.2 Stage 1 — Notability filter

Per-tag qualification rules run before anything is displayed or analysed, producing a **salience score** — not a binary verdict.

This stage is load-bearing. A flat `historic=*` wildcard scores a boundary stone identically to a castle. That is tolerable for a density weight, where noise averages out. It is **fatal for cluster-based proposal**, which will otherwise suggest *boundary stone near a drainage ditch* with exactly the confidence of *castle near a waterfall*. Sub-weighting the historic value list, and qualifying the known over-triggering tags (`leisure=park`, `natural=tree`, `man_made=silo`, `man_made=water_tower`, `tourism=attraction`), is what makes Stage 3 possible at all. *(FR98.)*

### 5.3 Stage 2 — Display

Candidates render as toggleable map layers with salience visible. **The Author can complete a whole trip from here.** Everything below is assistance.

### 5.4 Stage 3 — Co-location analysis

The capability that was missing entirely. Finds spatial clusters **across heterogeneous layers** within the trip's bbox, scored by combined salience and tightness. It runs as a **named Author action** over the bbox — "find the good spots" — not ambiently over a moving viewport.

Two flavours, which read very differently to a user:

- **Narrative clusters** — high-salience features near each other. *Castle beside a waterfall.* → proposes a narrative role.
- **Provision clusters** — utility features near each other. *Toilet + water + shelter.* → proposes a provision role.

A cluster may propose **both**, and **its composition suggests the roles by rule, not by recipe**. Every type in every layer's taxonomy declares **one primary role affinity**; a cluster proposes the union of the affinities present. So `historic=monument` (narrative) beside `amenity=toilets`/`drinking_water`/`cafe` (provision) reads as *a major stop — narrative + provision* — and a plugin declaring `manor_house → narrative` participates identically the day it loads. **Affinity is single-valued with Author override**: a hot spring is narrative by declaration, and the Author for whom the soak matters adds the station role at promotion, rather than every layer author having to reason about a matrix. *(FR102–FR105, FR100.)*

### 5.4a A worked pass — what reviewing proposals actually looks like

The pipeline above describes behaviour. This is the shape of the interaction, because "the Author reviews proposals" is not yet buildable.

An Author planning a Blue Ridge tour draws a bbox, enables the historic, natural, and amenity layers, and runs the analysis. Forty-three proposals come back, ranked.

**The list is the primary surface; the map is synchronized to it.** The top card reads *Linville Falls* — contributing features listed individually with their salience (`waterfall`, high; `tourism=viewpoint`, high; `amenity=parking`, low), suggested roles *narrative + provision* with the affinity that produced them, cluster tightness, and distance from the current route. Selecting the card highlights its extent on the map; selecting the cluster on the map selects the card.

**Three actions, one gesture each.** *Promote* opens the promotion interaction with roles and content pre-filled. *Reject* removes it and remembers the rejection for the trip. *Defer* keeps it, sorted below.

Nineteen of the forty-three are single-tree and small-park proposals. The Author **bulk-rejects below a salience threshold** in one action rather than nineteen. Six more are provision clusters along a road they aren't using; they filter by distance-from-route and reject those together.

Of the remaining eighteen they promote five, defer two, and leave the rest. **Re-running the analysis after adding a plugin battlefield layer preserves every rejection and marks what is new.**

*(FR105a, N4a. The rendering strategy for candidates and proposals at bbox scale is an open architectural question — ARCH Q15 — and its answer governs the map half of this.)*

### 5.5 Stage 4 — Promotion

The **editorial moment**. The Author accepts, rejects, or edits a proposal — or promotes a bare Candidate, or hand-places a point or area — and in the same interaction assigns the role set, the reveal policy per role, and any geometry offsets.

Promotion is what turns *what is out there* into *what this trip is about*. It is the single most important interaction in the product and had no representation in v1.0. *(FR110.)*

### 5.6 Stage 5 — Routing

Only now does the engine connect the promoted set. Weights govern the **character of the connecting passages** — prefer gravel, avoid traffic, take the climbier of two reasonable options — rather than searching weight space for a route that satisfies attribute bands.

### 5.7 Stage 6 — Narrative layering

Arc roles on anchors and passages, authored text and media, audio and trigger distances, Set curation, reveal decisions, and the itinerary's voice.

### 5.8 Two planning modes

| | **Explore** | **Compose** |
|---|---|---|
| Author supplies | distance, shape, weights, bands | a set of places |
| Engine returns | a route matching the bands | a route reaching the places |
| Distance is | an **input constraint**, banded by default | a **reported outcome** |
| Weights are | the search space | flavouring between fixed anchors |
| Discovery | "what's on this ride?" | "how long is this day?" |

Both are real workflows. v1.0 supported only explore.

**In compose mode, distance is reported, not enforced.** *"These seven plot points make a 94-mile day. Your band was 55–70."* The affordances are the Author's — drop one, move one to tomorrow, split the day, widen the band, accept it. This is the same information A6 surfaces, framed as an editing decision rather than a solver failure, because in compose mode it **is not a failure**. *(FR118.)*

This scopes FR8's "banded by default, never dropped from the constraint set" to explore mode, and it reframes SPIKE-01's via-node finding: distance error rising to +30.7% / +81.9% past two via-nodes is a *property of composing*, not a defect. The places determine the length. That is the correct behaviour, stated as a product position rather than discovered as a degradation.

**Modes switch in both directions, per day.** Explore → promote what you found → compose. Compose → loosen the spine → explore. Generate-then-keep-the-good-parts is a designed workflow, not an accident of the UI. *(FR119.)*

---

## 6. Scope & Non-Goals

### 6.1 In Scope

- **Data-layer and curation core**: layer selection, notability filtering, candidate display, co-location analysis, promotion to anchors with roles. *[NEW v2.0 — the pipeline above.]*
- **Routing core** (OSMnx + FastAPI backend, Dart/Flutter client) on Desktop and Web, with a Dart-first offline engine for Mobile.
- **Theme-driven route weighting**: climbing, traffic tolerance, surface distribution, and **interest** (a salience bias, FR5) — each a weight, not a mode.
- **Mode-legal routing**: routes are passable in their mode, honouring access tags, barriers, fords, and waterway obstacles. *[NEW v2.0 — a correctness gap in v1.0.]*
- **Multimodal travel** across cycling, hiking, paddling, cross-country skiing, packrafting, riverboarding and further traversal modes — plus **driving as a routed access mode**, and train/flight as authored legs.
- **Node-anchored activities** (stations): climbing, canyoneering, jumaring, soaking, swimming — activities with duration performed *at* a place. *[NEW v2.0.]*
- **Multi-day trip logistics**: waypoints, daily distance/elevation splitting, route alternatives per day, lodging and campground data, group-size-aware planning, historical weather, and river gauge readings for paddling segments.
- **Foundational usability**: session undo/redo over authoring actions, reachability of every created object, empty states that carry a next action, and **WCAG 2.2 AA** as the target for authoring and reading surfaces — a design-review checklist at MVP, with a formal audit gated before expansion beyond the Author desktop. *[NEW v2.0.]*
- **Roster and group-dynamics support**: a per-Character detail view, Author-private notes persisting across trips, and trip-scoped group/sub-group assignment overridable per day and per passage — the Author's expertise expressed as prose and arrangement, **never as a metric about a person**. *[NEW v2.0.]*
- **Narrative layer**: plot points, arc on anchors and passages, setting, place narration, reveal policy, **compose-mode place-spine trips** (FR39/FR117), trip-scoped feedback, GeoJSON export.
- **Character reading surfaces**: mobile app, web view, and print — routes, itineraries, cue sheets, POI notes, and plot points on all three. *[Corrected in v2.0 — v1.0 scoped Web to Author planning only.]*
- **In-field story participation**: reveal on arrival, arrival events shared to the roster by consent, authored branches, station decisions.
- **Export pipeline**: GPX / TCX / FIT as the interop path to external platforms.
- **Lightweight accounts, sync, and a web option** for the core loop.
- **Simple offline mobile routing**: point-to-point within a downloaded map set.
- **GPS-aware in-field companion**: a position-aware glanceable cue sheet and GPS-triggered playback of authored narration, with the phone pocketed — distinct from real-time route guidance, which is out of scope.
- **A clean plugin interface** for community data inputs and export outputs — **the data-input contract is now foundational rather than deferred** (§7, FR100).

### 6.2 Explicit Non-Goals

- **Real-time route guidance.** No live turn-by-turn, wrong-turn recalculation, or screen-centered "follow the blue line." **Distinct from GPS-aware content playback, which is in scope:** Plotlines uses GPS to trigger authored narration and advance a glanceable cue sheet while the phone stays pocketed. The boundary is *the phone is a companion that speaks up at authored moments, not a nav device you watch.* Export to a head unit remains the path for turn-by-turn.
- **Operating logistics as a platform, or social-platform parity with RideWithGPS.** No live transit/flight-status feeds, no booking engine, no continuous participant tracking, no social graph, no public feed. **Distinct from authored logistics content, which is in scope:** an Author records transit and access legs as trip data and weaves arrival into the narrative. **Also distinct from consented arrival events, which are in scope:** a Character may grant, per trip, that reaching a plot point is visible to the trip roster (FR122–FR123). That is discrete, sparse, tied to authored content, revocable, and default-off — not tracking. *(Pre-trip travel coordination remains hub-and-spoke through the Author; in-field route intel and arrivals are peer-to-peer within one roster.)*
- **Gamification.** No points, badges, achievements, unlockables, leaderboards, dice, or randomness. Reveal is authored and deterministic; chance never drives a route or an event.
- **Quantifying people.** No cohesion scores, ability indices, compatibility ratings, or any other metric describing a Character as a number to other humans. **Distinct from capability and preference data, which is in scope:** a Character's own stated pace, preferences, and derived pace profile (FR16a) are theirs, shared by their choice, and feed planning. What is out of scope is Plotlines scoring a person, or scoring how well two people go together. Group-dynamics knowledge enters as an Author's prose (FR135) and as arrangement (FR136), not as a rating.
- **UX polish beyond the foundation.** Keyboard shortcuts and a command palette, onboarding or a first-run tour, responsive layout beyond FR79's size classes, and undo across sessions are all out for MVP. **Distinct from FR142, which is in scope:** undo within a session, reachability, empty states, and WCAG 2.2 AA as a review target are the floor below which the product is capable but not usable. **Also distinct from the formal accessibility audit (FR142a), which is scheduled rather than dropped** — post-MVP, gated before expansion beyond the Author desktop.
- **Full biometric/passkey auth stack.** Magic-link only for launch.
- **Guest→account claim/merge flow.** Guest access is stateless.
- **Merge/diff conflict-resolution UI.** Sync uses a lightweight version check.
- **Shared server-side tile/elevation cache.** Deferred until real traffic justifies it.
- **"Fewest turns" route theme.** Removed — configuration surface without curation value.
- **Web *planning* parity with Desktop.** Web planning stays scoped to the core loop. **This is not a limit on Web *reading*** — the Character-facing web view of an authored journey is in scope and full (FR132).

### 6.3 Deliberately Simplified

- **Route themes** collapse into **weights**: flattest↔most-climbing is one weight; traffic tolerance is one weight; art/history becomes a **layer selection** (FR97) rather than a theme. **The v1.0 form of this simplification — "an Author-set POI type on the density weight" — was itself the defect FR5 was rewritten to remove**: a type parameter on the weight duplicated layer selection with no rule to resolve a conflict between them. The weight carries *how much*; the live layer set carries *what*.
- **Auth** collapses from a passkey cascade to magic-link.
- **Sync** keeps the version-checked conditional write and drops everything heavier.
- **Paddling difficulty** collapses from *routing constraint* to *advisory check* (SPIKE-04). The one entry here that *lost* a capability rather than a mechanism.
- **Co-location analysis is a named action over a fixed bbox**, not ambient viewport analysis. Cheap, explicit, precomputable, and it keeps the Author in charge of when the machine offers an opinion.

---

## 7. Roadmap (Legs)

Legs are capability tranches, roughly sequential, not hard gates. **v2.0 moves two things earlier**, because both turned out to be foundations rather than features.

| Leg | Theme | Disposition |
|---|---|---|
| **1–2** | Routing core, FastAPI, Desktop client, GPX/TCX/FIT export, security & QA hardening | **Done / kept as-is.** |
| **2.5** | **Layer, candidate & curation core** — layer catalog, notability filtering, salience, candidate display, plugin **data-input** contract, promotion, anchors and roles | **NEW in v2.0, and it precedes the content leg.** This is the substrate everything narrative sits on. |
| **3** | Multi-day trip logistics — waypoints, daily splits, surface scoring, weighting, per-day alternatives, lodging/campground, group-size planning, historical weather, river gauge readings | **Keep, nearly all.** The differentiated logistics territory. |
| **4** | Accounts, sync & Web | **Rescoped lighter**, plus the **Character-facing web reading surface** (FR132). |
| **5** | Mobile & offline | **Rescoped simple.** Point-to-point offline routing only; live navigation cut. |
| **6** | Narrative layer — plot points, arc on anchors and passages, setting, narration, reveal policy, themed trips, trip-scoped feedback, GeoJSON export | **Keep — and elevated.** Now sits on Leg 2.5 rather than floating. |
| **6.5** | **Co-location analysis** — narrative and provision cluster proposals, role suggestion | **NEW in v2.0.** Depends on Leg 2.5's salience. Separable from it, and the highest-leverage expression of "authorship over configuration." |
| **6.75** | **Accessibility audit** — formal WCAG 2.2 AA audit of the Author desktop surface, and remediation | **NEW in v2.0, and it is a gate rather than a leg.** Sits **before any expansion beyond the Author desktop** (FR142a). Every additional surface multiplies remediation cost, and desktop authoring is both where an Author spends the most time and where nothing currently specifies keyboard navigation, screen-reader semantics, or focus management. |
| **7** | Plugins / integrations — **output** side, and the wider ecosystem | **Redefined and split.** The data-**input** contract moved to Leg 2.5. Output shape left open. |

**Why the plugin data-input contract cannot stay in Leg 7.** Plugin datasets are how an Author gets battlefields and manor houses — they are the *substrate* the layer picker and the cluster analysis read. The contract's shape is determined by what those two surfaces need from a feature: geometry (point *and* area), a type taxonomy that can be sub-weighted, attribution, and clusterable attributes. Deferring it does not leave it open; it leaves the core loop's input format undesigned while everything above it is built on assumptions.

There is a licensing consequence too. FR86 and FR95 build careful attribution machinery for elevation and basemap. A plugin ecosystem means arbitrary third-party datasets, each with its own terms, flowing into exports and printed cue sheets — so per-layer attribution has to be part of the contract from the start (FR101).

**Hosting note (Leg 4):** Render remains the recommendation — it matches the single-instance rate-limiter and CORS assumptions already in the architecture and needs no Dockerfile/k8s for FastAPI + Postgres + static web. Budget ~$13–14/mo once live for real users.
---

## 8. Functional Requirements

FR1–FR96 carry forward from v1.0 with their numbering intact. **FR97–FR133 are new in v2.0.** Requirements whose *meaning* changed are marked **[AMENDED v2.0]** and state the prior reading, because several contradict v1.0 rather than extend it. The **Origin** column traces provenance only; Plotlines' numbering is canonical.

*Unassigned numbers, recorded so the sequence has no silent gaps:* **FR113** (arc on passages) was folded into the amended FR38; **FR127** (recap narrative axis) into the amended FR73; **FR131** (driving legs routed) into the amended FR29. Each belonged inside an existing requirement rather than beside it. FR13 remains retired per SPIKE-04.

### 8.1 Trip Initiation & Readiness

| FR | Requirement | Origin |
|---|---|---|
| **FR120** | **[NEW v2.0]** A trip **establishes a bounding box at initiation**, drawn on a map centered by a single location prompt (FR96). That extent bounds POI/layer extraction, co-location analysis, basemap tile download, and elevation coverage. **There is never a *second, different* extent for analysis** — that is the invariant; the bbox itself is **revisable throughout authoring**. Enlarging re-runs extraction and enrichment for the added area only. **The map is navigable while the extent is drawn** — zoom, pan, and recentre on the prompt's location — with a scale indication so the Author can judge the extent's real size, and an extent readout in the Author's display units (FR79). **Navigating does not alter the extent; only drawing does.** Without this, the declarable extent is bounded by whatever zoom the app happened to open at, and "declare the bbox" is the only MVP Author task with no stated means of framing the thing being declared. **Shrinking prompts**: the Author is shown which promoted anchors fall outside the new bounds and chooses to keep them (bbox unchanged), move the bounds, or remove them explicitly. Authored work is never silently discarded. | Decision D-D |
| **FR144** | **[NEW v2.0]** A trip **declares one or more travel modes at initiation**, alongside its title, location prompt, and bounding box. **At least one is required.** The declared set is the input FR97's layer defaults have been missing — it seeds which layers are live and which traversal modes are offered at passage creation (FR10). It is **not a constraint**: an Author may create a passage in an undeclared mode, and doing so **adds that mode to the trip** without warning or block. Modes are editable for the life of the trip; changing the set updates layer defaults for days the Author has not overridden and **leaves overridden days alone**. A cloned trip carries its source's modes (FR74). *Without this, FR97's central mechanism — "defaults vary by (travel mode × day type)" — has no argument to work from, and the layer picker has to assume cycling.* | Design cross-check CR-1 |
| **FR121** | **[NEW v2.0]** Readiness is **per-capability, not global**. On trip initiation, layer extraction and POI indexing complete first and unlock the authoring surfaces (layer selection, candidate display, co-location analysis, promotion); **elevation enrichment runs lazily in the background** and unlocks routing and elevation-dependent metrics on completion. Controls requiring elevation are visibly disabled with a stated reason and an honest progress indication ("terrain data loading — routing available in about 3 minutes"), never silently failing on click and never blocking the app. | Decision D-E |
| **FR91** | **[AMENDED v2.0]** Elevation enrichment at sidecar startup is a **blocking, minutes-long** operation and must run off the request-handling event loop. **Prior reading (v1.0): a sidecar still enriching elevation reports itself *not ready*, gating the whole app.** That is superseded by FR121: the sidecar reports **readiness per capability** — POI/layer/tile capabilities ready, routing and elevation capabilities not-ready-yet — and the client enables surfaces accordingly. A single global ready/not-ready flag is no longer sufficient. *(Requires a corresponding change to ARCH §7.3 health semantics.)* | POC; ARCH §7.3, amended |
| **FR96** | **[AMENDED v2.0]** The app opens on a **shipped home region** — a rectangular bbox over Buncombe County, North Carolina — so the map is never blank before any trip exists. This region is a **constant, not a default**: there is no override, no first-run prompt, and **no eager download of any kind**. It is a shipped asset that costs nothing at runtime. **Trip creation prompts for a single location** (city + state, zip code, or country + city), **prefilled with the last-used value and freely editable**, whose only job is to **center the map**; the Author then draws the trip bbox (FR120). The location prompt never becomes the bbox by inference, radius, or accepted default. **Prior reading (v1.0): a first-run prompt that downloaded a 100 km radius before any trip existed** — an eager fetch for an extent nothing had justified. **Two authoring extents now exist:** the shipped home region, and a **trip bbox**. A third extent, the **offline corridor buffer** (FR35/FR64), is a Character-side concern and never appears in this flow. | ARCH D41; corrected v2.0 |

### 8.2 Data Layers, Candidates & Curation *(Leg 2.5 — new)*

| FR | Requirement | Origin |
|---|---|---|
| **FR97** | **[NEW v2.0]** Authors select which **data layers** are live for a trip, overridable per day. Layers cover the OSM sightseeing/amenity/natural/historic/leisure/man-made taxonomy and any plugin-contributed dataset. **Layer defaults are data, not code, and vary by (travel mode × day type)** — a sauna is excluded from a riding day's sight layer and included on a rest day's amenity layer; the same tag is correctly Candidate in one context and Excluded in another. | OSM attribute mapping; concept framing |
| **FR98** | **[NEW v2.0]** Every candidate feature passes a **notability filter** producing a **salience score** (not a binary verdict) before display or analysis. **The governing rules, which apply to every layer including plugin layers:** (a) a **wildcard type is sub-weighted by value** wherever its values differ materially in notability — `historic=*` is the seed case, where a castle, fort, or archaeological site must outrank a boundary stone or milestone; (b) a type whose **instance density in a bbox exceeds a reviewable threshold requires a qualifying attribute** before it is displayable. **Seed cases for (b), not an exhaustive list:** `natural=tree` needs `denotation`, `leisure=park` needs a name or area threshold, `tourism=attraction` and `man_made=tower` need a name, `man_made=silo`/`water_tower` need a notability signal. A new layer, OSM or plugin, is qualified by applying the rules — not by being added to this list. | OSM attribute mapping ("a monument and a boundary_stone score identically") |
| **FR99** | **[NEW v2.0]** Candidates render on the planning map as **toggleable layers with salience visible** (size, weight, or opacity). An Author can promote a candidate directly from the map and complete an entire trip without invoking co-location analysis — every later pipeline stage is assistance, never a required wizard. | Pipeline §5.3 |
| **FR100** | **[NEW v2.0]** The **plugin data-input contract** is defined and shipped in Leg 2.5, not deferred. A contributed dataset supplies: feature geometry (**point and area both required**); a **type taxonomy in which every type declares a primary role affinity and a salience weight** (FR98, FR105); per-layer licence and attribution metadata (FR101); and clusterable attributes. **Affinity is what makes co-location analysis generic rather than recipe-driven** — a layer that cannot say what its features are *for* cannot participate in curation, the same discipline as the licence requirement. This contract is the substrate the layer picker (FR97) and co-location analysis (FR102) read; it cannot be designed after them. | Concept framing; supersedes part of FR84 |
| **FR101** | **[NEW v2.0]** Every layer carries **licence and attribution metadata** that propagates to the About surface (K10), to exported files where the format permits, and to **printed** itineraries and cue sheets. A plugin layer whose licence terms are absent or unsatisfiable is not loadable. A missing attribution is a build failure, consistent with FR86/FR95. | FR86/FR95 pattern extended to plugins |
| **FR129** | **[NEW v2.0]** Candidates and anchors carry **temporal availability** where the source provides it — `opening_hours`, seasonality, and conditional access. A plot point that closes on Mondays or a supermarket that shuts at six is a materially different object from one that is always there: availability surfaces to the Author at promotion, to the Character in the itinerary, and feeds FR28's scheduled-event conflict detection. | OSM attribute mapping gap |

### 8.3 Co-location Analysis *(Leg 6.5 — new)*

| FR | Requirement | Origin |
|---|---|---|
| **FR102** | **[NEW v2.0]** Plotlines performs **co-location analysis across heterogeneous live layers** within the trip's bbox, identifying spatial clusters and scoring them by combined salience and tightness. It runs as a **named Author action** over the bbox ("find the good spots"), not ambiently over a moving viewport. Results are proposals, never automatic trip content. | Concept framing (cluster/density identification) |
| **FR103** | **[NEW v2.0]** **Narrative cluster proposals**: co-located high-salience features (castle beside a waterfall; overlook above a historic mill) are proposed as candidate **plot points**, with the contributing features and their salience shown so the Author can judge the proposal rather than trust it. | Concept framing |
| **FR104** | **[NEW v2.0]** **Provision cluster proposals**: co-located utility features (toilet + drinking water + shelter; café + restroom + bike repair station) are proposed as candidate **rest stops / provisions**, with the contributing amenities listed. | Concept framing |
| **FR105** | **[NEW v2.0]** A cluster's **composition suggests its role set, by rule rather than by recipe**. Every type in every layer's taxonomy declares **one primary role affinity** — narrative, provision, or station (FR100). A cluster proposes the **union of the primary affinities present**, weighted by salience. *Illustration, not a lookup entry:* a cluster of `historic=monument` (narrative) + `amenity=toilets`/`drinking_water`/`cafe` (provision) proposes *narrative + provision* — and a plugin layer declaring `manor_house → narrative` or `crag → station` participates identically on the day it loads, with no core change. **Affinity is single-valued with Author override**: a hot spring's declared affinity is narrative, and an Author for whom the soak matters adds the station role at promotion. Single-valued because an Author should not be made to adjudicate detail that may be irrelevant to their story, and because a layer author declares one thing per type rather than a matrix. Suggested roles are always editable at promotion; the system proposes, the Author decides. | Decision D-A |
| **FR105a** | **[NEW v2.0]** Where a bbox yields more proposals than an Author can review, proposals are **ranked and bounded** — ordered by combined salience and cluster tightness, capped at a reviewable count, with the ability to filter by role, layer, or corridor proximity to an existing route. | Open item resolved as a requirement |

### 8.4 Anchors, Roles & Geometry

| FR | Requirement | Origin |
|---|---|---|
| **FR106** | **[NEW v2.0]** An Author **promotes** a candidate, cluster, or hand-placed location into an **anchor** — one object per place, carrying a **role set** of one or more of **narrative** (plot point), **provision**, and **station**. Roles are a set, not a type: a national monument is one anchor with a narrative role (the statue, its history, its audio) and a provision role (restrooms, water, café), one arrival, no duplication. | Decision D-A |
| **FR107** | **[NEW v2.0]** Each role carries **its own reveal policy, content, rendering, itinerary placement, and an optional geometry offset** from the anchor. The overlook is 400 m up a spur from the parking lot; the put-in is 80 m from the restroom — a trigger measured from the wrong point fires the narration in the wrong place. | Decision D-B |
| **FR108** | **[NEW v2.0]** **Anchors and roles may be areas, not only points.** Polygon geometry is first-class for a historic district, arboretum, main-street block, nature reserve, or park. Areas serve three distinct purposes: they can *be* a cluster boundary rather than a point-plus-radius; **entry into a polygon is a trigger event** distinct from point proximity (FR126); and they express rest-day authoring ("spend the afternoon on Main Street") that a point model cannot. *(Reverses v1.0's scope call that all spatial objects are nodes or edges.)* | Decision D-B |
| **FR109** | **[NEW v2.0]** The **station role** models an activity performed *at* a place with duration — a crag, hot spring, sauna, summit scramble, swimming hole, canyon descent. It carries activity type, expected duration, gear requirements, and an Author-declared difficulty, and it participates in day timing, ETAs, and gear lists (FR24). **Climbing, canyoneering, and jumaring are stations, not travel modes** — a Character reaches them by some traversal mode and then does the activity. | Concept framing; OSM mapping (`climbing=crag` as a site-level "worth a stop" marker) |
| **FR110** | **[NEW v2.0]** **Promotion** is a single interaction in which the Author accepts/edits a proposal or promotes a bare candidate, and assigns the role set, per-role reveal policy, per-role geometry offsets, and initial content. Rejected proposals are remembered for the trip so the same cluster is not re-proposed on every run. | Pipeline §5.5 |
| **FR37** | **[AMENDED v2.0]** Authors attach **rich notes, instructions, and media** to any anchor role, passage, or day, and may weave shared Character details into that narrative. **Prior reading (v1.0): content attached to an undifferentiated "node."** Content now belongs to a *role*, which is what allows one place to hold always-visible provision detail and revealed-on-arrival narrative at the same time. | CTP, Plotlines Story 6; amended |

### 8.5 Arc, Setting & Narrative Structure

| FR | Requirement | Origin |
|---|---|---|
| **FR38** | **[AMENDED v2.0]** **Arc roles** (exposition, rising action, crux, climax, resolution) attach to **anchors *and* passages**, are distinguished on map and timeline, and participate in day composition and itinerary rendering. **Prior reading (v1.0): arc was a [P1] tag applied to points only** — which meant the story could only happen at places and never on the road between them, wrong for an activity where the road between them is most of the experience. Arc is structure in v2.0, not a label. | Plotlines Story 16; amended |
| **FR111** | **[NEW v2.0]** Plotlines identifies **Sets** — named place-identities a passage or anchor sits inside. **The rule: any source-authored, named place-identity a route passes through or within is a Set candidate**, whatever layer supplies it. **Seed cases from OSM, not an exhaustive list:** route relations (`type=route` + `route=bicycle`/`hiking`/`mtb`/`piste`), `network=lcn`/`rcn`/`ncn`/`lwn`/`rwn`/`nwn`/`iwn`, `leisure=nature_reserve`, `boundary=*`, `mountain_pass=yes`, and `disused:railway=*` provenance. A plugin layer supplying named regions — a battlefield park, a wine appellation, a historic district — yields Sets by the same rule. This is the concrete form of *setting*. | OSM attribute mapping ("lets the app surface 'you're riding the X Greenway' as content") |
| **FR112** | **[NEW v2.0]** Authors **curate Sets** rather than composing them — accept, rename, annotate, or dismiss a detected place-identity, which then appears in itineraries, cue sheets, and node cards as narrative context ("you're on the Virginia Creeper Trail now"; "this was the Norfolk & Western line"). Set detection is the cheapest good narrative material in the system: free, already named, and locally true. | Concept framing (setting) |
| **FR133** | **[NEW v2.0 — the Frodo principle]** Itineraries, cue sheets, node cards, and print render **provisions within the same narrative register as plot points**, not broken out into a separate logistics panel. Practical detail is woven into the day's account; it is findable at a glance without dropping the Character out of the story. A build in which logistics and narrative are two disjoint surfaces does not satisfy this requirement. | Concept framing (§1.4) |

### 8.6 Reveal Policy

| FR | Requirement | Origin |
|---|---|---|
| **FR114** | **[NEW v2.0]** **Reveal is a property of a role, not of a place.** Each role is either *always visible* (present in the plan from download, on web, and in print) or *revealed on arrival* (withheld until the Character reaches its trigger). **Provision roles default to always-visible** — knowing where the water is reduces anxiety. **Narrative and station roles default to the Author's choice** — a waterfall found around the bend sparks joy that a spoiler destroys. | Decision D-H |
| **FR115** | **[NEW v2.0 — hard constraint]** **Hazards and technical cruxes are always visible, regardless of role, reveal setting, day type, or Author preference.** No Author can author their way into hiding a safety-critical item, and no reveal policy applies to one. This is enforced in the model, not left to authoring discipline. | Decision D-H |
| **FR116** | **[NEW v2.0]** **Print and web inherit reveal policy.** A printed cue sheet or itinerary shows every provision, every hazard, and the arc's shape — but not the content of unrevealed plot points. **The paper copy cannot spoil the trip.** | Decision D-H |
| **FR124** | **[NEW v2.0]** Revealed content is **delivered on arrival** in the field: reaching a role's trigger unlocks its text, media, and audio for the Character, permanently thereafter. Reveal runs fully offline from raw GPS and never requires connectivity. | Decision D-H; FR49 pattern |
| **FR126** | **[NEW v2.0]** **Area entry is a trigger event.** Crossing into a polygon anchor's boundary fires its narration, reveal, or notification the way point-proximity does for a point anchor, with entry debounced so a boundary-hugging route does not re-fire. | Decision D-B |

### 8.7 Planning Modes

| FR | Requirement | Origin |
|---|---|---|
| **FR117** | **[NEW v2.0]** Plotlines supports two planning modes per day: **explore** (Author supplies distance, shape, weights and bands; engine returns a route matching them; the Author discovers what is on it) and **compose** (Author supplies a set of promoted anchors; engine returns a route reaching them; the Author learns its length). | Decision D-F |
| **FR118** | **[NEW v2.0]** **In compose mode, distance is a reported outcome, not an enforced constraint.** The realized distance and its deviation from any stated band are surfaced as an *editing decision*, not a solver failure: "these seven plot points make a 94-mile day; your band was 55–70." Affordances are the Author's — drop an anchor, move one to another day, split the day, widen the band, or accept the deviation. In compose mode, **weights flavour the connecting passages** rather than defining a search space. | Decision D-F |
| **FR119** | **[NEW v2.0]** A day **switches between explore and compose in both directions**, without losing work. Explore → promote what was found → compose. Compose → loosen the spine → explore. Generate-then-keep-the-good-parts is a designed workflow. | Decision D-G |
| **FR8** | **[AMENDED v2.0]** Target **distance** is settable for loop and out-and-back shapes and is **banded by default in explore mode** — the search treats it as a constraint on the *realized* route, not a soft target free to trade away (SPIKE-03 measured up to +14.8% unannounced drift when unbanded). **Prior reading (v1.0): distance is never dropped from the search's constraint set, unconditionally.** In **compose** mode that no longer holds: the anchors determine the day's length and FR118 governs. | CTP FR47; SPIKE-03; scoped v2.0 |
| **FR8a** | **[AMENDED v2.0]** A **loop may be constrained to pass through designated via-anchors** while returning to start, with weights and target distance honoured around the constraint. In **explore** mode this is bounded: one or two via-anchors honour target distance (story A9); three or more make distance advisory (A9a, SPIKE-01: +30.7% Boulder, +81.9% Viroqua). **In compose mode this is not a degradation but the expected behaviour** — the places determine the length, per FR118. **Prior reading (v1.0) treated multi-via distance drift as a UI-and-expectations defect;** v2.0 states it as a product position for compose and a bounded constraint for explore. | SPIKE-01; reframed v2.0 |
| **FR5** | **[AMENDED v2.0]** An **interest weight** (0.0–5.0) biases an explore-mode route toward **high-salience candidates** (FR98) within the live layer set. **It carries no POI *type* parameter** — layer selection (FR97) already says *what* matters, and the weight says only *how much*. **Prior reading (v1.0): a POI-*density* weight with its own Author-set type.** Two defects are corrected. First, **type was a duplicate surface**: an Author could select historic layers in the picker and set a conflicting type on the weight, and no rule resolved it. Second, **density measured the wrong thing** — counting POIs biases toward *quantity*, and quantity correlates with boundary stones and street trees; salience did not exist when the weight was written, and "pass better places" is now available where only "pass more places" was. This preserves the workflow clustering does not serve — *"give me a 40-mile loop past good stuff; I don't want to review anything"* — which is explore mode's whole premise. **The weight is inactive in compose mode**, where the Author's promoted anchors are the spine. The two modes are therefore not *curated vs. uncurated* but **salience judged by the machine vs. salience judged by the Author** — same data, same notion of good, different level of Author involvement. | CTP FR5; reformulated v2.0 |
| **FR39** | **[AMENDED v2.0]** Authors build **POI-themed trips where the curated places are the organizing spine of the route**. **Prior reading (v1.0): a single [P1] sentence with no supporting machinery.** In v2.0 this is not a variant feature — it is **compose mode** (FR117–FR119), supported by the full pipeline of FR97–FR110, and it is a primary path rather than an alternative one. | Rebrand-plan Leg 6; elevated v2.0 |

### 8.8 Routing & Themes

| FR | Requirement | Origin |
|---|---|---|
| **FR1** | The routing engine generates routes on an OSMnx graph via the FastAPI backend on Desktop and Web. | CTP core |
| **FR2** | A **climbing weight** ("peaks", 0.0–5.0, decimal) controls elevation gain/density along a continuous scale (flat ↔ maximal climbing), honoring origin/destination. | CTP FR1/FR2, Plotlines 10a |
| **FR3** | A **traffic-tolerance weight** ("cars", 0.0–5.0, decimal) balances quiet roads against direct urban egress via road-class/density thresholds. **Rural/low-signal roads are the zero-stress baseline** — highway-class tags alone never impose a stress floor; only real capacity/speed signals (`maxspeed`/`lanes`) raise stress above it. | CTP FR3; SPIKE-03/ARCH D33 |
| **FR4** | A **surface weight** is set **independently per class** (paved / gravel / singletrack), each running **0.0 (avoid) ↔ 2.5 (indifferent) ↔ 5.0 (seek)** — so an Author can seek gravel or singletrack outright, not merely deprioritize paved. | CTP FR4; SPIKE-03 |
| **FR6** | **[AMENDED v2.0]** Authors set a **min and max** on any weighted route attribute — climbing, traffic exposure, surface mix, **realized salience** (FR5's interest weight), distance — and the engine searches weight space for a route whose *realized* values fall inside every band. Bands bound the outcome, not the weight setting. **Prior reading (v1.0): the band list named "POI density"**, which was both the wrong measure (quantity rather than quality) and the wrong name once FR5 was reformulated. *(Explore mode; see FR118 for compose.)* | CTP, Story 10; SPIKE-03 |
| **FR7** | Route **shape** (loop, out-and-back, point-to-point) is selectable independently of weights. | CTP FR35 |
| **FR9** | When constraints conflict, the engine names the conflicting constraints and offers relaxations with their trade-offs — never a silent compromise or raw error. | CTP FR43 |
| **FR128** | **[NEW v2.0 — correctness gap]** Generated routes are **legal and physically passable in their mode**. The engine honours access tags as hard constraints (`bicycle=no`, `bicycle=use_sidepath`, `bicycle=destination`, `foot=no`, `canoe=no`/`private`/`permit`), surfaces `bicycle=dismount` sections explicitly rather than silently routing through them, accounts for barriers (`barrier=cycle_barrier`, `bollard`, `gate` with their own access values), fords (`ford=yes`/`stepping_stones`), and hard waterway obstacles (`waterway=weir`/`lock_gate`/`hazard`/`waterfall`), and respects contraflow permission (`oneway:bicycle=no`) and climbing access closures (`climbing:access=*`). **The governing rule: a tag that determines whether a way may legally or physically be traversed in a given mode is a routability constraint, and is honoured as one.** The table above is the seed set for the modes shipping first, not a closed list — a new traversal mode, or a plugin supplying access semantics, brings its own constraints and is handled by applying the rule. **A "ridable route" guarantee means a route the Character can actually ride, walk, or paddle** — v1.0 specified no such guarantee anywhere in 96 requirements. | OSM attribute mapping (routability-constraint column) |

### 8.9 Multimodal Travel, Stations & Domain Parameters

| FR | Requirement | Origin |
|---|---|---|
| **FR10** | **[AMENDED v2.0]** Authors create **passages** with a start, end, and primary **traversal mode**. Plotlines distinguishes **traversal modes** — cycling, hiking, paddling, cross-country skiing, packrafting, riverboarding, mountain biking, and **driving** — from **station activities** (FR109), which are performed at a place rather than between two. **Prior reading (v1.0): three first-class modes with "further modes" deferred as a scoping decision** — which quietly filed climbing, canyoneering, and jumaring as travel, though `WeightProfile` models only horizontal traversal and could never have absorbed them. | Plotlines Story 2; corrected v2.0 |
| **FR130** | **[NEW v2.0]** Adding a **traversal mode** requires only a new `WeightProfile` entry and its domain parameters (M1) — no parallel scorer. Adding a **station activity** requires only an activity-type entry — no routing change at all. The two extension paths are distinct and both are configuration. | M1 seam; Decision from §4.3 |
| **FR11** | Authors **order and sequence** passages within a day to compose multimodal days, with a warning when adjacent endpoints fall more than a set distance apart. | Plotlines Story 3 |
| **FR12** | Authors place **transition nodes** between modes, marking where Characters switch activities, stash/retrieve gear, or execute put-ins/take-outs, with attached instructions. | Plotlines Story 15 |
| ~~**FR13**~~ | ~~Whitewater difficulty/water-type weighting.~~ **Removed — SPIKE-04.** No per-edge class rating exists in any usable source. *(Number retired, not reused.)* | Plotlines 10e/10f |
| **FR14** | Authors set an **advisory gauge band** (min/max flow or stage) on a paddling passage, and a **terrain technicality/exposure** level on a technical land passage. Plotlines shows the current reading against the band and warns outside it; it never filters or excludes routes on this basis. | Plotlines Story 18 |
| **FR14a** | Plotlines reads **river gauge data from USGS**, age-stamps every reading, and states plainly when a passage has no gauge. Delivered in Leg 3 alongside historical weather; a stale reading is labelled, never silently presented as current. | SPIKE-04 |
| **FR14b** | **[NEW v2.0]** Where a source **does** publish difficulty grading for a mode, Plotlines reads it rather than requiring Author declaration: `sac_scale` and `trail_visibility` for hiking, `mtb:scale`/`mtb:scale:uphill`/`mtb:scale:imba` for mountain biking, `piste:difficulty` for nordic. **SPIKE-04's whitewater finding does not generalize** — it tested `whitewater:section_grade` specifically, and coverage for these other schemas is a separate empirical question that should be measured before falling back to FR14's Author-declared level. Author declaration remains the fallback where data is absent or thin. | OSM attribute mapping; open question flagged v2.0 |
| **FR15** | Authors **draw portages and water-trail connections** on paddle passages — exit bank, portage distance, surface, elevation change, mandatory-hazard flag — calculated separately from water distance and auto-included in cue sheets/itineraries. Author-drawn (SPIKE-04 found no open portage-route data); mapped hazards may be surfaced to prompt one. | Plotlines Story 23 |
| **FR16** | Authors configure **mode- and terrain-specific travel speeds**, choosing a system default, a custom Author pace, or the aggregated participant pace. The system default's accuracy is mode-dependent: hiking's is within a point of a personal model (9.6% vs 9.7% MAPE); cycling's is off by **31.4%**, cut to **7.5%** by a personal pace. | Story 29; SPIKE-05 |
| **FR16a** | Authors and Characters may **upload activity files** (FIT/GPX) to derive a personal pace profile. Only derived metrics are retained; **no raw position or timestamp reaches the output**, keeping upload consentable at the field level like any other profile data. | SPIKE-05 |
| **FR16b** | **[NEW v2.0]** **Station durations participate in day timing.** A station's expected duration feeds moving-vs-elapsed time, ETAs, and scheduled-event conflict detection (FR28) — a three-hour crag is three hours of the day, not an annotation on a pin. | FR109 consequence |

### 8.10 Multi-Day Trip Logistics (Leg 3)

| FR | Requirement | Origin |
|---|---|---|
| **FR17** | Authors define **adventure duration** (single-day, multi-day, multi-week) via start/end dates or a day count. | Story 1 |
| **FR18** | Authors designate **Start, End, and Rest/Zero days**; rest days hold location, anchors, itinerary detail, and scheduled events without an active route. **Rest days are a primary use case for area anchors** (FR108) — a main street, a historic district, a spa quarter. | Story 9; extended v2.0 |
| **FR19** | **[AMENDED v2.0]** Authors split days with **per-mode min/max distance boundaries**, with an indicator when a passage breaches a threshold. **Day boundaries are additionally narrative**: a day may be closed at a resolution-arc anchor rather than a distance threshold, and the day-splitting surface presents both the metric and the arc shape. **Prior reading (v1.0): day splitting was purely a distance mechanic** — the chapter break had become a number. | CTP FR10/FR20, Story 20; extended v2.0 |
| **FR20** | **[AMENDED v2.0]** Authors attach per-day **alternate routes** to any passage, across any mode, tagged clearly for Characters on maps and cue sheets. Alternates carry **two distinct authoring intents**: *accommodation* alternates (bypass/easier, extension/challenge) that adjust effort, and **branch alternates** — story-shaped choices with **different content on each path** (the long way past the abandoned mine, or the direct way home). **Prior reading (v1.0): alternates were a fitness ladder only,** which gave Authors no vocabulary for a narrative choice. | CTP, Story 19; extended v2.0 |
| **FR21** | Authors place **waypoints, regroup points, and amenity-tagged rest stops** on a passage. *(In v2.0 these are provision-role anchors; FR104's cluster proposals feed this directly.)* | CTP, Stories 4–5 |
| **FR22** | Authors define a **target group-size tier** (solo / small / party / large / event), reflected in logistics. | CTP, Story 13 |
| **FR23** | Authors filter and place **lodging/campground** options on the planning map by type. | CTP, Story 11 |
| **FR24** | Authors build **gear checklists** by mode **and by station activity** — mandatory safety gear, shared group gear assignable to Characters, and personal lists Characters can check off. | Story 32; extended v2.0 |
| **FR25** | Authors mark **water sources, resupply points, and group meals** — potable vs. filter-required water, resupply with hours, meal responsibilities — with water-carry distances shown between sources. *(Provision-role anchors; always visible per FR114.)* | Story 33 |
| **FR26** | Authors attach **permits, land-access rules, and parking passes** to passages/anchors (status, confirmation numbers, documents/links), surfaced to Characters as a pre-trip checklist. | Story 34 |
| **FR27** | Authors place **hazard and technical-crux warnings** on any route, transit leg, or anchor, with severity levels, safety notes, and required-gear callouts; high-severity markers trigger a distinct Character alert. **Always visible per FR115.** | Story 27 |
| **FR28** | Authors embed **scheduled, time-bound events** (tours, ferries, concerts, bookings) tied to a date/time window, with the timeline flagging conflicts when pace would miss the window. Station durations (FR16b) and anchor opening hours (FR129) feed this check. | Story 28; extended v2.0 |
| **FR29** | **[AMENDED v2.0]** Authors build **transit and access legs** to trailheads and put-ins. **Driving legs are routed**, using the same engine in driving mode, producing a real route with distance, time, and a cue sheet — because the last mile to the trailhead is often the most harrowing part of the day. **Train, shuttle, and flight legs are authored notes**, carrying identifiers, carrier, scheduled times, and links. **Prior reading (v1.0): all four were flattened into "authored trip data, not a live integration,"** losing the distinction and leaving driving out of the mode list entirely. Neither form is a live-status or booking integration. | Story 17; corrected v2.0 |
| **FR29a** | **[NEW v2.0]** A driving leg carries a **vehicle-access advisory**. The Author declares an expected vehicle capability (2WD / AWD / high-clearance / 4WD); Plotlines reads the road's own signals — `surface=*` (gravel, dirt, unpaved, compacted, ground), `smoothness=*` (`very_bad` through `impassable`), `tracktype=grade1`–`grade5`, `4wd_only=yes`, `highway=track`, `motor_vehicle=*` — and **flags where the route exceeds the declared capability**, in the leg summary and on the cue sheet. **Advisory, not a constraint** — it warns and surfaces, it never excludes or reroutes, on the same footing as FR14's gauge band. Two reasons: tag coverage is uneven, and whether a given vehicle will make a given road is the Author's judgment, not the app's. **Tag coverage is stated plainly** rather than implying completeness, per the FR46 honesty clause. This is the requirement behind *"sometimes the last mile to the trailhead or put-in is the most harrowing moment of the day."* | Concept framing; OSM road-surface tags |
| **FR30** | Characters **share their own transit/arrival details** with the Author on a per-field, opt-in basis; the Author may author them into the narrative. Characters do not share pre-trip travel details with each other through Plotlines. | Story 17 |

### 8.11 Planning Metrics, Roster & Group Mechanics

| FR | Requirement | Origin |
|---|---|---|
| **FR31** | A **real-time planning dashboard** shows distance and elevation by passage, day, total, and mode — and, with FR16, moving time / elapsed time / ETA including station durations — updating on every edit. | CTP, Stories 21, 29 |
| **FR32** | Authors view **overlaid elevation-profile comparisons** for a primary route and its alternates in one view, colour-distinguished, with map-linked scrubbing. | Story 22 |
| **FR33** | Authors view **historical weather** — a 5-year temperature range for a passage, expandable to a 10-year distribution (±3 days) with precipitation volume and type. | CTP FR14, Stories 7–8 |
| **FR34** | Authors review **aggregated group preferences** (climbing, traffic, surface, distance, speed, river class) with Min/Max/Avg/Mode, plus a histogram for groups over ten, filtered to whole-trip modes. | Story 14 |
| **FR134** | **[NEW v2.0]** Authors open a **single detail view per Character** on a trip, consolidating granted profile fields (FR78), volunteered fields, preference and capability values feeding the aggregation (FR34), attendance days, assigned gear and meal responsibilities (FR24, FR25), roster group assignment (FR136), and the Author's own notes (FR135). Reachable from the roster and from Manage Roster (FR74). **An ungranted field reads as *not shared*, never inferred and never blank** — "no allergies listed" and "didn't tell me about allergies" are different facts and must not render alike. | Concept framing (group dynamics as Author expertise) |
| **FR135** | **[NEW v2.0]** Authors record **free-text notes about an individual Character**, visible only to that Author — the group-dynamics knowledge an Author carries that no structured field holds. **Scoped to Author + Character and persisting across trips**, because the knowledge is about the person, not the trip. Each note carries a **last-updated date, displayed small and unobtrusively beside the field**: a claim about someone's climbing written three years ago is worse than no claim if its age is invisible. **Notes are a category that never crosses to a Character** — no Character-facing surface, itinerary, cue sheet, print output, export, offline package, group relay, or shared link. *This is the inverse of the reveal boundary — reveal governs* when *Author content reaches a Character; notes reach them* never *— and it is enforced at the same gate.* **Excluded by default from the trip archive** (FR70), included only by an explicit, separately-confirmed choice naming what it would expose. | Concept framing; §1 "deep knowledge of how group dynamics influence an experience" |
| **FR135a** | **[NEW v2.0]** Authors **delete an individual note, all notes for one Character, or every record they hold about a Character** — notes across all trips plus any locally cached copy of that Character's shared profile data. Deletion is **immediate, complete, and irreversible**: data removed, not flagged hidden. The confirmation **states what will be removed and across how many trips**, since years of accumulated notes are unrecoverable. **Deletion never removes the Character from a roster or alters trip content**, and the two actions are independent in both directions. Available whether or not the Character is still on a trip, so a request can be honoured by an Author who no longer travels with them. Propagates to synced devices; a device offline at deletion completes it on reconnect. | Data-privacy practice |
| **FR136** | **[NEW v2.0]** A Character on a trip may be assigned a **group** and optional **sub-group**, stored on the **trip roster entry, not the account profile** — a person is in different groups on different trips, and a profile field would follow them onto the next one. **Time-scoped**: a trip-level default, overridable per day and per passage, because a group's composition changes across the arc of a day. **Groups are Character-visible**, unlike notes: a Character sees their group and its membership for a given day or passage. Groups are addressable wherever individuals already are — gear assignment (FR24), meal responsibility (FR25), regroup points (FR21), individual itineraries (FR48). **No cohesion score, ability index, compatibility rating, or any other quantification of people.** | Concept framing (group dynamics) |
| **FR137** | **[NEW v2.0, Later]** Authors manage the roster as **multiple Character cards in one view**, arranging them into groups and sub-groups by direct manipulation across the arc of a day, scoped per day or per passage with the arc visible so the Author sees *when* a grouping applies. Each card surfaces what is needed while arranging — capability signals, preferences, a note excerpt with its date, current assignment. **This is roster management in a richer surface, not a new feature area**: it writes to FR136's data, adds no new model, and blocks nothing before it. Deferred to a late leg as a substantial interface lift. | Concept framing |
| **FR35** | Authors set the **offline data buffer distance** (corridor around the finished route) saved as a download parameter for the adventure package. Distinct from the trip's authoring bbox (FR120) and from the home region (FR96). | Story 12; clarified v2.0 |
| **FR36** | Weight profiles **scope** to whole-tour, a single day, or a partial-day passage, overriding the tour default without re-planning the trip. | CTP FR13 scoping |

### 8.12 Content, Curation & Feedback (Leg 6)

| FR | Requirement | Origin |
|---|---|---|
| **FR40** | Plot points support **audio narration** authored or attached by the Author, downloaded with the offline package. | Rebrand-plan Leg 6 |
| **FR40a** | **[NEW v2.0]** Characters may opt to have **text content read aloud by the device's native text-to-speech engine** — plot-point notes, provision detail, Set context, cue text, and hazard notes — as an alternative or supplement to authored audio (FR40). The setting is Character-controlled and per-device, applies across the app, web, and field surfaces, and works offline wherever the platform's TTS voices are installed on-device. TTS reads **only what the Reveal Resolver has released** (FR114–FR116): unrevealed content is never spoken, and hazard content is always available to be spoken. Where an Author has attached audio narration for a role, that audio takes precedence and TTS does not duplicate it. | New v2.0 |
| **FR41** | Authors set a **per-role narration trigger distance** (or, for area roles, entry per FR126), so a viewpoint announces far out while a turn-off announces close in. | New; extended v2.0 |
| **FR42** | Characters submit **trip-scoped feedback** on the current trip's routes and places, visible only to that trip's Author and Characters; fellow Characters can upvote/downvote, the Author sees all feedback and tallies, and incorporation is manual. No cross-account or public content pool. | Rebrand-plan Leg 6, rescoped |
| **FR43** | Trips export to **GeoJSON** (RFC 7946) with custom feature properties for anchor roles, geometry types, modes, arc, and metadata. **Area anchors export as polygons** (FR108). | Rebrand-plan Leg 6; extended v2.0 |

### 8.13 Outputs, Interop & Reading Surfaces

| FR | Requirement | Origin |
|---|---|---|
| **FR44** | Trips export to **GPX, TCX, and FIT**, with selectable contents (track+elevation, waypoints/stops, cue sheet, variants) and file splitting (single or per-day). | CTP FR9, C14 |
| **FR45** | Exported waypoints, regroup markers, rest-stop names, and **plot-point notes** are preserved as native course/turn points where the target format supports them. *(In v2.0 "plot point" is a defined object — see §4.3 — not an undefined phrase.)* | CTP FR9, C14 |
| **FR46** | Authors generate **per-day cue sheets**, viewable in-app and printable, including surface shifts, plot points, provisions, portages, hazards, station activities, and scheduled events — rendered per FR133's narrative register and FR116's reveal policy. | CTP FR44, Story 26; extended v2.0 |
| **FR47** | The in-app cue sheet is **position-aware**: it advances with the Character's GPS location, highlighting current/next cue, glanceable in one look-down. Runs offline from raw GPS; the cached basemap is not in its critical path. | New |
| **FR48** | Authors generate a **master group itinerary** and **tailored individual itineraries** for partial-attendance Characters, retaining relevant notes and places, previewable/printable/exportable. | Stories 24–25 |
| **FR132** | **[NEW v2.0]** Characters read an authored journey on **three surfaces with equivalent content**: the mobile app, a **web view**, and **print**. All three carry routes, itineraries, cue sheets, place notes, and plot points, subject to reveal policy (FR116). **Prior gap: v1.0 scoped Web to the Author's core planning loop (FR61) and had no Character-facing web reading surface at all**, though the concept named it as one of three delivery channels. FR61's *planning* scoping is unchanged. | Concept framing; gap in v1.0 |
### 8.14 Field Execution (Character)

| FR | Requirement | Origin |
|---|---|---|
| **FR49** | Mobile plays a role's **narration automatically** when GPS enters its trigger distance (FR41) or its area boundary (FR126), phone pocketed, fully offline from raw GPS, no data connection. | New |
| **FR50** | The Character's execution view is an **auto-updating cue HUD** with progress, the next cue in focus, header readouts for remaining distance/elevation/ETA, expandable cue detail cards, and one-gesture toggle to the map. Active-scroll behavior is governed by device posture (FR50a). | Story C22 |
| **FR50a** | The HUD runs in two **device postures** over the same position and cue state: **Stowed** (screen off/dimmed, phone pocketed — GPS silently advances cue position and drives narration, no live rendering) and **Mounted** (screen on — the HUD auto-scrolls to the next cue live). Switching postures re-syncs the view to current position; the app never auto-scrolls a screen no one is watching. | New |
| **FR51** | Cue distances and ETAs **dynamically recalculate** from actual GPS position and pace; passing/missing a cue advances the marker; toggling an alternate re-inlines its cues without a full reload. | Story C23 |
| **FR52** | The cue HUD is **hands-free and glove-friendly**: oversized high-contrast type, ≥48dp touch targets, and optional volume-button/swipe stepping. | Story C24 |
| **FR53** | Characters receive **hazard/crux alerts** — severity badges and gear notes, with a warning tone/header when their offline position nears a high-severity hazard. Never subject to reveal policy (FR115). | Stories 27, C11 |
| **FR54** | A **dead-zone odometer** holds last-known position on GPS loss and allows manual mileage scrolling of the cue sheet until signal returns. | CTP, Story C20 |
| **FR54a** | Field execution uses **adaptive location accuracy**: a low-power tier for coarse proximity detection while stowed, escalating to high accuracy only near a narration/hazard/reveal trigger or when the screen is active. | New |
| **FR122** | **[NEW v2.0]** **Arrival at a plot point is an event.** Reaching a narrative-role trigger records an arrival for that Character — timestamped locally, offline-capable, and synced when connectivity allows. Arrivals feed the Character's own record and the post-trip recap regardless of any sharing decision. | Decision D-I |
| **FR123** | **[NEW v2.0]** **Arrival visibility is consented through the existing profile-request mechanism (FR78/FR78a)** — one more field in the Author's request set: the Author requests, the Character grants or declines, per trip, revisable, **default nothing shared**. When granted, arrivals are visible to the **trip roster**, not to the Author alone, because the use case is regroup — *"three of us are already at the overlook."* **Timestamp display is an Author option** per trip. This adds no new consent machinery, and is not participant tracking: it is discrete, sparse, tied to authored content, and default-off. | Decision D-I |
| **FR125** | **[NEW v2.0]** Characters make **in-story choices** at authored branch points (FR20) and station activities (FR109) — take the long way past the mine or the direct way home; spend three hours at the crag or bypass it. The choice is recorded, updates that Character's cues, metrics, and ETA independently, and is reflected in the recap. **No randomness, no chance, no dice** (Brand Value 9): every branch and its consequences are authored. | Decision D-J; §4 |
| **FR55** | Any User can make an **in-field route amendment** offline — toggle a pre-planned alternate or draw a modification — updating the local map, elevation, and cue sheet, persisting locally and syncing when connectivity returns. | Story 35 |
| **FR56** | A User may **publish a route amendment to the group**; connected members receive a notification, preview current-vs-proposed with updated distance/elevation/hazard metrics, and choose Accept / Decline / Select-Alternate. An amendment can carry a **severity/hazard flag and a free-text safety note**, which elevates it to a warning-level broadcast to everyone approaching that point. | Story 36 |
| **FR56a** | Any participant may pin a **field note** — a location-anchored, timestamped, advisory text note — to a point on the shared route. Field notes are peer-to-peer within the trip roster, surface to Characters as they approach, and change no one's route. They are **Author-anchored**: a note persists and keeps surfacing until the Author curates it into the plotline or dismisses it. | New (Story 36 discussion) |
| **FR56b** | **[NEW v2.0]** An Author may **promote a field note into a permanent anchor** — assigning it a role set, reveal policy, and content — closing the loop between what a Character discovered in the field and what the plotline says on the next running of the trip. | FR56a's "curates it into the plotline", made concrete |

### 8.15 Accounts, Sync & Web (Leg 4)

| FR | Requirement | Origin |
|---|---|---|
| **FR57** | Users authenticate via **magic link** only; no password, no SMS OTP. Local planning works immediately; only account-scoped surfaces wait on sign-in. | CTP FR19, rescoped |
| **FR58** | Signed-in Users' trips and non-trip preferences **sync** across devices via a canonical per-account copy; each device keeps an offline-capable working copy. | CTP FR21 |
| **FR59** | Sync uses a **version-checked conditional write** on open and before save: on conflict, the User chooses save-as or overwrite — never a silent overwrite, no auto-merge UI. | CTP FR32 |
| **FR60** | **Guests** use the core loop statelessly, with work persisted only in their own browser; nothing stored server-side; limits stated plainly. | CTP FR22 |
| **FR61** | The **Web planning client** is scoped to the core loop — pick theme/shape/distance → generate → save → export — not full Desktop planning parity. *(Web **reading** is not scoped down; see FR132.)* | Rebrand-plan Leg 4; clarified v2.0 |
| **FR62** | Web and Guest call the elevation provider **directly**; no shared server-side cache in this phase. | Rebrand-plan Leg 4 |

### 8.16 Mobile & Offline (Leg 5)

| FR | Requirement | Origin |
|---|---|---|
| **FR63** | Mobile supports **simple point-to-point** route creation within a downloaded map set via the Dart-first offline engine — no offline elevation, no real-time route guidance. | Rebrand-plan Leg 5 |
| **FR64** | Characters **download a complete adventure package** (routes, cue sheets, anchor media, narration audio, unrevealed content in encrypted-at-rest or otherwise non-browsable form, basemaps within the corridor buffer) in one action for fully-offline use. | CTP, Story C13; extended v2.0 |
| **FR64a** | **[NEW v2.0]** **Unrevealed content downloads with the package but is not browsable before its trigger.** Reveal must work in airplane mode, so the content is on the device — the requirement is that the app does not surface it early through any ordinary UI path (file lists, search, export preview, share sheets). This is a *product* guarantee against accidental spoiling, not a security boundary against a determined user inspecting their own device, and it is documented as such. | Decision D-H consequence |
| **FR65** | Offline behavior is **quiet**: offline-capable features show no offline messaging; a genuine limit surfaces once, inline, never modal; a passive indicator shows connectivity. | Rebrand-plan |
| **FR66** | Cached weather **forecasts are age-stamped** and never silently replaced by historical data; live forecast overlays but never obscures the historical baseline. | CTP FR15, C5 |
| **FR67** | The mobile app minimizes **GPS/CPU/network wake-ups** and keeps functioning under the device's OS power-saving mode. | CTP NFR |

### 8.17 Portability & Durability

| FR | Requirement | Origin |
|---|---|---|
| **FR68** | The app **auto-saves local GeoJSON backups** of trip spatial layers on key edits and at intervals. **Includes area anchors as polygons and role offsets as distinct features.** | Story S3; extended v2.0 |
| **FR69** | Field notes, journals, and narrative content are stored as **portable Markdown** with relative image references and standard link syntax. | Story S4 |
| **FR70** | Users **export a complete trip archive** (`.zip`) containing GeoJSON/GPX/TCX routes, Markdown journals, photo binaries, and a `manifest.json`, generated without choking the device. | Story S5 |
| **FR71** | Users **restore/import a trip** from a Plotlines `.zip`, validating the manifest and media references before importing, with progress and a completion summary. | Story S6 |
| **FR72** | Characters **log field notes, photos, and voice snippets** to anchors or days — private or shared to the group — stored on device first, then synced. | Story C17 |
| **FR73** | **[AMENDED v2.0]** Characters view a **post-trip recap** comparing planned vs. actual distance, moving time, and elevation by mode, combining Author narrative with Character logs into a keepsake record — **and a narrative axis: which plot points were reached, in what order, at what hour, which branches were taken, and which stations attempted.** **Prior reading (v1.0): a metrics-only comparison.** The recap is the story as it actually happened against the story as written. | Story C18; extended v2.0 |

### 8.18 Workspaces

| FR | Requirement | Origin |
|---|---|---|
| **FR74** | **[AMENDED v2.0]** Authors have a **Trip Library / portfolio workspace** — grid/list of authored trips with thumbnails, key metrics, variant count, group size, and sync badge; filter by mode/duration; search; per-card Edit / Manage Roster / Export / Clone. **Clone's contents are specified, not implied.** A clone **carries**: roster membership, group and sub-group assignments (FR136), and the whole authored trip — bbox, layer selection, anchors, roles, reveal settings, passages, days, arc. Author notes come along automatically because they are scoped to the person rather than the trip (FR135), which needs no rule. A clone **does not carry**: **profile grants or arrival-visibility permission** (FR78, FR78a, FR123), or any Character-layer state — reveals, arrivals, in-story choices, field notes, feedback, journals. **The grants exclusion is a hard clause, not a default.** Profile sharing is per-trip and revisable by design; carrying grants forward would make cloning a consent-laundering path, silently re-sharing a Character's medical conditions from last year's supported tour onto this year's unsupported one. **Each Character re-grants for each trip**, and "clone everything" is the obvious implementation and the wrong one. **The clone's scope is selectable per FR74b; this requirement describes the whole-trip scope.** | Story 37; specified v2.0 |
| **FR74b** | **[NEW v2.0]** Cloning offers a **scope**: the **whole trip**; the **roster only** (membership and group assignments, no days, passages, anchors, or content); the **authored trip only** (days, passages, anchors, roles, reveal settings, arc, and content, with an empty roster); or a **per-part selection**. The scope **names what it will and will not bring before the clone is created**. Two ordinary cases motivate this — *same people, different trip* and *same route, different people* — and under a single all-or-nothing scope an Author clones everything and then deletes half of it, walking through FR139's orphan prompts for content they never wanted. **No scope carries profile grants or arrival visibility** (FR74, FR78, FR123): every Character re-grants per trip regardless of what else came across, and **there is no scope in which consent is inherited**. **No scope carries Character-layer state** — reveals, arrivals, choices, field notes. **Author notes follow the person, not the trip** (FR135), so they are present in any scope carrying the roster and absent from one that does not, with no rule applied. **Where a scope drops people, everything assigned to them drops with them** — per-day and per-passage group assignments, shared gear assignments (FR24), and meal responsibilities (FR25) are removed rather than left dangling. **A roster-only clone has no trip content, so it runs trip initiation normally** — location prompt, bbox, and mode declaration (FR96, FR120, FR144) — since there is nothing to inherit them from. | Design cross-check CR-2 |
| **FR74a** | Authors **save a trip to local storage, reopen a previously saved trip, and see a list of local trips** (title, modes, last-edited) — the minimal single-device floor FR74 is built on. | MVP Scope §1.4.3 |
| **FR75** | Characters have a **Trip Library / travel vault** — joined trips under Active/Upcoming, Offline Ready, and Completed/Archived, with one-tap download or export and links to recaps. | Story C21 |
| **FR76** | Trip cards show **sync-status badges**: Cloud Synced, This Device, and Offline Ready. | Story S8 |

### 8.19 Any-User / Platform

| FR | Requirement | Origin |
|---|---|---|
| **FR77** | Users maintain a **profile** — nickname, email, phone, free-text home location, and travel/capability preferences that seed trip defaults and populate the Author's aggregation. | CTP FR40, S2/C6 |
| **FR78** | Profile sharing to an Author is a **per-field request/response**, defaulting to nothing shared. A Character may grant requested fields, decline specific ones, and volunteer fields the Author did not request. Sharing is always an explicit Character action, never a side effect of joining a trip. | CTP FR41, extended |
| **FR78a** | **[AMENDED v2.0]** An Author **requests the specific profile fields** they need for a trip, forming the request a Character responds to. **The request set now includes non-profile permissions of the same shape — notably arrival visibility (FR123)** — so that consent for in-field sharing uses this one surface rather than a parallel mechanism. The request is a default set the Author can adjust per trip; it never auto-grants access. | New; extended v2.0 |
| **FR79** | **[AMENDED v2.0]** Users configure **display and measurement preferences** — miles/km, °F/°C, light/dark/system, indoor/outdoor contrast, and **time and date format** — applied live across all surfaces. **Time and date formats inherit the device's own settings by default, with explicit overrides available.** *Inherit is not "pick one of the offered formats for me"* — it defers to the platform's own locale pattern, which may not be any of them, and it **resolves at render time rather than being frozen at install**. The override menu offers a 12/24-hour clock and seven date formats: `YYYY-MM-DD` (ISO 8601), `MM/DD/YYYY` (US), `DD/MM/YYYY` (UK, Europe, India, Australia, Latin America — the most widely used globally), `DD.MM.YYYY` (Germany, Central/Eastern Europe, Nordics), `YYYY/MM/DD` (East Asia), `DD Mon YYYY` (20 Aug 2026), and `Mon DD, YYYY` (Aug 20, 2026). The stored value is `inherit` or one of the seven. **The initial value of every display preference is read from the operating system** — units, date format, time format, and first day of week — rather than starting at an application default, so a fresh install on a metric machine shows kilometres without anyone visiting settings. An explicit choice overrides and syncs (FR58); `inherit` continues to resolve locally per device. **This changes only the starting value, not the storage rule.** **Display format is a render-time transform only: ISO 8601 remains the sole stored, exported, and filename form**, and a display preference never reaches a payload, an export, or a content digest. Applies to itineraries, cue sheets, scheduled events (FR28), gauge age-stamps (FR14a), and arrival timestamps (FR123). | Stories S1, C19; extended v2.0 |
| **FR80** | Users can **prune downloaded local content** to reclaim storage without affecting a current/upcoming trip. | CTP FR39 |
| **FR81** | Users have a single **reset** action reverting planning controls to defaults and clearing the generated route. **In compose mode, reset clears the generated route and weights but does not discard promoted anchors** — losing an afternoon of curation to a reset would be unrecoverable. *(One of the two precedents FR139 generalizes; the other is FR120's bbox shrink.)* | CTP FR49; qualified v2.0 |
| **FR82** | An Author may **participate as a Character** in their own trip without a second account, counted in aggregations, headcounts, and rosters. **An Author participating as a Character may opt into reveal**, experiencing their own trip's unrevealed content in the field rather than seeing it in the plan. | Story 31; extended v2.0 |
| **FR145** | **[NEW v2.0]** Every user-visible string is a **fixed template with typed slots**, resolved at render time. Slots carry values the app already holds — counts, distances, durations, day indices, names, timestamps — with plural and list forms handled by locale rules (FR83, M8's ARB framework). Where a message must state a **cause or reason**, the reason comes from a **bounded phrase table keyed by a typed enum**, never from free text at a call site; the enum aligns with M13's typed state enum where the cause is a failure. **No user-visible string is composed from content at runtime**, and no template interpolates the body of an authored role: a message about a role **names it and states its type**, and any content shown passes through `RevealResolver` **as content, not as part of a sentence**. **This is a reveal-gate requirement as much as a scope one.** ARCH P11 makes the resolver the single gate every content path crosses, and the punch-list CI gates assert that unrevealed content never appears in output bytes — but **a sentence assembled in the presentation layer is a path around that gate which byte assertions on the export path do not see.** A template with typed slots is inspectable; a composed sentence is not. Enforced by the same lint that keeps `Role.content` out of Presentation. | Design cross-check CR-4 |
| **FR83** | Users select an **application language**; UI, labels, and notifications localize live, defaulting to device locale (fallback English) and syncing when signed in. | Story S9 |
| **FR142** | **[NEW v2.0]** Plotlines is **usable as well as capable**. Four clauses, each testable, none adding a feature area. **(a) Undo and redo** — authoring actions are reversible within a session (promotion, removal, edits, arrangement, reveal changes, group assignment, day restructuring), implemented as bounded snapshots of the canonical payload, session-scoped, cleared on trip close. **Deliberately excluded:** Author-note deletion (FR135a is irreversible by design and says so at the point of deletion), anything already synced destructively, and Character-layer state. Undo covers **authored work**; **derived work is governed by `solve.stale`** (FR140) and needs no undo, because re-solving is idempotent. **(b) Reachability** — every object an Author creates is findable from a surface without reconstructing how it was made, verified against an enumeration rather than asserted. **A capability with no path back to what it made is not usable**, and a new object type ships with its path named or it does not ship. **(c) Empty states carry a next action** — a trip with no days, a day with no passages, a bbox with no promoted anchors, a roster with no Characters each state what to do, not merely that nothing is there. **(d) Accessibility** — authoring and reading surfaces target **WCAG 2.2 Level AA**, applied through platform accessibility APIs (VoiceOver/TalkBack semantics, dynamic type, reduced motion, platform contrast). **AA is the floor, not the target**: field surfaces exceed it deliberately, since FR52's oversized glove-friendly targets and FR79's outdoor contrast exist for a physical constraint WCAG has no concept of. **For MVP, conformance is a design-review checklist, not a release gate** — a formal audit is post-MVP and scheduled (FR142a). WCAG 3.0 is a Working Draft and is not the target; its Bronze level approximates 2.2 AA, so meeting AA now is the head start. **(e) Teaching is first-run and dismissible.** Where a behaviour is **not inferable from the interface**, Plotlines explains it **in place, at the moment it applies**, in a dismissible block. Several of the product's central behaviours qualify and each has to be told once: that promoting a place does not put it into a day; that reveal is a property of a role rather than a place; that a stale route is deliberate rather than broken; that compose-mode distance is an outcome rather than a failure. **Dismissal is scoped to the trip** — a tip dismissed on one trip does not reappear there and does appear on the next, since the next trip is often months later. **Every dismissed explanation remains reachable** from an inline help affordance on the surface it belongs to: teaching may be dismissed, never lost. Teaching is distinct from three things it is routinely confused with — a **live status** (part of the control, never dismissible: *"routing available in about 3 minutes"*), an **empty state** (FR142(c)), and a **failure** (M13). **A build in which explanatory copy is permanent panel furniture does not satisfy this clause**; it reads as the app lecturing an expert on every visit. *(Analogue to the confirmation-versus-undo tension: a caption that states a rule usually exists because the interface failed to demonstrate it. Teaching is the honest home for such captions — not a licence to keep them permanently.)* | Gap identified in flow review |
| **FR142a** | **[NEW v2.0]** A **formal accessibility audit against WCAG 2.2 AA is a scheduled post-MVP deliverable, gated before Plotlines expands beyond the Author desktop surface.** Rationale for the gate: every additional surface multiplies remediation cost, and the desktop authoring client is where an Author spends the most time and where nothing currently specifies keyboard navigation, screen-reader semantics, or focus management. Auditing one surface and carrying the findings forward is cheaper than auditing four. **Named as deferred with intent rather than left to be discovered late.** | FR142(d); roadmap |
| **FR143** | **[NEW v2.0, Later]** Authors maintain named **travel circles** — reusable sets of people they plan for repeatedly (a summer riding group, a Memorial Day paddling crew) — selectable at trip creation to populate a roster in one action. **A circle is a living list**: it is edited over time and **future trips pick up its current membership**. **A trip's roster is materialized from the circle at creation and is thereafter independent** — adding or removing someone from a circle never retroactively changes a trip already created, because a roster in flight carries grants, group assignments, and gear responsibilities that must not shift underneath an Author. Where a circle changes and the Author holds upcoming trips drawn from it, Plotlines **offers** to apply the change to those trips and never applies it silently. Circles carry **membership only** — not grants (FR74's clause applies identically), not trip content, and not group assignments, which are trip-scoped by definition (FR136). **Deferred: circles depend on roster (FR136), invitations, and accounts (Leg 4), none of which is MVP.** Filed alongside FR137's roster board, which is the surface where a circle would be managed and the same data. | Concept framing (recurring groups) |
| **FR138** | **[NEW v2.0]** Plotlines carries a **plain-language privacy statement, reachable from the About surface on every platform** — including the lightest ones (Web guest, and the share-token reading view, FR132). It states plainly: what is stored on the device and what reaches the server; that **reveal is a product guarantee against accidental spoiling and not a security boundary** (FR64a); what arrival sharing does and does not do, and that it defaults to nothing shared (FR123); that **an Author may keep private notes about Characters, that those notes are visible only to that Author, persist across trips, and can be deleted on request** (FR135, FR135a); and that guest sessions leave no server-side trace. **Author notes are the first data in Plotlines held *about* a person *by someone other than that person***, which is what makes this statement an obligation rather than a courtesy. Not legal boilerplate — it says what is true, briefly. | ARCH §13.4; FR135 consequence |

### 8.19a Editing & Lifecycle

*[NEW v2.0 — this entire subsection.] Almost every requirement above is written as **create-once**. Nothing said what happens when an Author cuts a six-day trip to four after day five has content, removes a mode mid-planning, or deletes an anchor carrying an arc stage. The rule below was already decided twice — for bbox shrink (FR120) and for compose-mode reset (FR81) — without being generalized.*

**The distinction everything here rests on:** **authored work** is anything the Author typed, drew, promoted, or arranged — anchors, roles, reveal settings, notes, arc stages, transition instructions, hazards. **Derived work** is anything Plotlines computed from it — routes, cue sheets, metrics, elevation profiles, distance-based day splits, candidate caches. **Orphaned authored work prompts. Invalidated derived work goes stale.**

| FR | Requirement | Origin |
|---|---|---|
| **FR139** | **[NEW v2.0]** Every object an Author creates can be **edited and removed**, not only created. Where a removal or reduction would **orphan authored work**, Plotlines states the scope and lets the Author decide; it never discards authored work silently. The prompt states **what would be affected and how much** — *"day 5 and day 6 hold 4 passages, 7 anchors, and 2 scheduled events"* — and offers **keep** (cancel), **adjust** (change the edit's extent), or **remove explicitly**. Governing cases, one rule rather than five: reducing day count prompts and offers merge-into-adjacent or removal; removing a passage prompts and **its anchors survive unattached** rather than being deleted with it; removing an anchor prompts if it holds authored content, while the day **holds its bounds** and the route goes stale (FR140); shrinking the bbox prompts (FR120, generalized here); **removing a layer does not prompt**, since promoted anchors copied at promotion and are unaffected (FR106). **The prompt is triggered by authored content, not by object type** — removing an anchor promoted but never written to applies without one, so tidying a mis-click is not friction. Days may be **inserted mid-trip**, not only appended, with subsequent days renumbering and their content moving with them. **Deliberateness is reserved for destruction**: an action removing authored work confirms; an action recomputing derived work does not (FR140). | Gap identified in flow review; generalizes FR120, FR81 |
| **FR140** | **[NEW v2.0]** An edit that invalidates derived work **marks it stale rather than recomputing it or prompting about it**, reusing `solve.stale` (ARCH D30) — no new mechanism. Applies to routes, cue sheets, planning metrics, elevation profiles, and distance-based day splits; candidate caches regenerate silently, being regenerable by design. **Staleness escalates across three levels, and the quietness of the first two is the requirement.** *(1) While planning — passive only:* a small marker on the affected object and a count in the planning dashboard beside the metrics already there. No modal, no banner, no interruption; an Author making six edits in a row sees the number climb and is stopped zero times. *(2) On export — blocking, and it opens the list:* the attempt opens a **stale list** naming each item by what it is and which day it's on, each individually resolvable, with **re-solve-all as one unconfirmed action** at the top, after which the export proceeds. *(3) On print — blocking with no override path*, since a stale GPX is corrected by the next sync but a stale printed cue sheet goes in a jersey pocket and is believed for eight hours. **Re-solve-all destroys nothing** — it recomputes derived work from inputs the Author already set — so it does not confirm; where the stale list offers *dropping* an object instead of re-solving it, that action does confirm. A stale route remains **viewable** while planning; blocking on-screen viewing would make an editing session a series of forced solves. | Gap identified in flow review; reuses ARCH D30 |
| **FR140a** | **[NEW v2.0]** The **stale list is a distinct surface, not part of the shared error surface** (M13). Stale work is **pending work, not a failure** — the Author caused it deliberately by editing, and every item has a one-action resolution. Routing it through M13's typed state enum would teach the Author that ordinary editing produces errors, which is the same defect as routing compose-mode distance deviation there (FR118). The stale list has its own presentation, its own resolve actions, and appears only on an export or print attempt. | ARCH M13 boundary |
| **FR141** | **[NEW v2.0]** Repeated objects can be **duplicated with their content and settings**, then edited — passages (mode, weights, technicality), anchors (role set, reveal policy, content, station activity), and days (type, structure, group assignments). A duplicate **does not carry provenance or identity**: it is not "from cluster X", carries no arrival or reveal state, and **position is never copied** — a duplicate at the original's coordinates is two anchors in one place, precisely the duplication the anchor model exists to prevent. The duplicate is independent immediately, with no link back to its source. For a nine-day tour with a repeating daily rhythm this is the difference between an afternoon and an evening. | Gap identified in flow review |

### 8.20 Plugins / Integrations (Leg 7 — output side)

| FR | Requirement | Origin |
|---|---|---|
| **FR84** | **[AMENDED v2.0]** Plotlines exposes a **clean two-way interface**. **The data-input half is no longer open or deferred — it is specified in FR100 and delivered in Leg 2.5**, because the layer picker and co-location analysis read it. **The output half** — exports to other platforms — retains its deliberately open contract shape in Leg 7. **Prior reading (v1.0): both halves deferred to Leg 7 with shapes left open.** | Rebrand-plan Leg 7; split v2.0 |

### 8.21 Elevation Data (Provider & Handling)

| FR | Requirement | Origin |
|---|---|---|
| **FR85** | Plotlines' elevation source is **GEDTM30** (30 m global ensemble DTM), distributed by OpenTopography, used as the **single** source with **no secondary/fallback service**. | POC; SPIKE-18 |
| **FR86** | Elevation attribution (CC BY) appears on the About surface and **embedded in exported files where the format permits**; a missing attribution is a build failure. | ARCH §11.2/§12.4; SPIKE-18 |
| **FR87** | OpenTopography's free non-academic API key is capped at **50 calls/24h**; a paid Enterprise key is required once elevation is integrated into commercial software. Plotlines' core app remaining free is what keeps Phase-1 usage within the free tier legally. | POC; SPIKE-18 |
| **FR88** | Elevation reads **never raise and never block a route solve**. `nodata` — including raw NaN, checked via `isnan` — falls back to `0.0`, as does out-of-bounds or a missing/unreadable raster. Each fallback logged **at most once per raster path**. No network fetch inside route computation. | POC; SPIKE-18 |
| **FR89** | Elevation enrichment annotates every graph node with its elevation and every edge with `elev_gain = max(0.0, elev[v] - elev[u])` — positive gain only. | POC; SPIKE-18 |
| **FR90** | The shipped default region's elevation raster is distributed as a **versioned tarball asset**, extracted by a documented one-time setup step. Windows setup extracts via `tar -C <dir>`, never PowerShell `>` redirection. | POC; SPIKE-18 |

### 8.22 Mapping & Tile Service Contract

| FR | Requirement | Origin |
|---|---|---|
| **FR92** | The client talks **only** to Plotlines' own tile service (`GET /tiles/{z}/{x}/{y}`) for basemap tiles; never a third-party tile host directly. | POC; SPIKE-14 |
| **FR93** | The tile service **validates `z/x/y` against range** before any upstream work. | POC; SPIKE-14 |
| **FR94** | Tiles are generated and cached **bbox-scoped and on demand**; the same pipeline is the origin for live map requests and offline packages. The elevation cache follows the identical pattern under a separate cache. **Both are scoped by the trip bbox (FR120).** | POC; SPIKE-14; clarified v2.0 |
| **FR95** | Basemap tiles come from the **Protomaps Basemap** (OSM-derived) under **ODbL** as a Produced Work. `© OpenStreetMap` attribution appears on the About surface and anywhere a map is exported or printed — a **separate obligation** from elevation's CC BY (FR86), under a different licence. Plotlines **mirrors** the tile source rather than hotlinking. | SPIKE-14; ARCH D23 |
---

## 9. User Stories (INVEST)

Stories are organized by epic in INVEST form. Priority tags: **[MVP]** core launch, **[P1]** fast-follow, **[Later]** deferred but designed-for. Stories new in this revision are marked **[NEW v2.0]**; stories whose meaning changed are marked **[AMENDED v2.0]**.

**Epic order note:** Epics **N** and **O** come first in v2.0 because they precede everything else in the Author's actual workflow. Epic A (routing) is what happens *after* an Author decides where they are going.

### Epic N — Author: Layers, Candidates & Curation *(new — the pipeline)*

**N0 — Declare how we're travelling** *[MVP]* **[NEW v2.0]** — *FR144*
**As an** Author, **I want to** declare the trip's travel modes when I create it **so that** the layer picker and passage creation start from how we are actually travelling rather than assuming cycling.
*AC:* A trip **declares one or more travel modes at initiation**, alongside its title, location prompt, and bounding box, and the declaration step **precedes the location prompt**; **at least one is required**. The declared set is the argument N3's layer defaults have been missing — it seeds which layers are live and which traversal modes are offered at passage creation (B1), and **the layer picker states which modes it derived its initial state from**. **Declaring is not constraining**: an Author may create a passage in an undeclared mode, and doing so **adds that mode to the trip** without warning, block, or confirmation. Modes are **editable for the life of the trip**; changing the set updates layer defaults for days the Author has not overridden and **leaves overridden days alone**. A cloned trip carries its source's modes (G2), and a roster-only clone, having nothing to inherit, runs trip initiation normally (G2b, N1). **Climbing, canyoneering, and jumaring are stations, not travel modes** (O4) and never appear in a mode list.

**N1 — Start a trip by drawing its area** *[MVP]* **[NEW v2.0]** — *FR120, FR96*
**As an** Author, **I want to** draw my trip's bounding box when I create it **so that** every piece of data the trip needs — places, clusters, maps, terrain — is scoped by one extent I set once.
*AC:* Trip creation prompts for **a single location, prefilled with the last-used value and freely editable**, whose only job is to center the map (A10); the Author then **draws the bbox** on that map. The location never becomes the bbox by inference or radius. **One extent scopes everything**: POI/layer extraction, co-location analysis (N4), tile download, elevation coverage — **there is never a second, different extent for analysis**, and that is the invariant, not immutability. The bbox is **revisable throughout authoring**: enlarging re-extracts only the added area; **shrinking prompts** with the promoted anchors that would fall outside, offering keep-bounds / adjust-bounds / remove-explicitly, and **never silently discards authored work**. Distinct from the shipped home region (A10) and from the trip's offline corridor buffer (C14); the UI never conflates them.

**N2 — Keep authoring while terrain loads** *[MVP]* **[NEW v2.0]** — *FR121, FR91*
**As an** Author who just declared a bbox, **I want to** start choosing layers and reviewing places immediately while elevation loads in the background **so that** I am not staring at a spinner for several minutes before I can do anything.
*AC:* Layer extraction and POI indexing complete first and unlock layer selection (N3), candidate display (N3), co-location analysis (N4), and promotion (O1); elevation enrichment runs in the background; routing and elevation-dependent metrics are visibly disabled with a stated reason and an honest progress estimate until it completes; no control silently fails on click; the app is never globally blocked. **Plugin layer loading follows the same non-blocking rule and is tracked per layer, not as one flag**: a slow or remote plugin dataset (N5) shows as *loading* in the picker while built-in layers are already usable, **one plugin layer failing to load never blocks the others or the workspace**, and a failure states which layer and why. *(Requires per-capability readiness — with per-layer state inside the layers capability — in the sidecar `/health` contract; ARCH §8.3 change, see M12a.)*

**N3 — Choose what the map shows me** *[MVP]* **[NEW v2.0]** — *FR97, FR98, FR99*
**As an** Author, **I want to** select which data layers are live and see their features on my planning map, ranked by how notable they are **so that** I can read the land and find what is worth reaching.
*AC:* Layer catalog spans the OSM sightseeing/amenity/natural/historic/leisure/man-made taxonomy plus plugin datasets (N5); selection is per trip and overridable per day; **defaults vary by travel mode and day type** — a sauna excluded from a riding day's sight layer, included on a rest day's amenity layer — and those defaults are config, not code; every candidate carries a salience score, with `historic=*` sub-weighted by value rather than flat, and known over-triggering tags (`natural=tree`, `leisure=park`, `tourism=attraction`, `man_made=silo`/`water_tower`/`tower`) qualified before display; salience is visible on the map; an Author can promote any candidate directly and complete a whole trip without ever running N4.

**N4 — Find the good spots** *[P1]* **[NEW v2.0]** — *FR102, FR103, FR104, FR105, FR105a*
**As an** Author, **I want** Plotlines to find clusters of interesting or useful things inside my trip area **so that** I discover the castle beside the waterfall, and the toilet-plus-water-plus-shelter stop, without hunting for them myself.
*AC:* Runs as a **named Author action** over the trip bbox, not ambiently on viewport change; analyses co-location across all live heterogeneous layers; returns two readable proposal kinds — **narrative clusters** (high-salience features together → suggested plot point) and **provision clusters** (utility features together → suggested rest stop); each proposal carries its contributing features and their salience so the Author judges rather than trusts; **cluster composition suggests the role set by affinity union** (FR105), so a plugin layer's types participate on the day they load; proposals are ranked by combined salience and tightness, capped at a reviewable count, filterable by role, layer, or proximity to an existing route; proposals are **never** automatically added to the trip; rejected proposals are remembered for the trip and not re-proposed.
*(N4 specifies the analysis and its outputs. The surface an Author reviews them on is **N4a**, which is the buildable half.)*

**N4a — Review and act on proposals** *[P1]* **[NEW v2.0]** — *FR102–FR105a, FR110*
**As an** Author looking at a list of suggestions, **I want** each one to show me what it is and let me act on it in one place **so that** reviewing forty proposals is a few minutes' work rather than an afternoon.
*AC:* **A proposal is a reviewable object, not a map pin.** Each renders as a card carrying: a generated name from its highest-salience member; its **contributing features listed individually with type, name where present, and salience**; the suggested **role set with the affinity that produced it**; the cluster's extent and tightness; and its distance from the current route where one exists. **The list is the primary surface, the map is synchronized to it** — selecting a card highlights its extent on the map, and selecting a cluster on the map selects its card. **Three actions on every card, each one gesture:** *Promote* (opens O1 with role set and content pre-filled), *Reject* (removed, remembered for the trip per N4, undoable within the session), *Defer* (stays in the list, sorts below). **Bulk reject by filter** — by layer, by role, or below a salience threshold — so an Author dismisses forty street-tree proposals in one action rather than forty. **Ordering and paging are explicit**: default sort is combined salience × tightness, resortable by distance-from-route or by layer, and the cap (FR105a) is stated with a count of what lies beyond it rather than silently truncating. **Running the analysis again preserves prior rejections** and marks which proposals are new since the last run. **Empty and dense states are specified, not incidental**: no clusters found says so and suggests widening layers or the bbox; a bbox yielding more than the cap says how many and offers a filter.
**The workspace carries three views over the same bbox: candidates, proposals, and anchors.** The anchors view lists what has been promoted, **filterable by attachment** — attached to a passage, or unattached. **Unattached anchors are ordinary working state, not a problem queue**: they are not badged, not counted as errors, and never block an export or a solve (Q2). An Author parking places for a day they haven't built yet is working normally. Re-attaching is available from this view and from the passage.
*(Design note: PRD §5.4a carries a worked walkthrough against a named region. Candidate and proposal rendering at bbox scale is an open architectural question — ARCH Q15 — and the display strategy it settles governs this story's map half.)*

**N5 — Bring in a specialist dataset** *[P1]* **[NEW v2.0]** — *FR100, FR101*
**As an** Author planning a themed tour, **I want to** add a community dataset — Revolutionary War battle sites, manor houses, historical markers — as a layer **so that** my trip is built on the data that actually fits its subject.
*AC:* A plugin dataset supplies point **and area** geometry, a type taxonomy that participates in salience sub-weighting (N3), clusterable attributes, and per-layer licence/attribution metadata; the layer appears in the catalog alongside OSM layers and feeds co-location analysis identically; **attribution propagates to the About surface, to exports where the format permits, and to printed itineraries and cue sheets**; a layer whose licence terms are absent or unsatisfiable does not load; a missing attribution is a build failure.

**N6 — Know when a place is only sometimes there** *[P1]* **[NEW v2.0]** — *FR129*
**As an** Author, **I want to** see opening hours, seasonality, and conditional access on a candidate **so that** I don't build a day around a castle that closes on Mondays or a supermarket that shuts at six.
*AC:* Temporal availability shown at promotion where the source provides it; carried onto the anchor; surfaced in the Character's itinerary; feeds C12's scheduled-event conflict detection; absence of hours data is stated plainly rather than implied as always-open.

### Epic O — Author: Anchors, Roles & Reveal *(new — the object model)*

**O1 — Promote a place into my trip** *[MVP]* **[NEW v2.0]** — *FR106, FR110*
**As an** Author, **I want to** turn a candidate, a cluster proposal, or a spot I picked myself into part of my trip, and say what it is **so that** the map's thousands of features become the handful this journey is about.
*AC:* Promotion available from a candidate, a cluster proposal, or a hand-placed location; one anchor per place; the Author assigns a **role set** — one or more of **narrative** (plot point), **provision**, **station** — in the same interaction, with suggested roles pre-filled from cluster composition and always editable; **a national monument is one anchor with narrative + provision roles, one arrival, no duplicate pin**; per-role reveal policy and content set here or later; rejected proposals remembered for the trip.

**O2 — Give a role its own place on the ground** *[MVP]* **[NEW v2.0]** — *FR107*
**As an** Author, **I want** a role to sit at an offset from its anchor **so that** the overlook 400 m up the spur triggers at the overlook, not in the parking lot.
*AC:* Each role optionally carries its own geometry offset from the anchor; trigger distances and narration fire from the role's geometry, not the anchor's; offsets appear on the map and export as distinct features; an anchor with no offsets behaves exactly as a single point.

**O3 — Author an area, not just a pin** *[MVP]* **[NEW v2.0]** — *FR108, FR126*
**As an** Author, **I want to** make a historic district, an arboretum, or a main-street block an anchor **so that** "spend the afternoon here" is something I can actually express.
*AC:* Polygon geometry is first-class for anchors and roles — drawn by the Author or adopted from a source feature's own area geometry; an area can serve as a cluster boundary instead of a point-plus-radius; **entry into the polygon is a trigger event** for narration, reveal, and notification, debounced so a boundary-hugging route does not re-fire; areas render on map, timeline, cue sheet, and GeoJSON export as polygons; rest days can be composed primarily of area anchors.

**O4 — Author a place where we stop and do something** *[P1]* **[NEW v2.0]** — *FR109, FR16b, FR24*
**As an** Author, **I want to** mark a crag, hot spring, sauna, summit scramble, or canyon descent as an activity with duration **so that** the day's timing, gear, and story account for the three hours we spend there.
*AC:* Station role carries activity type, expected duration, gear requirements, and an Author-declared difficulty; **duration feeds moving-vs-elapsed time, ETAs, and scheduled-event conflict detection** (D1, C12) rather than annotating a pin; gear requirements feed the mode/activity gear checklist (C8); climbing, canyoneering, and jumaring are authored as stations reached by a traversal mode, never as travel modes themselves; adding a new activity type is a config entry, not code.

**O5 — Decide what is known and what is discovered** *[MVP]* **[NEW v2.0]** — *FR114, FR115, FR116*
**As an** Author, **I want to** set, per role, whether Characters see it in advance or discover it on arrival **so that** they never worry about water and never have a waterfall spoiled.
*AC:* Each role is *always visible* or *revealed on arrival*; **provision roles default to always-visible**; narrative and station roles default to the Author's choice; **hazards and technical cruxes are always visible and cannot be set otherwise by any Author, on any trip, under any role** — enforced in the model, not by authoring discipline; reveal policy is inherited by web and print, so **a printed cue sheet shows every provision, every hazard, and the arc's shape but not unrevealed plot-point content**; the Author can preview the trip as a Character would see it before departure.

**O6 — Mark the shape of the day** *[MVP]* **[AMENDED v2.0]** — *FR38*
**As an** Author, **I want to** tag both places **and stretches of route** with arc stages **so that** the day reads as a story, including the long grind that *is* the rising action.
*AC:* Arc roles (exposition, rising action, crux, climax, resolution) attach to **anchors and passages both**; distinguished on map and timeline; participate in day composition (C3) and itinerary rendering (F2); a day can be closed at a resolution-stage anchor rather than only at a distance threshold. *(v1.0: arc was a [P1] tag on points only — the story could only happen at places, never on the road between them.)*

**O7 — Name the country the story happens in** *[P1]* **[NEW v2.0]** — *FR111, FR112*
**As an** Author, **I want** Plotlines to tell me when my route runs through a named place — the Virginia Creeper Trail, Pisgah National Forest, an old rail line — **so that** I can say so in the story without researching it.
*AC:* Sets detected from route relations, `network=*` cycling/walking networks, `leisure=nature_reserve`, `boundary=*`, `mountain_pass=yes`, and `disused:railway=*` provenance; presented to the Author to accept, rename, annotate, or dismiss; accepted Sets appear in itineraries, cue sheets, and node cards as narrative context; detection is suggestion only and never writes content without the Author accepting it.

**O8 — Turn a Character's find into part of the plotline** *[P1]* **[NEW v2.0]** — *FR56b*
**As an** Author reviewing a finished trip, **I want to** promote a Character's field note into a permanent anchor **so that** what the group discovered on the ground becomes part of the story next time.
*AC:* Any field note (I9a) can be promoted to an anchor with a role set, reveal policy, and authored content; promotion stops the note re-surfacing as advisory intel; provenance of the original poster is retained; declining to promote dismisses the note for the group per FR56a.

### Epic A — Author: Theme-Driven Routing

**A0 — Choose how I plan this day** *[MVP]* **[NEW v2.0]** — *FR117, FR119*
**As an** Author, **I want to** plan a day either by setting a distance and character and seeing what I find, or by picking my places and seeing how long that makes the day **so that** the tool matches how I am actually thinking about this particular day.
*AC:* Per-day choice of **explore** (distance/shape/weights/bands in, route out) or **compose** (promoted anchors in, route out); **switching in both directions loses no work** — explore's route can have its places promoted and become a spine; compose's spine can be loosened back to explore; the current mode is always visible, and the distance control's meaning changes visibly with it (constraint in explore, reported outcome in compose).

**A0a — See what my chosen places make** *[MVP]* **[NEW v2.0]** — *FR118*
**As an** Author in compose mode, **I want** the day's realized distance reported against my intent as an editing decision **so that** I choose what to change rather than being told the solver failed.
*AC:* Realized distance, elevation, and time reported with deviation from any stated band — *"these seven plot points make a 94-mile day; your band was 55–70"*; presented as an editing prompt, **not an error, not a conflict dialog, not a relaxation offer**; affordances are drop an anchor, move one to another day, split the day, widen the band, or accept; weights in compose mode flavour the connecting passages rather than defining a search space.

**A1 — Weight a route by climbing** *[MVP]* — *FR2*
**As an** Author, **I want to** set a climbing weight ("peaks") on a 0.0–5.0 decimal scale **so that** I control how much elevation the day seeks or avoids.
*AC:* 0.0–5.0 with decimal precision; "peaks" terminology in UI; engine biases toward/away from gain relative to the setting while honoring origin/destination; total gain moves monotonically as the weight rises across regenerations.

**A2 — Weight a route by traffic tolerance** *[MVP]* — *FR3*
**As an** Author, **I want to** set a traffic-tolerance weight ("cars") 0.0–5.0 **so that** I trade quiet roads against direct urban egress.
*AC:* 0.0–5.0 decimal; "cars" terminology; engine factors road-class/vehicle-density thresholds by the setting; at low tolerance the route measurably favors lower road classes where an alternative exists. **Rural/low-signal roads are the model's zero-stress baseline** — a road with no contrary signal (`maxspeed`/`lanes` indicating real capacity) is not floored by its highway-class tag alone (ARCH §16 D33; SPIKE-03).

**A3 — Weight a route by surface distribution** *[MVP]* — *FR4*
**As an** Author, **I want to** independently weight paved, gravel, and singletrack from avoid to seek **so that** the route matches the group's equipment and desired character.
*AC:* Each surface class carries its own 0.0 (avoid) – 2.5 (indifferent) – 5.0 (seek) weight, set independently rather than only relative to the others; the engine can be pointed at *seeking* gravel or singletrack; the route's surface breakdown is reported and shifts with the weights.

**A4 — Route past good places without reviewing anything** *[MVP]* **[AMENDED v2.0]** — *FR5, FR8, FR98*
**As an** Author **in explore mode**, **I want to** set how much the route should seek out good places, alongside a target mileage range, **so that** I get a forty-mile loop past interesting things on a day when I don't want to curate anything.
*AC:* A single **interest weight** (0.0–5.0) biasing toward **high-salience candidates** (N3) within the live layer set; **no POI type control on the weight** — layer selection already says what matters, and having both was two surfaces for one intent with no rule to resolve a conflict; daily mileage min/max; the engine favours higher-salience places within the distance envelope rather than maximizing a count. **Explore mode only** — in compose the promoted anchors are the spine and the weight is inactive. *(v1.0: a POI-**density** weight with its own type parameter — density biased toward quantity, and quantity means boundary stones and street trees.)*

**A5 — Compromise across competing weights** *[MVP]* — *FR6*
**As an** Author, **I want to** set a min and max on each weighted attribute **so that** the engine finds good compromises when preferences pull against each other.
*AC:* Each weighted attribute accepts a min/max band on its **realized** value — climbing, traffic exposure, surface mix, **realized salience** (A4's interest weight), distance; engine returns a route within all bands where one exists; where none exists, A6 governs. Band controls open on the range the region can actually deliver — derived by **probing the attainable envelope**, not fixed constants (SPIKE-03: fixed defaults feasible 22.2% of the time; envelope-derived, 100%). Band precision floored in absolute units.

**A6 — Understand why constraints conflict** *[MVP]* — *FR9*
**As an** Author, **I want** the planner to name conflicting constraints and offer relaxations with trade-offs **so that** I loosen the right one instead of hitting a dead end.
*AC:* On infeasibility the system names the specific conflicting constraints; offers nearest relaxations each stating its trade-off, applyable in one action; manual adjustment always available; never a raw error, never a silent drop. **Diagnosis is asynchronous:** the best-effort route and its band violations return with the initial solve; the named conflict and verified relaxations follow separately (SPIKE-02: 27–218 ms to solve vs 1.3–15.0 s to diagnose). **Compose-mode distance deviation is not a conflict and does not use this path** — see A0a.

**A7 — Choose route shape** *[MVP]* — *FR7*
**As an** Author, **I want to** pick loop, out-and-back, or point-to-point independently of weights **so that** geometry matches the day's logistics.
*AC:* Three shapes per passage; independent of weight profile; loop default; point-to-point requires a destination, loop/out-and-back require only a start.

**A8 — Target a distance** *[MVP]* **[AMENDED v2.0]** — *FR8*
**As an** Author **in explore mode**, **I want to** set a target distance for loop and out-and-back passages **so that** the day lands near the mileage I intend.
*AC:* Target-distance control for loop/out-and-back only; **banded by default in explore mode** (SPIKE-03 measured up to +14.8% unannounced drift when unbanded); the Author can widen the band, but distance is never dropped from the explore search's constraint set. **In compose mode distance is a reported outcome (A0a), not a constraint.** Point-to-point has no target-distance input.

**A9 — Route a loop through one or two designated anchors** *[MVP]* — *FR8a*
**As an** Author, **I want to** require a loop to pass through a chosen anchor while still returning to start **so that** the ride reaches a place that anchors the day without giving up the loop shape.
*AC:* One or two via-anchors on a loop; the route passes through each and returns to start; weights and target distance still honored around them; a genuine loop rather than an out-and-back, with any road ridden twice reported; if a via-anchor makes the loop infeasible within the distance envelope, A6 governs and names the via-anchor — not the terrain — as the binding constraint.
*SPIKE-01: promoted P1→MVP. Via-anchor, start, destination, loop and out-and-back are one solver call with a different anchor list, and a 1-via loop is ~6× **faster** than an unconstrained one.*

**A9a — Route a loop through three or more designated anchors** *[P1]* **[AMENDED v2.0]** — *FR8a*
**As an** Author, **I want to** require a loop to pass through three or more chosen anchors **so that** a day can be anchored to a whole sequence of places.
*AC:* Three or more via-anchors; the route passes through each and returns to start; **in explore mode target distance becomes advisory** and the deviation is surfaced with A6's relaxation path; **in compose mode this is the expected behaviour, not a degradation** — the places determine the length and A0a governs the presentation.
*SPIKE-01 measured distance error rising from under ±14% to +30.7% (Boulder) and +81.9% (Viroqua) at three via-anchors. Every via was hit and every loop closed. v1.0 called this a UI-and-expectations defect; v2.0 states it as the product position for compose mode.*

**A10 — Open to a map, and center it when I start a trip** *[MVP]* **[AMENDED v2.0]** — *FR96*
**As an** Author, **I want** the app to open on a map immediately and to ask me where I'm going only when I start a trip **so that** nothing is downloaded or decided before I've done anything.
*AC:* **First start opens on the shipped home region** — Buncombe County, NC, a rectangular bbox — with **no prompt, no override, and no download of any kind**. It is a shipped asset, a constant rather than a default. **Trip creation prompts for a single location** by city + state, zip code, or country + city, **prefilled with the last-used value and freely editable**; entering it **centers the map only**, and the Author draws the bbox from there (N1). The location never becomes an extent by inference, radius, or accepted default. **Two authoring extents exist** — the shipped home region and the trip bbox — plus the offline corridor buffer (C14), which is Character-side and never appears in this flow. *(v1.0 prompted on first run and eagerly downloaded a 100 km radius for a region no trip had justified.)*

**A11 — Get a route I can actually ride** *[MVP]* **[NEW v2.0]** — *FR128*
**As an** Author, **I want** generated routes to be legal and physically passable in their mode **so that** I am not publishing a day that runs down a prohibited path or through an uncrossable ford.
*AC:* Access tags honored as hard constraints (`bicycle=no`, `use_sidepath`, `destination`, `foot=no`, `canoe=no`/`private`/`permit`); `bicycle=dismount` sections surfaced explicitly rather than silently routed through; barriers accounted for with their own access values (`cycle_barrier`, `bollard`, `gate`); fords (`ford=yes`/`stepping_stones`) and hard waterway obstacles (`weir`, `lock_gate`, `waterfall`, `hazard`) treated as constraints; contraflow permission (`oneway:bicycle=no`) respected; climbing access closures (`climbing:access=*`) respected where a station is authored; where a constraint forces a materially worse route, it is named per A6. *(v1.0 specified no passability guarantee anywhere.)*
### Epic B — Author: Multimodal Composition

**B1 — Create multimodal passages** *[MVP]* **[AMENDED v2.0]** — *FR10, FR130*
**As an** Author, **I want to** create a passage with a start, end, and traversal mode **so that** each leg reflects its real activity.
*AC:* Start/end placement; mode selectable from the traversal list — cycling, hiking, paddling, cross-country skiing, packrafting, riverboarding, mountain biking, **and driving** — with cycling, hiking, and paddling as first-class at MVP and the rest absorbed by `WeightProfile` config; **activities performed at a place rather than between two (climbing, canyoneering, jumaring) are authored as stations (O4), not as modes**; passage saved with endpoints and mode.

**B2 — Order and sequence passages in a day** *[MVP]* — *FR11*
**As an** Author, **I want to** assign and reorder passages within a day **so that** a single day flows through multiple modes in a logical order.
*AC:* One or more passages assignable to a day; reorderable to set transition sequence; warning when adjacent endpoints fall more than the set threshold (e.g. 500 m) apart.

**B3 — Define transition points** *[MVP]* — *FR12*
**As an** Author, **I want to** define transition nodes between modes **so that** Characters know where to switch activities, stash gear, or put in / take out.
*AC:* Transition node placeable between two passages; carries Author instructions; appears on Character timeline at the mode change.

> **B4 and B5 were removed after SPIKE-04 (2026-08-14).** Both depended on knowing the difficulty class of the water a route would cross, and no usable source publishes it. Story numbers retired, not reused. The surviving buildable half is **B8**.

**B6 — Define portages and water-trail connections** *[P1]* — *FR15*
**As an** Author, **I want to** draw portages with exit bank and trail characteristics **so that** Characters can execute water-to-land transitions safely.
*AC:* Portage line **drawn by the Author** with exit bank (river left/right); distance, surface, and elevation change computed separately from water distance; mandatory portages flag a prominent warning; auto-included in cue sheets/itineraries; entry/exit points can be rest/way/regroup anchors. Mapped hazards may prompt the Author to draw one — **but the app never claims a portage route it does not have** (SPIKE-04 §6).

**B7 — Model mode/terrain travel speeds** *[P1]* — *FR16, FR16a, FR16b, FR31*
**As an** Author, **I want to** configure travel speeds by mode and terrain **so that** metrics show realistic moving time and ETAs.
*AC:* Base speeds adjustable per mode and terrain; choose system default, custom Author pace (including one derived from an uploaded activity file), or aggregated participant pace; **station durations (O4) included in elapsed time**; dashboard updates moving time, elapsed time, and ETA. *(SPIKE-05: hiking's system default needs no personal data; cycling's is 31.4% wrong without it, 7.5% with it.)*

**B8 — Set a gauge band and see the river's level against it** *[Leg 3]* — *FR14, FR14a*
**As an** Author on a paddling passage, **I want to** set a minimum and maximum flow or stage and see the current reading against it **so that** I know whether the trip is runnable — and Characters know on the morning of the trip.
*AC:* Author sets a min/max band per paddling passage, choosing cubic feet per second **or** gauge height; terrain technicality/exposure settable on technical land passages as an Author-declared level; the passage shows the governing gauge's latest reading, **age-stamped**, warning when outside the band; a passage with no gauge says so plainly. **The band is advisory: it warns, it never excludes or reroutes.** Author and Character see the same reading and warning.

**B9 — Use published difficulty grading where it exists** *[P1]* **[NEW v2.0]** — *FR14b*
**As an** Author, **I want** Plotlines to read published trail difficulty where the data has it **so that** I am not hand-declaring what OSM already knows.
*AC:* `sac_scale` and `trail_visibility` read for hiking, `mtb:scale`/`:uphill`/`:imba` for mountain biking, `piste:difficulty` for nordic; coverage measured per region before shipping, since **SPIKE-04's whitewater finding tested `whitewater:section_grade` specifically and does not generalize to these schemas**; Author declaration (B8) remains the fallback where coverage is absent or thin; source and coverage stated honestly rather than presenting sparse data as complete.

### Epic C — Author: Multi-Day Logistics

**C1 — Define adventure duration** *[MVP]* — *FR17*
*AC:* Start/end date or day count; single-day, multi-day, and multi-week all supported.

**C2 — Set start, end, and rest days** *[MVP]* **[AMENDED v2.0]** — *FR18*
**As an** Author, **I want to** mark Start, End, and Rest/Zero days **so that** I can pace the trip around lodging and amenities.
*AC:* Any day markable Start/End/Rest; rest days hold location without an active route and can carry anchors, itinerary detail, and scheduled events; **a rest day can be composed primarily of area anchors (O3)** — a main street, a historic district, a spa quarter — which is the case a point-only model could not express.

**C3 — Set daily distance boundaries by mode** *[MVP]* **[AMENDED v2.0]** — *FR19*
**As an** Author, **I want** per-mode min/max distance per day **so that** daily effort stays within the group's limits.
*AC:* Per-mode min/max per day; indicator when a passage breaches a threshold; reflected in the dashboard; **the day-splitting surface presents the arc shape alongside the metric**, so a day can be closed at a resolution-stage anchor (O6) rather than only at a distance number.

**C4 — Offer alternate routes per day** *[MVP]* **[AMENDED v2.0]** — *FR20*
**As an** Author, **I want to** attach alternates that adjust effort **and alternates that are genuine story choices** **so that** Characters can match the day to their condition *or* choose between two different experiences.
*AC:* **Accommodation alternates** tagged Bypass/Easiest or Extension/Challenge; **branch alternates** carrying different content on each path (the long way past the abandoned mine vs. the direct way home), each with its own anchors, narration, and reveal policy; both kinds available across any mode and visible to Characters on map and cue sheet; the authoring UI distinguishes the two intents so an Author has the vocabulary for a narrative choice. *(v1.0 offered a fitness ladder only.)*

**C5 — Place waypoints, regroup points, rest stops** *[MVP]* — *FR21*
*AC:* Anchors placeable on a passage; a waypoint can be flagged a regroup point; rest stops carry amenity tags (water, toilets, food, shelter); N4's provision-cluster proposals feed this directly.

**C6 — Set group size** *[P1]* — *FR22*
*AC:* One tier (solo / small / party / large / event); saved to trip metadata; downstream logistics reflect it.

**C7 — Place lodging and campgrounds** *[P1]* — *FR23*
*AC:* Filter by type (campsite, hotel, hut, hostel); overlays update with filters; placed lodging attaches to the day.

**C8 — Build gear checklists** *[P1]* **[AMENDED v2.0]** — *FR24*
*AC:* Mandatory and recommended gear attachable per mode **and per station activity (O4)**; items designatable Shared Group Gear and assignable to Characters; Characters see a consolidated personal+assigned list and check items off.

**C9 — Mark water, resupply, and meals** *[P1]* — *FR25*
*AC:* Water points tagged potable or filter-required; resupply points with hours and notes; meal responsibilities assignable; itineraries show water-carry distance between sources; these are provision-role anchors and are **always visible** per O5.

**C10 — Track permits, access, and passes** *[P1]* — *FR26*
*AC:* Permit status tags; confirmation numbers, documents, or links attachable; Characters get a pre-trip permit/pass checklist.

**C11 — Warn of hazards and cruxes** *[MVP]* **[AMENDED v2.0]** — *FR27, FR115*
*AC:* Hazard/crux marker attachable to any route, transit leg, or anchor; severity levels with safety notes and gear callouts; highlighted on map, elevation, itineraries, cue sheets; high-severity triggers a distinct Character alert on sync; **never subject to reveal policy — a hazard cannot be hidden by any Author under any setting**, enforced in the model.

**C12 — Embed scheduled events** *[P1]* — *FR28*
*AC:* Scheduled-event node with date/time window and location; timeline flags a conflict when planned pace would miss the window, **accounting for station durations (O4) and anchor opening hours (N6)**; events populate itineraries, cue sheets, and the mobile timeline.

**C13 — Build transit and access legs** *[P1]* **[AMENDED v2.0]** — *FR29*
**As an** Author, **I want** driving legs to the trailhead **routed like any other route**, and train/shuttle/flight legs recorded as notes, **so that** the harrowing last mile to the put-in is something Characters can actually follow.
*AC:* **Driving legs are generated by the routing engine in driving mode**, producing a real route with distance, time, and a cue sheet, exportable like any other; **train, shuttle, and flight legs are authored notes** carrying identifiers, carrier, scheduled times, and links; both attach to trip start/end or a day and render in itineraries; neither is a live-status or booking integration. *(v1.0 flattened all four into authored notes and left driving out of the mode list.)*

**C13a — Know if the last mile needs the good truck** *[P1]* **[NEW v2.0]** — *FR29a*
**As an** Author routing a group to a trailhead or put-in, **I want to** declare what the vehicles can handle and be told where the road exceeds it **so that** nobody discovers a 4WD-only forest road in a loaded sedan at dusk.
*AC:* Author declares expected vehicle capability per driving leg (2WD / AWD / high-clearance / 4WD); Plotlines reads `surface=*`, `smoothness=*`, `tracktype=*`, `4wd_only=*`, `highway=track`, and `motor_vehicle=*` and **flags the sections that exceed the declared capability**, in the leg summary and on the cue sheet, with the specific signal that triggered the flag. **Advisory only — it warns, it never excludes or reroutes**, on the same footing as B8's gauge band: tag coverage is uneven, and whether a given vehicle makes a given road is the Author's call. **Coverage is stated plainly** — an unflagged leg means *no contrary signal found*, not *confirmed passable* — per the honesty clause in F1.

**C14 — Set the offline buffer distance** *[P1]* — *FR35*
*AC:* Buffer distance enterable/selectable (mi/km from the finished route); saved as a download parameter for the package; **distinct from the trip's authoring bbox (N1) and the home region (A10)**.

**C15 — Scope a weight profile to a day or passage** *[P1]* — *FR36*
*AC:* Tour-level default; override at day or partial-passage scope; override applies only in scope; re-scoring touches only the affected scope.

### Epic D — Author: Metrics, Weather, Roster & Group Insight

**D1 — Watch planning metrics live** *[MVP]* — *FR31*
*AC:* Persistent panel with active-passage, day-total, and trip-total distance and elevation by mode; with FR16, moving time / elapsed time (including station durations) / ETA; updates on every add/edit/reorder.

**D2 — Compare elevation profiles across options** *[P1]* — *FR32*
*AC:* Primary and all alternates render together, colour-distinguished; hover/scrub highlights the corresponding map point across all shown options.

**D3 — Read historical weather** *[P1]* — *FR33*
*AC:* 5-year box-and-whisker temperature with all-time high/low as bounds; expandable to a 10-year distribution ±3 days with precipitation volume and type; clearly labeled historical, never conflated with forecast.

**D4 — Review aggregated group preferences** *[P1]* — *FR34*
*AC:* Aggregates climbing/traffic/surface/distance/speed/river-class with Min/Max/Avg/Mode; histogram for groups over ten; only whole-trip-mode preferences shown.

**D4a — Request the profile fields I need** *[P1]* **[AMENDED v2.0]** — *FR78a, FR123*
**As an** Author, **I want to** request the specific fields and permissions a trip needs from each Character **so that** I get what matters for this trip without demanding everything.
*AC:* Author selects fields to request per trip from an adjustable default set; **the request set includes arrival visibility (P3) alongside profile fields**, so in-field sharing consent uses this one surface rather than a parallel mechanism; requesting never auto-grants; the Author sees per Character which fields were granted, declined, and volunteered unprompted, so nothing shared for safety is buried.

**D5 — See everything I know about one person** *[P1]* **[NEW v2.0]** — *FR134*
**As an** Author, **I want** one view per Character holding everything they've shared and everything I've noted **so that** I plan around the person rather than around a row in an aggregate.
*AC:* Reachable from the roster and from Manage Roster (G2); consolidates granted profile fields, volunteered fields, preference and capability values, attendance days, assigned gear and meals, group assignment (D7), and notes with their dates (D6); **an ungranted field reads as *not shared*, never as empty** — "no allergies listed" and "didn't tell me about allergies" are different facts and must not render alike; **volunteered fields are surfaced prominently** rather than beside requested ones, since a Character who volunteers a medical condition is doing something deliberate (K2); works for a Character who has granted nothing, showing the request state instead; carries the delete action (D6a).

**D6 — Keep notes on a Character, across trips** *[P1]* **[NEW v2.0]** — *FR135*
**As an** Author, **I want** private notes about each person that follow them from trip to trip **so that** what I learned about how this group works — who to pair, who to seat together, who runs out of snacks — is there next year when I need it.
*AC:* Free text per Character, **scoped to Author + Character and persisting across trips**; **visible only to the authoring Author**; each note shows a **last-updated date, small and unobtrusive beside the field**, so an Author can see that a claim about someone's climbing is three years old; **never rendered on any Character-facing surface** — itineraries, cue sheets, print, exports, offline package, group relay, shared links; **excluded from the trip archive (L3) by default**, with inclusion requiring separate explicit confirmation naming what it would expose; an Author participating as a Character (G1) may hold notes on themselves; **the UI does not prompt for or template sensitive categories** — it is a blank notebook, and structured fields remain the right home for anything a Character volunteered through K2.

**D6a — Delete what I hold about someone** *[P1]* **[NEW v2.0]** — *FR135a*
**As an** Author, **I want to** delete a note, all my notes on a Character, or everything I hold about them **so that** I can honour a request to be forgotten, or clear out knowledge that has gone stale or wrong.
*AC:* Three scopes — one note, all notes for a Character, all records for a Character (notes across every trip plus any locally cached copy of their shared profile data); **immediate, complete, irreversible** — data removed, not flagged hidden; **the confirmation states what will be removed and across how many trips**, since years of notes are unrecoverable and scope should be visible before confirming; **deletion never removes the Character from a roster or changes trip content**, and the two actions are independent in both directions; available whether or not that Character is still on a trip; **deletion propagates to synced devices**, and a device offline at deletion completes it on reconnect (K3).

**D7 — Put people in groups** *[P1]* **[NEW v2.0]** — *FR136*
**As an** Author, **I want to** assign Characters to groups and sub-groups for a day or a passage **so that** the fast climbers, the spider-clearers, and the snack-carriers end up where they should be.
*AC:* Group and optional sub-group per Character, stored on the **trip roster entry, not the account profile** — a person is in different groups on different trips, and a profile field would follow them onto the next one; **trip-level default with per-day and per-passage override**, because groups reform across a day; **Characters see their own group and its membership** for a given day or passage; groups addressable wherever individuals already are — gear (C8), meals (C9), regroup points (C5), individual itineraries (F2); assignable from the roster as a simple control at MVP/P1, independent of the board (D8); **no cohesion score, ability index, compatibility rating, or any other quantification of people.**

**D8 — Manage the roster on a board** *[Later]* **[NEW v2.0]** — *FR137*
**As an** Author, **I want** the whole roster as cards in one view, arranged by hand across the day **so that** grouping is something I do by looking at the whole trip at once.
*AC:* All Characters as cards in one view; each card shows what's needed while arranging — capability, preferences, a note excerpt with its date, current assignment; **direct manipulation into groups and sub-groups**, scoped per day or per passage with the day's arc visible so the Author sees when a grouping applies; changes write to the same D7 data with **no separate model**; opening a card reaches the full detail view (D5). **This is roster management in a richer surface, not a new feature area** — it blocks nothing before it and can be built whenever the interface budget allows.

### Epic E — Author: Curation & Narrative *(the thesis)*

**E1 — Attach notes and media to a role** *[MVP]* **[AMENDED v2.0]** — *FR37*
**As an** Author, **I want to** attach rich notes and media to a role — not just to a place — **so that** the same monument can hold always-visible restroom detail and a revealed-on-arrival story.
*AC:* Rich text + media attachable per **role**, passage, or day; saved per role; visible to Characters per that role's reveal policy (O5); can weave shared Character details into narrative (e.g. *"Bob arrives by train Tuesday morning, shoulders his pack, and walks 3 km to the trailhead to meet the group"*). *(v1.0 attached content to an undifferentiated node, which made per-role reveal impossible.)*

**E2 — Mark the narrative arc** — *see **O6***, moved to Epic O in v2.0 because arc is structure rather than curation.

**E3 — Build a trip whose places are the spine** *[MVP]* **[AMENDED v2.0]** — *FR39, FR117*
**As an** Author, **I want to** organize a route around a curated set of places **so that** the points of interest *are* the journey.
*AC:* **This is compose mode (A0), not a variant feature** — promoted anchors are the spine, the engine reaches them, and A0a governs the distance conversation; the trip presents the places as its organizing structure in itinerary, cue sheet, and recap. *(v1.0 had this as one P1 sentence with no supporting machinery; it is now a primary path with the whole of Epics N and O beneath it.)*

**E4 — Add audio narration** *[P1]* — *FR40, FR41*
*AC:* Audio attachable per role; per-role trigger distance settable, or area entry for area roles (O3); audio downloads with the offline package; plays from the node card and via GPS trigger (H2), subject to reveal policy.

**E5 — Export a journey as GeoJSON** *[P1]* — *FR43*
*AC:* Valid RFC-7946 GeoJSON with custom feature properties for roles, arc, modes, and metadata; **area anchors export as polygons and role offsets as distinct features**; round-trips through standard GIS readers.

### Epic F — Author: Outputs

**F1 — Generate daily cue sheets** *[MVP]* **[AMENDED v2.0]** — *FR46, FR133, FR116*
**As an** Author, **I want** per-day cue sheets **so that** Characters have reliable directions on screen or paper.
*AC:* Per-day cues with turns, distances, surface shifts, plot points, provisions, portages, hazards, stations, and scheduled events; **provisions rendered within the narrative register rather than in a separate logistics panel (FR133)**; **reveal policy inherited, so the printed sheet cannot spoil an unrevealed plot point but always shows every provision and hazard (O5)**; syncs to Character offline; print-optimized. **Cues are derived, ordered by distance, and bounded in density** — SPIKE-21 measured 0.87–2.86 derived cues/km against a 4.0 ceiling, with hazards, portages and transitions never thinned. **Two limits stated rather than implied:** surface shifts are best-effort and bounded by OSM tagging (six across 132 km of test routes, none in one region) and never inferred from road class; a turn cue names a way only where OSM names one (46% of edges in the densest test region), otherwise describing its type. **A cue on road already ridden is marked as a retrace.**

**F2 — Generate group and individual itineraries** *[P1]* **[AMENDED v2.0]** — *FR48, FR133*
*AC:* Master aggregates days/routes/modes/places/rest stops/lodging; individual reflects only that Character's days/passages/transit and retains relevant notes and places; **both render logistics within the narrative register (FR133)** and inherit reveal policy; both previewable, printable, exportable.

**F3 — Configure export contents and splitting** *[MVP]* — *FR44, FR45*
*AC:* GPX/TCX/FIT; toggle track+elevation, waypoints/stops, cue sheet, variants; single or per-day files; native course/turn points and plot-point notes preserved where supported.

### Epic G — Author-as-Participant & Workspace

**G1 — Participate in my own trip** *[P1]* **[AMENDED v2.0]** — *FR82*
*AC:* "Participate as Character" toggle; generates a Character profile counted in aggregations/headcounts/group size; merges Author edit tools with Character execution views; rosters and itineraries list the Author as a participant; **the Author may opt into reveal**, experiencing their own unrevealed content in the field rather than seeing it in the plan.

**G2 — Manage my trip library** *[P1]* **[AMENDED v2.0]** — *FR74, FR76*
*AC:* Grid/list of authored trips with thumbnail, title, modes, distance/elevation, day count, variant count, group size, sync badge; filter by mode/duration; search; per-card Edit Route / Manage Roster & Preferences / Export Backup / Clone. **Clone states what it carries before it runs**: roster membership, group assignments, and the whole authored trip — and **explicitly not profile grants or arrival visibility**, which every Character re-grants per trip (K2). Author notes follow the person automatically (D6), needing no rule. **Cloning last year's trip is the MVP answer for a recurring group**; named travel circles (FR143) are Later.

**G2a — Save, reopen, and list my local trips** *[MVP]* — *FR74a*
*AC:* "Save" persists the current trip locally under its title; a list surface shows title, modes, and last-edited, most-recent-first; selecting reopens into the planner with all edits intact — **including promoted anchors, roles, and reveal settings**; no thumbnails, sync badges, or roster data required; works with no sign-in and no network.

**G2b — Reuse part of a trip** *[MVP]* **[NEW v2.0]** — *FR74b*
**As an** Author, **I want to** choose how much of an existing trip to reuse **so that** starting from last year's crew and starting from last year's route are both one action.
*AC:* Four scopes offered — whole trip, roster only, authored trip only, per-part selection — and the dialog **states carried and not-carried contents for the selected scope before the clone is created**; **roster-only** produces a trip with no days and no anchors, roster and group assignments intact, and **runs trip initiation normally** (N0, N1) since it has nothing to inherit a bbox or modes from; **authored-trip-only** produces the full structure with an empty roster, and **everything assigned to absent people is dropped rather than left dangling** — group assignments, shared gear (C8), meal responsibilities (C9); **in every scope every Character starts at nothing shared**, and no reveal, arrival, choice, or field note is present; **Author notes are present exactly when the roster is**, with `updated_at` preserved (D6); §4.33's cloned-trip check runs once per scope.

### Epic H — Character: Experience the Journey

**H1 — View my itinerary** *[MVP]* — *FR48*
*AC:* End-to-end timeline on mobile/web; personalized dates if partial; daily start/end, distance, and modes shown; subject to reveal policy.

**H2 — Hear authored narration as I reach it** *[MVP]* — *FR49, FR41, FR126*
*AC:* Fires when GPS enters a role's trigger distance **or crosses an area anchor's boundary**; plays with no screen interaction, phone pocketed; runs fully offline from raw GPS; audio included in the offline package (H7).

**H2a — Have text read aloud by my device** *[P1]* **[NEW v2.0]** — *FR40a, FR114, FR52*
**As a** Character with my hands on the bars, my eyes on the trail, or a reason not to read a screen, **I want to** turn on my device's own text-to-speech so the Author's notes and my cues are read to me **so that** I get the story and the practical detail without stopping or squinting.
*AC:* A Character-controlled setting enables **the device's native TTS engine** (platform speech synthesis, not a Plotlines voice and not a network service); when on, plot-point notes, provision detail, Set context, cue text, and hazard notes can be spoken. **Reveal policy governs what is spoken** — TTS reads only what the Reveal Resolver has released, so an unrevealed plot point is never read aloud early, and hazard content is always speakable (O5). **Authored audio wins:** where an Author attached narration for a role (E4), that audio plays and TTS does not read the same text over it. Works **offline** wherever the platform's voices are installed on-device, and says so plainly when they are not, rather than failing silently. Respects the trigger priority order — a hazard alert interrupts speech; narration and TTS queue rather than overlap (I2a). Playback is controllable hands-free per I4 (volume-button or swipe step, pause, skip, repeat). Available on mobile and, where the platform supports it, on the web reading surface (H13). Setting is per-device and lives with display preferences (K5); voice, rate, and language follow the device's own TTS configuration rather than being reimplemented in-app, and default to off.

**H3 — Inspect multimodal days and transitions** *[MVP]* — *FR11, FR12*
*AC:* Timeline distinguishes mode changes (drive → transition → bike → paddle); transition nodes show Author instructions.

**H4 — See regroup points and rest-stop amenities** *[MVP]* — *FR21*
*AC:* Regroup points highlighted mandatory/optional; rest stops show tagged amenities and distance to the next amenity cluster.

**H5 — Access notes and story highlights** *[MVP]* — *FR37, FR38*
*AC:* Tap opens a content card (text/media) for any revealed role; arc stages distinguished on map and timeline for anchors **and passages**.

**H6 — Personalize within the Author's bounds** *[P1]* — *FR6, FR20*
*AC:* Author-variable parameters Character-adjustable; locked ones visible but fixed; personal choices produce a Character-scoped variant that never alters the Author's canonical route; metrics update on toggle.

**H7 — Download for offline use** *[MVP]* — *FR64, FR64a*
*AC:* One action packages routes, cue sheets, media, narration audio, and basemaps within the corridor buffer; full function in airplane mode including GPS-triggered narration (H2), reveal (P1), and the position-aware cue sheet (I1); **unrevealed content downloads but is not browsable through any ordinary UI path before its trigger** — a product guarantee against accidental spoiling, documented as such rather than as a security boundary.

**H8 — Review weather forecast vs. baseline** *[P1]* — *FR66*
*AC:* Active forecast shown alongside historical ranges; deviations highlighted; forecast never removes or obscures historical; age-stamped with a short cache expiry.

**H9 — Submit my capability and preference profile** *[P1]* — *FR77*
*AC:* Profile captures the listed fields; feeds the Author's aggregation (D4); shared per the request/response controls (K2).

**H10 — Inspect elevation profiles and comparisons** *[P1]* — *FR32*
*AC:* Profile highlights steep-grade % and gain; scrubbing tracks the map position marker; alternates comparable side-by-side.

**H11 — Inspect portage and water details** *[P1]* — *FR15*
*AC:* Portage alerts show exit side, carry distance, and trail grade; mandatory portages render prominent safety banners in app and cue sheet.

**H12 — Submit trip feedback for the Author** *[P1]* — *FR42*
*AC:* Feedback attaches to a route, passage, or anchor within the current trip, visible only to that trip's Author and Characters; fellow Characters upvote/downvote; the Author sees all feedback with tallies; incorporation is manual. No moderation queue, reputation system, or cross-account store.

**H13 — Read my trip on the web or on paper** *[P1]* **[NEW v2.0]** — *FR132, FR116*
**As a** Character without the app open, **I want** the full journey on a webpage or printed **so that** I can read it at my desk, hand it to someone, or carry paper as a backup.
*AC:* Web and print carry **equivalent content to the app** — routes, itineraries, cue sheets, place notes, plot points, arc — subject to reveal policy (O5); print shows every provision and hazard and the arc's shape but not unrevealed plot-point content; **the paper copy cannot spoil the trip**; available to a Character without an account where the Author has shared the trip. *(v1.0 had no Character-facing web reading surface at all.)*
> **Gate — anonymity of the web reading surface.** Serving an authored journey to a reader with no account raises a joint design, security, and product question that **must be settled before any web presentation ships**: a share token in a URL leaks through referrers, history, and server logs; access and CDN logs are a retention surface; and **reveal state has nowhere to live for an anonymous reader** — no account, no device GPS, so nothing can fire a reveal. The likely resolution is that an anonymous share-token reader sees **the always-visible set only**, with revealed content requiring an account — but that is a decision to make, not an assumption to inherit. **Not an MVP blocker; gated to the web/hosted leg.** See ARCH Q17 / SPIKE-F.

### Epic I — Character: Field Execution

**I1 — Glance at a position-aware cue sheet** *[MVP]* — *FR47*
*AC:* Advances with GPS, highlighting current + next cue; readable in one look-down; advances offline from raw GPS with the basemap out of the critical path.

**I2 — Use the auto-updating cue HUD** *[MVP]* — *FR50*
*AC:* Active trip opens to the HUD with a progress readout; next cue in focus with distance remaining; header shows remaining distance, elevation, ETA; tapping expands notes/photos/hazards/transitions; one gesture toggles to the map.

**I2a — Choose stowed or mounted posture** *[MVP]* — *FR50a*
*AC:* Two postures over the same position/cue state — **Stowed** (screen off/dimmed: GPS silently advances cues and fires narration/hazard alerts/reveals, no live rendering) and **Mounted** (screen on: HUD auto-scrolls live); switching re-syncs to current position; never auto-scrolls while stowed; posture follows screen state, manually overridable.

**I3 — Get dynamic cue/ETA recalculation** *[MVP]* — *FR51*
*AC:* Passing/missing a cue advances the marker; remaining ETAs update live with pace, including station durations; toggling an alternate inlines its cues without a full reload.

**I4 — Navigate hands-free and glove-friendly** *[P1]* — *FR52*
*AC:* Oversized high-contrast type and directional arrows; ≥48dp touch targets; optional volume-button/swipe stepping.

**I5 — Receive hazard and crux alerts** *[MVP]* — *FR53, FR115*
*AC:* Severity badges and gear notes; a warning tone/header when offline position nears a high-severity hazard; **always fires regardless of reveal settings**.

**I6 — Keep navigating through GPS dead zones** *[P1]* — *FR54*
*AC:* Holds last-known position on signal loss; manual mileage scrolling; resumes automatically when GPS returns.

**I6a — Preserve battery with adaptive location accuracy** *[MVP]* — *FR54a*
*AC:* Low-power tier drives proximity detection while stowed; escalates near a narration, hazard, or **reveal** trigger, or when the screen is active; automatic and invisible; triggers still fire reliably at their Author-set distances; no network wake-ups introduced.

**I7 — Create simple point-to-point routes offline** *[P1]* — *FR63*
*AC:* Point-to-point within the downloaded set via the Dart-first engine; no offline elevation, no real-time guidance; result exports like any route.

**I8 — Amend a route in the field** *[P1]* — *FR55*
*AC:* Toggle an alternate or draw a modification on the offline map; local map, elevation, and cue sheet update; edits persist locally and auto-sync.

**I9 — Publish and evaluate route amendments** *[P1]* — *FR56*
*AC:* Any participant can publish; connected members get a change summary; recipient sees current-vs-proposed with updated distance/elevation/hazard; Accept / Decline / Select-Alternate updates that individual's path independently. Amendments flaggable **hazard/high-importance with a free-text safety note**, surfacing as a warning-level alert to everyone approaching that point.

**I9a — Pin a field note for the group** *[P1]* — *FR56a*
*AC:* Location-anchored, timestamped, attached to a point on the shared route; peer-to-peer to the trip roster; advisory only; attributed to its poster; syncs when connectivity allows.

**I9b — Receive field notes as I approach** *[P1]* — *FR56a*
*AC:* Surfaces as the Character nears its location, with text, poster, and age; dismissible per-Character; persists until the Author curates it into the plotline (**O8**) or dismisses it for the group; visually distinguished from Author-authored content so provenance is clear.

### Epic P — Character: Acting in the Story *(new)*

**P1 — Discover content by arriving** *[MVP]* **[NEW v2.0]** — *FR124, FR114*
**As a** Character, **I want** some of the Author's content to be revealed only when I get there **so that** rounding the bend and finding the waterfall is an actual experience rather than something I already read on the couch.
*AC:* A role marked *revealed on arrival* withholds its text, media, and audio until the Character's position enters its trigger distance or area boundary; on arrival it unlocks permanently for that Character; **runs fully offline from raw GPS with no connectivity**; provisions and hazards are never withheld (O5); the pre-trip view shows that unrevealed content exists and where, without showing what it is.

**P2 — Choose my path and my effort** *[P1]* **[NEW v2.0]** — *FR125, FR20, FR109*
**As a** Character reaching a branch or a station, **I want** to make a real choice with real consequences for my day **so that** I am participating in the story rather than following a line.
*AC:* At a branch alternate (C4) the Character chooses between paths carrying different content; at a station (O4) the Character chooses to take on the activity or bypass it; the choice updates that Character's cues, remaining distance, elevation, and ETA independently of the group; the choice is recorded and appears in the recap (J2); **no randomness, no dice, no chance-driven outcome** — every branch and its consequences are authored.

**P3 — Let the group know I got there** *[P1]* **[NEW v2.0]** — *FR122, FR123*
**As a** Character, **I want** my arrival at a plot point to be visible to the group when I choose to share it **so that** we can regroup without radios — *"three of us are already at the overlook."*
*AC:* Arrival recorded locally and offline whenever a narrative trigger fires, feeding the Character's own record and recap **regardless of sharing**; **visibility is granted through the Author's profile-field request (D4a/K2)** — requested, granted or declined, per trip, revisable, **default nothing shared** — with no separate consent surface; when granted, arrivals are visible to the **trip roster**, not the Author alone; **timestamp display is an Author option** per trip; sparse and event-driven, never a continuous position feed, consistent with the non-goal on participant tracking.

### Epic J — Character: Capture & Keepsake

**J1 — Log field notes, photos, and voice** *[P1]* — *FR72*
*AC:* Attachable to any anchor or track coordinate during/after a trip; private or shareable to the group; stored on device first, then synced.

**J2 — See a post-trip recap** *[P1]* **[AMENDED v2.0]** — *FR73*
**As a** Character, **I want** a recap comparing what was planned to what happened, **including the story of it** **so that** I keep a record of the journey rather than a table of numbers.
*AC:* Planned-vs-actual distance, moving time, and elevation by mode; **plus a narrative axis — which plot points were reached, in what order, at what hour (P3), which branches were taken and which stations attempted (P2)**; combines Author narrative with Character logs into a digital keepsake. *(v1.0 was metrics-only.)*

**J3 — Manage my trip vault** *[P1]* — *FR75, FR76*
*AC:* Trips under Active/Upcoming, Offline Ready, Completed/Archived; each card shows Author, attendance dates, modes, offline badge; one-tap download or export; completed trips link to recap, photos, journal.

### Epic K — Any User: Account & Platform

**K1 — Sign in with a magic link** *[MVP]* — *FR57*
*AC:* Magic link is the only auth and the recovery path; no password, no SMS OTP; local planning works immediately.

**K2 — Respond to an Author's request** *[P1]* **[AMENDED v2.0]** — *FR77, FR78, FR78a, FR123*
**As a** Character, **I want to** respond to what an Author asks for — granting what I choose, declining specifics, and volunteering things they didn't ask — **so that** the Author can plan well while I stay in control.
*AC:* Character sees exactly which fields **and permissions** the Author requested, **including arrival visibility (P3)**; can grant the requested set, decline individual items, and add unrequested fields (e.g. an allergy or medical condition); nothing shared until the Character responds; **default is nothing shared**; response is per-trip and revisable at any time including mid-trip; preference fields still seed weight defaults.

**K3 — Sync across my devices** *[MVP]* — *FR58, FR59*
*AC:* Canonical server copy; local working copy functions offline; version comparison on open and before save; User chooses save-as or overwrite; never silent overwrite; guests excluded.

**K4 — Use Plotlines as a guest** *[MVP]* — *FR60, FR61*
*AC:* Core loop + export + both weather types with no account; work persists in the browser across refresh; nothing server-side; limits stated plainly.

**K5 — Configure display and measurement preferences** *[MVP]* — *FR79*
*AC:* Miles/km, °F/°C, light/dark/system, indoor/outdoor contrast; applies live across charts, cue sheets, dashboards, maps, weather; mobile defaults outdoor, desktop indoor, override synced. **Time and date format inherit the device's own settings by default** — the platform's clock preference and locale date pattern — **with explicit overrides**: a 12/24-hour toggle and the seven date formats in FR79. *Inherit defers to the platform's pattern, which may not be one of the seven, and resolves at render time rather than being frozen at install.* **The setting syncs; `inherit` resolves per-device**, so an explicit choice follows the user across machines while an inheriting user gets each device's own answer. Web guests are inherit-only with nothing persisted. **The device-TTS readout toggle (H2a/FR40a) lives here too and is per-device rather than synced** — it depends on which voices are installed on the device in front of the Character.

**K6 — Set my language** *[P1]* — *FR83*
*AC:* Language menu in native scripts; defaults to device locale, falls back to English; switching updates static UI live; preference saved and synced.

**K7 — Prune downloaded content** *[P1]* — *FR80*
*AC:* View downloaded content with footprint; delete anything not needed for a current/upcoming trip; a delete affecting an upcoming trip warns first; N/A on Web.

**K8 — Reset planning controls** *[MVP]* **[AMENDED v2.0]** — *FR81*
*AC:* Always-visible reset; reverts theme, shape, start, destination, distance to defaults and clears the generated route; **in compose mode it does not discard promoted anchors, roles, or reveal settings** — losing an afternoon of curation to a single reset would be unrecoverable; if the Author wants that, it is a separate, confirmed action.

**K9 — See sync/offline status at a glance** *[P1]* — *FR76*
*AC:* Cards show Cloud Synced, This Device, and Offline Ready distinctly.

**K10 — See required data attribution and app/sidecar version** *[MVP]* **[AMENDED v2.0]** — *FR86, FR95, FR101*
*AC:* Reachable from every platform surface that displays licensed data, including the lightest ones; shows the CC BY credit for elevation and the ODbL `© OpenStreetMap` credit for the basemap together, since they are separate obligations under different licences; **plus per-layer attribution for every loaded plugin dataset (N5)**, which likewise propagates to exports and print; shows the running app version and, on desktop, the sidecar version matching `/health`; **a missing attribution is a build failure and this surface is a release gate**. **The privacy statement (K11) is reachable from here on every platform**, including Web guest and the share-token reading view.

**K11 — Read what Plotlines knows and shares** *[MVP]* **[NEW v2.0]** — *FR138*
**As** any User, **I want** a plain statement of what is stored, what is shared, and what is not **so that** I can decide what to share without guessing.
*AC:* **Reachable from the About surface on every platform**, including the lightest — Web guest and the share-token reading view (H13) — since those reach people who may have no account at all; states in plain terms what lives on the device and what reaches the server, that **reveal is a product guarantee against accidental spoiling and not a security boundary** (H7), what arrival sharing does and does not do and that it defaults to nothing shared (P3), **that an Author may keep private notes about Characters, that they are visible only to that Author, persist across trips, and can be deleted on request** (D6, D6a), and that guest sessions leave no server-side trace (K4); **not legal boilerplate — it says what is true, briefly**, and reads in the app's own voice.

**K12 — Work without fear** *[MVP]* **[NEW v2.0]** — *FR142*
**As** any User, **I want** to be able to undo what I just did, find what I made, and know what to do next **so that** using Plotlines doesn't require caution.
*AC:*
**Undo/redo** covers authoring actions within a session — promotion, removal, edits, arrangement, reveal changes, group assignment, day restructuring — with visible affordances and a stated depth; **Author-note deletion is excluded and says so at the point of deletion** (D6a); **derived work is not undone but re-solved** (Q3), since re-solving is idempotent; undo state is session-scoped and cleared on trip close, and **the app says so rather than implying permanence**.
**Reachability** is verified against an enumeration, not asserted: **anchor** attached and unattached (N4a anchors view), **passage** (day view), **day** (trip view), **trip** (library, G2a), **Character note** (detail view, D5), **group assignment** (roster, D7), **stale item** (stale list, Q3). **A new object type ships with its path named, or it does not ship.**
**Empty states** state a next action rather than an absence — a trip with no days, a day with no passages, a bbox with no promoted anchors, a roster with no Characters, a layer set yielding no candidates. Distinct from N4a's *no clusters found*, which is a **result** and belongs with the analysis, and from M13's states, which are **failures**.
**Accessibility** targets **WCAG 2.2 Level AA** through platform accessibility APIs, covering the desktop authoring surfaces specifically — keyboard navigation through the curation workspace, screen-reader semantics for the proposal and anchor lists, focus management through promotion. **Field surfaces exceed AA deliberately** (I4, K5). **For MVP this is a design-review checklist, not a release gate**; the formal audit is post-MVP and gated before expansion beyond the Author desktop (FR142a).

**D9 — Plan for the same crew again** *[Later]* **[NEW v2.0]** — *FR143*
**As an** Author with a summer riding group and a Memorial Day paddling crew, **I want** named sets of people I can drop into a new trip **so that** I'm not rebuilding the same roster every year.
*AC:* Named circles of Characters, editable over time; selectable at trip creation to populate a roster in one action; **a circle is a living list — future trips pick up its current membership**; **a trip's roster is materialized at creation and is thereafter independent**, so adding or removing someone from a circle never retroactively changes a trip already created, because a roster in flight carries grants, group assignments, and gear responsibilities that must not shift underneath an Author; where a circle changes and upcoming trips were drawn from it, Plotlines **offers** to apply the change and **never applies it silently**; circles carry **membership only** — not profile grants (K2 re-grants per trip, exactly as with clone), not trip content, and not group assignments, which are trip-scoped by definition (D7); managed from the roster board (D8), which is the same data in the same surface. **Cloning a prior trip (G2) is the MVP answer** for a recurring group.

**K12a — Tell me once** *[MVP]* **[NEW v2.0]** — *FR142(e)*
**As an** Author, **I want** to be told how something works the first time I meet it and not every time after, and to be able to read it again if I forget.
*AC:* **An enumeration of teaching moments exists**, one per non-inferable behaviour, each naming the surface it appears on — promotion not placing a place into a day, reveal belonging to a role rather than a place, a stale route being deliberate, compose distance being an outcome; **dismissing a tip hides it for that trip only** and a new trip shows it again, since the next trip is often months later; **every dismissed tip is reachable from an inline help affordance on its own surface**, verified against the enumeration exactly as K12's reachability is; **no teaching block is load-bearing** — dismissing all of them leaves every control operable and every status legible; **live status text is not dismissible and is not in this enumeration** (*"routing available in about 3 minutes"* is part of the control, per N2).

### Epic Q — Author: Editing & Lifecycle *(new)*

*Everything above is written as create-once. This epic is what an Author actually does after the first pass.*

**Q1 — Change the trip's shape after I've started** *[MVP]* **[NEW v2.0]** — *FR139*
**As an** Author, **I want to** add, insert, or remove days after I've already planned some **so that** the trip can change shape without me starting over.
*AC:* Day count editable at any time; days **insertable mid-trip**, not only appendable, with subsequent days renumbering and their content moving with them; reducing the count where affected days hold authored content **prompts with the scope** — *"day 5 and day 6 hold 4 passages, 7 anchors, and 2 scheduled events"* — offering keep, adjust, merge-into-adjacent-day, or explicit removal; **empty days are removed without a prompt**; derived work goes stale per Q3 and never cascades.

**Q2 — Change or remove a passage** *[MVP]* **[NEW v2.0]** — *FR139, FR140*
**As an** Author, **I want to** change a passage's mode, reorder it, or remove it mid-planning **so that** a day can be rethought without losing the places I've already chosen.
*AC:* Mode, endpoints, weights, and order all editable after routing; **removing a passage prompts if it carries authored content**, naming any transition nodes with Author instructions; **its anchors survive unattached** rather than being deleted with it — an anchor is a place, not a property of a route; **unattached anchors are findable and re-attachable through the curation workspace's anchors view (N4a), are not flagged as a problem, and block nothing** — an Author parking places for a day they haven't built yet is working normally, not accumulating errors; changing a mode **marks the route stale rather than re-solving** (Q3) and re-checks routability on the next solve (A11).

**Q3 — Let derived work go stale instead of chasing every edit** *[MVP]* **[NEW v2.0]** — *FR140, FR140a*
**As an** Author, **I want** routes and cue sheets marked out of date rather than silently recomputed or blocking me **so that** I can make several edits in a row and re-solve once.
*AC:* An edit invalidating derived work sets `solve.stale` visibly on the affected object; **while planning this is passive only** — a marker on the object and a count in the dashboard, no modal, no banner, no interruption across a run of edits; **a stale route stays viewable but is not exportable or printable**; an **export attempt opens the stale list** rather than erroring — each item named by what it is and which day it's on, each individually resolvable, with **re-solve-all as one unconfirmed action** at the top, after which the export proceeds; **print blocks with no override path**, since a printed cue sheet is believed for a day; where the list offers dropping an object instead of re-solving it, **that** action confirms; **the stale list is its own surface, not the shared error surface** (M13) — stale work is pending work the Author caused deliberately, not a failure; candidate caches regenerate silently (N3); staleness clears on re-solve.

**Q4 — Duplicate something similar** *[P1]* **[NEW v2.0]** — *FR141*
**As an** Author planning nine days with the same rhythm, **I want to** duplicate a passage, anchor, or day and adjust it **so that** the tenth similar thing takes a minute rather than a quarter of an hour.
*AC:* Duplicates carry content and settings — a passage's mode and weights, an anchor's role set, reveal policy, and content, a day's type and structure; **provenance is not copied** (a duplicate is not "from cluster X") and neither is any Character-layer state (arrivals, reveals); **position is never copied** — a duplicate requires its own geometry before it is complete, since two anchors in one place is precisely what the anchor model exists to prevent; the duplicate is independent immediately, with no link back to its source.

### Epic L — Portability & Durability

**L1 — Auto-back-up trips locally as GeoJSON** *[P1]* — *FR68*
*AC:* Auto-saves spatial layers as valid RFC-7946 GeoJSON to local storage on key edits and at intervals; **includes area anchors as polygons, role offsets as distinct features, and role/arc/reveal metadata as feature properties**.

**L2 — Keep notes as portable Markdown** *[P1]* — *FR69*
*AC:* Notes/journals saved as valid `.md`; images as relative references; links/coords/anchor references as standard Markdown links.

**L3 — Export a full trip archive** *[P1]* — *FR70*
*AC:* One `.zip` with `/routes`, `/journal`, `/photos`, and `manifest.json`; generated locally/in background without choking the device.

**L4 — Restore a trip from an archive** *[P1]* — *FR71*
*AC:* Validate `manifest.json` and file integrity before import; restore geometries, sequencing, metadata, cue sheets, Markdown notes, photos, **and the full anchor/role/reveal/arc model**; resolve relative references without breakage; show progress and a completion summary.

### Epic M — Developer: Architectural Seams

**M1 — Model themes as data** *[MVP]* — *design goal*
*AC:* Each theme is values in a shared `WeightProfile` (elevation, traffic class, surface penalty, POI bonus, detour budget, plus mode-specific weights); one scoring function consumes any profile; adding a **traversal mode** requires only a new profile entry; **adding a station activity requires no routing change at all** (FR130) — the two extension paths are distinct and both are configuration.

**M2 — Resolve weights per edge via a position lookup** *[MVP]* — *FR36 seam*
*AC:* Solver obtains weights through `weights.at(position)`; scalar case returns the same profile each time; introducing scopes changes only the lookup, not the solver.

**M3 — Abstract elevation behind one interface** *[MVP]* — *FR62 seam*
*AC:* One elevation interface from the first milestone; initial resolution is local-cache-then-direct-provider; a later phase inserts a shared cache ahead of the direct call, changing only order and base URL.

**M4 — Serve web auth same-site** *[MVP]* — *architecture requirement*
*AC:* Web and API on subdomains of one registered domain; cookie `HttpOnly; Secure; SameSite=Lax` on the shared parent; no tokens in `localStorage`/`IndexedDB`; persistence verified in Safari and Firefox as a release gate.

**M5 — Rate-limit guest compute per IP** *[P1]* — *architecture requirement*
*AC:* Per-IP in-memory counter on the single instance; calibrated threshold with progressive cool-off; guest sessions stateless server-side; single-instance limitation documented as accepted.

**M6 — Cache external resources by volatility** *[P1]* — *responsible-use NFR*
*AC:* Per-dependency TTLs; size-bounded caches with eviction; held data never re-fetched; attributions shown wherever that data appears.

**M7 — Pass the processing-core limit in from the caller** *[P1]* — *core-allocation rule*
*AC:* Desktop/Mobile pass `floor(coreCount / 2)`; the core treats the limit as a parameter and never queries the host; server uses a fixed allocation by instance size.

**M8 — Build an ARB-based localization framework** *[P1]* — *FR83 foundation*
*AC:* UI strings extracted to `.arb` templates in `/l10n`; codegen produces type-safe `AppLocalizations`; interpolation, pluralization, and date/number formatting via `intl`; missing keys fall back to base locale with build-time warnings.

**M9 — Run within device power-saving mode** *[P1]* — *FR67*
*AC:* Minimized wake-ups during active navigation; no errors/crashes under OS power-saving; core navigation remains available.

**M10 — Ship a single, licensed elevation source with no fallback** *[MVP]* — *FR85, FR88*
*AC:* GEDTM30/OpenTopography only, no secondary fallback; nodata (including NaN via explicit `isnan`) and out-of-bounds/missing-raster all resolve to `0.0`, logged at most once per raster path; no network call inside a solve.

**M11 — Serve tiles only through our own service** *[MVP]* — *FR92–FR95*
*AC:* Client requests tiles only from `GET /tiles/{z}/{x}/{y}`; service validates z/x/y before upstream work; generation is bbox-scoped and on-demand, shared with the offline-bundle pipeline; tiles extracted from a Plotlines-hosted Protomaps mirror; ODbL `© OpenStreetMap` ships alongside elevation's CC BY.

**M12 — Manage the sidecar's lifecycle and enforce a paired version** *[MVP]* — *ARCH §7.3, §12.1*
*AC:* Spawn binds an ephemeral port; the client polls `GET /health`; a sidecar that dies mid-session restarts **once**, and a second failure degrades honestly; graceful stop is platform-specific — POSIX SIGTERM→SIGKILL; Windows `AttachConsole` + muted Ctrl handling + `CTRL_BREAK_EVENT`→`TerminateProcess`, with the sidecar in a Job Object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`); app start performs an orphan sweep; client and sidecar versions compared at startup and **the app refuses to run on a mismatch**. Verified by the sidecar-lifecycle test suite.

**M12a — Report readiness per capability** *[MVP]* **[NEW v2.0]** — *FR121, FR91*
**As a** Developer, **I want** `/health` to report readiness **per capability** rather than as one global flag **so that** an Author can curate a trip while elevation enrichment is still running.
*AC:* `/health` reports readiness independently for tile/basemap, layer-and-POI, routing, and elevation capabilities, with a progress estimate for anything still warming; **layer extraction and POI indexing are ordered ahead of elevation enrichment** at trip initiation, since the Author needs the former immediately and the latter only when routing; the client enables and disables surfaces from those flags and states the reason on any disabled control; M12's version-mismatch refusal is unchanged. **This replaces v1.0's single ready/not-ready semantics and is a breaking change to ARCH §7.3.**

**M14 — Build every user-visible string as a template** *[MVP]* **[NEW v2.0]** — *FR145*
**As a** Developer, **I want** every user-visible string to resolve a fixed template against typed slots **so that** localization works and **so that** no sentence can become a path around the reveal gate.
*AC:* **Every template is enumerable with its slots typed**; a message with an unbounded string slot fails review; **reason phrases are an enum plus a bounded table** — adding a cause means adding a table entry, never writing a sentence at a call site — and the enum aligns with M13's typed state enum where the cause is a failure; **plural and list rules are locale-driven** via M8's ARB framework, never hardcoded to English; **a CI check asserts no template accepts `Role.content` or any authored text field as a slot value**, enforced by the same lint that keeps role content out of Presentation; the TTS path (H2a) reads **templates and resolved content separately**, never a pre-composed sentence. *(A composed sentence is assembled in Presentation, which is downstream of the export-path byte assertions — so it is invisible to them.)*

**M13 — Handle every desktop error/empty state through one shared surface** *[MVP]* **[AMENDED v2.0]** — *design goal; FR9*
*AC:* One shared surface driven by a typed state enum covers all desktop states — sidecar starting, sidecar won't start, sidecar died mid-session, no route possible, no data for the area, elevation void/missing tile, external provider unreachable, export failed — **plus four new v2.0 states: capability-warming (FR121), layer-extraction-failed, plugin-layer-unloadable-on-licence (FR101), and no-clusters-found-in-bbox (FR102)** — each with its defined treatment; the surface is stubbed before the first screen is built; a failure in an optional enrichment never blocks generation or discards the route. **Compose-mode distance deviation is explicitly *not* an error state** and does not route through this surface (A0a). **Neither is stale derived work** (Q3, FR140a): the stale list is a **distinct surface** with its own presentation and its own one-action resolutions, because stale work is pending work the Author caused deliberately by editing. Routing either through this enum teaches the Author that ordinary editing produces errors.
---

## 10. Open Items

Deliberately unresolved, carried forward or newly surfaced.

### Newly surfaced in v2.0

- **Naming: Passage and Set.** "Plot point" is settled and is the product's namesake. "Provision" is settled — right register, no competing meaning. **"Passage"** (the traversal between anchors, formerly "segment") and **"Set"** (the named place-identity, the setting) are both unsettled, and "Set" in particular may not survive contact with a UI label. Non-blocking; the concepts are locked even if the words move.
- **Whether narrative and provision are permanently one object.** v2.0 models them as roles on one anchor, which the historic-well and national-monument cases demand. If they diverge in authoring or rendering far enough that the shared object becomes a burden, splitting them is a later refactor — but the *one arrival, one place* property must survive any such split.
- **Cluster proposal ranking at scale.** FR105a bounds and ranks proposals, but the actual ranking function — how salience and tightness trade off, whether corridor proximity should dominate once a route exists, what "reviewable count" means for a 200 km bbox — is a design and tuning question that wants a spike against real regions.
- **Anonymity of the Character-facing web reading surface.** FR132/H13 serve an authored journey to a reader with no account. Three unresolved strands: a share token in a URL leaks through referrers, history, and server logs; access and CDN logs are a retention surface; and **reveal state has nowhere to live for an anonymous reader** — no account, no device GPS, nothing to fire a reveal. Likely resolution is that an anonymous reader sees the always-visible set only and revealed content requires an account, but that is a decision, not an inheritance. **Joint design, security, and product call. Not an MVP blocker; gated to the web/hosted leg and final before any web presentation.** *(ARCH Q17 / SPIKE-F.)*
- **Rendering candidates and proposals at bbox scale.** A dense trip bbox may put thousands of markers over a basemap that already costs ~1 GB. Clustering-for-display, zoom thresholds, or salience-gated rendering — undecided, and its answer governs the map half of N4a. *(ARCH Q15.)*
- **Affinity beyond the primary.** FR105 settles affinity as single-valued with Author override, deliberately: an Author should not adjudicate detail irrelevant to their story, and a layer author declares one thing per type rather than a matrix. If a class of types emerges where the override is nearly always needed — hot springs are the candidate — a declared secondary affinity is a small, additive change. Watch for it rather than pre-building it.
- ~~**Notability-filter tuning is a data question, not a code question.** FR98's per-tag qualification rules and `historic=*` sub-weighting will need calibration against real extracts in the target regions (NC, WI, SoCal). Under- and over-filtering both fail visibly, and the right values are almost certainly regional.~~ — **measured 2026-08-27 (SPIKE-A, ARCH §18 Q11).** Partly a code question after all: a bare-presence qualification gate is not a gate (`Qualification.requires_value` added). Calibrated against three trip bboxes; `RULESET_VERSION` → `1.2.0`; golden candidate sets locked. **The values are *not* regional** — one default ruleset holds in all three regions; what varies is candidate volume, which is a ranking concern (SPIKE-B). See `spikes/SPIKE-A/results/RESULTS.md`.
- **Difficulty-grading coverage beyond whitewater (FR14b).** SPIKE-04 tested `whitewater:section_grade` and found it effectively absent in North America. Whether `sac_scale`, `trail_visibility`, `mtb:scale`, and `piste:difficulty` have usable coverage is an **open empirical question that has not been measured** — and v1.0 generalized the whitewater result to all technical terrain without testing it. Worth a spike before committing to Author-declared difficulty as the only path.
- ~~**The utility-amenity layer is thin.** The OSM attribute mapping was scoped to a touring cyclist's sights and cycling support, and it does not contain `amenity=toilets` at all — the canonical example in the Frodo principle. `amenity=cafe`/`restaurant`/`pharmacy`/`shower`/`waste_basket` are likewise absent. **FR104's "toilet + water + shelter" cluster cannot be computed from the current mapping.**~~ — **decided 2026-08-27 (ARCH §18 Q16).** The provision-oriented pass is done: `core/plotlines_core/curation/taxonomy.py` now carries `toilets`, `water_point`, `shower`, `cafe`, `restaurant`, `fast_food`, `pharmacy`, `bicycle_repair_station`, and `compressed_air` as `provision`-affinity rows (source of truth: the OSM wiki `Key:amenity`, not `docs/osm_reference.md`, which is directional only). Both of FR104's worked clusters now resolve. `bench`/`waste_basket` were deferred to SPIKE-A, which **confirmed they stay out** (both fall in the unmatched tail as correct omissions — neither is a sight or a provision-cluster input).
- **Web reading surface and guest access.** FR132 puts full journey reading on the web. Whether a Character can read a shared trip without an account — and what an Author-shareable link looks like — is undecided and interacts with FR60's stateless guest model.
- **Unrevealed content on device (FR64a).** Reveal must work in airplane mode, so unrevealed content is on the device. v2.0 states this as a product guarantee against accidental spoiling, not a security boundary. Whether encryption-at-rest is worth the complexity for a spoiler is a Design and engineering call.
- **How a living circle surfaces its drift.** FR143 settles that circles are living and that rosters materialize independently, with changes **offered** to upcoming trips rather than applied. What that offer looks like — a prompt at circle-edit time, a badge on affected trips, or a review surface — is a Design question for the Later leg. The requirement is only that it is never silent.
- **Whether FR139's orphan prompt can lighten once undo exists.** Four separate confirmation mechanisms were written before undo did — FR139's orphan prompt, FR120's bbox shrink, FR135a's deletion scope, FR81's anchor protection — and each does undo's job from the wrong side: **a confirmation asks the Author to predict a consequence; undo lets them see it and change their mind.** All four stand as written, because loosening them on the strength of an unbuilt feature is how you end up with neither. **FR139's is the one to revisit first** — it fires most often and its cost is friction on ordinary editing. FR135a's does not move: note deletion is irreversible by design and excluded from undo.
- **Where unattached anchors live in the interface.** Q2 leaves anchors alive when their passage is removed, and N4a's anchors view is where they are found. Whether that view is a third tab, a filter on a single list, or a panel is a Design question — the requirement is only that unattached anchors are **findable, re-attachable, and never presented as a problem**.
- **Author-side reveal preview.** O5 requires the Author can preview the trip as a Character would see it. Whether that is a mode, a separate view, or a per-role toggle is a Design question.

### Carried forward from v1.0

- **In-field peer intel is intentionally in-scope, and route-anchored.** Route amendments (FR56/I9) and field notes (FR56a/I9a–b) let any participant share time-sensitive intel with the trip roster peer-to-peer — deliberate, because the Author may be riding and unable to relay. Bounded to one trip's roster, anchored to points on the shared route, advisory. **Arrival events (FR122–FR123) join this category in v2.0** under the same reasoning and the same consent surface. Not the social-platform territory the non-goal guards against — no friend graph, no cross-trip feed, no open messaging. The remaining design question is presentation: how notes, flagged amendments, and arrivals are surfaced or queued so a busy stretch doesn't overwhelm the Character.
- **Cue HUD vs. "no real-time route guidance."** The auto-updating HUD with live ETA recalculation is authored-content playback, not turn-by-turn routing — but the line is fine. Worth confirming during Design that the HUD never crosses into wrong-turn recalculation or "follow the line" guidance.
- **Multimodal breadth.** Cycling, hiking, and paddling are first-class at MVP. v2.0 resolves *how* further modes extend (FR130: traversal modes are `WeightProfile` entries; station activities need no routing change) but not *which* ship when.
- **Paddling difficulty — decided, and worth revisiting if the data changes.** SPIKE-04 found the paddling network and USGS gauge readings solid and public-domain, and class ratings absent. FR13 removed, B4/B5 removed, FR14 narrowed to an advisory gauge band, portages made Author-drawn. What remains open is the trigger, not the decision: if a data agreement with American Whitewater becomes possible, or the OSM whitewater schema gains North American adoption, re-adding the class term is two fields on `WeightProfile` and a scoring clause.
- **Unified "share with Author" surface.** FR78/FR78a is a request/response negotiation; FR30's transit/arrival sharing is a simpler per-field opt-in. **FR123 resolves part of this** by routing arrival visibility through the request/response mechanism. Whether transit sharing should also adopt it, and whether all of this lives in one surface, is still a Design decision.
- **Leg 7 interface shape.** The **output** contract and destination list remain open. The **input** contract is no longer open — see FR100.
- **Default download regions — settled.** SPIKE-14 measured ~3.5 MB per 1,000 km² at z0–15 over a ~1 MB floor: 1.0 MB for a CI/test bbox, 22 MB for an 80 km square, 118 MB for a 235 × 134 km corridor, roughly halving if capped at z14. A default region is not a storage trade-off — pick the region that routes well. Three distinct extents, not one model: the shipped home default (Buncombe County, NC), the **trip authoring bbox** (FR120, new in v2.0), and the **offline corridor buffer** (C14/FR35).
- ~~**Traffic-stress model overstates rural traffic**~~ — **decided 2026-08-16 (ARCH §16 D33).** Rural/low-signal roads are the model's zero-stress baseline rather than inheriting a class-derived floor.
- **Brand naming & positioning** beyond product/technical scope — not yet settled.
- **Visual identity & color system** — owned by `Brand Guide.md`, deliberately not duplicated here.

---

## Appendix A — Source-Story Traceability

Carried from v1.0 and extended. Consolidations of note:

- Author 10a–10d → FR2–FR5, FR8 (weights); 29 → FR16, FR31 (speeds/ETA).
- **Author 10e/10f/18 (water/technical) are not fully represented.** FR13 removed and FR14 narrowed after SPIKE-04, so the *class-rating* half is deliberately unbuilt. Story 18's gauge half survives as FR14/FR14a (B8) and its terrain-technicality half as FR14. **FR14b (new in v2.0) reopens the question for hiking/MTB/nordic schemas, which were never tested.**
- Author 1, 9 → FR17–FR18; 20 → FR19; 19 → FR20; 4/5 → FR21; 13 → FR22; 11 → FR23; 12 → FR35; 15 → FR12; 23 → FR15; 32 → FR24; 33 → FR25; 34 → FR26; 27 → FR27, FR53; 28 → FR28; 17 → FR29–FR30; 16 → FR38; 21/22 → FR31–FR32; 7/8 → FR33; 14 → FR34; 24/25 → FR48; 26 → FR46; 31 → FR82; 35/36 → FR55–FR56; 37 → FR74.
- Character C1–C13 map to their Author counterparts' Character-facing FRs; C17 → FR72; C18 → FR73; C19 → FR79; C20 → FR54; C21 → FR75; C22 → FR50; C23 → FR51; C24 → FR52; C11 → FR53; C14 → FR44–FR45; C5 → FR66; C6 → FR77.
- System S1 → FR79; S2 → FR77; S3 → FR68; S4 → FR69; S5 → FR70; S6 → FR71; S8 → FR76; S9 → FR83. Developer D1 → M8.
- Two source defects corrected: Story 10e's inverted "so that," and Story 10c's mileage target folded into FR8/FR5.

**New in v2.0 — the concept framing and the OSM attribute mapping are now first-class sources.** Neither was represented in v1.0. FR97–FR112, FR114–FR126, FR128–FR133 derive from them; Appendix B traces each.

---

## Appendix B — Recovered Concepts *(what v1.0 lost, and how)*

v1.0 was consolidated for consistency and concision. That consolidation had a systematic bias: **when two stories collapsed into one requirement, the testable mechanism survived and the intent did not.** "0.0–5.0 decimal scale" is easy to preserve in a sentence; "so the journey reads as a story" is not. Every loss below fits that pattern.

| # | Concept | How it was lost in v1.0 | Restored as |
|---|---|---|---|
| 1 | **The layer→analysis→promotion→routing pipeline** | Never present. v1.0 modelled planning as routing-first, with POI density as a weight inside the solve — inverting the concept's order of operations. | §5; FR97–FR110; Epics N, O |
| 2 | **Cluster / density identification** | Never present at all. The concept's "castle near a waterfall" and "toilet + water + shelter" analysis had no requirement. | FR102–FR105a; N4 |
| 3 | **Plot point as an object** | Used undefined in FR45 and F3 as "plot-point notes." The narrative role was distributed across FR37 (notes), FR38 (arc tags), FR40–41 (audio) with nothing composing them. | §4.3; FR106; O1 |
| 4 | **Setting** | Absent. The concept names characters / setting / plot; v1.0 had two of three. Route relations and named networks were in the OSM mapping and reached no requirement. | §4.7; FR111–FR112; O7 |
| 5 | **Area / polygon geometry** | Explicitly scoped out — "everything is a node or an edge." A rest day on a main street or in a historic district was inexpressible. | §4.4; FR108, FR126; O3 |
| 6 | **Node-anchored activities (stations)** | Climbing, canyoneering, and jumaring were filed under "further modes, a scoping decision" — but `WeightProfile` models horizontal traversal and could never have absorbed them. The OSM mapping already described `climbing=crag` as a site-level "worth a stop" marker. | §4.3; FR109, FR16b, FR130; O4 |
| 7 | **Reveal policy** | Absent. Every note was readable from the trip view the moment the package downloaded. A crux you had already read about is not a crux. | §1.5; FR114–FR116, FR124, FR64a; O5, P1 |
| 8 | **Character acting inside the story** | The Character was a pure consumer. Every Character-authored capability (feedback, field notes, amendments, journal) sat *outside* the story commenting on it. Nothing let a Character act *within* it. | FR122–FR125; Epic P |
| 9 | **The Frodo principle** | Water and toilets existed as cue-sheet rows beside hazards and surface shifts. Nothing required logistics to be woven into the narrative register rather than broken out beside it. | §1.4; FR133; F1, F2 |
| 10 | **Arc as structure** | Reduced to a [P1] tag on points only — so the story could only happen at places, never on the road between them. | §4.6; FR38; O6 |
| 11 | **Auto legs are routed** | The concept distinguishes *routes* for auto from *notes* for train and plane, because the last mile is often the day's worst. FR29 flattened all four into "authored trip data," and driving left the mode list. | FR29, FR10; C13, B1 |
| 12 | **Character web and print reading** | The concept names three delivery channels. FR61 scoped Web to *Author planning*; there was no Character-facing web reading surface anywhere in the document. | FR132; H13 |
| 13 | **Mode-legal routability** | Never specified. The OSM mapping carried a whole routability-constraint column — `bicycle=no`, `dismount`, barriers, fords, weirs — and none of it reached a requirement. v1.0 had no passability guarantee in 96 FRs. | FR128; A11 |
| 14 | **Plugin data-input as a foundation** | Deferred to Leg 7 with its shape "deliberately left open," though it is the substrate the layer picker and cluster analysis read. | FR100, FR101; Leg 2.5; N5 |
| 15 | **Salience / notability filtering** | `historic=*` was a flat wildcard — a castle and a boundary stone scored identically. Tolerable for a density weight; fatal for cluster proposal. | FR98; N3 |
| 16 | **Temporal availability** | No `opening_hours` or seasonality anywhere, though FR28's conflict detection needs it. | FR129; N6 |
| 17 | **Compose mode** | v1.0 supported only explore. FR39's one P1 sentence described compose without any machinery, and FR8's unconditional distance banding actively contradicted it. | §5.8; FR117–FR119; A0, A0a |
| 18 | **Group dynamics as Author expertise** | Reduced to a size tier (FR22) and a preferences histogram (FR34) — headcount and aggregation, all of it about coordinating a group that already exists. Nothing let an Author express *judgment about how this particular group will behave*. | **Restored.** FR134–FR137; D5–D8. A per-Character detail view, Author-private notes persisting across trips, and trip-scoped group/sub-group assignment with per-day and per-passage override. Deliberately **unquantified** — no cohesion score, ability index, or compatibility rating; the Author's knowledge goes in as prose and as arrangement, never as a metric. |

### A second failure mode, identified during the v2.0 review

The consolidation bias above is not the only way v1.0 lost meaning. **A short list of examples was repeatedly implemented as the complete set.** `historic=*`'s flat wildcard, the four "known over-triggering tags," FR128's routability table, FR111's Set tags, and FR105's monument-plus-toilets tuple all read as closed enumerations, because the rule that generated each list was never written down.

This is worse than it looks, because **plugins turn it from a limitation into a silent failure.** A plugin brings `battlefield`, `manor_house`, `covered_bridge`. No entry exists in the table. Co-location analysis runs, finds the co-location correctly, and proposes nothing — the flagship curation feature quietly not working with the extension mechanism built to feed it.

**The discipline, applied throughout v2.0 and carried in the punch list:** an enumerated list in a requirement is a **seed set** unless it says otherwise, and **the rule behind the list must be stated alongside it** — because if it isn't, the list will be implemented as the rule. FR98, FR105, FR111, and FR128 were rewritten on this basis.

### Requirements that v1.0 got *wrong* rather than merely thin

These four contradict v1.0 and must be reconciled downstream, not merely appended:

1. **FR91 / ARCH §7.3** — global readiness → per-capability readiness (FR121, M12a).
2. **FR8 / FR8a** — distance unconditionally banded → banded in explore, reported in compose (FR118).
3. **FR61** — "Web is scoped to the core loop" read as a limit on *all* web use → it limits web *planning* only (FR132).
4. **v1.0's node-or-edge scope call** — reversed by FR108.

---

## Appendix C — v2.0 Decision Log

| ID | Decision | Consequence |
|---|---|---|
| **D-A** | **Anchor with a role set.** One promoted object per place; roles are a set (narrative / provision / station), not a type field. Each role carries its own reveal policy, content, rendering, and itinerary placement. | FR106, FR107, FR110. Resolves the national-monument case: one anchor, one arrival, opposite reveal policies. |
| **D-B** | **Roles carry optional geometry, and areas are first-class.** Polygons for anchors and roles; role-level offsets from the anchor. **Reverses v1.0's node-or-edge scope call.** | FR107, FR108, FR126. Enables area clusters, polygon triggers, and rest-day authoring. |
| **D-C** | **"Plot point" is the term** for the narrative role. Plot points are the point in Plotlines. Provision and station stand. Passage and Set unsettled, non-blocking. | §4.3; Open Items. |
| **D-D** | **One bbox, drawn at trip initiation**, bounding layers, clusters, tiles, and elevation. **The invariant is that no *second, different* extent exists for analysis — not that the bbox is fixed**; it is revisable, with shrink prompting on affected anchors. **First start opens on a shipped home region with no prompt and no download**; trip creation prompts for a single location (prefilled with last-used) that centers the map only. **Two authoring extents**, plus the Character-side corridor buffer. | FR96, FR120; N1, A10. Gives clustering a bounded, precomputable domain and removes an eager download nothing had justified. Collapses ARCH D32/D41. |
| **D-E** | **Readiness is per-capability, not global.** Layer extraction and POI indexing first; elevation lazily in the background; routing gated with an honest indicator. | FR121, FR91 amended, M12a. **Breaking change to ARCH §7.3.** |
| **D-F** | **Two planning modes: explore and compose.** In compose, weights flavour and distance is a reported outcome with editorial affordances, not a solver failure. | FR117, FR118; scopes FR8, FR8a, FR5; reframes SPIKE-01. |
| **D-G** | **Modes switch in both directions, per day**, losing no work. Generate-then-keep-the-good-parts is designed, not accidental. | FR119; A0. |
| **D-H** | **Reveal is a role-level property.** Provisions always visible; narrative and station at the Author's choice; **hazards and cruxes always visible, enforced in the model**. Print and web inherit — the paper copy cannot spoil the trip. | FR114–FR116, FR124, FR64a; O5, P1, H13. |
| **D-I** | **Arrival is an event, consented through the existing profile-request mechanism.** Roster-visible, not Author-only, because regroup is the use case. Timestamp display is an Author option. Default nothing shared. | FR122, FR123, FR78a amended; P3, D4a, K2. No new consent machinery; stays inside the participant-tracking non-goal. |
| **D-J** | **No gamification.** No points, achievements, unlockables, dice, or randomness. Every route, branch, and reveal is authored and deterministic. | Brand Value 9; FR125; non-goal in §6.2. |
| **D-K** | **Role affinity is declared per type, single-valued, with Author override.** Every type in every layer's taxonomy declares one primary affinity (narrative / provision / station) plus a salience weight; clusters propose the union of affinities present. | FR100, FR105; N4, O1. Makes co-location analysis **generic rather than recipe-driven**, so plugin layers work the day they load. Gives the station role its first path from analysis. Single-valued so an Author is not made to adjudicate detail irrelevant to their story, and a layer author declares one thing per type rather than a matrix. |
| **D-L** | **An enumerated list in a requirement is a seed set, and the rule behind it is stated alongside it.** | FR98, FR105, FR111, FR128; Appendix B. v1.0's second failure mode: short example lists implemented as complete sets. Plugins turn that from a limitation into a silent failure — analysis runs, finds the cluster, and proposes nothing because no recipe matched. |
| **D-Q** | **Clone's contents are specified, and profile grants are excluded as a hard clause.** A clone carries roster membership, group assignments, and the whole authored trip; it never carries grants, arrival-visibility permission, or Character-layer state. **Named travel circles (FR143) are a living list, deferred to Later**; a trip's roster materializes from a circle at creation and is thereafter independent. | FR78 makes profile sharing per-trip and revisable by design. Carrying grants through a clone would make cloning a **consent-laundering path** — a Character who shared medical conditions for last year's supported tour would silently be sharing them on this year's unsupported one. "Clone everything" is the obvious implementation and the wrong one, so the exclusion is stated rather than assumed. **Author notes follow the person for free**, which is a consequence of D50's scoping rather than a new rule — useful confirmation the scoping was right. Circles are **living** because the useful thing about a recurring group is that it changes; rosters **materialize** because a roster in flight carries grants, group assignments, and gear responsibilities that must not shift underneath an Author mid-planning. | FR74, FR143; G2, D9. Circles depend on roster (FR136), invitations, and accounts (Leg 4) — none MVP — so **cloning a prior trip is the MVP answer** for a recurring group. |
| **D-P** | **Foundational usability is one requirement, not an epic**: session undo/redo over authored work, reachability of every created object, empty states carrying a next action, and **WCAG 2.2 AA** as a design-review target with a **formal audit gated before expansion beyond the Author desktop**. | The flow review exposed that the PRD specified **capabilities without reachability** — the unattached-anchor hole was one instance of a class, and patching instances one at a time is the pattern that produced eighteen recovered concepts. **Undo is unusually cheap here**: `trip.payload` is already one canonical serializable blob with a deterministic form (ARCH D28), so a session undo stack is a bounded ring of snapshots rather than command objects and inverse operations. **WCAG 2.2 AA** because it is the current W3C Recommendation and ISO/IEC 40500:2025; WCAG 3.0 is a Working Draft whose Bronze level approximates 2.2 AA, so meeting AA now is the head start rather than a detour. | FR142, FR142a; K12. **AA is a checklist at MVP, not a release gate** — a gate on an MVP is either theater or a reason not to ship. The audit is gated before surface expansion because every added surface multiplies remediation cost. Kept out: keyboard shortcuts, command palette, onboarding, responsive polish, cross-session undo. |
| **D-O** | **Authored work orphaned by an edit prompts with scope; derived work invalidated by an edit goes stale.** Two mechanisms, cleanly separated. Staleness escalates — passive while planning, blocking on export with a resolvable list, blocking with no override on print. **Re-solve-all is one unconfirmed action.** | The last structural gap in v2.0: nearly every requirement was written create-once, and the rule had already been decided twice (FR120 bbox shrink, FR81 compose reset) without being generalized. Deliberateness belongs where an action **destroys** authored work; requiring it to recompute derived work is bookkeeping, and Brand Value 1 says the strongest expression of authorship-over-configuration is work taken off the Author. Print blocks harder than export because a stale GPX is corrected by the next sync and a stale printed cue sheet is believed for eight hours. | FR139–FR141, FR140a; Epic Q. **The stale list is a distinct surface from M13's error enum** — stale work is pending work the Author caused deliberately, and routing it through the error surface would teach them that ordinary editing produces errors, the same defect as routing compose distance deviation there. |
| **D-N** | **Group-dynamics expertise is supported as prose and arrangement, never as metrics.** A per-Character detail view (FR134), Author-private notes scoped to Author + Character and persisting across trips with a visible last-updated date (FR135), Author-side deletion at three scopes (FR135a), and group/sub-group assignment on the **trip roster entry** with per-day and per-passage override (FR136). The card board (FR137) is a later, richer surface over the same data. | The eighteenth and last recovered concept, and the one v1.0 flattened hardest — into a size tier and a histogram. What an Author knows about a group is unstructured by nature ("never packs enough snacks, pair with Morgan"), so the honest home for it is a notebook, not a schema. Notes persist across trips because the knowledge is about the person; the date is visible because a three-year-old claim about someone's climbing is worse than none. Roster rather than profile because a person is in different groups on different trips. **Rejected: any quantification of people** — cohesion scores, ability indices, compatibility ratings — which would be unpleasant to fill in and sits badly beside Brand Value 9. | FR134–FR138; D5–D8, K11. Notes are the inverse of reveal: content that reaches a Character *never*, enforced at the same gate. They are also the first data Plotlines holds *about* a person *by someone other than that person*, which is what makes FR138's privacy statement an obligation rather than a courtesy. |
| **D-M** | **FR5 becomes a salience-based interest weight with no type parameter, and `detour_budget` is retired.** | FR5; A4; ARCH §7.3. Removes a duplicate surface (layer selection already says *what*) and stops biasing toward quantity, which meant boundary stones and street trees. Reframes the two modes as **machine-judged vs. Author-judged salience** rather than curated vs. uncurated. |

---

*End of Plotlines PRD v2.0.*
