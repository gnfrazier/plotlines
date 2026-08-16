# client/design

Source-of-truth visual reference for the desktop MVP, imported from the Claude Design
project **"Plotlines - Design"** (`https://claude.ai/design/p/29bd1f69-ef64-4208-8da4-7f38f5b7066f`)
via the Design MCP. Imported as reference, not as shipped code (MVP doc §2.4, §6 item 5).

Imported in two passes: the Author Desktop wireframe on **2026-08-13**, the rest of the
design system on **2026-08-15**. Re-synced against upstream on **2026-08-16**: the
wireframes and tokens were already current, and the missing `support.js` was pulled in
(see Runtime below). `assets/` is still the only outstanding gap.

## Files

### Screens
- **`Plotlines Author Desktop.dc.html`** — the MVP-relevant wireframe. **Five** screens
  (the file's own header text says four): `00 New Route`, `01 Route Planner`,
  `02 Constraint Conflict`, `03 Node & Narrative`, `04 Cue Sheet + Export`. Covers
  routing & themes (PRD Epic A), multimodal composition (Epic B), multi-day logistics
  (Epic C), live metrics (Epic D), curation (Epic E), and outputs (Epic F).
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

### Runtime
- **`support.js`** — the generated `.dc.html` viewer runtime both wireframe files need
  to render (a generic Claude Design shim, not project-specific content). Loaded via
  `<script src="./support.js">`; kept alongside as a sibling file.

  It went missing after the 2026-08-15 import: the stock Flutter `.gitignore` excludes
  `*.js` (to drop dart2js output), so the file was written but never tracked, and the
  wireframes have been rendering blank ever since. `.gitignore` now carries an explicit
  `!client/design/support.js` negation. Don't remove it.

### Not imported
- **`assets/`** — the logo and favicon PNGs both exceed the MCP's 256 KiB read cap and
  came back truncated. See `assets/README.md` for the consequence and how to fetch them.
- **`uploads/`** — design-session scratch (pasted screenshots, drafts, a stale copy of
  the PRD). Deliberately skipped.
- **`Plotlines Field App.dc.html`** — mobile/field execution (GPS-triggered narration,
  cue HUD). MVP doc §1.2 puts that whole tier out of scope for the desktop MVP.

## The Flutter package is not here

The design project also ships **`flutter/plotlines_ui/`**, a real Dart package —
`PlotTheme.light/dark/highContrast`, a `PlotColors` theme extension, `PlotButton`,
`PlotCard`, `PlotBadge`, `PlotDialog`, `PlotListTile`, and the brand widgets
`NodeMarker`, `CueSheetRow`, `ElevationProfile`, `TripCard`.

That is code, not reference, so it was imported to **`client/packages/plotlines_ui/`**
instead of here. It has **never been compiled** — see that package's README before
depending on it.

## What this is for

The Flutter `lib/presentation/` layer (ARCH §9.1) should be built to match the Author
Desktop wireframe, using `plotlines_ui` for theme and components. Importing the
reference and translating it into Flutter widgets are deliberately separate steps
(MVP doc §2.4); the widget implementation is the next session's work.

## Fonts — an open MVP issue

Instrument Serif, Archivo, and JetBrains Mono are loaded from Google's CDN in the
`.dc.html` files and via the `google_fonts` package (network fetch on first run) in
`plotlines_ui`. Reference documents may stay that way. **The shipped client may not** —
desktop MVP is offline-first (ARCH P2), so the `.ttf`s must be vendored and declared in
`client/pubspec.yaml` before release. The design system's own README flags this too.

## Where the wireframe and the requirements disagree

The Author Desktop wireframe predates the SPIKE-01/02/03 amendments of 2026-08-14. Read
it as a visual reference, not as a scope statement — searching all five screens:

| Missing / stale | Requirement |
|---|---|
| No via-node UI | A9 was promoted P1 → **MVP** on 2026-08-14 (SPIKE-01) |
| No min/max band controls | A5 `[MVP]` (FR6) |
| The relaxation chip reads *"Lower Peaks min to 1.8"* — a band on the **weight** | FR6 was reworded on 2026-08-14 to bound the **realized attribute** (SPIKE-03) |
| No shape selector — "loop" only | A7 `[MVP]` needs out-and-back and point-to-point |
| No rest days, no regroup points | C2, C5 `[MVP]` |
| No attribution / About surface | ARCH §11.2 makes a missing CC BY credit a **build failure** |
| Header text claims coverage of "B1–B5" | B4/B5 were removed on 2026-08-14 (SPIKE-04). No class/whitewater UI actually appears in the screens — the header text is stale, the screens are clean. |
| Window chrome mocks a browser address bar (`plotlines.app/plan/new`) | Desktop MVP is a native app, not a web page |
