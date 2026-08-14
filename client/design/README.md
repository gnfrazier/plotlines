# client/design

Source-of-truth visual reference for the desktop MVP, imported from the Claude Design
project **"Plotlines - Design"** (`https://claude.ai/design/p/29bd1f69-ef64-4208-8da4-7f38f5b7066f`)
via the Design MCP. Imported as reference, not as shipped code (MVP doc §2.4, §6 item 5).

## Files

- **`Plotlines Author Desktop.dc.html`** — the MVP-relevant file. The Author Desktop
  wireframe: four screens covering routing & themes (PRD Epic A), multimodal composition
  (Epic B), multi-day logistics (Epic C), live metrics (Epic D), curation (Epic E), and
  outputs (Epic F) — see the file's own header for the exact FR mapping.
- **`support.js`** — the generated `.dc.html` viewer runtime the wireframe file needs to
  render (a generic Claude Design shim, not project-specific content). Loaded via
  `<script src="./support.js">`; kept alongside the wireframe as a sibling file.

Fonts (Google Fonts: Instrument Serif, Archivo, JetBrains Mono) are loaded from Google's
CDN in the wireframe's `<head>` and were not vendored locally.

## What this is for

The Flutter `lib/presentation/` layer (ARCH §9.1) should be built to match this wireframe.
Importing the reference and translating it into Flutter widgets are deliberately separate
steps (MVP doc §2.4) — this import is scaffolding only; the widget implementation is the
next session's work.

## Scope mismatch — flagged, not silently absorbed

The source Design project also contains **`Plotlines Field App.dc.html`**, a
**`Plotlines Brand Guide.dc.html`**, and a **`Plotlines UI Gallery.dc.html`**, plus a
`flutter/plotlines_ui/` component package — none of which were imported here.

`Plotlines Field App.dc.html` in particular covers mobile/field execution (GPS-triggered
narration, cue HUD, etc.), which MVP doc §1.2 explicitly puts out of scope for the desktop
MVP. Only `Plotlines Author Desktop.dc.html` — the desktop Author persona — was pulled in.
The Brand Guide, UI Gallery, and the `flutter/plotlines_ui/` Dart component package look
like reusable design-system assets that could inform the real widget implementation later,
but pulling them in wasn't part of this run's scope (Phase 4 of the setup prompt names only
the Author Desktop file) — flagging their existence here rather than importing them
silently.
