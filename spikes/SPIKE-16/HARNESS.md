# SPIKE-16 live harness — the device tests this environment cannot run

The offline half (`run.py`, `tests/`) proves a **pure-Python, zero-dependency FIT
course writer produces spec-conformant, CRC-valid bytes** whose structure matches
what real Garmin devices write (verified against `spikes/fit_files/`). What it
**cannot** prove is the issue's actual "done when": *a generated FIT course loads
and displays its course points correctly on head units from two vendors.* That is
this document.

Same standing as SPIKE-G / SPIKE-13: a pre-registered spec, ready to run when the
hardware is in hand, so the verdict below is falsifiable rather than assumed.

## Inputs (already generated)

| file | role |
|---|---|
| `results/spike16_course.fit` | the **Python-in-core arm's** output — load this as-is |
| `results/fixture.json` | language-neutral payload — the **Dart-FFI arm** builds its own `.fit` from this |
| `results/selfcheck.json` | the offline check results, for the write-up |

## Arm A — Python-in-core (candidate; already built)

Nothing more to build. `results/spike16_course.fit` is the artefact.

## Arm B — Dart FFI against the official Garmin FIT SDK

Build a throwaway Dart CLI that:

1. `dart run` on desktop, links the Garmin FIT SDK C library via `dart:ffi`
   (or the SDK's C++ encoder behind a thin C shim).
2. Reads `results/fixture.json`, emits `spike16_course_ffi.fit` using the SDK's
   `Encode` / `CoursePointMesg` API.
3. Record: LOC added, native toolchain steps per platform (Win/macOS/Linux, then
   iOS/Android for the mobile reality check), binary-size delta, build-time delta.
   This is the **risk A5** cost — a native dep on a binary already carrying
   GDAL/GEOS.

The reveal gate still applies to Arm B: `fixture.json`'s `reveal_canary` must not
appear in `spike16_course_ffi.fit`. Assert on the bytes, same as Arm A.

## Devices — at least two vendors

| vendor | suggested unit | why |
|---|---|---|
| Garmin | Edge 530/540 or 830/840 | the reference FIT consumer; strictest parser |
| Wahoo | ELEMNT BOLT/ROAM | different parser lineage; known to be picky about `course` files |
| (bonus) Coros | DURA / any nav-capable | third data point if available |

Load **both** `.fit` files onto **every** device (USB mass-storage `/NewFiles/`
for Garmin, Wahoo companion app or `/plans/` for ELEMNT).

## What to record — per file, per device

### Acceptance
- Does the file import at all? (accepted / rejected / silently ignored)
- Does it appear as a **course/route** (navigable), not just a saved activity?
- Does the track render with elevation profile?

### Course-point fidelity — the FR45 table

For each of the five required types, record what the device actually does:

| our `cp_type` | FIT enum | Garmin shows | Wahoo shows | Coros shows |
|---|---|---|---|---|
| `left`    | 6 (`left`)    | | | |
| `water`   | 3 (`water`)   | | | |
| `food`    | 4 (`food`)    | | | |
| `danger`  | 5 (`danger`)  | | | |
| `generic` | 0 (`generic`) | | | |

For each cell capture: the **icon** drawn, whether it produces a **turn/cue
prompt** or only a map pin, and whether it fires an **alert** on approach.

### Notes (FR45 "plot-point notes preserved … where supported")
- Does the `course_point.name` string display in full?
- **Truncation point** — the writer currently hard-caps at 64 bytes and the dump
  shows mid-word cuts ("…the right for", "Walk "). Record each device's real
  display limit (Garmin has historically shown ~15–30 chars in the cue list, more
  on the point detail screen) so the writer's truncation rule can be set to the
  measured floor and cut on a word boundary.
- Does any device surface a separate notes/description field we should target
  instead of `name`?

### Reveal (ARCH P11 / punch-list §6A.2)
- Confirm the withheld point (`pp-still-site` / "Old still site") is **absent**
  from every device's course-point list. (It is already absent from the bytes;
  this is the belt-and-braces field check.)

### Areas (FR108) and offsets (FR107)
- `fixture.json` carries one area anchor (`area-rail-district`, a polygon) and
  one offset role (`pp-shuttle-pickup`, ~40 m off-trail). The writer currently
  **drops the area** (no native FIT slot) and **honours the offset** (exports the
  point at its offset position). Record whether a centroid course-point for the
  area would help or clutter on each device.

## Decision rule (pre-registered)

- **If both arms load and render the five course-point types equivalently on
  both vendors** → **Python-in-core ships.** The FFI arm's fidelity does not beat
  it, and it costs a native per-platform dependency + the SDK redistribution
  obligation (`licence_notes.md`) + the core-boundary fork. No Decision-Log
  entry needed beyond "SPIKE-16: in-core writer confirmed."
- **If the FFI arm renders a type or a note that the Python arm cannot** → record
  the specific gap. Only then does exporting one format outside the core become a
  live option, and it goes to the Decision Log as a **P1 boundary** call with the
  measured gap attached — not a library preference.
- **If neither arm renders a type on a vendor** (e.g. Wahoo ignores `danger`) →
  that is an **FR45 AC narrowing**: "native where the target format supports
  them" is then defined per-device by this table, and the PRD AC cites it.
