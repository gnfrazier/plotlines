# SPIKE-20 — The trip payload schema

**Covers:** ARCH §6.1 (core's plain-data return), §9.1 (Flutter domain layer), §10.1
(`trip.payload JSONB`), §10.3 (drift's local `trip`); PRD §6 — every FR describing
trip-shaped data; MVP §1.4.5, the third of the four "decisions this list cannot make
for itself" · **Priority:** gates desktop MVP — all 31 carried-over stories write
through this seam · **Run:** 2026-08-16, Linux x86_64 · Python 3.12.12 · Dart 3.12.2 ·
drift 2.31.0 · sqlite3 2.9.4

> **Spike question.** Draft one schema document for `trip.payload`, scoped to MVP
> §1.4.1–1.4.2's 31 stories plus G2a/K10/M12/M13. Implement it three times against one
> fixture trip built on the SPIKE-01/02/03 shared regions: as `plotlines-core`'s actual
> return type from `compose_day`/`split_trip`; written to and read back from a local
> drift `trip.payload` column; deserialized into real Dart domain classes, then
> re-serialized after a simulated Author edit. Diff the final JSON against the original
> at every field.
>
> **Done when.** A schema document is checked into the repo, a fixture multi-day
> multimodal trip round-trips core → drift → Dart → drift with zero field loss or
> silent coercion, and every MVP-scope FR that describes trip-shaped data is mapped to
> a field in the schema.

---

## Verdict

**One document serves all three consumers, with no adapter at any boundary.** The
schema is checked in at **[`docs/schemas/trip_payload.schema.json`](../../../docs/schemas/trip_payload.schema.json)**.

A four-day multimodal trip — solved on real graphs, 927–1,485 geometry vertices —
went `plotlines-core` → JSON → drift → Dart domain classes → JSON on all three shared
regions with **zero field-level differences**, and the schema validated the payload at
every stage: as the core emitted it, as Dart re-serialized it, and after an Author
edit.

Stronger than the bar the spike set: once both producers agree on a canonical form
(sorted keys, compact separators), **Python and Dart emit byte-identical files for the
same trip** — 51,793 bytes in, 51,793 identical bytes out. That was not required, and
it is what makes a content digest meaningful across the boundary, which the cue
sheet's `derived_from.geometry_digest` needs and SPIKE-21 will depend on.

The interesting results are not the round trip. They are the four things the round
trip forced into the open:

1. **The payload holds authored inputs and derived outputs in one object, and an
   Author edit invalidates the second half instantly.** Nothing recorded that. A new
   field, `solve.stale`, does (§5.1).
2. **JSON Schema cannot catch the most likely coercion.** `{"distance_m": 4}` is a
   valid `number`. Only the reader can catch it, and a `as double` reader throws
   (§4).
3. **ARCH §9.1's seven domain classes are not seven payload types.** Three of them are
   deliberately outside the canon, which is P8 working as designed — but the layering
   diagram reads as though one schema covers all seven (§5.2).
4. **`WeightProfile` currently means three different things** in three documents, and
   the payload had to pick one (§5.3).

---

## 1. What round-tripped

The fixture trip is the awkward case, not the tidy one: **Day 1** cycling
point-to-point with an alternate, waypoints, a regroup point, a hazard, two
realised-attribute bands and a real violation; **Day 2** a loop through two via-nodes
at a banded target distance, with notes, media, arc stages and narration trigger
metadata; **Day 3** a rest day with no route, a location, POIs and a scheduled event;
**Day 4** hiking → transition → Author-drawn paddling with a mandatory portage and a
`mandatory_reroute` hazard.

| Region | Payload | gzip | Vertices | Curated nodes | Schema errors | Field loss |
|---|---|---|---|---|---|---|
| Boulder, CO | 51,793 B | 14,143 B | 1,485 | 10 | 0 | **none** |
| Davis, CA | 51,664 B | 14,504 B | 1,478 | 10 | 0 | **none** |
| Viroqua, WI | 35,530 B | 9,371 B | 927 | 10 | 0 | **none** |
| *Week-scale (synthetic)* | 1,204,186 B | 281,412 B | 45,912 | 17 | 0 | **none** |

"Field loss: none" is a type-aware diff of every leaf in the document, not a byte
comparison — `4` and `4.0` are equal in Python and are not the same JSON, so the diff
reports a retype as a difference. Nothing retyped.

The week-scale row is the fixture's own days cloned to seven and its geometry
densified, with identifiers remapped consistently so internal references still
resolve. It exists because the shared regions are small bboxes: a fixture day is a few
kilometres where a real one is sixty. At 45,912 vertices it is past SPIKE-14's 41k
worst case, and it round-tripped losslessly and byte-identically too.

**Geometry is 73.5% of the payload, at 25.6 bytes per vertex.** Everything else — four
days of days, segments, nodes, bands, metrics, hazards, portages, provenance —
is 13.7 KB.

---

## 2. The rules that make it work

Six rules are stated at the top of the schema. Each exists because of a specific way
this round trip goes wrong, and four of them were confirmed by probe (§4):

| Rule | Why |
|---|---|
| **SI units everywhere** | Miles/°F are a display preference (FR79/K5). A trip authored in miles and read in kilometres has to be the same trip. |
| **`[lon, lat]`, RFC 7946 order, 7 dp** | 7 dp is ~1.1 cm — past OSM's own precision. Rounding once at the producer makes every later re-serialization idempotent instead of drifting in the last digits. |
| **Absent means unset; `null` is never written** | `null` means "absent" in Python, "explicitly null" in Dart, and a stored JSON null in Postgres. Three readings of one byte. |
| **Key order carries no meaning** | Postgres JSONB does not preserve it. Verified by shuffling every object's keys and re-running the whole Dart leg: identical result. |
| **Anything fractional is a JSON number, read through `num`** | `round(x)` returns an `int` in Python and `round(x, 1)` a `float`. §4 shows what the strict reader does with the first. |
| **`additionalProperties: false` everywhere** | An unknown key is schema drift surfacing at the boundary that introduced it. |

**Canonical form** (sorted keys, compact separators, `allow_nan=False`) is the seventh
rule, added during the run when the two producers' byte counts disagreed by 7% for no
semantic reason — Python's default separators carry a space. With it, both sides emit
the same bytes.

---

## 3. The Author edit

Three edits, applied through the Dart domain classes to what came *out* of storage —
not to the object still in memory, and not by poking the decoded map:

* add a third via-node to the Day 2 loop
* reword a curated node's note
* change one surface weight (`gravel`, 5.0 → 2.0)

**Result: exactly four differences against the original, all four expected, zero
unexpected**, in all three regions:

```
/days/1/segments/0/via/2                     added    [-105.2194022, 40.0197327]
/days/1/segments/0/nodes/0/note              changed  "The gravel starts here…" → "Rewritten by the Author…"
/days/1/segments/0/weights/surface/gravel    changed  5.0 → 2.0
/days/1/segments/0/solve/stale               added    true
```

The fourth is the finding, and §5.1 is about it. The edited payload validates, and
re-storing it produces identical bytes a second time.

---

## 4. Four ways it breaks, probed

| Probe | Caught by the schema? | Caught by the reader? |
|---|---|---|
| `{"distance_m": 4}` where `4.0` was meant | **No** — `4` is a valid `number` | Strict `as double`: `type 'int' is not a subtype of type 'double'`. Shipped `as num` reader: `4.0`, correct. |
| `"title": null` | **Yes** — `None is not of type 'string'` | Yes — `trip.duration is null; the schema forbids null` |
| An unknown key from a newer producer | **Yes** — `Additional properties are not allowed ('unexpected_field' was unexpected)` | Yes — `unread field(s) on trip: [unexpected_field] — the domain layer would have dropped them on the next write` |
| A non-finite float (`NaN`) | n/a — never reaches JSON | Producer refuses: `Out of range float values are not JSON compliant: nan`. Had it not, Dart's decoder rejects the file: `Unexpected character (at character 14)` |

**The first row is the load-bearing one.** JSON Schema's `number` accepts an integer,
so validation cannot catch a retyped distance — and the natural Dart spelling
(`json['distance_m'] as double`) throws at the boundary rather than at the mistake, on
a file that passed validation. That is why the domain layer reads every fractional
field through `num`, and why the diff in §1 is type-aware.

The fourth row matters for a specific reason: FR88's elevation-void policy makes `0.0`
the fallback, and a NaN that escapes it would produce a file this codebase can write
and the client cannot read. `allow_nan=False` in the producer turns that into a
failure at the write, where it belongs.

---

## 5. Findings that change the build

### 5.1 `solve.stale` — the derived half of the payload needed a name

`trip.payload` mixes two kinds of data with one lifetime each: **authored inputs**
(via-nodes, weights, target distance, notes) and **derived outputs** (geometry,
metrics, elevation, roll-ups, cue sheets). The moment an Author adds a via-node, the
derived half describes a route nobody asked for — and nothing in ARCH §10.1/§10.3
recorded that. drift's `dirty` column is about sync, not staleness; `updated_at` moves
for a reworded note too.

Without a flag, a client has two bad options: re-solve on every keystroke, or show the
previous route's distance and climbing as if they described the edited one. **Added
`solve.stale` to the schema** — the client sets it, only a solve clears it, and the
dashboard (D1) reads it to know when its numbers are provisional. One boolean, and it
only exists because an edit was actually performed rather than imagined.

### 5.2 ARCH §9.1's seven domain classes are not seven payload types

§9.1 lists `Trip, Day, Segment, WeightProfile, RiderProfile, FieldNote, Amendment` as
one layer. Four are in the payload; **three are deliberately outside it**:

| Class | Where it actually lives |
|---|---|
| `RiderProfile` | `rider_profile(account_id, fields JSONB)` — account-scoped, not trip canon, and FR78-consented per field |
| `FieldNote` | `field_note(...)` — a group-relay layer over the canon (P8); a note can never mutate `trip.payload` |
| `Amendment` | `amendment(...)` — same |

This is P8 working exactly as designed, and it is not a defect. It is worth writing
down because the layering diagram reads as though one shape covers all seven, and a
client author who assumed that would put a field note inside the trip blob — the one
thing §10.1 says must be impossible.

### 5.3 `WeightProfile` means three different things right now

| Where | Shape |
|---|---|
| PRD FR2–FR5 (Author-facing) | `climbing`, `traffic`, per-class bipolar `surface`, `poi` density + type, all 0.0–5.0 |
| ARCH §6.3 (documented) | `climbing`, `traffic`, `surface_pref: dict[str, float]`, `poi_bonus`, `detour_budget`, `terrain_technicality` |
| `core/plotlines_core/scoring/profile.py` (implemented) | `quiet`, `surface`, `scenic`, `directness`, `peaks`, all 0.0–1.0 (`peaks` −1..1) |

The third is SPIKE-00/01/02/03's solver profile and it is *not* the second. The payload
had to pick one, and picked **the Author-facing form**: it is what an Author set, it is
what a UI redraws, and it is the only one of the three that is stable under a change of
scoring implementation. The solver's form is derived on the way in (`w = ui / 5.0`, and
`(ui − 2.5) / 2.5` for the bipolar climbing term) and **never stored beside it** —
storing both is two representations of one preference, and they disagree the first time
one is edited without the other.

**This leaves a real conversion to write** in `scoring/`, and a documentation gap: ARCH
§6.3's field list matches neither the PRD nor the code. That is a doc fix, not a spike
finding, but it would have been found the hard way by whoever wired the first slider.

### 5.4 G2a's trip list must project columns — measured, not asserted

`select(trips)` is `SELECT *`, so a library screen drawing titles pulls every payload
into memory. With 20 saved week-scale trips:

| Query | Time |
|---|---|
| `SELECT *` (drift's `select(trips)`) | **137.1 ms** |
| Three-column projection (`id`, `name`, `updated_at`) | **1.0 ms** |

137 ms is eight dropped frames to draw a list of names. G2a's AC also asks for
**modes** per row, which is the one thing it needs that no column carries —
recommendation: a denormalized `modes` column on the drift row rather than decoding a
megabyte per entry. (`listTrips` is kept in `database.dart` beside the projected query
precisely so this stays measurable.)

### 5.5 `split_trip` is not what it does

ARCH §6.1 names it `split_trip(days, limits) -> Trip`. What it does — and all C3
requires — is *assemble*: number the days, apply the per-mode limits, roll the metrics
up, record breaches. Automatic day-splitting (cutting a long route into days that fit
the limits) is a different operation the signature has room for and MVP does not need.
Implemented as written, documented as what it is.

---

## 6. What it costs the client

Steady-state, best of five passes, on the Linux box above:

| | 4-day fixture (1,485 vertices, 51.8 KB) | Week-scale (45,912 vertices, 1.20 MB) |
|---|---|---|
| `jsonDecode` | 0.57 ms | 4.4 ms |
| Build domain classes | 0.60 ms | 4.6 ms |
| Re-serialize (canonical) | 2.8 ms | **22.7 ms** |
| drift write (first, includes schema create) | 61 ms | 89 ms |
| drift read | 8.8 ms | 13.0 ms |
| SQLite file | 1.1 MB | 25.3 MB (20 rows) |

First-pass decode is ~18× the steady state (10.5 ms vs 0.57 ms) — that is the Dart VM
warming up, not the payload, and it is why the table reports the best of five.

**Two of these cross the 16.7 ms frame budget at week scale**, which is a direct
contribution to **SPIKE-15**'s open question ("find the payload size at which the main
isolate visibly stutters"):

* **Re-serialization (22.7 ms) and drift writes (89 ms) belong off the main isolate.**
  Both happen on save, which is exactly when an Author is watching.
* **Decode + domain build together are 9.0 ms at 45,912 vertices** — under one frame,
  but not by much. The stutter threshold for the *read* path sits somewhere past a
  week-long trip, so SPIKE-15 should start its sweep there rather than below it.

**Storage sizing:** a real week-long trip is ~1.2 MB of JSON, ~280 KB gzipped. Twenty
of them is a 25 MB SQLite file — fine on desktop, and worth knowing before the hosted
tier stores the same blob in a JSONB column. Per-vertex elevation samples would add
**18%** (9.3 KB on the 51.8 KB fixture), which is why `elevation.samples` is optional
and omitted by default: D2's profile view can re-derive it from geometry and the DEM.

---

## 7. FR coverage

Every MVP-scope FR describing trip-shaped data, mapped to a schema pointer or an
honest reason there is none. `run.py` resolves each pointer against the schema and
fails if one does not exist, so the table cannot rot silently. Full table in
[`fr_map.py`](../fr_map.py); `results.json` carries it verbatim.

| Status | Count | |
|---|---|---|
| **mapped** | 37 | FR2–FR12 (FR13 retired), FR15–FR21, FR27, FR28, FR31, FR36, FR37, FR38, FR40, FR41, FR45, FR62, FR74a, FR85, FR86, FR88, FR89, FR95, M12 |
| **out_of_payload** | 5 | FR43 (GeoJSON export is a projection), FR44 (export contents are request parameters), FR79 (display prefs are user-scoped), FR81 (reset acts on unsaved state), M13 (a handling surface) |
| **placeholder** | 1 | FR46 — the cue sheet, waiting on SPIKE-21 |
| **gap** | 3 | FR14, FR22, FR35 |

The three gaps, each with its reason and its cost to close:

* **FR14 — the paddling gauge band (B8, Leg 3).** Deliberately absent: SPIKE-19 has not
  yet confirmed which identifier joins a reach to a gauge after the NHD retirement, and
  a field shaped around the wrong identifier is worse than no field. Closing it is a
  `paddling_gauge` object on `segment` — additive, because segments already carry
  per-mode detail.
* **FR22 — group-size tier (C6, P1).** One enum on the trip root.
* **FR35 — offline buffer distance (C14, P1).** Arguably not trip canon at all — it is
  a download parameter. Recorded so the question gets asked rather than assumed.

---

## 8. SPIKE-21's dependency is discharged

SPIKE-21 was written to depend on this spike "for where derived output is written".
That place now exists and round-trips: `day.cue_sheet` with `generated_at`,
`generator`, `derived_from.{segment_ids, geometry_digest}`, and an ordered `cues`
array whose entries carry `sequence`, `distance_along_m`, `kind` (turn / surface /
node / hazard / event / portage / transition / alternate / start / finish),
`instruction`, `modifier`, `bearing_deg`, and a `ref_id` back to the node, hazard,
portage or alternate a cue was derived from.

What SPIKE-20 fixed is the *shape and identity* of a cue. What SPIKE-21 still owns is
every question about deriving one: collapsing shape-only vertices to decision points,
the density ceiling, the unknown-surface-tag rule, interleaving and minimum spacing,
and the retraced-spur labelling. Adding a field to `cue` is a schema patch; discovering
there was nowhere to put the output would have been a rewrite. **SPIKE-21 is unblocked.**

`geometry_digest` is also now meaningful rather than aspirational, because §1's
byte-identical canonical form means a digest computed in Python verifies in Dart.

---

## 9. Limits — what this spike did not prove

* **No Postgres.** Desktop MVP has no hosted tier, so `trip.payload JSONB` (§10.1) was
  not exercised against a real server. The two JSONB behaviours that matter were
  handled by rule instead of by test: key order carries no meaning (probed by
  shuffling), and duplicate keys are impossible in these producers. **A JSONB round
  trip should be re-run when the hosted tier lands** — in particular to confirm that
  `numeric` preserves the exact decimal forms this schema writes.
* **No Flutter widget layer.** The Dart leg is a console program on pure-Dart drift.
  §9.1's Riverpod/presentation layers above the domain classes are untouched, and the
  isolate question is SPIKE-15's.
* **Sync fields unexercised.** `version`, `dirty`, `server_version` exist in the drift
  schema as ARCH §10.3 writes them, but FR59's version-check protocol is hosted-tier
  work and was not run.
* **The week-scale payload is synthetic in its geometry**, real in its structure. Its
  vertex count comes from densifying real solved routes, not from routing a 400 km day
  on a bbox that does not contain one.
* **One serializer pair.** Python's `json` and Dart's `dart:convert`. A third producer
  (a plugin, an importer) is not proven to agree, though the canonical-form rule is
  what would make it.

---

## 10. Decisions this spike takes

1. **`docs/schemas/trip_payload.schema.json` is the authority.** Where the Python
   dataclasses, the drift column, or the Dart classes disagree with it, it wins — it is
   the only artifact all three read.
2. **The payload stores the Author-facing weight profile** (FR2–FR5's 0.0–5.0 form),
   never the solver's internal form, and never both.
3. **Canonical form is sorted keys + compact separators + no non-finite floats.** Both
   producers implement it; it is what makes digests and byte comparison possible.
4. **`solve.stale` is set by the client on any edit to a solved segment's inputs**, and
   cleared only by a solve.
5. **Trip-library surfaces project columns; they never `SELECT *`.** A `modes` column
   on the drift row is the recommended way to satisfy G2a's per-row modes.
6. **The payload is SI and metric-canonical.** Unit preference is applied at render.
7. **`compose_day` and `split_trip` land in `core/plotlines_core/trips/`** as written
   here, and are the only supported way to build a payload — because the derived
   fields (gap measurement, limit breaches, roll-ups) are written there and nowhere
   else.

---

## Reproducing

```bash
PYTHONPATH=core .venv/bin/python spikes/SPIKE-20/run.py
```

See [`../README.md`](../README.md) for the one-time Dart setup. `results.json` holds
every number in this document; `fixtures/*_trip.json` are the payloads themselves —
small enough to read, and re-validatable against the schema by anything that speaks
JSON Schema 2020-12.
