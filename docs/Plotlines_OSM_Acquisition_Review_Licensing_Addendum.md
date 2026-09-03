# OSM Acquisition Review — Licensing and Policy Addendum

**Date:** 2026-09-03 · **Branch:** `fix/232-overpass-status-failover`
**Reviews:** [`docs/Plotlines_OSM_Acquisition_Review.md`](Plotlines_OSM_Acquisition_Review.md)
**Status:** **accepted 2026-09-03.** All six §5 questions answered with the recommendations as
written — recorded here per question and in the reviewed document's §12. §6's Phase 0 amendments
are filed as #241–#253 (epic #254); the Phase 1 amendments are filed as #255–#263 under epic #264;
Phase 2 is #265–#267 under epic #268. **§6's Phase 3+ block was re-triaged 2026-09-03** — 3b was
not Phase 3 work and is now #269 (Phase 0), and 3a split, its schema half landing as #270
(Phase 1).
**Not legal advice.** Clause readings below are engineering readings; §L2/§L3 and open
question 4 are the two that warrant a real sign-off before they ship.

---

## 0. Verdict

**The plan is right, the sequencing is right, and Phase 0 should ship as written.** Every
code claim in the reviewed document verifies against the tree — §3.1 (`candidate_set()` is
reserved and unread), §3.2 (`configure_overpass_cache` sits past the warm-cache return at
`graph/regions.py:371-376`), §3.3 (`trip_area_map.dart` proposes on pointer-**up** only, so
the burst is on the accepted-bbox edge), §3.4 (`tiles/extract.py:59` sets a UA, no OSM call
does), and the stray `cache/` and `service/cache/` directories are both present and
untracked, `service/cache/549fdfc3…json` being #239's `{"elements": []}` exactly as
described.

Where it needs work is **breadth, not direction**. Three things:

1. **§4's licence/policy split is the right frame, but §11.6 draws the redistribution line
   in the wrong place.** ODbL share-alike triggers on *public use*, not only on handing
   someone a file — which means the obligation attaches to hosted web (Phase 4) and,
   arguably, to trip sharing and cloning **today**, not at Phase 3.
2. **The plan names a GPL-3 tool and freezes a BSD-2 library as if they were the same
   dependency.** `osmium extract` (osmium-tool) and `pyosmium` are separately licensed.
3. **A user-facing privacy claim is currently false**, and it is false because of exactly
   the acquisition behaviour this document is about.

Everything below is additive. Nothing here argues against the plan.

---

## 1. Source-by-source obligation table

Consolidating what is actually owed, because the reviewed document treats OSM as one
resource and it is four (data, two service operators, one file publisher) plus a software
stack.

| Resource | Licence / policy | What we owe | Status today |
|---|---|---|---|
| **OSM data** (any transport) | ODbL 1.0 (database) + DbCL 1.0 (contents) | Attribution on Produced Works (§4.3); ODbL + offer of the database on Derivative Databases distributed **or publicly used** (§4.4, §4.6); no DRM-only distribution (§4.7) | **Attribution: satisfied.** Share-alike: **unassessed** — see L2/L3 |
| **Overpass public instances** (`overpass-api.de`, `overpass.kumi.systems`) | Operator usage policy: interactive/small queries, per-IP concurrent slots and daily quota, bulk consumers directed to extracts | Identify ourselves; stay small; back off; do not treat as bulk transport | **Not satisfied** — this is the document's whole thesis, and P3 makes it ~2× worse than stated |
| **Nominatim** (`nominatim.openstreetmap.org`, osmnx default) | OSMF Nominatim Usage Policy | UA/Referer identifying *the application* (a stock library UA is explicitly insufficient); ≤1 req/s; **cache results**; no bulk or per-keystroke autocomplete; display attribution | **Partially satisfied by accident** — see P2 |
| **Geofabrik extracts** (`.osm.pbf`) | Data: ODbL. Service: Geofabrik's download-server terms and pull etiquette | Attribution + licence notice when we redistribute; polite, conditional, ≤daily pull cadence; identify the puller | **Not yet mechanical** — see L4/P5 |
| **Geofabrik `index-v1.json`** | **Unverified.** Region geometries are Geofabrik's own cartographic work, not necessarily ODbL OSM data | Unknown until checked | **Gap — verify before mirroring it** (L4) |
| **Protomaps Basemap** | ODbL as a Produced Work (FR95) | `© OpenStreetMap contributors`; mirror, never hotlink | **Satisfied and mechanical** (`HotlinkRefused`) — the model the rest should copy |
| **OpenTopography elevation** | CC BY 4.0 (FR86) | Separate credit, not substitutable | Out of scope here; shares the attribution machinery |
| **osmnx** | MIT | Notice only | Fine. Its *default UA* is the problem, not its licence |
| **`osmium` CLI (osmium-tool)** | **GPL-3.0** | Source offer + licence notice **if we distribute the binary** | **Named in §6/§7.1/§8 — see L1** |
| **`pyosmium` / libosmium** | BSD-2-Clause | Notice | Fine — and it is the way out of L1 |
| **`pyrosm`** | MIT (verify its transitive native deps) | Notice | Fine |
| **PyInstaller** | GPL-2.0+ **with bootloader exception** | Notice; exception permits shipping proprietary frozen apps | Already relied on today; worth writing down |

---

## 2. Licensing gaps

### L1 — `osmium extract` is GPL-3; `pyosmium` is BSD-2. The plan uses both names for one dependency.

§6.6, §7.1(3), §8(3) and checklist item 21 all specify **`osmium extract`** — the
command-line tool. §7.2 specifies freezing **pyosmium** through PyInstaller on four
targets. These are different projects under different licences: osmium-tool is GPL-3.0;
libosmium and its Python binding pyosmium are BSD-2-Clause.

Why it matters: bundling a GPL-3 binary inside a shipped desktop app is a distribution
event with real obligations (licence text, written offer of corresponding source,
anti-tivoization terms). Invoking a separately-installed `osmium` via `subprocess` is a
much weaker aggregation argument, but "the user must install a GPL tool first" is not an
offline-first install story.

**Resolution — cheap, and it should be a decision, not a discovery:** do the clip through
**pyosmium's Python API** (`osmium.SimpleHandler` / `osmium.io.Writer`, or
`pyosmium-up-to-date`'s underlying library calls), never the CLI. That is what SPIKE-J is
already freezing. Add to SPIKE-I an explicit acceptance criterion: *the clip is performed
with no GPL-licensed binary in the shipped artifact.*

**Second-order:** §7.1(3) wants to measure `simple` / `complete_ways` / `smart` strategies.
Those are osmium-tool concepts. The equivalent behaviour through pyosmium has to be
implemented, not selected by flag — that is real spike scope the document currently prices
as a flag comparison.

### L2 — §11.6 under-scopes ODbL: the trigger is *public use*, not distribution

§11.6 reads: *"Mirroring extracts and handing a client a clipped `.pbf` makes Plotlines a
distributor of a Derivative Database."* True, but it is the **easy** case: a clipped OSM
extract is pure OSM data, ODbL in and ODbL out, and it needs a licence notice beside the
file and nothing more. Geofabrik does exactly this in public every day.

The harder case is the one the document does not name. ODbL's share-alike and its
access-to-derivative-databases condition (§4.4 / §4.6) attach when you **Publicly Use** a
Derivative Database — which the licence defines to include making it available over a
network — not only when you convey a copy. Practically:

- **Phase 4 (hosted web, §9)** serves produced works out of a server-side OSM-derived
  database. That is public use. Serving it does not exempt us the way a proprietary SaaS
  would be exempt under a source-available code licence.
- **Trip sharing, cloning, and the anonymous web reading view exist today** (SPIKE-F /
  D59, share tokens, `RevealResolver`). Each publishes something derived from OSM to a
  third party. Whether that crosses into "derivative database" turns on substantiality —
  see L3 — but the question is live **now**, not at Phase 3, and the reviewed document
  sequences it behind a spike.

**What this changes in the plan:** open question 4's sign-off is not a Phase-3 gate. It is
a Phase-0-or-1 gate on a decision that is already shipping.

### L3 — Derivative vs Collective Database: decide the data-model split now, while it is free

`OsmLayerProvider` fetches OSM features; `notability.score_with_taxonomy` attaches
Plotlines' own scores; the result lands in the candidate cache and, once promoted, in
`Trip.days[].segments[].nodes[]` alongside Author-authored content. Whether share-alike
reaches **Plotlines' own tables** depends on whether that is one merged database (a
Derivative Database — share-alike propagates) or two layers kept distinguishable (a
Collective Database — each part keeps its own licence).

OSMF's community guidelines are the operative reading here — *Collective Database*,
*Horizontal Map Layers*, *Substantial*, *Trivial Transformations*, *Geocoding*, *Produced
Work*. Two useful anchors from them: a format-or-region transformation of OSM (our clip)
is treated as OSM, not as something new; and small extracts are insubstantial, which is
where a single trip's handful of anchors most plausibly lands.

**The cheap design move, worth making before Phase 3:** keep the OSM-derived fields
structurally separable from Plotlines-authored fields — a per-feature `source` /
provenance discriminator on the candidate record and on the promoted `Node`, so an
"offer the derivative database" obligation can be satisfied by exporting **the OSM layer**
rather than the whole trip store. `Provenance` / `Attribution` in `trips/payload.py:812-828`
is the right place for the hook and it already exists. Retrofitting this after Authors have
data is the expensive version.

### L4 — The mirror itself has no licence artifacts, and one of its files may not be ODbL

§6.3's layout is data only:

```
/srv/plotlines-mirror/
  MIRROR_STATE.json
  basemap/protomaps/20250101/planet.pmtiles
  osm/geofabrik/2026-09-01/index-v1.json
  osm/geofabrik/2026-09-01/north-america/us/north-carolina.osm.pbf
```

Two gaps:

- **No `COPYRIGHT.txt` / `LICENSE` / ODbL notice** anywhere in the tree. The moment
  `tiles.plotlines.app` is internet-reachable and serving `.osm.pbf`, Plotlines is a public
  redistributor of an OSM database, and the notice obligation (§4.2) attaches to the
  distribution channel, not just to the app UI. This is one file per directory and it
  should be in the §6.3 layout and in checklist item 11, not remembered later.
- **`index-v1.json` licence is unverified.** The extract `.pbf`s are unambiguously ODbL
  OSM data. The *index* is Geofabrik's own region geometry and metadata — their cut lines,
  their naming. Check Geofabrik's stated terms for that file before mirroring and
  redistributing it, and if it is unclear, derive the covering-set geometry ourselves from
  the bboxes we actually need rather than re-serving their index.

### L5 — There is no third-party dependency licence inventory, and Phase 2 adds to the shipped binary

`grep` finds no `THIRD_PARTY_LICENSES`, no dependency-licence doc, and no notice bundle in
`packaging/`. Today's frozen sidecar already ships osmnx (MIT), shapely, rasterio and its
GDAL/PROJ stack, numpy, networkx, pmtiles, FastAPI/uvicorn — and is built with PyInstaller,
whose bootloader exception is the reason that is permissible at all. Phase 2 adds a
C++-extension dependency to that binary.

Given that **FR101 already makes a missing *data* attribution a build failure**, the
asymmetry is conspicuous: data credits are mechanical and release-gated, software notices
are not collected at all. Generating a notice bundle at freeze time (`pip-licenses` or
equivalent into `packaging/`, surfaced from the About screen's existing "licences"
affordance) is a small piece of work that closes it, and it gives L1's answer somewhere to
live.

### L6 — The attribution gate does not cover mirror-served payloads

`attribution.attributions_for` / `assert_attribution_complete` enumerate **loaded
`LayerProvider`s**. The basemap's ODbL line is merged in by `service` from
`mirror.basemap_attribution`; elevation's CC BY comes from `elevation/region_asset.py`. A
clipped `.osm.pbf` served from the Plotlines mirror and consumed as the routing graph
would be a **fourth** path with neither a provider nor a hand-merged line — the routing
graph is not a layer, so nothing enumerates it.

This is the same shape as ARCH §8.1's "one policy, three payloads" that §8(3) invokes for
the cache. The attribution machinery deserves the same treatment: one gate, every payload,
including the graph. Today the graph gets its credit only incidentally, because the
basemap under it happens to be OSM too — which stops being true the moment a non-OSM
basemap is ever offered.

### L7 — A trip does not record which OSM snapshot it was built from

§8 says *"a trip pins the build it started on and does not shift under the Author
mid-planning"*, which is exactly right. But nothing in the plan says the pin is **written
into the trip payload**. `Provenance` and `Attribution` exist (`trips/payload.py:812-828`)
and `SolveProvenance` already records solve inputs, so the slot is there.

Two reasons it matters beyond tidiness: an exported cue sheet or FIT course carrying
"contains OSM data, snapshot 2026-09-01" is a stronger §4.3 notice than a bare credit; and
without it, a trip built from a stale pin is indistinguishable from a fresh one, which is
precisely §11.3's quiet-and-permanent failure mode arriving in the Author's data instead of
in ops.

---

## 3. Usage-policy gaps

### P1 — The privacy statement is currently false, and it is false about this exact behaviour

`client/lib/domain/privacy_statement.dart` (mirrored in `core/plotlines_core/web/about.py`,
pinned by tests on both sides, reachable from every surface per K10/FR138) says:

> **What stays on this device** — "Your trips, routes, notes, and the maps and elevation you
> have downloaded all live on this device. **Planning works with nothing signed in and
> nothing sent anywhere.**"

> **What reaches the server** — "…If you never do those, **nothing about your planning
> leaves this device.**"

Planning today sends **the Author's trip bbox to a volunteer-operated third party in
Germany or Lithuania**, and **the Author's typed place name to the OSM Foundation's
Nominatim**, both without an account and both as a direct consequence of drawing an area.
The statement is not describing the software.

This is worth raising here rather than filing separately because the acquisition decision
changes the answer: after the migration, the bbox goes to a **Plotlines-operated** mirror
instead of a stranger's, which is a materially better sentence to have to write. But the
statement needs correcting **either way and now** — it is a user-facing accuracy problem
that survives every option in this document. Nominatim in particular still receives the
query text under every phase of the current plan.

Suggested shape, for whoever files it: a third bullet naming what leaves the device during
planning (map data requests for the area you draw, place-name lookups), who receives it,
and that neither carries identity. That is a truthful FR138 clause, and it is short.

### P2 — Nominatim: three obligations, one satisfied, and it is satisfied by accident

Verified against the installed osmnx 2.1.1 and the client:

- **Pacing — accidentally OK, fragilely.** `osmnx/_nominatim.py` hard-codes `pause = 1`
  before every request, and the client calls `/geocode` on submit (`_search()` in
  `new_route_screen.dart:766`, `_continue()` in `trip_location_prompt.dart:124`), not per
  keystroke. So no autocomplete violation and roughly ≤1 rps. But the pause is
  **per-process**: two sidecars, or a hosted service with any concurrency, exceed 1 rps
  with no code change and no warning. §5.8's audit should convert this from an accident
  into an asserted invariant.
- **Identification — not satisfied.** Same root cause as §3.4. `settings.nominatim_url`
  defaults to `https://nominatim.openstreetmap.org/` and the UA defaults to the OSMnx
  string. The policy names a stock library UA as explicitly insufficient. §5.1 fixes both
  Overpass and Nominatim in one line, which is another reason it is the right first move.
- **Caching — not satisfied.** The policy asks that results be cached rather than
  re-queried. `/geocode` caches nothing of its own; it inherits `ox.settings.use_cache`
  with the CWD-relative `cache_folder` §3.2 already indicts — so today's geocode cache is
  the stray `service/cache/` directory checklist item 2 proposes to delete. Fixing §5.2
  fixes this too, but only if the deletion in item 2 happens *after* the relocation, not
  before.
- **Corroborating evidence the plan already has:** `regions.py:76-77` records that
  `overpass.openstreetmap.fr` answers **403 "only available to white-listed usages"** to
  the osmnx UA while serving `curl` fine. That is an operator already refusing
  library-generic user agents. §5.1 is not politeness theatre; it is the difference
  between being a recognisable client and being indistinguishable from every other
  unattended osmnx script.

### P3 — One accepted bbox is not one Overpass query. It is at least two.

`ox.settings.max_query_area_size` is 2,500 km² (`50 * 1000 * 50 * 1000`), and
`_make_overpass_polygon_coord_strs` subdivides above it via
`utils_geo._consolidate_subdivide_geometry`, yielding one `_overpass_request` **per
sub-polygon**. #238's largest box, 56 × 74 km, is ~4,100 km² — two queries minimum, and
the candidate path issues its own independent set.

This confirms the reviewed document's own numbers (22 builds → 44 requests is exactly 2×)
but the document never draws the inference, and it changes two things:

- Any "requests per accepted bbox" budget in §10 must be stated in **queries**, not
  builds, or it will under-count by the ratio of bbox area to 2,500 km².
- It makes the load *superlinear in area* from the operator's point of view while the
  Author perceives one gesture — which is the strongest single argument in the whole
  document for why debouncing gestures (§3.3) was never going to be enough.

### P4 — "Small, polite Overpass" (§10) is undefined, which is how the endpoint list grew

§10 keeps a user-initiated live-refresh affordance and argues, correctly, that this is what
public instances are *for*. But "small" and "polite" are prose, and §10's own thesis is
that prose erodes — `DEFAULT_OVERPASS_ENDPOINTS`' docstring is a page of excellent policy
reasoning sitting directly above a list that grew anyway.

Make the affordance mechanical in the same commit that introduces it: a hard maximum bbox
area **below `max_query_area_size` so it can never subdivide**, concurrency of 1, a
per-day request budget that fails closed with an honest message, and no automatic
retry — a user-initiated action that fails is re-initiated by the user or not at all.
Those are four assertable numbers, and they turn §10's third bullet ("a test asserting a
non-default UA") into a small family of tests rather than one.

### P5 — Geofabrik gets etiquette by assumption; Overpass got it by measurement

§6.6 says "pull each region from Geofabrik **once**" and then checklist item 17 puts the
pull "on a cron" with no cadence, no conditional request, and no UA. That is the same
shape of unexamined automation that produced #232, just aimed at a different volunteer-
adjacent operator — and the document itself warns against exactly this ("we should not
repeat it on the Geofabrik side").

Make it concrete in §6.6: pull **at most daily** (their files update daily; anything faster
downloads the same bytes), check the `.md5` or an `If-Modified-Since` / `HEAD` first and
skip the body when unchanged, send the same Plotlines UA §5.1 introduces, and back off on
error rather than retrying on the next cron tick. Also: if the mirror becomes
internet-reachable, decide whether it is open or restricted to Plotlines clients — an open
one is legal but makes us an unintentional public extract service, and its bandwidth is
ours.

### P6 — The OSM path has no mechanical gate for the entire migration window

§10's `HotlinkRefused` equivalent lands in **Phase 5**, after Phases 1–4. So the whole
period during which the endpoint list is most likely to be edited under pressure — while
the mirror is half-built and the extract path is unproven — is the period with no gate.

`classify_upstream` in `tiles/mirror.py` is tile-scoped and hostname-only, so it will not
cover an Overpass URL as written. But the Phase 5 items are cheap and independent:
"a test that fails if the default endpoint list regrows" and "a test asserting a non-default
UA is set before any OSM request goes out" are both **Phase 0** work, testable today,
and the second is the natural regression test for §5.1. Only the refuse-a-third-party-host
gate genuinely needs the mirror to exist first. Recommend splitting §10 and pulling those
two tests forward into checklist item 9.

---

## 4. Plan-internal gaps worth a line each

**G1 — `ox.settings` is process-global and `ensure_graph` mutates it mid-flight.**
`regions.py:389-400` sets `overpass_url` and `overpass_rate_limit` per endpoint and restores
them in `finally`. Both `/regions` and `/candidates` are sync `def` endpoints, so FastAPI
runs them in a threadpool concurrently. A `/candidates` call landing during a failing region
build inherits the **failover endpoint and `rate_limit = False`** — the candidate path
becomes impolite as a side effect of the graph path's retry, on an endpoint nobody chose for
it. This is both a correctness bug and a politeness bug, it is Phase-0-sized, and it is not
in the checklist. The fix is to stop driving policy through globals: pass the endpoint into
the download call, or serialise OSM access behind one lock.

**G2 — The candidate path's missing failover is diagnosed and never fixed.** §2's table
records "single `ox.settings.overpass_url`, no failover" as a finding, and no numbered item
addresses it. Phase 0 hardens the graph path further while the candidate path keeps the
pre-#229 behaviour. Either fix it in Phase 0 or state explicitly that it is accepted until
the extract path removes the transport entirely.

**G3 — §6.2 and §6.3 contradict each other, and checklist item 13 ships the contradiction.**
§6.3 names `basemap/protomaps/20250101/planet.pmtiles` and says it "matches
`MIRROR_ARCHIVE_URL` exactly"; §6.2 says "**do not put a planet archive on it**"; item 13
copies `spikes/SPIKE-14/tiles/wnc-corridor.pmtiles` into that path. The rehearsal then has a
file named `planet.pmtiles` that contains one corridor, so any bbox outside WNC gets a
silent miss that looks like a mirror bug — and "build-pinned paths are immutable" becomes
untrue for the one file most likely to be swapped. Give the stand-in an honest path
(`basemap/protomaps/20250101-wnc/`) or its own build id, and note in `MIRROR_STATE.json`
which regions the archive actually covers.

**G4 — §5.4's connect probe does not cover the failure #232 was about.** A short-timeout
socket open catches *refused / unreachable*. #232's actual failure was a `502 Bad Gateway`
from an overloaded mirror's reverse proxy — the socket opens fine and the probe says
healthy. The probe is still worth having (it makes the refused case fast, which is the
common one), but it should be described as an optimisation for one failure class, not as
the thing that makes keeping `overpass_rate_limit` on affordable in general.

**G5 — §7.1's parity spike has no stated pass/fail band.** The document is emphatic that
parity is the sharpest risk (§11.1) and that everything calibrated to date — SPIKE-A's
golden candidate sets, SPIKE-G's ~2,800-marker density ceiling, the scoring weights, cue
derivation — was measured on osmnx output. A spike this consequential should pre-register
what counts as parity (exact node/edge sets? ±x% on largest-SCC size? identical
`PLOTLINES_WAY_TAGS` survival with zero tolerance?), in the house style the other spikes
use. Otherwise "close enough" gets decided after the numbers are visible.

---

## 5. The six open questions

### Q1 — Extract granularity

| Option | Pros | Cons |
|---|---|---|
| **A. Geofabrik sub-region as published (US state)** | Zero cutting work; verifiable `.md5`; mirror stays dumb static files; matches how everyone else consumes Geofabrik | 200–800 MB per state; every border trip needs 2–4 of them (§11.7); an Author near a tri-point pulls ~1.5 GB for one weekend |
| **B. Self-cut county / sub-state tiles** | Small downloads; covering sets stay small in *bytes* even when plural | We become the cutter — every clip bug is ours, and we lose Geofabrik's `.md5` as an integrity check; covering sets become plural *more often*, not less; new ops surface (re-cut on every pin bump) |
| **C. Mirror-side clip to the trip bbox; client never sees a region extract** ★ | Smallest possible download (one bbox, tens of MB); no covering-set merge on the client at all (dissolves Q3); no native clip dependency on desktop, which **also dissolves most of SPIKE-J and all of L1**; identical code path to Phase 4's hosted clip, so §9's "MVP is the first half of the real thing" becomes literally true | The mirror stops being dumb static files — §6's central discipline — and gains CPU, a queue, and an availability profile; offline re-clip for a *changed* bbox needs a round trip; ARCH D41/D57's offline-first posture needs an explicit answer for "Author edits the bbox on a mountain with no signal" |
| **D. Hybrid: mirror states, serve bbox clips, cache both** | Keeps the offline story (a state extract can be pulled deliberately for a trip you know is coming) while making the common path small | Two paths to build, two to test, two to keep honest |

**Recommendation: C, with D as the stated fallback if offline bbox-editing turns out to
matter.** C is the option that removes work rather than moving it — it deletes the
covering-set merge, the client-side native dependency, and the GPL question in one move,
and it is the only option where Phase 3 and Phase 4 are the same code. The right way to
decide is to make SPIKE-I measure the clip **server-side**, so the number that comes back
is the one C depends on.

Note that C changes what the Pi rehearses: it is no longer "static files with byte ranges"
but "a small service." That is a real cost against §6's discipline and should be
acknowledged, not glossed — but the Pi rehearses the *hosted clip* instead, which §9
currently lists as an unmeasured future risk.

**Decision — adopted 2026-09-03: C, with D as the stated fallback.** The mirror gains one
endpoint and the client never sees a region extract. Accepted with eyes open on the cost this
section names: the Pi stops rehearsing "static files with byte ranges" alone and starts rehearsing
the hosted clip of §9 — which is the measurement §9 currently carries as an unmeasured future
risk, so the discipline lost is partly bought back. Pinned region extracts stay served as
immutable files so **D is a configuration decision later, not a rebuild**. The offline case
("Author edits the bbox on a mountain with no signal") is the trigger for D and is a
**measurement for SPIKE-I**, not a guess. Recorded in the review as §6.7 and §12-Q1.

### Q2 — Pin cadence and ownership

| Option | Pros | Cons |
|---|---|---|
| **A. Ad-hoc, a maintainer bumps it when they notice** | Zero infrastructure; honest at current scale | This is precisely §11.3's quiet failure: nobody notices for three months, and nothing distinguishes that from working |
| **B. Scheduled monthly pin, with a release checklist item** ★ | Predictable; the pin bump becomes a reviewable event; matches `PROTOMAPS_BASEMAP_BUILD`'s existing discipline exactly; a missed month is *visible* | Up to 30 days stale for the Authors §11.4 worries about |
| **C. Weekly/continuous auto-pull with staleness monitoring** | Freshest; smallest §11.4 regression | Real ops surface (alerting, disk, failure handling) for a benefit measured in days; more upstream load (P5) |
| **D. Follow upstream daily cadence, pin only per-trip** | Every new trip is ~1 day fresh | Maximum upstream load and egress; per-trip pinning means the *fleet* holds many different builds, which complicates any future "why did this route differ" question |

**Recommendation: B, with C's monitoring built anyway.** The cadence and the monitor are
separable, and the monitor is the part §11.3 says is missing. `MIRROR_STATE.json` +
a `/health` field reporting mirror age (the sidecar already has a per-layer `/health`
surface from N4) makes staleness loud for free. **Ownership** should be named in the doc,
not left as a role: one person bumps, the release checklist blocks on it, and L7's payload
pin makes every trip say which build it used.

**Decision — adopted 2026-09-03: B, with C's monitoring built anyway.** Monthly pin, **one named
owner**, release checklist blocks on the bump — the `PROTOMAPS_BASEMAP_BUILD` discipline, where a
missed month is visible. The monitor ships regardless: `MIRROR_STATE.json` plus a mirror-age field
on the sidecar's existing per-layer `/health` (N4). L7's payload pin — every trip records which
build it used — is part of this answer, not separate from it. Recorded in the review as §6.6 and
§12-Q2.

### Q3 — Where the covering-set merge happens

**If Q1 lands on C, this question dissolves** — there is no merge, because the mirror clips
across whatever extracts it holds and returns one file. Presented below for the case where
it does not.

| Option | Pros | Cons |
|---|---|---|
| **A. Client-side merge after downloading N extracts** | Mirror stays dumb; works offline once the extracts are local | Way deduplication across extracts on four frozen platforms is the hardest correctness surface in the plan (§11.7), and it runs on the least observable machine we have |
| **B. Mirror-side pre-merged region groups** ("NC + TN + SC + GA") | Client sees exactly one file, always; merge is done once by us, in one place, observable, testable | Combinatorial: which groups? A group is only right for the trips that fall inside it, and Buncombe-to-Tennessee is a different group from Buncombe-to-Georgia; storage multiplies |
| **C. Mirror-side clip per request** (= Q1-C) ★ | One file, no merge, no groups, no client native dependency | The mirror is a service (see Q1-C) |
| **D. Choose granularity coarse enough that plurality is rare** | Simplest thing that could work | It does not work where the product lives — the document's own example is that Buncombe County is ~30 km from Tennessee. Plurality is the *normal* case in the launch region |

**Recommendation: C if Q1 = C; otherwise B, scoped to a small hand-curated set of groups
covering the launch regions, with A as the acknowledged long-tail fallback.** Do not put a
way-deduplicating merge on the client as the primary path.

**Decision — adopted 2026-09-03: dissolved by Q1-C.** There is no covering set, so there is no
merge and no way-deduplication anywhere — least of all on the client, which this section's own
recommendation says must never be the primary path. If Q1's D fallback is ever taken, this
question reopens **as B** (mirror-side pre-merged groups), not as A. Recorded in the review as
§12-Q3.

### Q4 — ODbL redistribution review: who signs off

Reframed per L2 — this is not gated on Phase 3, because share-alike is already implicated by
hosted web and by today's sharing surfaces.

| Option | Pros | Cons |
|---|---|---|
| **A. Self-serve: write a `docs/Plotlines_Licensing_Position.md` against the OSMF community guidelines, decide, record as an ARCH D-number** | Fast; cheap; forces the L3 data-model decision while it is still free; produces the artifact any later reviewer will ask for first | No external validation; wrong readings stay wrong until someone external looks |
| **B. Ask the OSMF Licensing Working Group** | Free; authoritative-ish; they answer exactly this class of question routinely; a public answer is reusable | Volunteer turnaround is unpredictable; advisory, not binding; requires a precisely-framed question, which means doing A first anyway |
| **C. Paid counsel with open-data experience** | Binding-ish; the right answer if Plotlines is commercial and share-alike could touch proprietary tables | Costs real money for a question that A + B may fully resolve; premature before the data model is settled |
| **D. Design around it: never distribute or publicly use a Derivative Database** — mirror-side clip only, produced works only, OSM layer kept separable | Reduces the legal question to attribution, which is already solved and mechanical; aligns exactly with Q1-C and L3 | Constrains the architecture on a legal reading rather than an engineering one; "produced work only" needs holding as a genuine invariant, not a preference |

**Recommendation: A now → D as the design posture → B to confirm → C only if a commercial
model puts proprietary data in contact with OSM-derived tables.** Concretely: write the
position doc in Phase 0 (it costs a day and it is the input to the L3 decision), adopt the
separable-layer design, and send the LWG a narrow question about the one case you cannot
resolve — almost certainly "is a shared trip payload containing N OSM-derived POIs a
Produced Work or a substantial extract?"

**Decision — adopted 2026-09-03: A now → D as the design posture → B to confirm.** The position
doc is **Phase 0 work and is filed as #253**, not a Phase 3 gate — L2's whole point is that
share-alike is already implicated by trip sharing, cloning and the anon web reading view. C (paid
counsel) stays out of scope until a commercial model puts proprietary data in contact with
OSM-derived tables. Recorded in the review as §12-Q4.

### Q5 — Keep the interactive Overpass affordance, and whose rate budget

| Option | Pros | Cons |
|---|---|---|
| **A. Keep public instances, hard-capped (P4)** ★ | Free; genuinely the use case public instances exist for; recovers §11.4's freshness for the Authors most likely to have edited OSM themselves; keeps a live-network code path warm, so the fallback does not rot | Still someone else's budget; requires the P4 caps to be real and tested, or it silently becomes the old behaviour again |
| **B. Self-hosted Overpass on the mirror box** | Our budget entirely; no policy question at all; the Pi already exists | An Overpass instance is a real database with real disk and update-daemon requirements — far heavier than static files, and a second ops surface serving a *convenience* feature; regional-only, so it fails exactly at trip edges |
| **C. Drop live Overpass entirely; freshness comes from pin cadence + an "improve this in OSM" link** | Zero third-party dependency; simplest policy story; §10's give-back affordance carries the goodwill | Gives up §11.4 outright. An Author who just mapped a trailhead waits for the pin. That is the *specific* user the product is for |
| **D. Commercial Overpass instance** | Contractual rates; no goodwill question | Recurring cost for a feature used rarely; still a third-party availability dependency |

**Recommendation: A, with the budget named as ours to spend and mechanically bounded.**
The honest framing for §10 is: we removed thousands of km² of bulk load from these
operators, and we are keeping one small, user-initiated, hard-capped query class that is
squarely within what they offer. Pair it with the §10 give-back (OSMF donation, and
Geofabrik if we become a heavy diff consumer) and the position is defensible in public,
which is the real test.

**Decision — adopted 2026-09-03: A, with the budget named as ours to spend and mechanically
bounded.** The affordance ships with P4's four assertable numbers in the same commit that
introduces it — bbox area below `max_query_area_size` so it can never subdivide, concurrency 1, a
per-day budget that fails closed with an honest message, and no automatic retry. Paired with §10's
give-back (OSMF donation; Geofabrik if we become a heavy diff consumer). Phase 5. Recorded in the
review as §12-Q5.

### Q6 — Egress budget when web lands

| Option | Pros | Cons |
|---|---|---|
| **A. Origin serves everything** | Simplest; no new vendor | Egress scales with trips × region size; §11.5's cost curve at its steepest; origin bandwidth is the availability risk |
| **B. CDN in front of the immutable mirror paths** | The §6.4 layout is *designed* for this — build-pinned immutable paths with `max-age=31536000` cache perfectly; one region extract is fetched from origin once per edge, then free; byte-range support is table stakes at any CDN | A vendor and a bill; cache-hit economics only work if the pin is stable (which argues for Q2-B over Q2-D) |
| **C. Object storage with cheap or zero egress (R2, B2)** | Removes the egress line item almost entirely; no origin to saturate; the §6.3 layout maps onto a bucket unchanged, which is what §6.5 promised | Vendor lock on the storage side; still pays for the *hosted clip* compute if Q1 = C |
| **D. Serve bbox clips only, never region extracts** (= Q1-C) ★ | Egress drops by roughly the ratio of bbox area to region area — one to two orders of magnitude; the question stops being a budget and becomes a rounding error | Compute instead of bandwidth; concurrency profile is the unmeasured thing §9 already flags |
| **E. Distribute region extracts P2P / BitTorrent** | Zero egress at scale | Absurd for a planning app; NAT, mobile, and a client that must not do background networking (D41/D57) |

**Recommendation: D + C.** Clip server-side so the bytes on the wire are small, and put what
bulk remains (the pinned region extracts, pulled by the clip service and by any offline
bundle path) on zero-egress object storage. B is the right answer *only* if Q1 lands on A/B
and clients really do download region extracts — in which case the §6.4 immutable headers
are already doing the necessary work and adding a CDN is a config change.

**One number to get before deciding:** §11.5's premise is "an active Author re-pulls a
regional extract for each new trip in a new region." SPIKE-I's extract-size measurement
(§7.1(4)) plus a guess at trips-per-Author-per-region turns this whole question into
arithmetic. It is currently the only open question with no measurement attached, and it is
the cheapest one to attach a measurement to.

**Decision — adopted 2026-09-03: D + C.** Clip server-side so the bytes on the wire are small
(which is Q1-C, already decided), and put the remaining bulk — the pinned region extracts the clip
service reads, and any later offline-bundle path — on zero-egress object storage. The practical
constraint this puts on Phase 1 **now**: §6.3's tree must stay a bucket layout, so no path may
depend on a filesystem, a directory listing, or a server-side rewrite. B (CDN) becomes right only
if Q1's D fallback puts region extracts on the wire to clients, and by then §6.4's immutable
headers have already done the work. **Still owed:** the one arithmetic check — SPIKE-I's extract
sizes × trips-per-Author-per-region. Recorded in the review as §12-Q6 and §6.0.

---

## 6. Suggested checklist amendments

Additive to §13, in the same phases. **Phase 0, Phase 1 and Phase 2 are filed** — the issue
number follows each item. Phase 2's spike amendments are filed **inside the spike issues they
amend** rather than as separate stories, since each is an acceptance criterion on a spike;
2d is a build task and has its own issue.

**The Phase 3+ block was re-triaged on 2026-09-03 and mostly emptied.** The rule "carried into
their phase's epic when it is opened" is what buried them: **neither item was Phase 3 work in
the first place**, and filing by phase label rather than by dependency is how a shipped-code
defect (3b) ended up scheduled behind a mirror it does not need. What genuinely remains in
Phase 3 is one half of one item.

**Phase 0**
- **0a.** Correct the FR138/K11 privacy statement's planning claims in both mirrors
  (`privacy_statement.dart`, `web/about.py`) and their pinned tests. *(P1 — user-facing
  accuracy, independent of every other decision here.)* → **#252**
- **0b.** Pass the Overpass endpoint into the download call instead of driving
  `ox.settings` globals across threads; or serialise OSM access behind one lock. *(G1)* → **#244**
- **0c.** Pull §10's two cheap tests forward: default endpoint list cannot regrow, and a
  non-default UA is set before any OSM request. *(P6 — both testable today.)* → **#251**
- **0d.** Decide the candidate path's failover: fix it, or record it as accepted. *(G2)* → **#250**
- **0e.** Sequence item 2 as *relocate, verify, then delete* — deleting `service/cache/`
  before the relocation lands loses the geocode cache the Nominatim policy asks for. *(P2)* → **#242**
- **0f.** Write `docs/Plotlines_Licensing_Position.md`: the derivative-vs-collective
  reading, the separable-layer decision, and the public-use analysis. *(L2, L3, Q4-A)* → **#253**

**Phase 1**
- **1a.** Add `COPYRIGHT.txt` / ODbL notice files to the §6.3 layout; verify
  `index-v1.json`'s licence before mirroring it. *(L4)* → **#256 / #259**
- **1b.** Give the corridor stand-in an honest path; record covered regions in
  `MIRROR_STATE.json`. *(G3)* → **#257**
- **1c.** Write the Geofabrik pull etiquette into §6.6 as rules, not prose: ≤daily,
  conditional, identified, backs off. *(P5)* → **#258**
- **1d.** Decide whether the mirror is open or client-restricted once internet-reachable. *(P5)* → **#263**

**Phase 2** *(epic #268)*
- **2a.** Add to SPIKE-J's acceptance criteria: *no GPL-licensed binary in the shipped
  artifact* — clip via pyosmium's API, not the `osmium` CLI. *(L1)* → **#266**
- **2b.** Pre-register SPIKE-I's parity bands before running it. *(G5)* → **#265**
- **2c.** Measure the clip **server-side** as well as client-side, so Q1-C is decidable on
  evidence. *(Q1)* → **#265**
- **2d.** Generate a dependency notice bundle at freeze time. *(L5)* → **#267** — a build
  task rather than a spike; #266 records the frozen dependency tree it inventories.

**Phase 3+** *(re-triaged 2026-09-03 — see above)*

- **3a.** Record the OSM pin in `Provenance` / `Attribution` and propagate it to exports. *(L7)*
  — **split.**
  - **3a-i, the producer and the field → #270, Phase 1.** `Provenance` and `Attribution` are
    declared in `trips/payload.py:811-836` and in `$defs/provenance`, and **nothing constructs
    them** — zero call sites in `core/plotlines_core/`. The client already *reads* them:
    `reveal_view.dart:146`'s `attributionForTrip()` merges `trip.provenance?.attribution` with
    the two static credits. A live consumer with no producer. Cheaper now for L3's reason —
    there is no backfill for "what produced this payload", and the schema is a four-consumer
    contract (SPIKE-20). Q2 already folded this in: *"L7's payload pin is part of this answer,
    not separate from it."*
  - **3a-ii, the pin as a mirror build id, and export propagation → stays Phase 3.** That value
    does not exist until the extract path does, and `core/plotlines_core/export/` references
    neither provenance nor attribution today.
- **3b.** Bring the routing graph under `assert_attribution_complete`'s gate, so
  attribution is one policy over all payloads. *(L6)* → **#269, Phase 0 — pulled forward.**
  Not future work: `graph/` carries **no attribution reference at all**, the graph is in neither
  half of the gate (`registry.ready_layers()` never sees it; `_STATIC_ATTRIBUTIONS` is exactly
  `("elevation", "basemap")`), and the fix has no dependency on the mirror, the extract path, or
  either Phase 2 spike. Same argument **P6** made for the two Phase 5 tests pulled forward as
  #251. Today the graph is credited **by accident**, because the basemap above it happens to be
  OSM too.

**Doc amendments owed, not issues.** Two ARCH edits fall out of the above and are wording
changes rather than work: **§12.2 / §13.4** describe attribution as derived from the loaded
layer set, which is now one of two mechanisms — restate it as one policy over every payload, per
§8.1's precedent (#269); and **§8** says a trip pins the build it started on without saying the
pin is *written into the payload*, which is the whole of L7 (#270). Both are owed by decisions
already taken, not by the issues.
