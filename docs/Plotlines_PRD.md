# Plotlines — Product Requirements Document

**Version:** 1.0 (clean-sheet)
**Status:** Draft for Design engagement
**Supersedes:** Cycle Tour Planner PRD v2.1 (referenced for traceability only)

---

## 1. Vision

Plotlines is a platform for **authoring and experiencing curated multimodal adventures**. An Author brings expertise — knowledge of the terrain, the climbs, the water, the stories along the way — and shapes a journey that a group of Characters then lives out in the field.

The insight behind Plotlines is narrow and deliberate: the hard, generic parts of trip logistics are already solved by tools like RideWithGPS, and export interop is the intended bridge to them, not a gap to close. Plotlines earns its place by doing the two things those tools do *not* do well — **theme-driven route weighting** and **content curation** — and wrapping them in a narrative frame where the route is something an Author *writes* and a Character *reads*.

Everything in this PRD is selected against that thesis. Where the predecessor Cycle Tour Planner accumulated capability for its own sake, Plotlines pulls forward only what serves authorship, curation, and the multimodal journey — and deliberately leaves the rest behind.

---

## 2. Brand Values

These values are the filter for every requirement. A feature that doesn't serve one of them is a candidate for cutting, not adding.

1. **Authorship over configuration.** The Author is a creator, not a form-filler. Planning tools should feel like composing a journey, and the Author's expertise and voice should be visible in the result.
2. **Curation over parity.** Plotlines is not trying to match every logistics feature of existing platforms. It curates — themes, points of interest, the shape of a day — and hands off the rest through clean export.
3. **The journey is a story.** Routes have arc, context, and highlights. A Character experiences the Author's narrative, not just a GPX track.
4. **Quiet in the field.** In-field software should be calm: work offline without nagging, degrade gracefully, respect the device's battery, and never interrupt a ride with a modal.
5. **Portable and vendor-neutral.** A Character's device, head unit, or preferred platform is their choice. Plotlines exports cleanly and never traps a journey inside itself.
6. **Honest state.** The app always tells the truth about what it knows — how fresh a forecast is, whether data is synced, what's downloaded — plainly and without alarm.
7. **Organized and logical.** Keeping the story straight serves everyone. Structure is coherent and predictable — segments sequence sensibly, data has one clear home, decisions carry their rationale, and both Author and Character always know where they are and what comes next. A well-ordered plotline is what makes authorship feel effortless and the field experience feel calm.

---

## 3. Personas

**Author (Planner).** Designs adventures. Brings domain expertise across one or more travel modes. Curates routes by theme, marks the story beats, sets the logistics that matter for a group, and publishes a journey others can experience. May also participate as a Character in their own trip.

**Character (Adventurer/Participant).** Experiences an authored adventure in the field. Downloads the journey for offline use, follows curated routes and cue sheets, personalizes within the bounds the Author allows, exports to their own devices, and captures their own experience along the way.

**Any User.** Either role, acting on account-level concerns: profile, preferences, authentication, sync, storage, display.

**Developer.** Builds and maintains the platform. Concerned with the architectural seams that keep Plotlines simple to extend — themes as data, clean elevation and routing abstractions, and a maintainable client/backend split.

---

## 4. Scope & Non-Goals

### 4.1 In Scope

- **Routing core** (OSMnx + FastAPI backend, Dart/Flutter client) on Desktop and Web, with a Dart-first offline engine for Mobile.
- **Theme-driven route weighting**: climbing, traffic tolerance, surface distribution, POI density — each a weight, not a mode.
- **Multi-day trip logistics**: waypoints, daily distance/elevation splitting, route alternatives per day, lodging and campground data, group-size-aware planning, historical weather, and river gauge readings for paddling segments.
- **Content/curation layer**: POI narration, POI-themed trips, narrative arc, trip-scoped route/POI feedback, GeoJSON export.
- **Export pipeline**: GPX / TCX / FIT as the interop path to external platforms.
- **Lightweight accounts, sync, and a web option** for the core loop.
- **Simple offline mobile routing**: point-to-point within a downloaded map set.
- **GPS-aware in-field companion**: a position-aware glanceable cue sheet and GPS-triggered playback of authored POI/node narration, with the phone pocketed — distinct from real-time route guidance, which is out of scope.
- **A clean plugin interface** for community data inputs and export outputs — defined in principle, open in detail.

### 4.2 Explicit Non-Goals

These are deliberately *not* built. Each was a candidate carried over from Cycle Tour Planner and cut against the brand values.

- **Real-time route guidance.** Plotlines does not provide live turn-by-turn navigation, wrong-turn recalculation, or screen-centered "follow the blue line" guidance. Enough devices and apps do this well, and it pulls the Character's attention onto the screen — the opposite of the intended in-field experience. **This is distinct from GPS-aware content playback, which is in scope:** Plotlines uses GPS position to trigger authored narration and to advance a glanceable cue sheet while the phone stays pocketed (see FR26a, FR38a). The boundary is *the phone is a companion that speaks up at authored moments, not a nav device you watch.* Export to a dedicated head unit remains the path for those who want turn-by-turn on the handlebars.
- **Operating logistics as a platform, or social-platform parity with RideWithGPS.** Plotlines does not become the machinery that *runs* logistics — no live transit/flight-status feeds, no booking or reservation engine, no real-time participant tracking, no social graph (following/friends between strangers), and no public ride feed. Export is the bridge to platforms that do those things. **This is distinct from authored logistics content, which is in scope:** an Author records transit and access legs (flight numbers, shuttle carriers, scheduled times, links) as trip data and weaves a Character's arrival into the narrative (FR18, FR27, Story 17). The boundary is *the Author writes down and narrates the plan; Plotlines does not operate it.* Data flows to a single Author as the hub — Characters share their own travel details with the Author (opt-in, per-field, FR39), and the Author authors it into the journey. Characters do not coordinate travel with each other through Plotlines. *(This concerns pre-trip travel logistics — getting to the trailhead. It is distinct from in-field route intel: route amendments and field notes among participants on a live trip are intentionally in scope and peer-to-peer — see FR56, FR56a.)*
- **Full biometric/passkey auth stack.** Magic-link only for launch (see §7, Auth). Passkey/WebAuthn, QR cross-device binding, and multi-passkey management are deferred, not built now.
- **Guest→account claim/merge flow.** Guest access is stateless; the merge-on-signup flow is deferred.
- **Merge/diff conflict-resolution UI.** Sync uses a lightweight version check; on conflict the app prompts to reload rather than auto-resolving.
- **Shared server-side tile/elevation cache.** Deferred until real traffic justifies it; Web and Guest call the elevation provider directly, as Desktop does today.
- **"Fewest turns" route theme.** Removed as a standalone theme — it added configuration surface without serving curation.
- **Web planning parity with Desktop.** Web is scoped to the core loop (pick theme/shape/distance → generate → save → export), growing toward parity only if real usage justifies it.

### 4.3 Deliberately Simplified

Where Cycle Tour Planner over-engineered, Plotlines keeps the intent and drops the complexity:

- **Route themes** collapse into **weights**: flattest↔most-climbing is one weight; traffic tolerance is one weight; art/history becomes an Author-set **POI type** on the density weight — not a bespoke theme each.
- **Auth** collapses from a passkey cascade to magic-link.
- **Sync** keeps the version-checked conditional write and drops everything heavier.
- **Paddling difficulty** collapses from *routing constraint* to *advisory check*: the Author sets a gauge band, Plotlines shows the reading against it and warns. There is no class-rating weight and no ability-band route filter — SPIKE-04 established that no usable data source publishes per-reach difficulty, so those would have been configuration surface the engine could never honour. This is a simplification forced by evidence rather than chosen for elegance, and it is the one entry here that *lost* a capability rather than a mechanism.

---

## 5. Roadmap (Legs)

Plotlines inherits the "leg" structure from the rebrand-plan. Legs are capability tranches, roughly sequential, not hard gates.

| Leg | Theme | Disposition (per rebrand-plan) |
|---|---|---|
| **1–2** | Routing core, FastAPI, Desktop client, GPX/TCX/FIT export, security & QA hardening | **Done / kept as-is.** The foundation and the intended interop path. |
| **3** | Multi-day trip logistics — waypoints, daily splits, surface scoring, weighting, per-day alternatives, lodging/campground, group-size planning, historical weather, **river gauge readings (FR14a)** | **Keep, nearly all.** This is the differentiated territory. Gauge data joins weather here: both are external, time-varying, age-stamped reads against an authored plan, so they share a leg, a caching pattern, and a staleness rule. |
| **4** | Accounts, sync & Web | **Rescoped lighter.** Magic-link auth, core web loop, version-checked sync, stateless guest, direct elevation calls. |
| **5** | Mobile & offline | **Rescoped simple.** Point-to-point offline routing only; live navigation cut. |
| **6** | Content layer — POI narration, themed trips, trip-scoped feedback, GeoJSON export | **Keep as-is — and elevated.** The strongest anchor for the rebrand thesis. |
| **7** | Plugins / integrations | **Redefined.** Clean two-way interface: community data inputs + export outputs. Shape left open. |

**Hosting note (Leg 4):** Render remains the recommended platform — it matches the single-instance rate-limiter and CORS assumptions already in the architecture and needs no Dockerfile/k8s for FastAPI + Postgres + static web. Budget ~$13–14/mo once live for real users (≈$6–7 Postgres + ≈$7 web service) to avoid free-tier Postgres expiry and cold starts.

---

## 6. Functional Requirements

FRs are numbered fresh in Plotlines' own sequence. The **Origin** column traces each to the Cycle Tour Planner FR it derives from (or marks it new), for provenance only — Plotlines' numbering is canonical going forward.


### Routing & Themes

| FR | Requirement | Origin |
|---|---|---|
| **FR1** | The routing engine generates routes on an OSMnx graph via the FastAPI backend on Desktop and Web. | CTP core |
| **FR2** | A **climbing weight** ("peaks", 0.0–5.0, decimal) controls elevation gain/density along a continuous scale (flat ↔ maximal climbing), honoring origin/destination. | CTP FR1/FR2, Plotlines 10a |
| **FR3** | A **traffic-tolerance weight** ("cars", 0.0–5.0, decimal) balances quiet roads against direct urban egress via road-class/density thresholds. | CTP FR3, Plotlines 10b |
| **FR4** | A **surface weight** sets relative preference (0.0–5.0) across paved / gravel / singletrack. | CTP FR4, Plotlines 10d |
| **FR5** | A **POI-density weight** (0.0–5.0) biases toward more/fewer POIs, with the POI *type* set by the Author (subsumes the former "art/history" theme). | CTP FR5, Plotlines 10c |
| **FR6** | Authors set a **min and max** on any weighted route attribute — climbing, traffic exposure, surface mix, POI density, distance — and the engine searches weight space for a route whose *realized* values fall inside every band, finding good compromises across competing preferences. Bands bound the outcome ("400–600 m of climbing"), not the weight setting. | CTP, Plotlines Story 10; bound-the-attribute wording per SPIKE-03 |
| **FR7** | Route **shape** (loop, out-and-back, point-to-point) is selectable independently of weights. | CTP FR35 |
| **FR8** | Target **distance** is settable for loop and out-and-back shapes, seeding the engine's distance envelope. | CTP FR47, Plotlines 10c |
| **FR8a** | A **loop may be constrained to pass through one or more designated via-nodes** (rest stop, landmark, café, or any node) while returning to start, with weights and target distance still honored around the constraint. *Delivered in two stories: **A9** (one or two via-nodes, MVP) and **A9a** (three or more, P1) — beyond two, the via-nodes fix the loop's length and target distance becomes advisory rather than honored (SPIKE-01).* | New |
| **FR9** | When constraints conflict, the engine names the conflicting constraints and offers relaxations with their trade-offs — never a silent compromise or raw error. | CTP FR43 |

### Multimodal Routing & Domain Parameters

| FR | Requirement | Origin |
|---|---|---|
| **FR10** | Authors create **route segments** with a start, end, and primary travel mode, and Plotlines supports multiple modes as first-class (cycling, hiking, paddling, and further modes) rather than cycling-only. | Plotlines Story 2 |
| **FR11** | Authors **order and sequence** segments within a day to compose multimodal days, with a warning when adjacent segment endpoints fall more than a set distance apart. | Plotlines Story 3 |
| **FR12** | Authors place **transition nodes** between modes, marking where Characters switch activities, stash/retrieve gear, or execute put-ins/take-outs, with attached instructions. | Plotlines Story 15 |
| ~~**FR13**~~ | ~~Authors set **whitewater difficulty and water-type** weighting (flatwater ↔ whitewater, class rating) on paddling segments, so routing matches the group's ability and equipment.~~ **Removed — SPIKE-04.** No per-edge class rating exists in any usable data source, so a class weight has nothing to score against. See the decision log entry and §8. *(FR number retired, not reused.)* | Plotlines 10e/10f |
| **FR14** | Authors set an **advisory gauge band** (minimum/maximum flow or stage) on a paddling segment, and a **terrain technicality/exposure** level on a technical land segment. Plotlines shows the current reading against the band and warns outside it; it never filters or excludes routes on this basis. | Plotlines Story 18 |
| **FR14a** | Plotlines reads **river gauge data from USGS** (`api.waterdata.usgs.gov`) for gauged segments, age-stamps every reading, and states plainly when a segment has no gauge — surfaced to both Author and Character. Delivered in **Leg 3, alongside historical weather**, and following FR66's rule: a stale reading is labelled, never silently presented as current. | SPIKE-04 |
| **FR15** | Authors **draw portages and water-trail connections** on paddle segments — exit bank, portage distance, surface, elevation change, mandatory-hazard flag — calculated separately from water distance and auto-included in cue sheets/itineraries. The portage line is Author-drawn (SPIKE-04 found no open portage-route data); mapped hazards may be surfaced to prompt one. | Plotlines Story 23 |
| **FR16** | Authors configure **mode- and terrain-specific travel speeds** (e.g., pavement vs. singletrack, flatwater vs. moving water, ascent rate), choosing a system default, a custom Author pace, or the aggregated participant pace, feeding realistic moving time and ETAs. | Plotlines Story 29 |

### Multi-Day Trip Logistics (Leg 3)

| FR | Requirement | Origin |
|---|---|---|
| **FR17** | Authors define **adventure duration** (single-day, multi-day, multi-week) via start/end dates or a day count. | Plotlines Story 1 |
| **FR18** | Authors designate **Start, End, and Rest/Zero days**; rest days hold location, POIs, itinerary detail, and scheduled events without an active route. | Plotlines Story 9 |
| **FR19** | Authors split days with **per-mode min/max distance boundaries**, with an indicator when a segment breaches a threshold. | CTP FR10/FR20, Plotlines Story 20 |
| **FR20** | Authors attach per-day **alternate routes** (bypass/easier, extension/challenge) to any segment, across any mode, tagged clearly for Characters on maps and cue sheets. | CTP, Plotlines Story 19 |
| **FR21** | Authors place **waypoints, regroup points, and amenity-tagged rest stops** on a segment. | CTP, Plotlines Stories 4–5 |
| **FR22** | Authors define a **target group-size tier** (solo / small / party / large / event), reflected in logistics. | CTP, Plotlines Story 13 |
| **FR23** | Authors filter and place **lodging/campground** options on the planning map by type. | CTP, Plotlines Story 11 |
| **FR24** | Authors build **gear checklists** by mode — mandatory safety gear, shared group gear assignable to Characters, and personal lists Characters can check off. | Plotlines Story 32 |
| **FR25** | Authors mark **water sources, resupply points, and group meals** — potable vs. filter-required water, resupply with hours, meal responsibilities — with water-carry distances shown between sources. | Plotlines Story 33 |
| **FR26** | Authors attach **permits, land-access rules, and parking passes** to segments/nodes (status, confirmation numbers, documents/links), surfaced to Characters as a pre-trip checklist. | Plotlines Story 34 |
| **FR27** | Authors place **hazard and technical-crux warnings** on any route, transit leg, or node, with severity levels, safety notes, and required-gear callouts; high-severity markers trigger a distinct Character alert. | Plotlines Story 27 |
| **FR28** | Authors embed **scheduled, time-bound events** (tours, ferries, concerts, bookings) tied to a date/time window, with the timeline flagging conflicts when pace would miss the window. | Plotlines Story 28 |
| **FR29** | Authors build **transit/access legs** (drive, train, shuttle, flight) to trailheads/put-ins with identifiers, scheduled times, and links — authored trip data, not a live integration. | Plotlines Story 17 |
| **FR30** | Characters **share their own transit/arrival details** with the Author on a per-field, opt-in basis; the Author may author them into the narrative (FR40). Characters do not share travel details with each other through Plotlines. | Plotlines Story 17, FR55 |

### Planning Metrics & Group Mechanics

| FR | Requirement | Origin |
|---|---|---|
| **FR31** | A **real-time planning dashboard** shows distance and elevation by segment, day, total, and mode — and, with FR16, moving time / elapsed time / ETA — updating on every edit. | CTP, Plotlines Stories 21, 29 |
| **FR32** | Authors view **overlaid elevation-profile comparisons** for a primary route and its alternates in one view, colour-distinguished, with map-linked scrubbing. | Plotlines Story 22 |
| **FR33** | Authors view **historical weather** — a 5-year temperature range (box-and-whisker) for a segment, expandable to a 10-year distribution (±3 days) with precipitation volume and type. | CTP FR14, Plotlines Stories 7–8 |
| **FR34** | Authors review **aggregated group preferences** (climbing, traffic, surface, distance, speed, river class) with Min/Max/Avg/Mode, plus a histogram for groups over ten, filtered to whole-trip modes. | Plotlines Story 14 |
| **FR35** | Authors set the **offline data buffer distance** (corridor around the route) saved as a download parameter for the adventure package. | Plotlines Story 12 |

### Offset weighting scope

| FR | Requirement | Origin |
|---|---|---|
| **FR36** | Weight profiles **scope** to whole-tour, a single day, or a partial-day segment, overriding the tour default without re-planning the trip. | CTP FR13 scoping |

### Content & Curation (Leg 6 — the thesis)

| FR | Requirement | Origin |
|---|---|---|
| **FR37** | Authors attach **rich notes, instructions, and media** to any node (POI, waypoint, rest stop, transition, endpoint), and may weave shared Character details into that narrative. | CTP, Plotlines Story 6 |
| **FR38** | Authors tag route locations with **narrative-arc stages** (exposition, crux, climax, resolution), distinguished on map and timeline. | Plotlines Story 16 |
| **FR39** | Authors build **POI-themed trips** where the curated POIs are the organizing spine of the route. | Rebrand-plan Leg 6 |
| **FR40** | POIs support **audio narration** authored or attached by the Author, downloaded with the offline package. | Rebrand-plan Leg 6 |
| **FR41** | Authors set a **per-node narration trigger distance**, so a viewpoint announces far out while a turn-off announces close in. | New |
| **FR42** | Characters submit **trip-scoped feedback** on the current trip's routes and POIs, visible only to that trip's Author and Characters; fellow Characters can upvote/downvote, the Author sees all feedback and tallies, and incorporation into the plotline is manual. No cross-account or public content pool. | Rebrand-plan Leg 6, rescoped |
| **FR43** | Trips export to **GeoJSON** (RFC 7946) with custom feature properties for node types, modes, and metadata. | Rebrand-plan Leg 6 |

### Outputs & Interop

| FR | Requirement | Origin |
|---|---|---|
| **FR44** | Trips export to **GPX, TCX, and FIT**, with selectable contents (track+elevation, waypoints/stops, cue sheet, variants) and file splitting (single or per-day). | CTP FR9, Plotlines C14 |
| **FR45** | Exported waypoints, regroup markers, rest-stop names, and plot-point notes are **preserved as native course/turn points** where the target format supports them. | CTP FR9, Plotlines C14 |
| **FR46** | Authors generate **per-day cue sheets**, viewable in-app and printable, including surface shifts, node highlights, portages, hazards, and scheduled events. | CTP FR44, Plotlines Story 26 |
| **FR47** | The in-app cue sheet is **position-aware**: it advances with the Character's GPS location, highlighting current/next cue, glanceable in one look-down. Runs offline from raw GPS; the cached basemap is not in its critical path. | New |
| **FR48** | Authors generate a **master group itinerary** and **tailored individual itineraries** for partial-attendance Characters, retaining relevant notes and POIs, previewable/printable/exportable. | Plotlines Stories 24–25 |

### Field Execution (Character)

| FR | Requirement | Origin |
|---|---|---|
| **FR49** | Mobile plays a node's **narration automatically** when GPS enters the node's trigger distance (FR41), phone pocketed, fully offline from raw GPS, no data connection. | New |
| **FR50** | The Character's execution view is an **auto-updating cue HUD** with progress (e.g., mile X of Y), the next cue in focus, header readouts for remaining distance/elevation/ETA, expandable cue detail cards, and one-gesture toggle to the map. Active-scroll behavior is governed by device posture (FR50a). | Plotlines Story C22 |
| **FR50a** | The HUD runs in two **device postures** over the same underlying position and cue state: **Stowed** (screen off/dimmed, phone pocketed — GPS silently advances cue position and drives narration, no live rendering) and **Mounted** (screen on, handlebar/bow-bag — the HUD auto-scrolls to the next cue live). Switching postures re-syncs the view to current position; the app never auto-scrolls a screen no one is watching. | New |
| **FR51** | Cue distances and ETAs **dynamically recalculate** from actual GPS position and pace; passing/missing a cue advances the marker; toggling an alternate re-inlines its cues without a full reload. | Plotlines Story C23 |
| **FR52** | The cue HUD is **hands-free and glove-friendly**: oversized high-contrast type, ≥48dp touch targets, and optional volume-button/swipe stepping. | Plotlines Story C24 |
| **FR53** | Characters receive **hazard/crux alerts** — severity badges and gear notes, with a warning tone/header when their offline position nears a high-severity hazard. | Plotlines Stories 27, C11 |
| **FR54** | A **dead-zone odometer** holds last-known position on GPS loss and allows manual mileage scrolling of the cue sheet until signal returns. | CTP, Plotlines Story C20 |
| **FR54a** | Field execution uses **adaptive location accuracy**: a low-power tier for coarse node-proximity detection while stowed, escalating to high accuracy only near a narration/hazard trigger or when the screen is active — delivering FR67's power-saving behavior without sacrificing trigger reliability. | New |
| **FR55** | Any User can make an **in-field route amendment** offline — toggle a pre-planned alternate or draw a modification — updating the local map, elevation, and cue sheet, persisting locally and syncing when connectivity returns. | Plotlines Story 35 |
| **FR56** | A User may **publish a route amendment to the group**; connected members receive a notification, preview current-vs-proposed with updated distance/elevation/hazard metrics, and choose Accept / Decline / Select-Alternate, updating their own path independently. An amendment can carry a **severity/hazard flag and a free-text safety note** (e.g. "Bridge out — strainer river right, not crossable"), which elevates it to a warning-level broadcast to everyone approaching that point. | Plotlines Story 36 |
| **FR56a** | Any participant may pin a **field note** — a location-anchored, timestamped, advisory text note ("farmers market today, booth 12"; "lots of construction, we went this way") — to a point on the shared route. Field notes are peer-to-peer within the trip roster, surface to Characters as they approach that location, and change no one's route. They are **Author-anchored**: a note persists and keeps surfacing until the Author curates it into the plotline or dismisses it. | New (from the Story 36 discussion) |

### Accounts, Sync & Web (Leg 4 — rescoped)

| FR | Requirement | Origin |
|---|---|---|
| **FR57** | Users authenticate via **magic link** only; no password, no SMS OTP. Local planning works immediately; only account-scoped surfaces wait on sign-in. | CTP FR19, rescoped |
| **FR58** | Signed-in Users' trips and non-trip preferences **sync** across devices via a canonical per-account copy; each device keeps an offline-capable working copy. | CTP FR21 |
| **FR59** | Sync uses a **version-checked conditional write** on open and before save: on conflict, the User chooses save-as or overwrite — never a silent overwrite, no auto-merge UI. | CTP FR32 |
| **FR60** | **Guests** use the core loop (generate, view, export, both weather types) statelessly, with work persisted only in their own browser; nothing stored server-side; limits stated plainly. | CTP FR22 |
| **FR61** | The **Web client** is scoped to the core loop — pick theme/shape/distance → generate → save → export — not full Desktop parity. | Rebrand-plan Leg 4 |
| **FR62** | Web and Guest call the elevation provider **directly**; no shared server-side cache in this phase. | Rebrand-plan Leg 4 |

### Mobile & Offline (Leg 5 — rescoped simple)

| FR | Requirement | Origin |
|---|---|---|
| **FR63** | Mobile supports **simple point-to-point** route creation (A→B or current-location→destination) within a downloaded map set via the Dart-first offline engine — no offline elevation, no real-time route guidance. | Rebrand-plan Leg 5 |
| **FR64** | Characters **download a complete adventure package** (routes, cue sheets, node media, narration audio, basemaps within the buffer) in one action for fully-offline use. | CTP, Plotlines Story C13 |
| **FR65** | Offline behavior is **quiet**: offline-capable features show no offline messaging; a genuine limit surfaces once, inline, never modal; a passive indicator shows connectivity. | Rebrand-plan §"quiet in field" |
| **FR66** | Cached weather **forecasts are age-stamped** and never silently replaced by historical data; live forecast (within its 10-day horizon) overlays but never obscures the historical baseline. | CTP FR15, Plotlines C5 |
| **FR67** | The mobile app minimizes **GPS/CPU/network wake-ups** and keeps functioning under the device's OS power-saving mode. | CTP NFR |

### Portability & Durability

| FR | Requirement | Origin |
|---|---|---|
| **FR68** | The app **auto-saves local GeoJSON backups** of trip spatial layers on key edits and at intervals, protecting against crashes and network drops. | Plotlines Story S3 |
| **FR69** | Field notes, journals, and node highlights are stored as **portable Markdown** with relative image references and standard link syntax. | Plotlines Story S4 |
| **FR70** | Users **export a complete trip archive** (`.zip`) containing GeoJSON/GPX/TCX routes, Markdown journals, photo binaries, and a `manifest.json`, generated without choking the device. | Plotlines Story S5 |
| **FR71** | Users **restore/import a trip** from a Plotlines `.zip`, validating the manifest and media references before importing, with progress and a completion summary. | Plotlines Story S6 |
| **FR72** | Characters **log field notes, photos, and voice snippets** to nodes or days — private or shared to the group — stored on device first, then synced. | Plotlines Story C17 |
| **FR73** | Characters view a **post-trip recap** comparing planned vs. actual distance, moving time, and elevation by mode, combining Author narrative with Character logs into a keepsake record. | Plotlines Story C18 |

### Workspaces

| FR | Requirement | Origin |
|---|---|---|
| **FR74** | Authors have a **Trip Library / portfolio workspace** — grid/list of authored trips with thumbnails, key metrics, variant count, group size, and sync badge; filter by mode/duration; search; and per-card Edit / Manage Roster / Export / Clone actions. | Plotlines Story 37 |
| **FR75** | Characters have a **Trip Library / travel vault** — joined trips under Active/Upcoming, Offline Ready, and Completed/Archived, each card showing Author, attendance dates, modes, and offline badge, with one-tap download or export and links to recaps. | Plotlines Story C21 |
| **FR76** | Trip cards show **sync-status badges**: Cloud Synced, This Device, and Offline Ready. | Plotlines Story S8 |

### Any-User / Platform

| FR | Requirement | Origin |
|---|---|---|
| **FR77** | Users maintain a **profile** — nickname, email, phone, free-text home location, and travel/capability preferences (elevation/distance tolerance, surface, traffic, river class, moving speed) that seed trip defaults and populate the Author's aggregation. | CTP FR40, Plotlines S2/C6 |
| **FR78** | Profile sharing to an Author is a **per-field request/response**, defaulting to nothing shared. Responding to an Author's field request (FR78a), a Character may **grant requested fields, decline specific ones, and volunteer fields the Author did not request** (e.g. an allergy or medical condition). Sharing is always an explicit Character action, never a side effect of joining a trip. | CTP FR41, extended |
| **FR78a** | An Author **requests the specific profile fields** they need for a trip (e.g. climbing tolerance, distance, dietary preference), forming the request a Character responds to. The request is a default set the Author can adjust per trip; it never auto-grants access — the Character must respond. | New |
| **FR79** | Users configure **display and measurement preferences** — miles/km, °F/°C, light/dark/system, and indoor/outdoor contrast — applied live across all surfaces. | Plotlines Story S1, C19 |
| **FR80** | Users can **prune downloaded local content** to reclaim storage without affecting a current/upcoming trip. | CTP FR39 |
| **FR81** | Users have a single **reset** action reverting planning controls (theme, shape, start, destination, distance) to defaults and clearing the generated route. | CTP FR49 |
| **FR82** | An Author may **participate as a Character** in their own trip without a second account, counted in aggregations, headcounts, and rosters, merging Author tools with Character views. | Plotlines Story 31 |
| **FR83** | Users select an **application language**; UI, labels, and notifications localize live, defaulting to device locale (fallback English) and syncing when signed in. | Plotlines Story S9 |

### Plugins / Integrations (Leg 7 — redefined, open)

| FR | Requirement | Origin |
|---|---|---|
| **FR84** | Plotlines exposes a **clean two-way interface**: community-contributed **data inputs** that enhance routing, and **outputs** to other platforms. Concrete contract shapes are deliberately left open. | Rebrand-plan Leg 7 |

### Elevation Data (Provider & Handling)

Resolved via prior art from the cycling-tour-planner POC (`backend/ctp_core/elevation.py`) — see **SPIKE-18**.

| FR | Requirement | Origin |
|---|---|---|
| **FR85** | Plotlines' elevation source is **GEDTM30** (30 m global ensemble DTM fusing Copernicus DEM, ALOS World 3D, and ICESat-2/GEDI ground points), distributed by OpenTopography, used as the **single** elevation source with **no secondary/fallback elevation service** — GEDTM30 is already the best-available fused product, so a fallback adds complexity without improving coverage. | cycling-tour-planner POC (`backend/ctp_core/elevation.py`); SPIKE-18 |
| **FR86** | Elevation attribution (CC BY) appears both on the app's About/info surface and **embedded in exported files where the format permits** (e.g. GPX `<metadata>`); a missing attribution is a build failure, not a polish item. | ARCH §11.2/§12.4, extended; SPIKE-18 |
| **FR87** | OpenTopography's free non-academic API key is capped at **50 calls/24h**, and a paid Enterprise key is required once elevation is integrated into commercial software per OpenTopography's API Agreement. Plotlines' core app remaining free is what keeps Phase-1 elevation usage (FR62) within the free tier legally — this constrains both the architecture and any future monetization model. | cycling-tour-planner POC (`backend/ctp_service` config); SPIKE-18 |
| **FR88** | Elevation reads **never raise and never block a route solve**. A value present at a coordinate is used; a `nodata` sentinel — **including a raw NaN nodata value, checked explicitly via `isnan`, not `== ds.nodata`** — falls back to `0.0` (flat-earth), as does a coordinate outside every open raster's bounds or a raster missing/unreadable on disk. Each fallback is logged **at most once per raster path**, never once per coordinate. No network fetch may occur inside route computation. | cycling-tour-planner POC (`backend/ctp_core/elevation.py`, `test_elevation.py` — a real NaN-vs-`==` defect found and fixed there); SPIKE-18 |
| **FR89** | Elevation enrichment annotates every graph node with its elevation and every edge with `elev_gain = max(0.0, elev[v] - elev[u])` — **positive gain only** — matching ARCH §6.1's `enrich_elevation` contract. | cycling-tour-planner POC; SPIKE-18 |
| **FR90** | The shipped default region's elevation raster is distributed as a **versioned tarball asset**, extracted into a local cache by a documented one-time setup step. Windows setup extracts via `tar -C <dir>`, **never** PowerShell `>` redirection, which corrupts the binary raster. | cycling-tour-planner POC (`README.md`); SPIKE-18 |
| **FR91** | Elevation enrichment at sidecar startup is a **blocking, minutes-long** operation and must run off the request-handling event loop; per ARCH §7.3's existing readiness-not-liveness health semantics, a sidecar still enriching elevation must report itself **not ready**, never merely "up." | cycling-tour-planner POC (`backend/ctp_service/app.py`); ARCH §7.3, extended |

### Mapping & Tile Service Contract

FR92–FR94 are the POC-validated *contract*; **FR95 adds the source and licence, settled by SPIKE-14 (run 2026-08-15)** along with the rendering stack (ARCH D22) and the tooling and sizing questions (ARCH Q9/Q10).

| FR | Requirement | Origin |
|---|---|---|
| **FR92** | The client talks **only** to Plotlines' own tile service (`GET /tiles/{z}/{x}/{y}`, ARCH §7.2) for basemap tiles; it never contacts a third-party tile host directly. (Today's dev-time backend proxies to a public OSM tile server as a **temporary implementation**; the client-talks-only-to-us **contract is permanent** regardless of the upstream source — now Protomaps, FR95.) | cycling-tour-planner POC (`backend/ctp_service/app.py`); SPIKE-14 |
| **FR93** | The tile service **validates `z/x/y` against range** (`0 ≤ z ≤ 19`, `0 ≤ x,y < 2^z`) before doing any upstream work, rejecting out-of-range requests. | cycling-tour-planner POC (security review finding); SPIKE-14 |
| **FR94** | Tiles are generated and cached **bbox-scoped and on demand**, not served from a standing global tile server; the same cache/pipeline is the origin for both live map requests and offline adventure-package bundles (FR64) — one pipeline, not two. The elevation cache (FR85–91) follows the identical bbox-scoped, on-demand pattern under a separate cache. | cycling-tour-planner POC; SPIKE-14 |
| **FR95** | Basemap tiles come from the **Protomaps Basemap** (OpenStreetMap-derived), used under the **ODbL** as a Produced Work. The attribution **`© OpenStreetMap`**, linking to `https://www.openstreetmap.org/copyright`, appears on the About surface and anywhere a map is exported or printed. This is a **separate obligation from the elevation layer's CC BY (FR86), under a different licence — both are owed, and neither substitutes for the other.** Plotlines **mirrors** the tile source to its own storage rather than hotlinking the public build channel, which the source explicitly discourages; this is also what FR92 already requires. A missing attribution is a build failure, not a polish item. | SPIKE-14 (2026-08-15); ARCH D23 |


## 7. User Stories (INVEST)

Stories are organized by epic and expressed in INVEST form — **I**ndependent, **N**egotiable, **V**aluable, **E**stimable, **S**mall, **T**estable. Priority tags: **[MVP]** core launch, **[P1]** fast-follow, **[Later]** deferred but designed-for. Every Plotlines.md story is represented; where several collapse into one capability they are cited together.

### Epic A — Author: Theme-Driven Routing

**A1 — Weight a route by climbing** *[MVP]* — *FR2*
**As an** Author, **I want to** set a climbing weight ("peaks") on a 0.0–5.0 decimal scale **so that** I control how much elevation the day seeks or avoids.
*AC:* 0.0–5.0 with decimal precision; "peaks" terminology in UI; engine biases toward/away from gain relative to the setting while honoring origin/destination; total gain moves monotonically as the weight rises across regenerations.

**A2 — Weight a route by traffic tolerance** *[MVP]* — *FR3*
**As an** Author, **I want to** set a traffic-tolerance weight ("cars") 0.0–5.0 **so that** I trade quiet roads against direct urban egress.
*AC:* 0.0–5.0 decimal; "cars" terminology; engine factors road-class/vehicle-density thresholds by the setting; at low tolerance the route measurably favors lower road classes where an alternative exists.

**A3 — Weight a route by surface distribution** *[MVP]* — *FR4*
**As an** Author, **I want to** weight paved vs. gravel vs. singletrack 0.0–5.0 **so that** the route matches the group's equipment and desired character.
*AC:* Relative 0.0–5.0 weights per surface class; engine favors the highest-weighted surfaces; the route's surface breakdown is reported and shifts with the weights.

**A4 — Curate by POI density, type, and mileage** *[MVP]* — *FR5, FR8*
**As an** Author, **I want to** set POI density (0.0–5.0) and type alongside a target mileage range **so that** the route threads through the places I want without exceeding sensible distance.
*AC:* Density control plus Author-set POI type (e.g., waterfalls, overlooks); daily mileage min/max; engine maximizes high-value POIs of that type within the distance envelope; no separate "art/history" theme exists.

**A5 — Compromise across competing weights** *[MVP]* — *FR6*
**As an** Author, **I want to** set a min and max on each weighted attribute **so that** the engine finds good compromises when preferences pull against each other.
*AC:* Each weighted attribute accepts a min/max band on its **realized** value; engine returns a route within all bands where one exists; where none exists, A6 governs. Band controls open on the range the region can actually deliver at the chosen distance, not on a fixed absolute scale; band precision is floored in absolute units so a control cannot ask for a resolution the terrain cannot support.

**A6 — Understand why constraints conflict** *[MVP]* — *FR9*
**As an** Author, **I want** the planner to name conflicting constraints and offer relaxations with trade-offs **so that** I loosen the right one instead of hitting a dead end.
*AC:* On infeasibility the system names the specific conflicting constraints; offers nearest relaxations each stating its trade-off, applyable in one action; manual adjustment always available; never a raw error, never a silent drop.

**A7 — Choose route shape** *[MVP]* — *FR7*
**As an** Author, **I want to** pick loop, out-and-back, or point-to-point independently of weights **so that** geometry matches the day's logistics.
*AC:* Three shapes per segment; independent of weight profile; loop default; point-to-point requires a destination, loop/out-and-back require only a start.

**A8 — Target a distance** *[MVP]* — *FR8*
**As an** Author, **I want to** set a target distance for loop and out-and-back segments **so that** the day lands near the mileage I intend.
*AC:* Target-distance control for loop/out-and-back only; seeds the engine's distance envelope; point-to-point has no target-distance input.

**A9 — Route a loop through one or two designated nodes** *[MVP]* — *FR8a*
**As an** Author, **I want to** require a loop to pass through a chosen node (rest stop, landmark, café) while still returning to start **so that** the ride reaches a place that anchors the day without giving up the loop shape.
*AC:* One or two via-nodes designable on a loop; the generated route passes through each and returns to start; weights and target distance are still honored around the via-node(s); the route is a genuine loop rather than an out-and-back, and any road ridden twice is reported; if a via-node makes the loop infeasible within the distance envelope, A6's conflict-explanation path governs and names the via-node — not the terrain — as the binding constraint.
*Priority note (resolved 2026-08-14 by SPIKE-01): promoted from P1 to MVP. The condition the original note set was met literally — via-node, start, destination, loop, and out-and-back are one solver call with a different anchor list, and a 1-via loop is ~6× **faster** than an unconstrained one because the via replaces an anchor the engine would otherwise have to search for. Three or more via-nodes split out as A9a.*

**A9a — Route a loop through three or more designated nodes** *[P1]* — *FR8a*
**As an** Author, **I want to** require a loop to pass through three or more chosen nodes **so that** a day can be anchored to a whole sequence of places, not just one or two.
*AC:* Three or more via-nodes designable on a loop; the route passes through each and returns to start; **the target distance is presented as advisory rather than honored**, because past two via-nodes the nodes themselves determine the loop's length; the achieved distance and its deviation are surfaced, and A6's relaxation path is offered in the same interaction so the Author can widen the distance band, drop a via-node, or accept the deviation.
*Split from A9 on 2026-08-14 (SPIKE-01). Measured: at three via-nodes the distance error rose from under ±14% to +30.7% (Boulder) and +81.9% (Viroqua). The routing itself works — every via was hit and every loop closed — so this is a UI-and-expectations problem, not a solver one, which is why it is a separate story rather than a deferred capability.*

### Epic B — Author: Multimodal Composition

**B1 — Create multimodal route segments** *[MVP]* — *FR10*
**As an** Author, **I want to** create a segment with a start, end, and primary mode from cycling, hiking, paddling, and beyond **so that** each leg reflects its real activity.
*AC:* Start/end node placement; mode selectable from the supported list with cycling, hiking, and paddling as first-class equals; segment saved with endpoints and mode.

**B2 — Order and sequence segments in a day** *[MVP]* — *FR11*
**As an** Author, **I want to** assign and reorder segments within a day **so that** a single day flows through multiple modes in a logical order.
*AC:* One or more segments assignable to a day; reorderable to set transition sequence; warning when adjacent endpoints fall more than the set threshold (e.g. 500 m) apart.

**B3 — Define transition points** *[MVP]* — *FR12*
**As an** Author, **I want to** define transition nodes between modes **so that** Characters know where to switch activities, stash gear, or put in / take out.
*AC:* Transition node placeable between two segments; carries Author instructions (parking, gear stash, put-in/take-out); appears on Character timeline at the mode change.

> **B4 and B5 were removed after SPIKE-04 (2026-08-14).** Both depended on knowing the
> difficulty class of the water a route would cross, and no usable source publishes it:
> one graded feature across the three regions tested, 58 across all of North America, and
> the authoritative US inventory prohibits reuse. Their story numbers are retired rather
> than reused. The surviving, buildable half — an Author-set gauge band checked against a
> real reading — is **B8** below. See the decision log and §8.

**B6 — Define portages and water-trail connections** *[P1]* — *FR15*
**As an** Author, **I want to** draw portages with exit bank and trail characteristics **so that** Characters can execute water-to-land transitions safely.
*AC:* Portage line **drawn by the Author** on a paddle segment with exit bank (river left/right); portage distance, surface, and elevation change computed from that line, separately from water distance; mandatory portages (dams/falls) flag a prominent warning; auto-included in cue sheets/itineraries; entry/exit nodes can be rest/way/regroup points with notes. Mapped hazards (dams, weirs, falls) may be surfaced on the segment to prompt the Author to draw one — **but the app never claims a portage route it does not have**, because no open dataset carries them (SPIKE-04 §6).

**B7 — Model mode/terrain travel speeds** *[P1]* — *FR16, FR31*
**As an** Author, **I want to** configure travel speeds by mode and terrain **so that** metrics show realistic moving time and ETAs.
*AC:* Base speeds adjustable per mode and terrain (pavement/gravel/singletrack, flat/steep, flatwater/moving water); choose system default, custom Author pace, or aggregated participant pace; dashboard updates moving time, elapsed time (incl. stops), and ETA; itineraries show elapsed time beside distance and elevation.

**B8 — Set a gauge band and see the river's level against it** *[Leg 3]* — *FR14, FR14a*
**As an** Author on a paddling segment, **I want to** set a minimum and maximum flow or stage and see the current reading against it **so that** I know whether the trip I am planning is runnable — and so that Characters know on the morning of the trip.
*AC:* Author sets a min/max band per paddling segment, choosing the unit (cubic feet per second **or** gauge height — SPIKE-04 §5 confirmed USGS publishes both, and paddlers quote flow more often than stage). Terrain technicality/exposure is settable on technical land segments as an Author-declared level. The segment shows the governing gauge's latest reading, **age-stamped**, and warns when the reading sits outside the band. A segment with no gauge says so plainly rather than showing a blank or a guess. **The band is advisory: it warns, it never excludes or reroutes.** Author and Character see the same reading and the same warning.

### Epic C — Author: Multi-Day Logistics

**C1 — Define adventure duration** *[MVP]* — *FR17*
**As an** Author, **I want to** set single-day, multi-day, or multi-week duration **so that** the structure fits the group's time.
*AC:* Start/end date or day count; all three duration classes supported.

**C2 — Set start, end, and rest days** *[MVP]* — *FR18*
**As an** Author, **I want to** mark Start, End, and Rest/Zero days **so that** I can pace the trip around lodging and amenities.
*AC:* Any day markable Start/End/Rest; rest days hold location without an active route; rest days can carry POIs, itinerary detail, and scheduled events.

**C3 — Set daily distance boundaries by mode** *[MVP]* — *FR19*
**As an** Author, **I want** per-mode min/max distance per day **so that** daily effort stays within the group's limits.
*AC:* Per-mode min/max per day; indicator/warning when a segment breaches a threshold; reflected in the dashboard.

**C4 — Offer alternate routes per day** *[MVP]* — *FR20*
**As an** Author, **I want to** attach bypass/easier and extension/challenge alternates **so that** Characters match the day to their condition.
*AC:* Secondary path tagged Bypass/Easiest or Extension/Challenge; available across any mode; both visible to Characters on map and cue sheet.

**C5 — Place waypoints, regroup points, rest stops** *[MVP]* — *FR21*
**As an** Author, **I want to** mark waypoints, regroup points, and amenity-tagged rest stops **so that** a mixed-pace group has rally points and known services.
*AC:* Nodes placeable on a segment; a waypoint can be flagged a regroup point; rest stops carry amenity tags (water, toilets, food, shelter).

**C6 — Set group size** *[P1]* — *FR22*
**As an** Author, **I want to** set a group-size tier **so that** logistics, rest stops, and lodging scale to the group.
*AC:* One tier (solo / small / party / large / event); saved to trip metadata; downstream logistics reflect it.

**C7 — Place lodging and campgrounds** *[P1]* — *FR23*
**As an** Author, **I want to** filter and place lodging on the map **so that** accommodations fit the group.
*AC:* Filter by type (campsite, hotel, hut, hostel); overlays update with filters; placed lodging attaches to the day.

**C8 — Build gear checklists** *[P1]* — *FR24*
**As an** Author, **I want** mode-specific gear lists with shared-gear assignment **so that** Characters pack exactly what each segment requires.
*AC:* Mandatory and recommended gear attachable per mode; items designatable Shared Group Gear and assignable to Characters; Characters see a consolidated personal+assigned list and check items off.

**C9 — Mark water, resupply, and meals** *[P1]* — *FR25*
**As an** Author, **I want to** mark water points, resupply stops, and group meals **so that** Characters manage hydration and nutrition between supply points.
*AC:* Water points tagged potable or filter-required; resupply points with hours and notes; meal responsibilities assignable; itineraries show water-carry distance between sources.

**C10 — Track permits, access, and passes** *[P1]* — *FR26*
**As an** Author, **I want to** attach permits, access rules, and parking passes to segments/nodes **so that** Characters arrive with the right permissions.
*AC:* Permit status tags (required / self-register / pass required); confirmation numbers, documents, or links attachable; Characters get a pre-trip permit/pass checklist.

**C11 — Warn of hazards and cruxes** *[MVP]* — *FR27*
**As an** Author, **I want to** place hazard and technical-crux warnings with severity and gear notes **so that** Characters are alerted to high-risk terrain in advance.
*AC:* Hazard/crux marker attachable to any route, transit leg, or node; severity levels (caution / high hazard / mandatory re-route) with safety notes and gear callouts; highlighted on map, elevation, itineraries, cue sheets; high-severity triggers a distinct Character alert on sync.

**C12 — Embed scheduled events** *[P1]* — *FR28*
**As an** Author, **I want to** schedule time-bound events into a day **so that** routing and arrivals align with fixed times.
*AC:* Scheduled-event node with date and time window and location; attachable to mid-route or day-end nodes; timeline flags a conflict when planned pace would miss the window; events populate itineraries, cue sheets, and the mobile timeline.

**C13 — Build transit and access legs** *[P1]* — *FR29*
**As an** Author, **I want to** add drive/train/shuttle/flight legs to trailheads and put-ins **so that** Characters have end-to-end travel in one place.
*AC:* Transit legs carry identifiers, carrier, scheduled times, and links; attach to trip start/end or a day; stored as authored data with no live-status or booking integration; render in itineraries.

**C14 — Set the offline buffer distance** *[P1]* — *FR35*
**As an** Author, **I want to** set the corridor buffer for offline downloads **so that** Characters get enough surrounding map context without oversized files.
*AC:* Buffer distance enterable/selectable (mi/km from route); saved as a download parameter for the package.

**C15 — Scope a weight profile to a day or segment** *[P1]* — *FR36*
**As an** Author, **I want to** override the tour's weight profile for one day or partial segment **so that** I can front-load climbing or favor gravel without re-planning.
*AC:* Tour-level default; override at day or partial-segment scope; override applies only in scope; re-scoring touches only the affected scope.

### Epic D — Author: Metrics, Weather & Group Insight

**D1 — Watch planning metrics live** *[MVP]* — *FR31*
**As an** Author, **I want** a dashboard of distance, elevation, and time by segment/day/total/mode **so that** I judge each edit immediately.
*AC:* Persistent panel with active-segment, day-total, and trip-total distance and elevation by mode; with FR16, moving time / elapsed time / ETA; updates on every add/edit/reorder.

**D2 — Compare elevation profiles across options** *[P1]* — *FR32*
**As an** Author, **I want to** overlay elevation profiles for a route and its alternates **so that** I compare climbing and steepness without toggling.
*AC:* Primary and all alternates render together, colour-distinguished; hover/scrub highlights the corresponding map point across all shown options.

**D3 — Read historical weather** *[P1]* — *FR33*
**As an** Author, **I want** historical temperature and precipitation for a segment and date **so that** I anticipate conditions.
*AC:* 5-year box-and-whisker temperature for the location, with all-time high/low as bounds; expandable to a 10-year distribution ±3 days with precipitation volume and type; clearly labeled historical, never conflated with forecast.

**D4 — Review aggregated group preferences** *[P1]* — *FR34*
**As an** Author, **I want** submitted Character preferences aggregated **so that** I design routes fitting the group's collective ability.
*AC:* Aggregates climbing/traffic/surface/distance/speed/river-class with Min/Max/Avg/Mode; histogram for groups over ten; only whole-trip-mode preferences shown; accessible in the planning dashboard.

**D4a — Request the profile fields I need** *[P1]* — *FR78a*
**As an** Author, **I want to** request the specific profile fields a trip needs from each Character **so that** I get the attributes that matter for this trip without demanding everything by default.
*AC:* Author selects the fields to request per trip (from a sensible default set, adjustable — e.g. add river-class for a paddling trip, drop dietary for a self-catered one); the request goes to each Character to respond to (K2); requesting never auto-grants access; the Author sees, per Character, which requested fields were granted, which were declined, and any fields the Character volunteered unprompted (e.g. an allergy or medical condition), so nothing shared for safety is buried.

### Epic E — Author: Curation & Narrative *(the thesis)*

**E1 — Attach notes and media to nodes** *[MVP]* — *FR37*
**As an** Author, **I want to** attach rich notes and media to any node **so that** Characters get my context where it matters.
*AC:* Rich text + media on any node; saved per node; visible to Characters at that location; can weave shared Character details into narrative (e.g., "Bob arrives by train Tuesday morning, shoulders his pack, and walks 3 km to the trailhead to meet the group").

**E2 — Mark the narrative arc** *[P1]* — *FR38*
**As an** Author, **I want to** tag locations with arc stages **so that** the journey reads as a story.
*AC:* Arc-stage tags (exposition, crux, climax, resolution) on segments/nodes; distinguished on map and timeline.

**E3 — Build a POI-themed trip** *[P1]* — *FR39*
**As an** Author, **I want to** organize a route around a curated POI set **so that** the points of interest *are* the journey.
*AC:* POIs selectable as the organizing set; engine threads them within the distance envelope; the trip presents them as its spine.

**E4 — Add POI audio narration** *[P1]* — *FR40, FR41*
**As an** Author, **I want to** attach audio narration to a POI and set its trigger distance **so that** Characters hear the story hands-free at the right moment.
*AC:* Audio attachable per POI; per-node trigger distance settable (far for a viewpoint, near for a turn-off); audio downloads with the offline package; plays from the node card and via GPS trigger (H2).

**E5 — Export a journey as GeoJSON** *[P1]* — *FR43*
**As an** Author, **I want to** export a trip as RFC-7946 GeoJSON **so that** the journey is portable to any geospatial tool.
*AC:* Valid GeoJSON with custom feature properties for node types/modes/metadata; round-trips through standard GIS readers.

### Epic F — Author: Outputs

**F1 — Generate daily cue sheets** *[MVP]* — *FR46*
**As an** Author, **I want** per-day cue sheets **so that** Characters have reliable directions on screen or paper.
*AC:* Per-day cues with turns, distances, surface shifts, node highlights, portages, hazards, and scheduled events; syncs to Character offline; print-optimized layout.

**F2 — Generate group and individual itineraries** *[P1]* — *FR48*
**As an** Author, **I want** a master itinerary and tailored individual ones **so that** partial-attendance Characters get accurate personal plans.
*AC:* Master aggregates days/routes/modes/POIs/rest stops/lodging; individual reflects only that Character's days/segments/transit and retains relevant notes/POIs; both previewable, printable, exportable (e.g. PDF).

**F3 — Configure export contents and splitting** *[MVP]* — *FR44, FR45*
**As an** Author, **I want to** choose export contents and splitting **so that** each Character gets what their device needs.
*AC:* GPX/TCX/FIT; toggle track+elevation, waypoints/stops, cue sheet, variants; single or per-day files; native course/turn points and plot-point notes preserved where supported.

### Epic G — Author-as-Participant & Workspace

**G1 — Participate in my own trip** *[P1]* — *FR82*
**As an** Author, **I want to** join my own trip as a Character without a second account **so that** I get offline packages and Character views while keeping my Author tools.
*AC:* "Participate as Character" toggle; generates a Character profile counted in aggregations/headcounts/group size; app merges Author edit tools with Character execution views; rosters and itineraries list the Author as a participant.

**G2 — Manage my trip library** *[P1]* — *FR74, FR76*
**As an** Author, **I want** a portfolio workspace **so that** I can find, organize, and launch trips.
*AC:* Grid/list of authored trips with thumbnail, title, modes, distance/elevation, day count, variant count, group size, and sync badge; filter by mode/duration and search by title/location; per-card Edit Route / Manage Roster & Preferences / Export Backup / Clone.

### Epic H — Character: Experience the Journey

**H1 — View my itinerary** *[MVP]* — *FR48*
**As a** Character, **I want to** view the master or my individual itinerary **so that** I understand scope, daily stages, lodging, and my arrival/departure.
*AC:* End-to-end timeline on mobile/web; personalized dates if partial; daily start/end, distance, and modes shown.

**H2 — Hear authored narration as I reach it** *[MVP]* — *FR49, FR41*
**As a** Character with my phone pocketed, **I want** a node's narration to play when I reach the Author-set distance **so that** I experience the story hands-free.
*AC:* Fires when GPS enters the node's trigger distance; plays with no screen interaction, phone pocketed; runs fully offline from raw GPS, no data connection; far trigger announces ahead, near trigger announces close; audio included in the offline package (H7).

**H3 — Inspect multimodal days and transitions** *[MVP]* — *FR11, FR12*
**As a** Character, **I want to** see each day broken down by mode and transition **so that** I know when and how we switch activities.
*AC:* Timeline distinguishes mode changes (drive → transition → bike → paddle); transition nodes show Author instructions for parking, gear stash, or equipment switches.

**H4 — See regroup points and rest-stop amenities** *[MVP]* — *FR21*
**As a** Character, **I want to** see regroup points and amenity-rich rest stops **so that** I know where to rally and what services to expect.
*AC:* Regroup points highlighted mandatory/optional; rest stops show tagged amenities and distance to the next amenity cluster.

**H5 — Access node notes and story highlights** *[MVP]* — *FR37, FR38*
**As a** Character, **I want to** tap nodes and plot points to read the Author's notes, media, and narrative **so that** I experience the curated context.
*AC:* Node tap opens a content card (text/media); arc stages distinguished on map/timeline.

**H6 — Personalize within the Author's bounds** *[P1]* — *FR6, FR20*
**As a** Character, **I want to** set my own weighting on Author-variable parameters and toggle alternates **so that** the day fits me without leaving the trip.
*AC:* Author-variable parameters Character-adjustable (0.0–5.0); locked ones visible but fixed; personal choices produce a Character-scoped variant that never alters the Author's canonical route; metrics update on toggle.

**H7 — Download for offline use** *[MVP]* — *FR64*
**As a** Character, **I want to** download the full adventure package before departure **so that** I have maps, routes, cues, media, and narration with zero connectivity.
*AC:* One "download for offline" packages routes, cue sheets, node media, narration audio, and basemaps within the buffer; full function in airplane mode, including GPS-triggered narration (H2) and the position-aware cue sheet (I1).

**H8 — Review weather forecast vs. baseline** *[P1]* — *FR66*
**As a** Character, **I want** the live forecast (within its 10-day horizon) overlaid on the historical baseline **so that** I pack for expected ranges.
*AC:* Active forecast shown alongside historical ranges for the corridor; deviations highlighted; forecast never removes or obscures historical; forecast is age-stamped with a short cache expiry.

**H9 — Submit my capability and preference profile** *[P1]* — *FR77*
**As a** Character, **I want to** submit my thresholds (climbing, river class, distance, speed, surface, traffic) **so that** the Author can build trips matching my ability.
*AC:* Profile captures the listed fields; feeds the Author's aggregation automatically (D4); shared per the opt-in field controls (K2).

**H10 — Inspect elevation profiles and comparisons** *[P1]* — *FR32*
**As a** Character, **I want to** view daily elevation profiles and compare alternates **so that** I understand steepness and gain before starting.
*AC:* Profile highlights steep-grade % and gain; scrubbing tracks the map position marker; alternates comparable side-by-side.

**H11 — Inspect portage and water details** *[P1]* — *FR15*
**As a** Character on a paddling trip, **I want** portage callouts with exit bank, land distance, surface, and hazard severity **so that** I execute water-to-land transitions safely.
*AC:* Portage alerts show exit side, carry distance, and trail grade; mandatory portages render prominent safety banners in app and cue sheet.

**H12 — Submit trip feedback for the Author** *[P1]* — *FR42*
**As a** Character on a trip, **I want to** submit feedback on the trip's routes and POIs that the Author and my fellow Characters can see and vote on **so that** useful observations surface to the Author, who decides what to fold into the plotline.
*AC:* Feedback attaches to a route, segment, or POI within the current trip and is visible only to that trip's Author and Characters — never to a cross-trip or public pool; fellow Characters can upvote/downvote each item; the Author sees all feedback with its vote tally and author; incorporation is manual — the Author edits the plotline in response, and Plotlines never auto-applies feedback to the route or content. No moderation queue, reputation system, or cross-account content store is implied.

### Epic I — Character: Field Execution

**I1 — Glance at a position-aware cue sheet** *[MVP]* — *FR47*
**As a** Character, **I want** the cue sheet to track my position and highlight current/next cue **so that** a glance tells me where I am and what's next.
*AC:* Advances with GPS, highlighting current + next cue; readable in one look-down; advances offline from raw GPS with the basemap out of the critical path; never demands sustained attention.

**I2 — Use the auto-updating cue HUD** *[MVP]* — *FR50*
**As a** Character, **I want** a live cue HUD **so that** I see upcoming turns and metrics without digging through map layers.
*AC:* Active trip opens to the HUD with a progress readout (e.g., mile 14.2 of 38.5); the next cue is in focus with distance remaining; header shows remaining distance, elevation, and ETA; tapping a cue expands notes/photos/hazards/transitions; one gesture toggles to the map. Live auto-scroll is governed by device posture (I2a).

**I2a — Choose stowed or mounted posture** *[MVP]* — *FR50a*
**As a** Character, **I want** the HUD to behave differently when my phone is pocketed versus mounted **so that** it speaks up and tracks silently in my pocket but auto-scrolls live on my handlebars — without wasting battery drawing a screen no one sees.
*AC:* Two postures over the same position/cue state — **Stowed** (screen off/dimmed: GPS silently advances cue position and fires narration/hazard alerts, no live rendering) and **Mounted** (screen on: HUD auto-scrolls to the next cue live); switching posture re-syncs the view to current position so pulling the phone from a pocket shows the correct current cue immediately; the app never auto-scrolls while stowed; posture follows screen state and is manually overridable.

**I3 — Get dynamic cue/ETA recalculation** *[MVP]* — *FR51*
**As a** Character, **I want** cue distances and ETAs to recalc from my actual position and pace **so that** the sheet stays accurate through late starts, rests, and detours.
*AC:* Passing/missing a cue advances the marker; remaining ETAs (incl. events, rests, regroups) update live with pace; toggling an alternate inlines its cues and removes bypassed ones without a full reload.

**I4 — Navigate hands-free and glove-friendly** *[P1]* — *FR52*
**As a** Character riding, hiking, or paddling with gloves, **I want** large controls and high-visibility type **so that** I interact with single taps or gestures.
*AC:* Oversized high-contrast type and directional arrows for daylight; ≥48dp touch targets; optional volume-button/swipe stepping through cues without precise targeting.

**I5 — Receive hazard and crux alerts** *[MVP]* — *FR53*
**As a** Character, **I want** prominent alerts approaching Author-designated hazards **so that** I'm warned of rough access, exposure, or big rapids in advance.
*AC:* Severity badges and gear notes; a warning tone/header when offline position nears a high-severity hazard.

**I6 — Keep navigating through GPS dead zones** *[P1]* — *FR54*
**As a** Character losing GPS in cover or canyons, **I want** the app to hold last-known position and let me scroll mileage manually **so that** I navigate by landmark and distance until signal returns.
*AC:* Holds last-known position on signal loss; manual mileage scrolling of the cue sheet; resumes automatically when GPS returns.

**I6a — Preserve battery with adaptive location accuracy** *[MVP]* — *FR54a*
**As a** Character on a long day with limited battery, **I want** the app to sip location power while stowed and only spend high-accuracy GPS when it matters **so that** narration and cues stay reliable without draining my phone before the finish.
*AC:* Low-power/coarse location tier drives node-proximity detection while stowed; escalates to high accuracy only near a narration or hazard trigger, or when the screen is active for the cue HUD; the switch is automatic and invisible to the Character; narration and hazard triggers still fire reliably at their Author-set distances; no network wake-ups are introduced.

**I7 — Create simple point-to-point routes offline** *[P1]* — *FR63*
**As a** Character, **I want to** make a quick A→B route within my downloaded map set **so that** I can improvise off-plan without connectivity.
*AC:* Point-to-point (or current-location→destination) within the downloaded set via the Dart-first engine; no offline elevation, no real-time route guidance; result exports like any route.

**I8 — Amend a route in the field** *[P1]* — *FR55*
**As a** User in the field, **I want to** toggle a pre-planned alternate or draw a modification offline **so that** my local views and cues update when I hit a washout or high water.
*AC:* Toggle an alternate or draw a modification on the offline map; local map layer, elevation, and cue sheet update; edits persist locally and auto-sync when connectivity returns.

**I9 — Publish and evaluate route amendments** *[P1]* — *FR56*
**As a** participant who rerouted in the field, **I want to** publish the amendment to the group and evaluate others' **so that** we adopt necessary changes — especially safety-critical ones — while keeping control of our own path.
*AC:* Any participant can publish; connected members get a notification with a change summary; recipient sees current-vs-proposed with updated distance/elevation/hazard; can Accept, Decline, or Select-Alternate; declining/selecting updates that individual's path independently. An amendment can be flagged **hazard/high-importance with a free-text safety note** ("Water source dry", "Bridge out — strainer river right, not crossable"); flagged amendments surface as a warning-level alert (I5-style) to everyone approaching that point, not just as a route diff.

**I9a — Pin a field note for the group** *[P1]* — *FR56a*
**As a** participant seeing something worth sharing, **I want to** pin a short note to a spot on our route **so that** others approaching it benefit from what I just learned — without changing anyone's route.
*AC:* Note is location-anchored and timestamped, attached to a point on the shared route; posts peer-to-peer to the trip roster (no Author relay required, since the Author may be riding and unreachable); advisory only — it never alters a recipient's route, cues, or metrics; attributed to its poster; syncs when connectivity allows.

**I9b — Receive field notes as I approach** *[P1]* — *FR56a*
**As a** Character on the route, **I want** pinned field notes to surface as I near their location **so that** I get timely, local intel ("farmers market today, booth 12"; "construction, we detoured here") in context.
*AC:* A note surfaces as the Character approaches its pinned location, shown with its text, poster, and age; dismissible per-Character; persists and keeps surfacing to others until the Author curates it into the plotline (e.g. promotes it to a permanent POI/hazard) or dismisses it for the group; distinguished from Author-authored content so provenance is clear.

### Epic J — Character: Capture & Keepsake

**J1 — Log field notes, photos, and voice** *[P1]* — *FR72*
**As a** Character, **I want to** attach personal notes, photos, and voice snippets to nodes or days **so that** I capture my experience alongside the Author's plotlines.
*AC:* Attachable to any node or track coordinate during/after a trip; private or shareable to the group; stored on device first, then synced.

**J2 — See a post-trip recap** *[P1]* — *FR73*
**As a** Character, **I want** a recap comparing planned vs. actual **so that** I review the journey and keep a record.
*AC:* Planned-vs-actual distance, moving time, and elevation by mode; combines Author narrative with Character logs into a digital keepsake.

**J3 — Manage my trip vault** *[P1]* — *FR75, FR76*
**As a** Character, **I want** a personal library of my trips **so that** I manage downloads, cue sheets, exports, and recaps.
*AC:* Trips under Active/Upcoming, Offline Ready, Completed/Archived; each card shows Author, my attendance dates, modes, offline badge; one-tap download or export from the card; completed trips link to recap, photos, and journal.

### Epic K — Any User: Account & Platform

**K1 — Sign in with a magic link** *[MVP]* — *FR57*
**As a** User, **I want** passwordless magic-link sign-in **so that** I authenticate without a password or SMS code.
*AC:* Magic link is the only auth and the recovery path; no password, no SMS OTP; local planning works immediately, only account-scoped surfaces wait.

**K2 — Respond to an Author's profile request** *[P1]* — *FR77, FR78*
**As a** Character, **I want to** respond to the profile fields an Author requests — granting what I choose, declining specific fields, and volunteering fields they didn't ask for — **so that** the Author has the attributes they need to plan the best trip while I stay in control of my data.
*AC:* Profile captures nickname/email/phone/home-location and travel/capability preferences; Character sees exactly which fields the Author requested; can grant the requested set, decline individual fields within it, and add fields the Author did not request (e.g. dietary preference on a self-catered trip, or an allergy/medical condition absent from the default request); nothing is shared until the Character responds; default is nothing shared; the response is per-trip and revisable; preference fields still seed weight defaults that per-trip/day/segment scope can override.

**K3 — Sync across my devices** *[MVP]* — *FR58, FR59*
**As a** signed-in User, **I want** trips and preferences to sync via a canonical copy with a version check **so that** I plan on desktop and execute on mobile without losing edits.
*AC:* Canonical server copy; local working copy functions offline; on open and before save the client compares versions; if server is newer, User chooses save-as or overwrite; never silent overwrite; guests excluded.

**K4 — Use Plotlines as a guest** *[MVP]* — *FR60, FR61*
**As a** Guest, **I want to** generate, view, and export in the browser with no account **so that** I can try Plotlines or ride a route planned for me with zero setup.
*AC:* Core loop + export + both weather types with no account; work persists in the browser across refresh; nothing stored server-side; limits stated plainly (same browser only, lost on cleared data/incognito, no sync/share-back).

**K5 — Configure display and measurement preferences** *[MVP]* — *FR79*
**As a** User, **I want to** set units, theme, and contrast **so that** everything matches my standards and viewing conditions.
*AC:* Miles/km, °F/°C, light/dark/system, indoor/outdoor contrast; changes apply live across charts, cue sheets, dashboards, maps, and weather on web and mobile; mobile defaults outdoor, desktop indoor, override synced.

**K6 — Set my language** *[P1]* — *FR83*
**As a** User, **I want to** pick my app language **so that** UI, labels, and notifications appear in my language.
*AC:* Language menu in native scripts; defaults to device locale, falls back to English; switching updates static UI live without restart; preference saved and synced when signed in.

**K7 — Prune downloaded content** *[P1]* — *FR80*
**As a** User, **I want to** delete downloaded maps/elevation I no longer need **so that** I reclaim storage safely.
*AC:* View downloaded content with footprint; delete anything not needed for a current/upcoming trip; a delete affecting an upcoming trip warns first; N/A on Web.

**K8 — Reset planning controls** *[MVP]* — *FR81*
**As a** User, **I want** one action to revert planning controls and clear the route **so that** I back out cleanly.
*AC:* Always-visible reset; reverts theme, shape, start, destination, distance to defaults and clears any generated route; no per-control interaction.

**K9 — See sync/offline status at a glance** *[P1]* — *FR76*
**As a** User, **I want** clear status badges on trip cards **so that** I know my data is backed up before going offline.
*AC:* Cards show Cloud Synced, This Device, and Offline Ready distinctly.

### Epic L — Portability & Durability

**L1 — Auto-back-up trips locally as GeoJSON** *[P1]* — *FR68*
**As a** User editing an adventure, **I want** automatic local GeoJSON backups **so that** my edits survive crashes and network drops.
*AC:* Auto-saves spatial layers (routes, alternates, waypoints, rest stops, transitions, hazards) as valid RFC-7946 GeoJSON to local storage; triggers on key edits and at intervals; custom feature properties for node types/modes/metadata.

**L2 — Keep notes as portable Markdown** *[P1]* — *FR69*
**As a** User, **I want** notes and journals stored as Markdown **so that** they stay readable and portable.
*AC:* Notes/journals saved as valid `.md`; images as relative references with standard image syntax; links/coords/node references as standard Markdown links.

**L3 — Export a full trip archive** *[P1]* — *FR70*
**As a** User, **I want to** export a trip as a `.zip` **so that** I have a vendor-neutral offline backup of the whole adventure.
*AC:* One `.zip` with `/routes` (GeoJSON/GPX/TCX), `/journal` (Markdown), `/photos` (binaries), and `manifest.json`; generated locally/in background without choking the device.

**L4 — Restore a trip from an archive** *[P1]* — *FR71*
**As a** User, **I want to** restore/import from a Plotlines `.zip` **so that** I can recover, migrate, or import a shared trip cleanly.
*AC:* Select a valid archive; validate `manifest.json` and file integrity before import; restore geometries, sequencing, metadata, cue sheets, Markdown notes, and photos; resolve relative photo/link references without breakage; show progress and a completion summary.

### Epic M — Developer: Architectural Seams

**M1 — Model themes as data** *[MVP]* — *design goal*
**As a** Developer, **I want** every theme to be a `WeightProfile` instance fed to one scoring function **so that** a new theme is a config entry, not new code.
*AC:* Each theme is values in a shared `WeightProfile` (elevation, traffic class, surface penalty, POI bonus, detour budget, plus mode-specific weights such as terrain technicality); one scoring function consumes any profile; adding a theme requires only a new profile entry; mode-specific weights extend the same structure, not a parallel scorer. *(The whitewater-class and water-type weights that used to illustrate this were removed with FR13 — see ARCH D19. The requirement is the extension mechanism, which is unaffected; re-adding a mode weight if data appears is a profile field, which is the point.)*

**M2 — Resolve weights per edge via a position lookup** *[MVP]* — *FR36 seam*
**As a** Developer, **I want** the solver to read an edge's weight via `weights.at(position)` from day one **so that** scoped/segment-varying weighting later is a one-function change.
*AC:* Solver obtains weights through `weights.at(position)`; scalar case returns the same profile each time; the seam exists before scoped weights are needed; introducing scopes changes only the lookup, not the solver.

**M3 — Abstract elevation behind one interface** *[MVP]* — *FR62 seam*
**As a** Developer, **I want** elevation requested for a bounding box through one interface **so that** adding a shared cache later is a config change, not a client rewrite.
*AC:* One elevation interface from the first milestone; initial resolution is local-cache-then-direct-provider; a later phase inserts a shared cache ahead of the direct call, changing only order and base URL; the routing core's elevation reads are unchanged. The direct provider in Phase 1 is GEDTM30/OpenTopography (FR85).

**M4 — Serve web auth same-site** *[MVP]* — *architecture requirement*
**As a** Developer, **I want** web and API on subdomains of one registered domain with a first-party `SameSite=Lax` session cookie **so that** sessions survive Safari and Firefox third-party-cookie blocking.
*AC:* Both surfaces on subdomains of one registered domain (not Public-Suffix-List platform hosts); cookie is `HttpOnly; Secure; SameSite=Lax` on the shared parent; no tokens in `localStorage`/`IndexedDB`; persistence verified in Safari and Firefox as a release gate.

**M5 — Rate-limit guest compute per IP** *[P1]* — *architecture requirement*
**As a** Developer, **I want** an in-memory per-IP limiter with progressive cool-off **so that** the guest tier's cost and abuse surface stays bounded without new infrastructure.
*AC:* Per-IP in-memory counter on the single instance; calibrated threshold with progressive cool-off; guest sessions stay stateless server-side; the single-instance limitation is documented as accepted.

**M6 — Cache external resources by volatility** *[P1]* — *responsible-use NFR*
**As a** Developer, **I want** every external dependency cached with a volatility-appropriate TTL, bounded with eviction, and never re-requested when held **so that** we respect free-tier limits and attribution.
*AC:* Per-dependency TTLs (short for forecasts, long/bundled for terrain/historical); size-bounded caches with eviction; held data never re-fetched; CC-BY attributions shown wherever that data appears; design supports a later shared server-side cache without changing the client interface.

**M7 — Pass the processing-core limit in from the caller** *[P1]* — *core-allocation rule*
**As a** Developer, **I want** the routing core to receive its core limit as a parameter **so that** route computation doesn't starve the UI and the library stays host-agnostic.
*AC:* On Desktop/Mobile the client passes `floor(coreCount / 2)`; the core treats the limit as a passed-in parameter and never queries the host; the server instance uses a fixed allocation by instance size.

**M8 — Build an ARB-based localization framework** *[P1]* — *FR83 foundation*
**As a** Developer, **I want** a `flutter_localizations` + `.arb` pipeline **so that** adding languages is streamlined, type-safe, and decoupled from app logic.
*AC:* UI strings extracted to `.arb` templates in `/l10n`; codegen produces type-safe `AppLocalizations`; parameter interpolation, pluralization, and date/number formatting via `intl`; missing keys fall back to base locale with build-time warnings.

**M9 — Run within device power-saving mode** *[P1]* — *FR67*
**As a** Developer, **I want** the mobile app to minimize GPS/CPU/network wake-ups and keep working under OS power-saving **so that** navigation survives a full day in the field.
*AC:* Minimized wake-ups during active navigation; no errors/crashes under OS power-saving; core navigation (cue sheet, position, next maneuver) remains available.

**M10 — Ship a single, licensed elevation source with no fallback** *[MVP]* — *FR85, FR88*
**As a** Developer, **I want** one fused elevation source with an explicit void/nodata/NaN policy **so that** elevation reads are simple, predictable, and never the reason a solve hangs or throws.
*AC:* GEDTM30/OpenTopography is the only elevation source, no secondary fallback; nodata (including NaN, via explicit `isnan`) and out-of-bounds/missing-raster cases all resolve to `0.0`, logged at most once per raster path; no network call occurs inside a solve.

**M11 — Serve tiles only through our own service** *[MVP]* — *FR92, FR93, FR94, FR95*
**As a** Developer, **I want** the client to depend on one tile contract regardless of the upstream tile source **so that** swapping the basemap vendor or generation tooling never touches client code.
*AC:* Client requests tiles only from `GET /tiles/{z}/{x}/{y}`; the service validates z/x/y range before any upstream work; tile generation is bbox-scoped and on-demand, shared with the offline-bundle pipeline (FR64); tiles are extracted from a Plotlines-hosted mirror of the Protomaps build rather than fetched from the public channel, and the ODbL `© OpenStreetMap` attribution ships alongside the elevation layer's CC BY (FR86) — both, under different licences.


## 8. Open Items

Deliberately unresolved, carried forward or newly surfaced:

- **In-field peer intel is intentionally in-scope, and route-anchored.** Route amendments (FR56 / I9) and field notes (FR56a / I9a–b) let any participant share time-sensitive intel with the trip roster peer-to-peer — resolved this way deliberately, because the Author may be riding the trip and unable to relay in real time. This is bounded to one trip's roster, anchored to points on the shared route, and advisory (recipients Accept/Decline/ignore; nothing changes a path without consent). It is **not** the social-platform territory the non-goal guards against — no friend graph, no cross-trip feed, no open messaging. The remaining design question is presentation, not permission: how notes and flagged amendments are surfaced/queued so a busy stretch doesn't overwhelm the Character.
- **Cue HUD vs. "no real-time route guidance."** The auto-updating HUD with live ETA recalculation (FR50–FR51) is authored-content playback, not turn-by-turn routing — but the line is fine. Worth confirming during Design that the HUD never crosses into wrong-turn recalculation or "follow the line" guidance.
- **Multimodal MVP breadth.** Cycling, hiking, and paddling are first-class in MVP. The exact set of *further* modes (skiing, climbing, packrafting, etc.) and their weight/parameter profiles is a scoping decision; the `WeightProfile` model (M1) is designed to absorb them without new scorers.
- **Paddling difficulty — decided, and worth revisiting if the data changes.** SPIKE-04 ([results](../spikes/SPIKE-04/results/RESULTS.md)) found the paddling network and live gauge readings solid and public-domain (USGS), and **class ratings absent**: one graded feature across the three regions tested, 58 across all of North America, and the authoritative US inventory prohibits reuse. **Decided 2026-08-14: FR13 removed, stories B4 and B5 removed, FR14 narrowed to an advisory gauge band (B8, Leg 3), FR15/B6 portages made Author-drawn.** What remains open is not the decision but its trigger: **if a data agreement with American Whitewater becomes possible — or the OSM whitewater schema gains North American adoption — the class-band capability becomes buildable and should be reconsidered on its merits.** Nothing in the current design forecloses it: re-adding the class term is two fields on `WeightProfile` and a scoring clause (ARCH §6.3, D19) once a data source exists — not a redesign.
- **Unified "share with Author" surface.** Profile field-sharing is now a request/response negotiation (FR78/FR78a — Author requests, Character grants/declines/volunteers), while transit/arrival sharing (FR30) is a simpler per-field opt-in. Design should decide whether these live in one "what I share with the Author" surface or two, and whether transit sharing should also adopt the request/response pattern.
- **Leg 7 interface shape.** The concrete data-input contract and output-destination list are intentionally open (FR84).
- **Default download regions — mostly settled; the first-run experience is not.** SPIKE-14 measured the sizing this depended on: **~3.5 MB per 1,000 km² at z0–15**, over a ~1 MB floor — **1.0 MB** for a CI/test bbox (small enough to commit as a fixture), **22 MB** for an 80 km square, **118 MB** for a 235 × 134 km multi-day corridor, and capping at z14 roughly halves each. The POC's cautionary ~80 km square is confirmed as the right order of magnitude and costs almost nothing, so **a default region is not a storage trade-off — pick the region that routes well.** The corridor case is the one that costs, which argues for a **per-trip bounding box** over fixed named regions (only the trip knows which corridor it needs); that remains a product call rather than a measurement. **Still open: what a Character sees on first start with nothing downloaded** — nothing in SPIKE-14 measures it, and Character first-start download stays written generically until it is decided.
- **Brand naming & positioning** beyond product/technical scope — not yet settled.
- **Visual identity & color system** — owned by `Brand Guide.md`, deliberately not duplicated here.

---

## Appendix — Source-Story Traceability

Every user story in `Plotlines.md` is represented in this PRD. Consolidations of note:

- Author 10a–10d → FR2–FR5, FR8 (weights); 29 → FR16, FR31 (speeds/ETA).
- **Author 10e/10f/18 (water/technical) are no longer fully represented.** They mapped to FR13–FR14; FR13 was removed and FR14 narrowed after SPIKE-04, so the *class-rating* half of those source stories is deliberately unbuilt. Story 18's gauge half survives as FR14/FR14a (story B8) and its terrain-technicality half as FR14. This is the one place a source story was dropped on evidence rather than consolidated.
- Author 1, 9 → FR17–FR18; 20 → FR19; 19 → FR20; 4/5 → FR21; 13 → FR22; 11 → FR23; 12 → FR35; 15 → FR12; 23 → FR15; 32 → FR24; 33 → FR25; 34 → FR26; 27 → FR27, FR53; 28 → FR28; 17 → FR29–FR30; 16 → FR38; 21/22 → FR31–FR32; 7/8 → FR33; 14 → FR34; 24/25 → FR48; 26 → FR46; 31 → FR82; 35/36 → FR55–FR56; 37 → FR74.
- Character C1–C13 map to their Author counterparts' Character-facing FRs; C17 → FR72; C18 → FR73; C19 → FR79; C20 → FR54; C21 → FR75; C22 → FR50; C23 → FR51; C24 → FR52; C11 → FR53; C14 → FR44–FR45; C5 → FR66; C6 → FR77.
- System S1 → FR79; S2 → FR77; S3 → FR68; S4 → FR69; S5 → FR70; S6 → FR71; S8 → FR76; S9 → FR83. Developer D1 → M8.
- Two source defects corrected: Story 10e's inverted "so that" (routing was to keep Characters *within* ability, not beyond it — moot now that FR13/B4 are removed), and Story 10c's mileage target folded into FR8/FR5.
