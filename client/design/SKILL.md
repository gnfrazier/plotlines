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
  spine. **Built by PR #566 (2026-10-01)**: Frame / Tune / Refine is a one-open-at-a-time
  accordion with mono summaries from M14 templates, Explore/Compose in the rail header, a
  fixed action bar below the scroll, and THIS PASSAGE leading the right rail. It must not
  scroll at 1440×900 with one task open (`route_rail_task_spine_test.dart`, run with the
  app's real fonts). Its named deviations: Discipline is a collapsed row in Frame, and
  Interest is one in Tune. Read the canvas's `readme.md` before touching the Route rail.
  Later re-designs of a single
  surface belong in a sibling directory shaped the same way, not in the numbered flow set.
- **`uploads/` is scratch input, not source of truth** — it holds the images originally
  uploaded with the design brief. The stale product-doc copies that used to sit beside them
  (including a v1 PRD whose model is reversed) were removed on 2026-09-28. Read product docs
  from `docs/*_v2.md` in the repo, never from here.

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

A selected chip or segment is filled Riverslate (Material 3's `secondaryContainer`) and
inked with `PlotColors.onSelectedControl` (paper-white in the light theme, #613). A label
that sets its own colour on a chip or segment uses `c.controlInk(selected)`, never a fixed
`textPrimary`/`textSecondary`: that is how dark ink ended up on dark teal.

Cache and canon are drawn differently on the map, by treatment rather than colour.
A candidate is a salience-scaled `CandidateMarker` ring — but only the top **300** in
view by salience get one; the rest are canvas dots whose size and opacity carry the
same salience ramp, and zoomed out past the trip overview (or past ~2,800 in view)
they group into count glyphs on a pan-stable 64 px grid (`CandidatePointLayer`, #478,
SPIKE-G's strategy). Never add a per-candidate widget; a lone candidate in a cell keeps
its full marker. A polygon/line candidate also gets an outline on the same salience
ramp (`CandidateGeometryLayer`, #475 — drawn only when ≥ 48 px on screen, at most 300). A promoted anchor is an
`AnchorMarker` (#410): a **diamond** (circle/square/triangle were taken), fixed size,
fully opaque, whose internal mark keeps its candidate's affinity shape for one role
and becomes a star for several. An area anchor's ring (`AnchorAreaLayer`, #484) has
one fixed weight on a paper casing, drawn under every line and marker. Promotion
retires the candidate's pin and ring, so the two never stack.

Basemap styles are Protomaps Light / Dark / Grayscale, chosen through the
`BasemapStylePref` setting (#465, default *match appearance*) and resolved in one
place, `resolveBasemapStyleName`. The style JSONs are **generated** by
`build_basemap_theme.py` and never hand-edited. #486 found a hand patch (#321's WCAG
water-label fix) that the next run would have reverted; the fix now lives in the generator,
and `build_basemap_theme.py --check` fails CI when a committed style differs from what it
generates. Every map uses the one shared `basemapVectorLayer` in **vector** mode (#575):
raster mode scales labels up to 2× between zoom levels.
Grayscale/White/Black carry no POIs or landcover (SPIKE-K); say so where offered.
Advisories (a stale mirror, a refused tile upstream) use the warning icon with
secondary body text — never gold text, never error styling. Waits are not failures: a
region queued for its build (#573) or an area the mirror is still fetching (#522) shows the
quiet hourglass notice, never the error card with *Try again*. The same holds inside the
trip shell (#656): while the trip's region is not ready, the weights rail shows
`CapabilityWarmingNotice` first in its scroll, not in the fixed action plane, where the
failure card overflowed a short window. Generate, Regenerate and Diagnose are disabled, and
each says why in its tooltip.

A map gesture in progress on the Route tab is shown one way: a gesture panel in the
map's top-right corner, in place of the buttons that started it, with a mono heading, one
line of instruction and an explicit **Cancel**. Three gestures use it:
`AlternateDraftBar` (#324), `AlternateMoveBar` (#344) and `NodePlacementBar` (#588).
Never relabel the arming button into an instruction (`Tap map to…`). That leaves no way
out, which is the defect #588 found. **Esc** backs out of any of the three. Selecting
another passage or day, or the passage going away, disarms them too. Abandoning one is
always free. Node placement also puts a crosshair cursor over the map.

Points a route must reach are one concept on screen (#589). The node editor carries a
**Route through this** checkbox, which in Compose points the Author to promotion instead.
There is **one** ROUTE THROUGH list, in the metrics rail (#640, `RouteThroughList`): every via
point in order — a node by its title, a New Route tap as *Point N* — numbered, with a drag
handle, *Move earlier / later* and remove in Explore (report-only in Compose). A start and a
finish are pinned rows: a lock and a START / FINISH tag, no move controls. Each row reports
reached or missed once solved, and a miss carries its distance in mono beside the warning
icon, never a bare *no*. Never add a second list with the same name: #589 had two, and the
visible one was read-only. Start, finish and via nodes lock *Route through this* on, with the
reason, and the selected passage's routed points carry their order as a mono number on the
map.

The trip shell's app bar carries labelled actions, not bare icons: **← Library** (#577),
**Settings** (#578) and **Save**. Work autosaves while the shell is showing, so leaving
never prompts; a quiet line beside Save reads *Saving…* / *Saved*, or *Not saved — press
Save* when a write fails, with no exception text on screen (#390). Hazards are marked on
the route map and as ticks on the elevation profile (#47), and they are never subject to
reveal.

New Route has two faces (#655). Opened as trip creation it is *New trip · step 4 of 4*, with
the trip name, dates and party block. Opened from the shell (`/add-route`) it names what is
being added, such as *Add a passage to Day N*, and has neither of those. Its *Choose area*
opens the trip extent and comes back.

Screen copy never carries requirement or story ids: no *(FR106)*, no *E4 —*, no *(C9)*
(#639). Say what the control does. `no_requirement_ids_on_screen_gate_test` fails on one.
The unit of a day is a **passage**, never a *segment*, on every surface (#659). Name only
tabs that exist (ROUTE, LOGISTICS, LAYERS, CONTENT, ROSTER, EXPORT, READ — `tripShellTabs`), never *Curation*.

If invoked without guidance, ask what the user wants to build, ask a few focused
questions, and act as an expert designer who outputs HTML artifacts or Flutter
code depending on the need.
