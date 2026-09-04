# Plotlines Licensing Position

**Date:** 2026-09-04 · **Issue:** #253 (Phase 0.13, checklist amendment 0f) · **Status:** adopted
2026-09-04, recorded as ARCH **D60**.
**Input:** [`Plotlines_OSM_Acquisition_Review.md`](Plotlines_OSM_Acquisition_Review.md) §4, §11.6,
§12-Q4; [`Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md`](Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md)
L2, L3, Q4.

**Not legal advice.** This is an engineering position, written down, against the ODbL 1.0 licence
text and the OSMF's own community licence/guidelines pages, so that a design decision with a real
cost to reverse gets made on a considered reading rather than by accident. Paid counsel is out of
scope until a commercial model puts proprietary data in contact with OSM-derived tables (Q4-C);
this document is what such counsel, or the OSMF Licensing Working Group, would be handed first.

---

## 0. Verdict

**Plotlines' OSM-derived data and its own authored content are a Collective Database, not a
Derivative Database, provided they stay structurally separable — and they already are.**
`AnchorProvenance` (`core/plotlines_core/content/anchor.py`), which stamps every promoted anchor
with the layer it came from, has existed since 2026-08-24 — **before** the acquisition review and
its addendum were written. L3 asked whether to *adopt* a per-feature source discriminator; the
correct answer is that Plotlines already did, nine days before the question was posed. That is
this document's one correction to the addendum, and it does not change the addendum's
recommendation — it means the recommended design posture (§4 below) was already the shipped one
for anchors, and what remains is to state that plainly, close the one real gap it left open (§3),
and adopt the posture as policy rather than accident.

The design posture that follows (§4) reduces the live legal question to attribution, which is
already mechanical and release-gated (D45, FR101). One question is worth sending to the OSMF
Licensing Working Group to confirm the substantiality reading (§5); sending it is optional per the
issue's acceptance criteria and is not a blocker for anything in this document.

---

## 1. Public-use analysis

ODbL 1.0's share-alike (§4.5) and offer-of-database (§4.4) conditions attach when a Derivative
Database is **Publicly Used** — a defined term that includes making the database available over a
network, not only handing someone a file. §4.3's attribution notice is broader: it attaches to
Public Use of the Database *or* of a Produced Work made from it, so attribution is owed on
everything below regardless of how the Derivative/Collective question resolves. What is actually
open, surface by surface, is whether §4.4/§4.5 attach on top of that.

| Surface | Built today? | What crosses the wire | Public Use? | Substantiality reading |
|---|---|---|---|---|
| **`GET /candidates`, `GET /layers`, `GET /attribution`, `GET /about`** | Yes | Scored OSM features (coord, tags, salience) to the Author's own client during authoring | The Author is the same actor who initiated the fetch — not obviously "the public" in ODbL's sense, and never persisted as a database the Author does not already control | N/A — this is Use, not redistribution to a third party; attribution is owed and is satisfied (§4) |
| **Hosted web, Phase 4** (`#279`–`#282`, not yet built) | No | Rendered produced works — a map view, a cue sheet, a rendered itinerary — served from a server-side OSM-derived store to a reader who is not the Author | **Yes, unambiguously.** Serving over a network to a third party is the literal definition of Publicly Use | Substantiality is per-Produced-Work: a rendered map or itinerary is the paradigm Produced Work example in the OSMF guidelines, not a database extract — **low risk if it stays render-only** |
| **Anonymous web reading view** (D59/SPIKE-F, spec'd, gated to Leg 4, not yet a live endpoint) | No | The always-visible subset of a shared trip, to an unauthenticated reader | Yes, by the same reasoning — a share token is precisely a mechanism for making a Derivative Database available to the public over a network | The reader gets a rendered view (D59: `anonymous_view(payload)`), not a raw JSON extract, in the shipped design — same reasoning as hosted web. **The open question is the API shape underneath it** — see below |
| **Trip sharing generally** (share tokens; the mechanism D59 builds on) | No | A trip payload — or a filtered view of one — to a recipient who is not the Author | Yes, once it ships, on the same reasoning | Turns on whether the wire format is a rendered view or a structured document (JSON with `anchors[].provenance` intact) — the precise ambiguity §5's LWG question names |
| **Cloning** (D55, decided, not yet built) | No | Copies an allowlisted subset of one Author's trip into a **different Author's own trip** in the same service, never crossing to an outside party by itself | Weaker case for Public Use — the copy stays inside Plotlines-operated infrastructure between two accounts, not published to the world. It becomes a Public Use question only combined with whatever that second Author then does (share, print, host) | Not independently substantial; inherits whatever the eventual publishing act's reading is |
| **Mirror-side bbox clip** (Phase 1, Q1-C, `#264`) | Not yet | Raw `.osm.pbf` bytes, clipped to a bbox, served by the Plotlines mirror to the Plotlines client | **Yes — this is unambiguous Derivative Database redistribution**, not a substantiality question at all: it is literally OSM data, clipped. Already correctly scoped as such (L2's "easy case") and already gated by L4/L6 (`COPYRIGHT.txt` in the mirror tree, `#256`/`#259`; the attribution gate reaching the graph, `#269`) | N/A — full ODbL notice obligation, satisfied mechanically once L4/L6 land; no share-alike question because it *is* OSM data, not a merged database |
| **Interactive Overpass affordance** (Phase 5, hard-capped, `#284`–`#285`) | Not yet | A live query result, ephemeral, rendered to the requesting Author only | Same as row 1 — Use, not redistribution | N/A |

Three things fall out of this table that the addendum's L2 framing (correctly) pushed toward, and
that this document confirms:

1. **The rendered/produced-work surfaces (hosted web, anon reading, general sharing) are where the
   real question lives**, and it is a *shape* question, not a volume question: does the wire format
   the reader receives stay a rendered produced work, or does it expose a structured, re-usable
   extract of OSM-derived records (coordinates, names, categories) that a recipient could pull back
   out? A JSON API response with `anchors[]` intact is the latter even if a human only ever sees the
   rendered map on top of it — the OSMF guidelines assess what is *made available*, not only what a
   typical viewer does with it.
2. **Cloning is the weakest Public-Use case of the three** the addendum named, because the copy
   never leaves Plotlines-operated infrastructure by itself — it becomes live only in combination
   with a later share/host/print act, which is already covered by its own row.
3. **The mirror-side clip is not actually a substantiality question and was never in doubt** — it
   is openly, entirely OSM data, and is handled correctly today as a distribution event under L4/L6,
   independent of everything else in this table.

---

## 2. Derivative vs Collective

The operative OSMF community-guidelines terms, applied:

- **Produced Work** — "a creative, artistic, presentational or otherwise transformative work
  produced using [OSM data] as one of its sources, that is not otherwise a Derivative Database" —
  a map image, a route description, a printed cue sheet, a rendered itinerary page. Attribution is
  owed (§4.3); share-alike is not, because the Produced Work is not itself a database.
- **Derivative Database** — "a database based upon a Database (as modified, e.g., through
  extraction, translation, addition, alteration, or updating), and includes a database formed by
  combining it with other data or by extracting parts of it." A dataset that keeps the *shape* of a
  database — records, coordinates, keyed attributes, queryable structure — even after selection or
  reformatting.
- **Collective Database** — the guidelines' own resolution for the case Plotlines is actually in:
  "a database consisting of a number of separate and independent databases," where the OSMF's
  position is that combining OSM data with other, independently-produced data as **separate
  layers** does not turn the whole into one Derivative Database subject to share-alike, as long as
  the OSM-derived part stays identifiable and the other part is not itself built by copying from
  OSM.
- **Horizontal Map Layers** — the guideline that names Plotlines' exact shape: OSM contributes one
  layer (the geographic/POI substrate); an operator's own layer (narrative content, roles, reveal
  policy, arc, itinerary structure, weights) sits alongside it. Kept as genuinely separate layers,
  the whole is a Collective Database and the operator's layer is under whatever licence the
  operator chooses.
- **Substantial** — "a quantitatively or qualitatively substantial part of the Contents." The
  guidelines are explicit that this is not a bright-line percentage and weighs both axes; a small
  number of records can still be substantial if they are the qualitatively significant ones for the
  purpose at hand. This is why §1's per-surface reading matters more than a single "N POIs is fine"
  rule — a trip's handful of promoted anchors is *usually* insubstantial by volume, and this
  document does not treat that as guaranteed for every trip.
- **Trivial Transformations** — format conversion, cropping/clipping to an area, and similar
  operations do not turn OSM data into something new; a bbox-clipped extract (the mirror's Q1-C
  behaviour) is still OSM data, full stop, which is exactly why that row in §1 is a distribution
  question and not a substantiality one.
- **Geocoding** — the guidelines' worked example closest to Plotlines' shape: looking up a location
  from OSM data and publishing only the derived result (a coordinate, a label) without exposing the
  underlying database is generally a Produced Work, not a Derivative Database extract — provided
  what is published is the *result*, not a re-usable structured record set.

**The decision:** Plotlines' trip payload is a **Collective Database** — an OSM-derived layer
(candidate-sourced anchor identity: coordinate, name, category, tags) combined with a
Plotlines/Author-authored layer (titles overridden after promotion, notes, role sets, reveal
policy, arc, itinerary structure, weights, metrics) — **conditioned on the two layers staying
separably identifiable**, which is exactly the Horizontal Map Layers guideline's own condition and
exactly what §3 confirms is already true in the shipped schema.

---

## 3. The separable-layer decision: **yes** — and it shipped 2026-08-26

L3 asked whether to "adopt a per-feature `source`/provenance discriminator on the candidate record
and the promoted `Node`, so an 'offer the derivative database' obligation can be satisfied by
exporting the OSM layer rather than the whole trip store." The answer is yes, and checking the tree
against the question the addendum itself points at (`trips/payload.py:812-828`, now the `Provenance`/
`Attribution` classes at approximately that range) turned up an adjacent structure that already
answers it:

- **`core/plotlines_core/content/anchor.py`** declares `AnchorProvenance` — `kind`
  (`candidate`/`cluster`/`hand_placed`), `source_id`, **`layer`**, `tags` — committed **2026-08-24
  to 2026-08-26** (`git log`), which predates both the acquisition review and this addendum
  (2026-09-03).
- **`docs/schemas/trip_payload.schema.json`**'s `$defs/anchor_provenance` carries the identical
  shape and is the wire authority (`Anchor.to_dict()` and the Dart `AnchorProvenance.toJson()` both
  answer to it).
- **`client/lib/domain/promote.dart`**'s `provenanceFromCandidate` populates it at the moment of
  promotion — `layer: candidate.layer` — for every candidate-sourced anchor, and the cluster-promotion
  path in `proposals_view.dart` does the same from the cluster's top member. A hand-placed anchor
  gets `AnchorProvenance(kind: hand_placed)` with `layer: null` — correctly unattributed to any
  external source, because it isn't one.
- **`AnchorProvenance.layer` round-trips to a real licence.** It is the same string
  `LayerRegistry.provider(layer)` keys on, and `LayerProvider.licence` (`LayerLicence`) is what
  `attribution.attributions_for` already reads. The discriminator is not just present — it is
  sufficient on its own to reconstruct which licence governs which anchor, with no second lookup
  table to keep in sync.

**Why the addendum read this as open:** the review and addendum were written against
`Trip.days[].segments[].nodes[]` — the older, day-scoped `Node` shape in `trips/payload.py` — which
genuinely has no such field. The trip-scoped `anchors[]` array (ARCH D36, "candidates are cache;
anchors are canon") is the *current* promoted-place model, is what promotion actually writes to
(`current_trip_provider.dart`'s `promoteAnchor`), and is where the discriminator already lives.
This is the pattern the `plotlines-build` skill names directly: a doc read against an older shape,
overtaken by shipped code, is a doc bug rather than an open design question — recorded here rather
than left in the transcript only.

**What is genuinely still open, and is filed as its own implementation issue (`#301`):**

1. **Nothing today reads `anchor.provenance.layer` to produce "the OSM layer" as a standalone
   artifact.** The discriminator makes the offer-the-database obligation *cheap to satisfy if it is
   ever invoked*, but no function or endpoint currently filters `Trip.anchors` down to the
   OSM-sourced subset and emits it — that one function is the actual mechanism §4.4 would need, and
   it does not exist yet. This is a small, well-scoped addition alongside `#270`'s work populating
   trip-level `Provenance`/`Attribution` (same files, same phase-1 timing), not a schema change.
2. **A cluster-promoted anchor's provenance is stamped from only its cluster's top member**
   (`proposals_view.dart:356`, `p.members.first`). If a cluster merges candidates from two different
   layers (an OSM candidate co-located with a plugin candidate, exactly SPIKE-H's real-data case —
   14 of 30 proposals mixed sources), the resulting anchor's single `layer` field silently drops the
   second source's provenance. This does not break `assert_attribution_complete` (that gate
   enumerates *loaded layers*, not anchors-per-layer), but it does mean the future OSM-layer-export
   function in point 1 would under-report for a cluster-merged anchor. Worth a line in `#301`, not a
   blocker on adopting the decision.

---

## 4. The design posture

Adopt **Q4's option D**: produced works and mirror-side clips only; the OSM layer kept structurally
separable. Concretely, against §1's table:

- **Hosted web and the anonymous reading view** serve rendered produced works (map tiles, rendered
  itinerary/cue-sheet pages) as the primary surface — this was already D59's shape for the reading
  view (`anonymous_view(payload)`, not a raw payload dump) and should be the explicit rule for
  hosted web generally, not an accident of how the prototype happened to be built.
- **Any JSON/API surface that does expose `anchors[]` with `provenance` intact** (needed for the
  Dart client to render anything, and unavoidable for a native/offline reading experience) stays
  **authenticated and Author-or-invited-only** — the anonymous case is where Public Use to a
  genuinely unknown party is live, and that is exactly the surface D59 already restricts to a
  rendered, revealed-content-filtered view.
- **The mirror-side clip stays governed by L4/L6**, unrelated to this question — it is already
  correctly treated as literal OSM redistribution, not a Collective Database question.
- **Attribution is owed everywhere in the table regardless**, and is already mechanical (D45,
  FR101, `assert_attribution_complete` / `assert_about_attribution_complete`) — this posture does
  not add a new attribution obligation, it is what keeps the *share-alike* question from ever
  needing to be litigated per-trip.

This is materially the posture the shipped `AnchorProvenance` design already put in place for
anchors; adopting it here makes it a stated policy rather than a property nobody had connected back
to the licence question.

---

## 5. The one question for the OSMF Licensing Working Group

Sending it is optional (per #253's acceptance criteria) and not required for this document to be
complete. If sent, this is the question, framed against §1's actual ambiguity rather than a generic
one:

> Plotlines is a trip-planning application. An Author draws a bbox, and OSM points of interest
> inside it are notability-scored and offered as candidates; the Author *promotes* a handful
> (typically 5–40 per trip) into named "anchors" that also carry the Author's own narrative content
> (titles, notes, arrival triggers). A promoted anchor's OSM origin — the layer it came from — is
> recorded separably from the Author's own content, per the OSMF's Horizontal Map Layers guidance.
>
> When an Author shares such a trip with another person (via a public link, requiring no account),
> is the resulting shared trip — served either as (a) a rendered read-only web page (map + narrative
> text), or (b) the JSON document underlying that page, containing the promoted anchors' coordinates,
> names, and OSM-sourced category tags — a **Produced Work** under §4.6, or a **substantial extract
> of a Derivative/Collective Database** subject to §4.4/§4.5? Does the answer differ between (a) and
> (b)? Attribution is provided in both cases regardless; the question is only about the
> offer-of-database and share-alike conditions.

---

## Decision, recorded as ARCH D60

> **D60 — Plotlines' trip payload is a Collective Database: the OSM-derived anchor layer
> (coordinate, name, category, tags — via `AnchorProvenance.layer`, shipped 2026-08-24) stays
> structurally separable from Plotlines/Author-authored content, which is what keeps ODbL
> share-alike from reaching Plotlines' own tables. Design posture: produced works and mirror-side
> clips only — hosted web and the anonymous reading view serve rendered output, not raw
> payload dumps, to an unauthenticated party; any authenticated API surface exposing
> `anchors[].provenance` is Author-or-invited-only. The mirror-side bbox clip (Q1-C) is unrelated
> literal OSM redistribution, governed by L4/L6, not this decision. Attribution is owed on every
> surface regardless and is already mechanical (D45).**

This is recorded in `Plotlines_ARCHITECTURE_v2.md` §17 alongside D59, in the same commit as this
document.

---

## Acceptance against issue #253

- [x] `docs/Plotlines_Licensing_Position.md` exists and covers the public-use analysis (§1),
  Derivative-vs-Collective with the guidelines cited by name (§2), the separable-layer decision
  (§3), the design posture (§4), and the LWG question (§5).
- [x] The separable-layer decision is made — **yes**, and it was already built; the one gap it
  left (an OSM-layer export function, and the cluster-provenance under-reporting) is filed as
  **#301**.
- [x] Recorded as ARCH **D60**.
- [x] The LWG question is drafted in §5; sending it is optional and separate, per the issue.
