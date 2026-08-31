# SPIKE-16 results — Byte-accurate FIT export

**Recorded:** 2026-08-30 · **Issue:** [#163](https://github.com/gnfrazier/plotlines/issues/163)
**Covers:** PRD **FR44 / FR45** · story **F3** `[MVP]` · ARCH §6.1 (`export_trip` in the core), §7.2 (`POST /trips/{id}/export`), §13.3 · risk **A5** · punch-list §6A.2

---

## Verdict

**F3 ships the FIT writer in `plotlines-core`, in Python, with no dependency —
not Dart FFI against the Garmin FIT SDK.**

The proposal to move FIT out of the core rested on an assumption: that a correct
FIT course file is hard enough to produce that only Garmin's own SDK can be
trusted to do it. **That assumption does not survive contact with the format.**
This spike built the writer — file header, definition/data message framing,
CRC-16, the seven-message course sub-profile, semicircle/`(m+500)*5`/`m*100`
unit encodings — in **~90 lines of dependency-free Python** (`fitenc.py` +
`profile.py`), and verified it two ways that "it parsed in a validator" does not:

1. **The CRC and the container framing are validated against 10 real Garmin
   activity files** (`spikes/fit_files/`). The spike's CRC-16 reproduces the
   stored header CRC and trailing file CRC on **10/10**; the spike's decoder
   re-reads all 10 with both CRCs valid. Format understanding is measured against
   what real devices wrote, not against a spec reading.
2. **The generated course round-trips** — `decode(encode(fixture))` recovers
   every field to the byte, including the five required `course_point` types
   (`left`/`water`/`food`/`danger`/`generic` → enums 6/3/4/5/0), elevation, and
   distance.

`run.py` runs 25 offline checks, all green (`results/selfcheck.json`). 24 pytest
tests cover the CRC, the encoder, the decoder against the reference corpus, and
the reveal/fidelity findings.

**What is still open:** the issue's literal "done when" — *loads and displays
correctly on head units from two vendors* — needs hardware this environment does
not have. `HARNESS.md` specifies that run (both arms, Garmin + Wahoo, the FR45
per-type table) with a **pre-registered decision rule**. The verdict above is
falsifiable by exactly one finding: the FFI arm rendering a course-point type or
a note that the Python arm cannot. Nothing in the format suggests it will.

## Why not the FFI arm — the P1 boundary call

The architecture (P1/D2) keeps one `export_trip` for sidecar and hosted. Moving
FIT to Dart FFI would:

- put **one of four formats on a different code path** from GPX/TCX/GeoJSON, and
  give sidecar and hosted deployments **different FIT writers**;
- add a **native, per-platform dependency** (the C/C++ SDK, ×5 platform bundles)
  to a binary already carrying GDAL/GEOS — **risk A5**, the exact stack the risk
  register is worried about;
- pull in the **FIT SDK redistribution + notice obligation** on every bundle
  (`licence_notes.md`) — an obligation the Python arm does not incur at all,
  because it ships no Garmin code and the FIT protocol spec is openly published
  for this use;
- move an **export writer** — "the archetypal reveal leak path" (ARCH A22) —
  outside the core boundary the reveal gate is easiest to enforce at.

None of that is justified unless the FFI arm buys fidelity the Python arm can't
reach. This spike found no structural reason it would, and `HARNESS.md` is the
test that would catch it if it does.

## Findings that shape FR45's AC

FR45 says notes/markers survive "as native course/turn points **where the target
format supports them**." Per the FIT profile (`profile.COURSE_POINT_TYPE`):

- **FIT has a native slot for every marker type Plotlines produces** — turn
  directions (`left`/`right`/`sharp_*`/`slight_*`/`u_turn`), `water`, `food`,
  `danger`, `generic`, `rest_area` (SDK 21.x), summit/valley. "Where the format
  supports them" is, for FIT, **all of them at the format level.** Whether a
  given *device* draws each one is the `HARNESS.md` table — that is where the AC
  gets its per-device truth, and it cannot be stated until the devices are run.
- **Note text is carried in `course_point.name`** (there is no separate
  description field in the `course_point` message). The writer currently
  hard-caps the combined `"name — note"` string at 64 bytes and the dump shows
  **mid-word truncation** ("…the right for", "Walk "). This is a real fidelity
  ceiling: Garmin head units have historically shown ~15–30 characters in the cue
  list. **Action for F3:** set the truncation length from the `HARNESS.md`
  measurement and cut on a word boundary; consider a short `cp_type`-implied
  prefix instead of repeating the name.
- **Area anchors (FR108) have no FIT representation.** The writer **drops** them
  (records the decision, emits nothing). Options for F3: emit a single
  `generic` course-point at the polygon centroid with the area name, or declare
  areas **GPX/GeoJSON-only** in the export contents UI. `HARNESS.md` asks which
  reads better on-device; default to GPX/GeoJSON-only until then.
- **Role offsets (FR107) export cleanly.** A role carried at a geometry offset
  from its anchor is written at its **offset** position (verified:
  `pp-shuttle-pickup`, ~40 m off-trail, lands at the offset lat/lon, not the
  anchor's). No FIT-side problem.

## Reveal gate at the byte boundary (punch-list §6A.2)

The fixture includes an **unrevealed** narrative plot point whose note is a
canary string. `course.py` applies the reveal decision **before writing a byte**:
a plot point whose role is not `reveal="always"` (and is not a hazard)
contributes **no `course_point` message and no name string**.

- ✅ canary string **absent** from the output bytes (asserted on the bytes)
- ✅ withheld point produces **no** `course_point` (6 points in, 5 + 1 offset out,
  1 withheld)
- ✅ positive control — the canary **is** in the fixture, so its absence is the
  writer dropping it, not the fixture lacking it
- ✅ the hazard point (`danger`) **is** exported despite not being narrative
  `reveal="always"` — hazards are never withheld (PRD §1.5)

This is the writer being "first exercised" against §6A.2, as the issue notes; the
permanent CI assertion still belongs to §6A.2 itself, across all four formats.

## What did not clear

- **No device run.** The whole point of the issue is a device, and there is
  none here. `HARNESS.md` is the spec; the verdict is explicitly conditional on
  it and pre-registers what would overturn it.
- **Licence is directional, not cleared.** `licence_notes.md` reads the public
  21.x text. The one line worth counsel is the reassuring one — that a pure
  re-implementation of the published protocol (the recommended path) is
  unencumbered.
- **No `.fit` course was validated in Garmin's own FIT SDK verification tool**
  (`FitCSVTool` / `fitdecode`). The reference-corpus CRC cross-check and the
  round-trip are strong proxies; running the official verifier is a
  five-minute `HARNESS.md` pre-flight before the device load.
- **`file_creator` / manufacturer id.** The spike writes manufacturer `255`
  (development). F3 needs a real value — Garmin issues manufacturer ids; until
  Plotlines has one, `255` or `general` (`1`) is correct and devices accept it.

## Doc edits this spike owes (F3 / #69 carries them)

- **`Plotlines_Research_Spikes.md`** — SPIKE-16 entry + summary-table row:
  resolved 2026-08-30 on an offline proof (dependency-free Python writer,
  CRC-validated against real device files); device run specified in `HARNESS.md`.
- **`Plotlines_MVP_Redirection_Punchlist.md`** — §6 spike checklist and the
  #163 row: resolved; F3 is unblocked for the writer, gated on `HARNESS.md`
  only for the per-device FR45 table.
- **ARCH Decision Log** — add: *"SPIKE-16 — FIT export stays in `plotlines-core`
  (Python, no dependency). Dart-FFI-against-SDK rejected: no fidelity gain shown,
  costs a native per-platform dep (A5), the SDK redistribution obligation, and a
  core-boundary fork. Reconsider only on a device-measured fidelity gap
  (HARNESS.md)."*
- **ARCH §6.1 / §13.3** — note that `export_trip`'s FIT arm is in-core Python;
  strike any implication that FIT is the odd-one-out format.
- **PRD FR45** — add that "where the target format supports them" is, for FIT,
  defined by the per-device table in SPIKE-16's `HARNESS.md`; areas (FR108) are
  GPX/GeoJSON-only in export unless the harness shows a centroid point helps.
- **PRD F3 / issue #69** — the `course_point.name` truncation rule (word-boundary
  cut at the measured device floor) is an F3 implementation task.

## No product code changed

Same discipline as SPIKE-A/B/C/D/G/H: nothing here touches `plotlines-core` or
`plotlines-service`. `core/plotlines_core/export/` still holds only its docstring
`__init__.py`. The writer here is the reference the F3 build ports in.
