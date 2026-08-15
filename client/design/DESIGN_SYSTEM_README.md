# Plotlines Design System

A design system for **Plotlines**, a trip-planning platform that replaces
spreadsheet-based group-trip coordination. The brand is an "expedition diarist"
narrative laid over a function-first product: expressive where it earns it,
rigorous everywhere data lives.

This system is delivered in two layers:

1. **Flutter package** (`flutter/plotlines_ui/`) — the real, consumable
   deliverable. Material 3 themed to the brand, adaptive across Android, iOS,
   web, and desktop, with light / dark / outdoor-high-contrast modes.
2. **HTML reference** — CSS design tokens (`styles.css` + `tokens/`), foundation
   specimen cards, component preview cards, and a full gallery
   (`Plotlines UI Gallery.dc.html`) so the system is reviewable in the browser.
   The HTML cards mirror the Flutter widgets 1:1; they are the visual spec.

> Source of truth: `Plotlines Brand Guide.dc.html` in this project. Nothing in
> the brand guide was modified to build this system.

## Content fundamentals
- **Voice**: matter-of-fact and precise for anything operational (distances,
  ETAs, turns), warm and first-person-plural for narrative moments ("Plot a
  trip", "Regroup"). The diarist tone is a seasoning, never the default.
- **Casing**: sentence case for UI copy; UPPERCASE mono for data labels, tags,
  and units (`178 MI`, `OFFLINE READY`, `GRAVEL+PADDLE`).
- **Numbers are never fudged** — distances, elevation, and ETAs show real
  precision. Data is always mono so it "looks accountable".
- **No emoji.** Meaning is carried by shape + label, not by decorative glyphs.

## Visual foundations
- **Color**: warm paper/canvas neutrals under a dark warm ink; Blaze (#DB5A28)
  is the single primary; Spruce = land, Riverslate = water, Gold = caution
  (fills/markers only), Ember = hazard. ~70% canvas / 18% ink / 8% blaze / 4%
  mode accents.
- **Type**: Instrument Serif (expressive display), Archivo (UI/body), JetBrains
  Mono (data/coordinates).
- **Shape & depth**: subtle corners (4px controls, 6px cards); **borders do the
  structural work**, shadows are soft and sparing.
- **Layout**: generous whitespace, 4px spacing rhythm, 44px minimum touch
  targets (one-handed, gloved, in glare).
- **Motion**: short, quiet transitions (~120ms); no bounces.
- **Iconography**: two families — line **mode pictographs** (24px grid, 2px
  stroke) and geometric **node markers** where shape + an internal mark carries
  meaning and color only reinforces (topographic convention, after NPS / USGS /
  German Freizeitkarte). See the brand guide's Iconography section.

## Iconography approach
No icon font is bundled. The brand-critical marks — the six node markers — are
drawn in Dart with `CustomPainter` (`NodeMarker`) so they stay crisp at any
size and recolor per theme. Mode pictographs follow the same 24px/2px spec;
teams may render the general UI glyph set with Material Icons themed to
`textSecondary`. There is a badge logo and a compass-rose monogram in the brand
guide; copy those in from the guide's `assets/` when a mark is needed.

## Index / manifest
- `styles.css` — global entry; `@import`s everything in `tokens/`.
- `tokens/` — `fonts.css`, `colors.css`, `typography.css`, `spacing.css`,
  `radii.css`, `elevation.css`.
- `flutter/plotlines_ui/` — the Flutter package (see its own `README.md`).
- `cards/` — foundation + component specimen cards (Design System tab).
- `Plotlines UI Gallery.dc.html` — full reviewable gallery.
- `SKILL.md` — downloadable Agent Skill wrapper.

## Caveats
- Flutter code was authored here but **not compiled/run** — verify in a real
  Flutter project.
- Fonts use `google_fonts` (network fetch on first run); bundle `.ttf`s for
  fully offline field use.

---

## Plotlines repo notes (added on import, 2026-08-15)

This is the upstream `readme.md` from the Claude Design project
(`29bd1f69-ef64-4208-8da4-7f38f5b7066f`), renamed on import so it does not
collide with `client/design/README.md` (which documents the import itself).
Content is unmodified above this line.

**Paths differ in this repo:**

| Upstream path | Here |
|---|---|
| `flutter/plotlines_ui/` | `client/packages/plotlines_ui/` — real code, not reference |
| `styles.css`, `tokens/`, `cards/`, `assets/` | `client/design/` (same names) |
| `Plotlines Brand Guide.dc.html`, `Plotlines UI Gallery.dc.html` | `client/design/` |

**The last caveat is a hard MVP requirement, not a nice-to-have.** Desktop MVP is
offline-first (ARCH P2), so the `google_fonts` network fetch must be replaced by
bundled `.ttf`s in `client/pubspec.yaml` before the client ships. The same applies
to the `@import` of Google Fonts in `tokens/fonts.css` and the `<link>` in the
`.dc.html` wireframes — those are reference documents and may stay as they are.
