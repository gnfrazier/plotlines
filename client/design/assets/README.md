# client/design/assets — NOT IMPORTED

The Claude Design project holds two brand image assets that **could not be
imported** on 2026-08-15:

| Upstream path | Status |
|---|---|
| `assets/plotlines-logo.png` | not imported — exceeds the read cap |
| `assets/plotlines-favicon.png` | not imported — exceeds the read cap |

The Design MCP's `get_file` caps a single read at **256 KiB**. Both PNGs are
larger than that, so every read came back truncated at exactly 262 144 base64
characters with `truncated: true`. A truncated PNG is a corrupt PNG — writing
one here would have been worse than leaving the gap, so neither was written.

## Consequence

`Plotlines Brand Guide.dc.html` references `assets/plotlines-favicon.png` in its
`<helmet>` and the logo in its nav. Opening the brand guide locally will show a
broken image in those two places. Nothing else depends on them, and no Flutter
code references them — `plotlines_ui` bundles no icon font and draws the six
node markers in Dart with `CustomPainter` (see the package README).

## How to get them

Download both files directly from the Design project in the browser:

    https://claude.ai/design/p/29bd1f69-ef64-4208-8da4-7f38f5b7066f

and drop them in this directory under their upstream names. The rest of the
design system is fully imported and does not need them.

The same two images also exist upstream as `uploads/plotlines-favicon.png`,
`uploads/plotlines-cropped.png`, and `uploads/favicon.png`; the `uploads/`
directory was not imported at all (it holds design-session scratch — pasted
screenshots, drafts, and a copy of the PRD that this repo already owns in
`docs/`).
