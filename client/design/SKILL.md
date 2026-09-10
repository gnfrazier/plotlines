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
- **Flow canvases** are the eleven `Flow N - *.dc.html` files — the designed shape of each
  feature area, one canvas per area.
- **`screens/`** holds captured screenshots of the app as it actually is today — since issue
  **#271** this is a 35-screen Author-desktop walkthrough, and several filenames name the
  defect they capture (`layers-broken.png`, `too-many-scrolly-sidebars.png`,
  `rest-day-need-a-search-by-address-not-usable.png`). Use them to see what a surface looks
  like now before redesigning it; they are evidence, not a spec, and the ones naming a defect
  usually have an issue behind them — search before assuming a finding is unfiled.
- **`route-workspace-ia/`** is a worked re-design canvas rather than a flow canvas: the Route
  tab's planning rail (issue **#328**, out of #271's Finding 9), diagnosing 50+ controls at one
  depth across three competing scroll regions and proposing a **Frame / Tune / Refine** task
  spine. Read its `readme.md` before touching the Route rail. Later re-designs of a single
  surface belong in a sibling directory shaped the same way, not in the numbered flow set.
- **`uploads/` is scratch input, not source of truth** — it contains stale hashed copies of
  product docs, including a **v1 `Plotlines_PRD.md`** whose model is reversed relative to v2.
  Never read a doc from here; read `docs/*_v2.md` in the repo.

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
