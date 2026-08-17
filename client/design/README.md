# client/design

Source-of-truth visual reference for the desktop MVP, imported from the Claude Design
project **"Plotlines - Design"** (`https://claude.ai/design/p/29bd1f69-ef64-4208-8da4-7f38f5b7066f`).
Imported as reference, not as shipped code (MVP doc §2.4, §6 item 5).

Imported in three passes: the Author Desktop wireframe on **2026-08-13**; the rest of the
design system (brand guide, UI gallery, tokens, cards, `plotlines_ui`) on **2026-08-15**,
partial — the Brand Guide and UI Gallery `.dc.html` files and `assets/` were referenced but
did not actually land; a full re-export (`Plotlines - Design.zip`, provided directly rather
than through the Design MCP) closed every remaining gap on **2026-08-17**, landing all four
`.dc.html` wireframes, both brand PNGs, and a **substantially revised Author Desktop** —
see "Where the wireframe and the requirements disagree" below, most of which is no longer
disagreement.

## Files

### Screens
- **`Plotlines Author Desktop.dc.html`** — the MVP-relevant wireframe, revised as of the
  2026-08-17 re-export. Five screens: `00 New Route`, `01 Route Planner`,
  `02 Constraint Conflict`, `03 Node & Narrative`, `04 Cue Sheet + Export` — plus a trips
  library (`plotlines.app/trips`) and settings (`plotlines.app/settings`) that weren't in
  the original pass. Covers routing & themes (PRD Epic A), multimodal composition (Epic
  B), multi-day logistics (Epic C), live metrics (Epic D), curation (Epic E), and outputs
  (Epic F).
- **`Plotlines UI Gallery.dc.html`** — live component gallery mirroring the
  `plotlines_ui` Flutter package, with a light / dark / outdoor-high-contrast toggle.

### Brand & tokens
- **`Plotlines Brand Guide.dc.html`** — the canonical brand reference. Everything else
  in the design system derives from it.
- **`DESIGN_SYSTEM_README.md`** — the design system's own README (upstream `readme.md`,
  renamed on import so it doesn't collide with this file). Voice, casing, color
  proportions, iconography rules.
- **`SKILL.md`** — the upstream Agent Skill wrapper. Reference only; not installed as a
  skill in this repo.
- **`styles.css`** + **`tokens/`** — the CSS custom-property token set (colors,
  typography, spacing, radii, elevation, fonts). `styles.css` `@import`s all six.
- **`cards/`** — 14 specimen cards (foundations + components), each a standalone HTML
  page linking `../styles.css`.
- **`assets/plotlines-logo.png`**, **`assets/plotlines-favicon.png`** — the brand marks,
  landed whole in the 2026-08-17 re-export (see "Not imported" below for the earlier gap).

### Runtime
- **`support.js`** — the generated `.dc.html` viewer runtime all four wireframe files need
  to render (a generic Claude Design shim, not project-specific content). Loaded via
  `<script src="./support.js">`; kept alongside as a sibling file.

  It went missing after the 2026-08-15 import: the stock Flutter `.gitignore` excludes
  `*.js` (to drop dart2js output), so the file was written but never tracked, and the
  wireframes have been rendering blank ever since. `.gitignore` now carries an explicit
  `!client/design/support.js` negation. Don't remove it.

### Imported as reference, out of scope for desktop MVP
- **`Plotlines Field App.dc.html`** — mobile/field execution (GPS-triggered narration,
  cue HUD). MVP doc §1.2 puts that whole tier out of scope for the desktop MVP; kept here
  so a future mobile milestone has a design reference already in the repo.

### Not imported
- **`uploads/`** — design-session scratch (pasted screenshots, drafts, stale copies of
  the PRD and MVP doc). Deliberately skipped, every pass.
- **`client-design/`** (in the source zip) — the design tool's own mirror of what it
  last saw synced *from* this repo (byte-identical to the Author Desktop file this
  README replaced). Not a source to import from; skipped.
- **`.thumbnail`, `Canvas.dc.html`** (in the source zip) — project-browser chrome, no
  content of their own. Skipped.

## The Flutter package is not here

The design project also ships **`flutter/plotlines_ui/`**, a real Dart package —
`PlotTheme.light/dark/highContrast`, a `PlotColors` theme extension, `PlotButton`,
`PlotCard`, `PlotBadge`, `PlotDialog`, `PlotListTile`, and the brand widgets
`NodeMarker`, `CueSheetRow`, `ElevationProfile`, `TripCard`.

That is code, not reference, so it was imported to **`client/packages/plotlines_ui/`**
instead of here. **Compiled and verified** (`flutter analyze`/`flutter test` both pass) —
the upstream package's own "never been compiled" warning no longer applies to the copy in
this repo; see that package's README for what changed on the way in. The 2026-08-17
re-export's copy of `flutter/plotlines_ui/` is byte-identical to upstream on every file
this repo hasn't since patched for the offline-fonts fix below, so nothing new landed
there this pass.

## Fonts — resolved for the shipped client, still open for the reference docs

Instrument Serif, Archivo, and JetBrains Mono are loaded from Google's CDN in the
`.dc.html` files and in `tokens/fonts.css` — reference documents, and they may stay that
way. **The shipped client does not**: desktop MVP is offline-first (ARCH P2), so
`client/packages/plotlines_ui` now vendors all three as `.ttf`s under its own `assets/fonts/`
and declares them in its `pubspec.yaml`, with `PlotTypography` reading local `fontFamily`
names instead of calling `google_fonts`. That patch is Flutter-side only and isn't
reflected in this directory's reference files, which is expected — see the plotlines_ui
package's README for the detail.

## Where the wireframe and the requirements disagree

The Author Desktop wireframe originally predated the SPIKE-01/02/03 amendments of
2026-08-14. **The 2026-08-17 re-export closes most of that gap** — via-node UI, min/max
band controls, a real three-way shape selector (`LOOP` / `OUT-BACK` / `P2P`), rest days,
and an attribution surface (`CC BY`, `ODbL`, `OpenStreetMap` all now appear in the
wireframe) are all present. What's confirmed still open, checked directly against this
file's text:

| Still stale / unconfirmed | Requirement |
|---|---|
| No occurrence of "regroup" anywhere in the file (a "Waypoint" node kind is present, but C5's regroup point isn't distinguishable in the text search this was checked with) | C5 `[MVP]` — worth a visual pass, not just a text search, before concluding it's missing |
| Window chrome still mocks a browser address bar (`plotlines.app/plan/new`, `/trips`, `/settings`) | Desktop MVP is a native app, not a web page — unchanged from the original finding |

Everything else the first import's gap table flagged — via-node UI, band controls, the
loop-only shape selector, the weight-bounding relaxation chip copy, missing rest
days/attribution — either no longer reproduces in the file or wasn't re-checked in this
pass and should be treated as resolved-pending-visual-confirmation rather than reasserted
as a live gap. `client/lib/presentation/`'s build (MVP doc §8) was completed against the
*previous* wireframe pass and the additions §8 lists as "extended past the wireframe" —
via-node UI, bands, shape selector, rest/regroup, attribution — may now be closer to what
this revised wireframe actually shows than to an extension beyond it. Reconciling the two
is follow-up work, not done as part of this file swap.
