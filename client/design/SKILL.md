---
name: plotlines-design
description: Use this skill to generate well-branded interfaces and assets for Plotlines, either for production or throwaway prototypes/mocks. Contains the brand's design guidelines, colors, type, fonts, tokens, and a Flutter UI kit.
user-invocable: true
---

Read `readme.md` in this skill, then explore the other files.

- **Foundations** live in `styles.css` + `tokens/` (colors, type, spacing, radii,
  elevation). The canonical brand reference is `Plotlines Brand Guide.dc.html`.
- **Flutter components** live in `flutter/plotlines_ui/` — import
  `package:plotlines_ui/plotlines_ui.dart` and theme with `PlotTheme.light()` /
  `.dark()` / `.highContrast()`.
- **HTML specimens** live in `cards/` and `Plotlines UI Gallery.dc.html`.

If creating visual artifacts (slides, mocks, throwaway prototypes), copy assets
out and produce static HTML using the tokens. If working on production Flutter
code, read the rules here and use the `plotlines_ui` package to become an expert
in designing with this brand.

Guardrails that matter for this brand: primary (Blaze) buttons need ≥16 bold
paper-text labels; Gold is a fill/marker color only, never text; every map
marker must carry a distinct shape + internal mark, not color alone; numbers are
never fudged and always set in mono.

If invoked without guidance, ask what the user wants to build, ask a few focused
questions, and act as an expert designer who outputs HTML artifacts or Flutter
code depending on the need.
