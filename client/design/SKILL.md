---
name: plotlines-design
description: Use this skill to generate well-branded interfaces and assets for Plotlines, either for production or throwaway prototypes/mocks. Contains the brand's design guidelines, colors, type, fonts, tokens, and a Flutter UI kit.
user-invocable: true
---

Read `readme.md` in this skill, then explore the other files.

- **Foundations** live in `styles.css` + `tokens/` (colors, type, spacing, radii,
  elevation). The canonical brand reference is `Plotlines Brand Guide.dc.html`.
- **Flutter components** live in `flutter/plotlines_ui/` (symlink to
  `client/packages/plotlines_ui/`, the package the client ships) — import
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
never fudged and always set in mono. Ownership and choice are drawn as different
kinds of control (#319): a set the Author *owns* — the trip's modes — is a row of
checked chips, and a *pick from* that set — a passage's mode — is a `SegmentedButton`;
two identically-drawn selectors for those two things is the defect #271 found.

Cache and canon are drawn differently on the map, by treatment rather than colour.
A candidate is a salience-scaled `CandidateMarker` ring, and a polygon/line candidate
also gets an outline on the same salience ramp (`CandidateGeometryLayer`, #475 —
drawn only when ≥ 48 px on screen, at most 300). A promoted anchor is an
`AnchorMarker` (#410): a **diamond** (circle/square/triangle were taken), fixed size,
fully opaque, whose internal mark keeps its candidate's affinity shape for one role
and becomes a star for several. An area anchor's ring (`AnchorAreaLayer`, #484) has
one fixed weight on a paper casing, drawn under every line and marker. Promotion
retires the candidate's pin and ring, so the two never stack.

Basemap styles are Protomaps Light / Dark / Grayscale, chosen through the
`BasemapStylePref` setting (#465, default *match appearance*) and resolved in one
place, `resolveBasemapStyleName`. The style JSONs are **generated** by
`build_basemap_theme.py` and never hand-edited — a hand patch is silently reverted
by the next run, which is what #486 (open) found for #321's WCAG water-label fix.
Grayscale/White/Black carry no POIs or landcover (SPIKE-K); say so where offered.
Advisories (a stale mirror, a refused tile upstream) use the warning icon with
secondary body text — never gold text, never error styling.

If invoked without guidance, ask what the user wants to build, ask a few focused
questions, and act as an expert designer who outputs HTML artifacts or Flutter
code depending on the need.
