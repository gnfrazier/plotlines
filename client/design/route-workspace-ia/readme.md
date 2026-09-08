# Route workspace — information architecture

A re-design of the Route tab's planning rail, produced for **issue #328**, which
came out of the UX review in **#271** (Finding 9 — `sidebar-scrolling.png`,
`sidebar-scrolling-3.png`, `too-many-scrolly-sidebars.png`).

Published canvas: <https://claude.ai/code/artifact/b60031f2-b8a1-4a1c-9f86-641a4ecd6d35>

## The artboards

| File | What it is |
|---|---|
| `Today.dc.html` | The diagnosis — the rail's full control inventory, counted, and the three competing scroll regions |
| `Depth.dc.html` | The depth model: two levels today, five proposed |
| `Main.dc.html` | The re-designed workspace at rest, 1440 × 900 |
| `Tasks.dc.html` | The rail with each of Frame / Tune / Refine opened, side by side |
| `canvas.json` | Layout, titles and the two sticky notes |

## The proposal in one paragraph

The rail holds every property a `Segment` has — 50+ controls — at a single
depth, in one 305 px column. The missing level is **what the Author is doing
right now**: framing a day, tuning how it feels, and refining what is on it are
three tasks at three different moments. The rail becomes an accordion of
**Frame / Tune / Refine**, one open at a time, each stating its own answer in a
mono summary line when closed. Within a task, controls group by subject rather
than listing flat. The action bar moves to its own plane so it stops overlapping
the rail's content, Explore/Compose moves to the rail header where a posture
belongs, and the right rail leads with passage scope rather than interleaving
passage and trip figures.

## Working notes

- These are **Design Component** files, the same format as the `Flow N - *.dc.html`
  canvases one directory up. They are a proposal, not a spec — `#328` carries the
  acceptance criteria.
- Tokens are inlined from `client/design/tokens/` rather than imported, so each
  artboard renders standalone. If a token changes, these do not follow
  automatically.
- The start and finish map marks drawn in `Main.dc.html` (a ring with a solid
  chevron; a ring with a solid square) are a **proposal for #320**, which found
  that `NodeMarkerType` has no start or finish mark at all. They are not in the
  brand guide yet.
- The seeded canvas HTML is a build output and is not committed — regenerate it
  with the `design` skill's `seed-canvas.mjs` from the files above.

## Open question

The Frame / Tune / Refine split is inferred from the screenshots and from
`weights_rail.dart`, not from watching anyone plan a trip. If the real sequence
differs, the three names change and the structure survives; if the sequence is
genuinely non-linear, the accordion is the wrong control. `#328` records this as
the one thing the canvas cannot settle on its own.
