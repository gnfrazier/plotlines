# Plotlines — Author Flow, End to End (as built)

**Version:** 1.0 · **Traced:** 2026-10-07 against `main` at `a3245b3` (after PR #650)
**Companion to:** `Plotlines_Author_Flows_MVP.md` (the flows as specified), `Plotlines_PRD_v2.md` (source of truth)

`Plotlines_Author_Flows_MVP.md` draws each feature area from the PRD, which is what the app was
*meant* to do. This document is traced from the **client code**, which is what the desktop app does
today. It covers every screen, dialog, disabled-with-a-reason control, waiting state, error and
retry, from launch to a printed cue sheet and an exported FIT file. Each node points at the code
that draws it. Where the two documents disagree, the PRD still wins on *intent*, and this document
wins on *what an Author will meet*. The diff between them is §12.

**Legend.**
- A solid arrow is a path the Author can see.
- A dashed arrow is a way back: Cancel, Esc, ←, Retry or Undo.
- A node outlined in red with an **F*n*** tag is a finding; see §11.
- A node drawn as a stadium (rounded ends) is work that starts in the background.
- The spine (§0) is the order a first trip runs in. After the first route, the stages are tabs, and
  the Author moves between them freely.

---

## 0 · Spine

```mermaid
flowchart LR
    S0["1 · Launch<br/><i>sidecar gate</i>"] --> S1["2 · Library"]
    S1 --> S2["3 · Trip initiation<br/><i>modes, location, extent, layers</i>"]
    S2 --> S3["4 · First route<br/><i>New Route</i>"]
    S3 --> S4["5 · Trip shell<br/><i>7 tabs, app bar</i>"]
    S1 -->|open a trip| S4
    S4 --> S5["6 · Curate<br/><i>Layers, Content</i>"]
    S4 --> S6["7 · Route<br/><i>nodes, generate, alternates</i>"]
    S4 --> S7["8 · Days, logistics, roster"]
    S5 <--> S6
    S6 <--> S7
    S5 --> S8["9 · Edit, stale, re-solve"]
    S6 --> S8
    S7 --> S8
    S8 --> S9["10 · Outputs<br/><i>itinerary, cue sheets,<br/>print, device export</i>"]
    S6 --> S9
    S9 -.->|back to work| S4
    S4 -.->|← Library| S1
```

---

## 1 · Launch — the sidecar gate

`main.dart` · `presentation/widgets/sidecar_gate.dart`

```mermaid
flowchart TD
    A[App launch] --> B{Sidecar state}
    B -->|starting / restarting| W["Full-screen wait<br/>'Plotting the route graph'<br/><b>F19</b>"]:::finding
    W --> B
    B -->|failed after one restart| X["'The routing engine won't start'<br/>Retry"]
    X -.->|Retry| B
    B -->|degraded| D["Warning banner above the app<br/><i>work continues</i>"]
    D --> L[Library]
    B -->|ready| L
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 2 · Library

`presentation/screens/trip_library_screen.dart`

```mermaid
flowchart TD
    L[Library] --> E{Library state}
    E -->|DB read failed| LF["'The trip library didn't open'<br/>Retry"]
    LF -.->|Retry| L
    E -->|no trips| EM["'No trips yet'<br/>New trip"]
    E -->|trips| G["Cards, grid or list<br/>mode and duration filters"]
    G -->|filters match nothing| NM["'No trips match those filters.'"]
    NM -.-> G
    EM --> NT([Start a new trip → §3])
    G -->|+ New trip| NT
    G -->|tap a card| OP{Payload parses?}
    OP -->|yes| SH([Trip shell → §5])
    OP -->|no| OPF["Snackbar: 'couldn't be opened'"]
    OPF -.-> G
    G --> MN[Card menu]
    MN -->|"Edit route · Manage roster ·<br/>Export backup"| MNX["All three open the trip on ROUTE<br/><b>F8</b>"]:::finding
    MNX --> OP
    MN -->|Clone…| CS["Clone scope<br/>whole trip · roster only ·<br/>authored trip · per part"]
    CS -.->|Cancel| G
    CS -->|roster only| NT
    CS -->|any other scope| CL["Snackbar 'Cloned as …'<br/>new card in the library"]
    CL --> G
    MN -->|Delete…| DL{"'Delete …? This can't be undone.'"}
    DL -->|Delete| G
    DL -.->|Cancel| G
    G -->|Preferences & about| ST[Settings]
    ST -.->|←| G
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 3 · Trip initiation (steps 1–3 of 4)

`trip_mode_prompt.dart` · `trip_location_prompt.dart` · `trip_area_screen.dart` ·
`map/trip_area_map.dart` · `trip_layers_screen.dart` · `state/trip_bbox_provider.dart`

```mermaid
flowchart TD
    M["'How will you travel?'<br/>pick at least one mode"] -.->|Cancel| LIB[Library]
    M -->|Continue| LO["'Where are we going?'<br/>prefilled with the last one used"]
    LO -.->|Cancel| LIB
    LO -->|Use Buncombe County| AR
    LO -->|Continue, field empty| AR
    LO -->|Continue, a query| GC{Geocode}
    GC -->|a hit| AR
    GC -->|no hit / failed| GE["Inline sentence: 'continue and<br/>place the map yourself'<br/><b>F22</b>"]:::finding
    GE -.->|edit, Continue| GC
    AR["Trip extent · STEP 2 OF 4<br/>framed on the hit, or the home region"] --> DR{Drag a rectangle}
    DR -->|a tap, or a side under 200 m| IG["Ignored, no message<br/><b>F13</b>"]:::finding
    IG -.-> DR
    DR -->|a real box| BX["Box + readout<br/>advisory at 5,000 km² or more"]
    BX -->|Redraw / drag a corner| DR
    BX -->|Use this extent| LY
    BX --> RB(["Region build starts<br/>after the settle window"])
    AR -.->|"← 'Back to the location prompt'"| BK["Lands on the Library;<br/>modes and location asked again<br/><b>F24</b>"]:::finding
    LY["Layers · STEP 3 OF 4<br/>mode-derived defaults"] -->|toggle a layer / Reset to defaults| LY
    LY -->|Continue| NR([New Route → §4])
    LY --> CX(["Candidate extraction starts"])
    LY -.->|←| AR
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 4 · First route — New Route (step 4 of 4)

`presentation/screens/new_route_screen.dart` · `widgets/error_states.dart`

New Route is reached from two places: trip creation, and *+ New route day*, *Add a passage* or *Add
segment* inside the shell (§7). It draws the same screen both times. **F7**

```mermaid
flowchart TD
    NR["New route · 'NEW TRIP · STEP 4 OF 4'<br/>trip name, dates, party<br/><b>F7</b>"]:::finding --> SM{Start from}
    NR -.->|Reset| NR
    NR -.->|←| PREV[previous screen]
    SM -->|Blank canvas| CB[Create route]
    CB --> AD["Adds an empty Day N+1<br/>even when opened from 'Add a passage'<br/><b>F4</b>"]:::finding
    AD --> SH([Trip shell → §5])
    SM -->|Generate from a theme| FM["Passage mode · discipline · shape ·<br/>theme · target distance ·<br/>tap start / end / up to 2 via, or search a town"]
    FM --> RC{Routing for this region}
    RC -->|settling / queued / building| WT["ROUTING · warming notice<br/>observed progress"]
    WT -.-> RC
    RC -->|failed, or area too small| RF["Notice: what still works<br/>+ Retry"]
    RF -.->|Retry| RC
    RF -->|start blank instead| SM
    RC -->|ready| IN{Inputs complete?}
    IN -->|no| WH["Generate disabled<br/>+ the missing input, in a sentence"]
    WH -.-> FM
    IN -->|yes| GN[Generate route]
    GN --> SV{Solve}
    SV -->|ok| SH
    SV -->|outside the routable area| ND["'This area doesn't have routable data'<br/>Choose area → pops one screen<br/><b>F6</b>"]:::finding
    ND -.-> PREV
    SV -->|any other failure| ER["Error sentence"]
    ER -.->|try again| GN
    FM -->|search fails| SE["'Couldn't resolve that location'"]
    SE -.-> FM
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 5 · The trip shell

`presentation/screens/trip_shell_screen.dart`

```mermaid
flowchart TD
    IN([Open from Library, or after New Route]) --> HZ{"Hazards need attention?<br/><i>once per trip open</i>"}
    HZ -->|yes| HD["'Hazards on this trip' · Got it"]
    HD --> TB
    HZ -->|no| TB["Tabs: <b>ROUTE</b> (default) · LOGISTICS · LAYERS ·<br/>CONTENT · ROSTER · EXPORT · READ"]
    TB --> R6([ROUTE → §7])
    TB --> L6([LAYERS, CONTENT → §6])
    TB --> G8([LOGISTICS, ROSTER → §8])
    TB --> O10([EXPORT, READ → §10])
    AB["App bar"] -->|← Library| FL["Flush autosave, clear undo"]
    FL --> LIB[Library]
    AB -->|tap the title| RN["Rename trip · Save / Cancel"]
    AB -->|Trip area| TA([Revise the extent → §9])
    AB -->|'N stale'| SL([Stale list → §9])
    AB -->|"Undo / Redo · Ctrl+Z"| UN["One authored edit per step"]
    AB -->|Save| SV["'Saved locally'<br/><i>autosave also runs</i>"]
    AB -->|Settings| ST[Settings]
    ST -.->|←| TB
```

---

## 6 · Curate — Layers and Content

`plan_tabs/layers_tab.dart` · `plan_tabs/proposals_view.dart` · `plan_tabs/content_tab.dart` ·
`widgets/anchor_promotion_panel.dart`

```mermaid
flowchart TD
    LT[LAYERS tab] --> LC{Catalog}
    LC -->|failed| LCF["Cause sentence · Retry"]
    LCF -.->|Retry| LC
    LC -->|no trip area| DA["Draw area"]
    DA --> TA([Trip area → §9])
    LC -->|ok| CS{Candidates}
    CS -->|loading| CL(["Extraction / mirror fetch<br/>hourglass wait"])
    CL -.-> CS
    CS -->|all failed| CF["'The candidates didn't load' · Retry"]
    CF -.->|Retry| CS
    CS -->|some layers failed| CP["'Some layers are missing'<br/>each layer and its reason ·<br/>Retry those layers"]
    CP -.->|Retry| CS
    CS -->|none in the area| CN["Empty state · Widen the trip area"]
    CN --> TA
    CS -->|served| VW{"View: Candidates · Proposals · Anchors"}
    LT -->|this day| OV["Override for this day / Use trip default"]
    VW -->|Candidates| TP["Tap a candidate on the map"]
    TP -->|active day exists| PR["Promoted at once: role from affinity,<br/>snackbar"]
    TP -->|no days on the trip| NO["Nothing happens<br/><b>F20</b>"]:::finding
    TP -->|already an anchor| DU["'edit its roles in the Anchors view'<br/><b>F15</b>"]:::finding
    VW -->|Proposals| PP["Sort · filter · reject (Undo) ·<br/>bulk reject · promote with roles"]
    PP -->|already an anchor| DU2["'edit it on Content'<br/><b>F15</b>"]:::finding
    VW -->|Anchors| AN["Attach to a day · passage, or Detach"]
    CT[CONTENT tab] --> PA["Anchors panel · 'Promote a place' dialog:<br/>roles, area, reveal, arc, water, station<br/><b>F17</b>"]:::finding
    CT --> NE{Passage selected on ROUTE?}
    NE -->|no| NS["'Select a segment on the Route tab'"]
    NE -->|yes| NM["Second node map: no route line,<br/>no Cancel · node chips in route order<br/><b>F16</b>"]:::finding
    NM --> NF["Node editor form → saved"]
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 7 · Route — nodes, generate, alternates

`plan_tabs/route_tab.dart` · `widgets/weights_rail.dart` · `widgets/metrics_rail.dart` ·
`widgets/route_through_list.dart` · `widgets/node_editor_sheet.dart` ·
`state/current_trip_provider.dart`

```mermaid
flowchart TD
    RT[ROUTE tab] --> SEL{"What is selected?"}
    SEL -->|a day with no passage| AN0["Add node"]
    AN0 --> MP{More than one trip mode?}
    MP -->|yes| MD["'Start a passage' · pick its mode"]
    MD -.->|Cancel| RT
    MP -->|no| PB
    MD --> PB["Placement bar · crosshair<br/>Esc / Cancel"]
    SEL -->|a day with passages, none selected| NA["No map action<br/><b>F18</b>"]:::finding
    NA -->|pick a passage| SEL
    SEL -->|a passage| PS["Add node · Add alternate"]
    PS -->|Add node| PB
    PB -.->|Esc / Cancel| RT
    PB -->|tap the map| ED["Node editor: kind, title, notes,<br/>Route through this<br/><i>start / finish / via lock it on</i>"]
    ED -.->|Cancel| RT
    ED -->|Save| NS["Node saved · one undo step<br/>a second start or finish demotes the first<br/>passage stale if routed"]
    NS --> RTL["Metrics rail · ROUTE THROUGH<br/>drag / arrows / remove ·<br/>start and finish pinned"]
    RTL -->|reorder| ST([Stale → §9])
    PS -->|Add alternate| AD["Draft bar: tap fork, tap rejoin<br/>Undo last · Cancel"]
    AD -.->|Cancel / Esc| RT
    AD -->|Create| AN["Name it · type"]
    AN --> AC["Alternate on the passage"]
    AC -->|open its card → Move| AM["Move bar: grab fork / rejoin / shape points<br/>Done · Cancel"]
    AM -.->|Cancel| AC
    AM -->|Done| ST
    RT --> RL["Weights rail · EXPLORE / COMPOSE<br/>Frame · Tune · Refine"]
    RL --> GB{Generate / Regenerate}
    GB -->|no route points, or Compose loop| GD["Disabled + reason"]
    GB -->|region still building| GW["503 shown as an error banner,<br/>not a wait<br/><b>F5</b>"]:::finding
    GW -.->|try again later| GB
    GB -->|ok| SOL["Solved: line, metrics, reached / missed,<br/>band violations"]
    GB -->|failure| GF["Error sentence"]
    GF -.-> GB
    RL -->|Explore, bands set, solved| DG{Diagnose}
    DG -->|"no bands / not solved"| DGD["Disabled; tooltip empty<br/>when unsolved<br/><b>F21</b>"]:::finding
    DG -->|"passage built from nodes"| DGX["Null-check crash, no message;<br/>poll has no deadline<br/><b>F2</b>"]:::finding
    DG -->|ok| CD["Conflict dialog · relaxations"]
    CD -->|apply| ST
    RL -->|Compose| CM["Spine: add / reorder / remove anchors<br/>Split the day · Widen the band ·<br/>Drop an anchor · Move to another day"]
    CM --> ST
    RL -->|Remove passage| RP{Authored content?}
    RP -->|yes| RPC["Confirm removal"]
    RP -->|no| RM["Removed · undoable"]
    RPC --> RM
    RL -->|Reset planning controls| RS["Weights / bands back to defaults"]
    RT --> DS["Day strip: day chips ·<br/>+ New route day · Add a rest day"]
    DS -->|+ New route day| NR([New Route → §4])
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 8 · Days, logistics and roster

`plan_tabs/logistics_tab.dart` · `rest_day_location_screen.dart` · `plan_tabs/roster_tab.dart`

```mermaid
flowchart TD
    LG[LOGISTICS tab] --> DT["Edit dates → date range picker"]
    DT -.->|cancel| LG
    LG --> DC["Day count"]
    DC -->|fewer days than have content| DRP{"Day removal prompt"}
    DRP -->|Merge into adjacent| LG
    DRP -->|Remove explicitly| LG
    DRP -.->|Keep| LG
    LG -->|no days| ND["Empty state: Add a route day / Add a rest day"]
    LG -->|New route day| NR([New Route → §4])
    LG -->|"a day with no passage: Add a passage<br/>a day with passages: 'Add segment'"| AS["New Route<br/><b>F4 F7 F17</b>"]:::finding
    AS --> NR
    LG --> RD["Rest day → location screen"]
    LG --> LD["LODGING · Place lodging on map → Confirm / Cancel"]
    LG --> WM["Water carry · meals · gear"]
    LG --> AL["Alternates per passage<br/>ACCOMMODATION / BRANCH"]
    LG -->|stale count| SL([Stale list → §9])
    RO[ROSTER tab] -->|no Characters| RE["Empty state"]
    RO --> RA["Add a Character → profile fields → Save"]
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 9 · Edit, stale and re-solve

`widgets/stale_list_dialog.dart` · `widgets/trip_bbox_shrink_prompt.dart` ·
`state/current_trip_provider.dart` (`_edit`, `markSegmentStale`, `resolveAllStale`)

```mermaid
flowchart TD
    E["An edit that changes what was solved:<br/>node kind or route-through · ROUTE THROUGH order ·<br/>a band or weight · relaxation · alternate move"] --> S["Passage / alternate marked stale<br/>'N stale' in the app bar"]
    E -.->|Ctrl+Z| U["Undo: one step back"]
    S --> SL["Stale list"]
    SL -->|Re-solve one| RS["Solved in Explore,<br/>whatever the day's mode<br/><b>F3</b>"]:::finding
    SL -->|Re-solve all| RS
    RS -->|ok| OK["Item leaves the list;<br/>list closes when empty"]
    RS -->|failure| RE["Error sentence on the row"]
    RE -.->|try again| RS
    SL -->|Drop| DC{"'Drop this route / branch / alternate?'"}
    DC -->|Drop| OK
    DC -.->|Keep| SL
    SL -.->|Close| BACK[Back to work]
    TA["Trip area · revise"] --> PX{Proposed box}
    PX -->|anchors stay inside| AP["Applied · one undo step"]
    PX -->|anchors fall outside| SP{Shrink prompt}
    SP -->|Move bounds| AP
    SP -->|Remove anchors| RA["Removed, then applied:<br/>two undo steps<br/><b>F14</b>"]:::finding
    SP -.->|Keep bounds| TA
    AP --> RB(["Only the new strip is fetched"])
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 10 · Outputs — itinerary, cue sheets, print, device export

`plan_tabs/export_tab.dart` · `widgets/print_preview.dart` · `widgets/stale_list_dialog.dart` ·
`data/export/fit_writer.dart` · `data/routing_client.dart` (`cuesFor`)

```mermaid
flowchart TD
    EX[EXPORT tab] -->|no routed days| NRD["'No routed days yet.'<br/>Export disabled"]
    EX --> IT["ITINERARY · MASTER / INDIVIDUAL<br/>individual: days attended, a label"]
    IT -->|Print preview| PG{Stale work on these days?}
    PG -->|yes| PB["'N stale items need re-solving'<br/>Close only, no way to the list<br/><b>F10</b>"]:::finding
    PB -.-> EX
    PG -->|no| PV["PDF preview · Print<br/><i>no share, attribution footer</i>"]
    IT -->|Export .md| SD{Save dialog}
    SD -.->|cancel| EX
    SD --> WR{Write}
    WR -->|ok| SN["Snackbar 'Exported …'"]
    WR -->|fails| UH["Unhandled, no message<br/><b>F9</b>"]:::finding
    EX --> DC["DAY N cue sheet, per day"]
    DC --> CQ{What passages does the day hold?}
    CQ -->|tapped or generated routes| CU["Turn-by-turn cues + authored points"]
    CQ -->|only node-built passages| CA["Authored points only, no turns,<br/>no message<br/><b>F1</b>"]:::finding
    CQ -->|a mix| CM["Client null-check throws →<br/>'unreachable' banner, the whole day<br/>loses its turns, no Retry<br/><b>F1 F11</b>"]:::finding
    CU -->|Print preview| PG
    CA -->|Print preview| PG
    CM -->|Print preview| PG
    EX --> BOX["EXPORT box<br/>FORMAT GPX · TCX · GEOJSON · FIT<br/>CONTENTS track (fixed) · waypoints ·<br/>cue sheet · alternates<br/>SINGLE FILE / PER DAY"]
    BOX --> XB[Export … file / files]
    XB --> SG{Stale work anywhere on the trip?}
    SG -->|yes| SLD["Stale list<br/>resolve or drop all to continue"]
    SLD -.->|Close| BOX
    SLD -->|list empties| CF
    SG -->|no| CF{Cue sheet on?}
    CF -->|yes| FC["Fetch cues per passage:<br/>node-built skipped, failures swallowed<br/><b>F1 F12</b>"]:::finding
    CF -->|no| PK
    FC --> PK{"Save dialog (single) /<br/>folder picker (per day)"}
    PK -.->|cancel| BOX
    PK --> WF["Write · FIT also writes .fit.txt<br/>with the ODbL notice<br/>per day overwrites same-named files<br/><b>F23</b>"]:::finding
    WF -->|ok| XS["Snackbar 'Exported …'"]
    WF -->|fails| XF["Export failed dialog with a reason"]
    XF -.->|try again| XB
    RD[READ tab] --> RV["Character view, reveal-safe"]
    RV --> RP["Print"]
    classDef finding stroke:#c0392b,stroke-width:3px
```

---

## 11 · Findings

Severity: **High** means wrong output, a crash, or work silently lost. **Medium** means a dead end
or a path that misleads. **Low** means copy or consistency. Each finding was traced in code at
`a3245b3`; none has been reproduced on the desktop app yet. Line numbers are under `client/lib/`
unless stated.

| ID | Sev | Stage | Finding | Evidence |
|---|---|---|---|---|
| **F1** | High | 10 | **A passage built from nodes (#626/#640) gets no turn-by-turn cues anywhere.** Such a passage has no stored `start` (D71), and every cue path keys on `start`. If a day holds only node-built passages, its cue sheet is authored points only, with no message. If a day mixes them with tapped routes, `cuesFor` hits a null check, the day shows the *"unreachable"* banner, and **the routed passages lose their turns too**. Device export with *Cue sheet* on skips them silently, so a FIT file ships with no turns. | `plan_tabs/export_tab.dart:695`, `:1063`; `data/routing_client.dart:373` |
| **F2** | High | 7 | **Diagnose crashes on a node-built passage.** `segment.start!` is null there. Only `RoutingException` is caught, so the button resets and nothing is said. The poll loop has no deadline either, and the `StateError` for a missing bbox isn't caught. | `widgets/weights_rail.dart:745`, `:765`, `:740` |
| **F3** | High | 9 | **The stale list re-solves every item in Explore,** including passages on a Compose day. Weights convert per mode (Compose drops `interest`) and so does the target, so the re-solved route can differ from the one the rail's own button would give. This covers *Re-solve*, *Re-solve all*, and both export/print stale gates. | `widgets/stale_list_dialog.dart:189`, `:148`; `state/current_trip_provider.dart:2168` |
| **F4** | High | 4, 8 | **"Add a passage" plus Blank canvas adds a new empty day** instead of a passage on the day the Author picked. `_createBlank` ignores `plannerTargetDayIdProvider` and leaves it set, so the next New Route can target a stale day. | `screens/new_route_screen.dart:787` |
| **F5** | Med | 7 | **Inside the shell, a region still building reads as an error.** Generate / Regenerate are enabled while the graph builds. The sidecar's 503 comes back as a red `ConflictBanner`, not the hourglass wait with progress. Only New Route shows routing readiness. This breaks the design rule that waits are not failures. | `widgets/weights_rail.dart:527`, `:565`; `service/plotlines_service/app.py:3473` |
| **F6** | Med | 4 | **"Choose area" on New Route pops one screen,** which lands on the layer step during creation, or back in the shell when adding a day. Neither is the trip area. | `screens/new_route_screen.dart:612` |
| **F7** | Med | 4 | **New Route always reads "NEW TRIP · STEP 4 OF 4"** and shows the trip-name / dates / party block, even when it is opened to add a passage to an existing trip. | `screens/new_route_screen.dart:219` |
| **F8** | Med | 2 | **Three library card actions do one thing.** *Edit route*, *Manage roster & preferences* and *Export backup* all open the trip on ROUTE. *Export backup* has no backup behind it (it is story L3, #127). | `screens/trip_library_screen.dart:555` |
| **F9** | Med | 10 | **The itinerary `.md` export has no catch.** A write failure is an unhandled exception with nothing on screen, unlike the device export, which has a dialog. | `plan_tabs/export_tab.dart:244` |
| **F10** | Med | 10 | **Print blocked by stale work is a dead end.** The dialog says *"open the stale list from Export"* but offers only *Close*. | `widgets/print_preview.dart:169` |
| **F11** | Med | 10 | **A failed cue derivation has no Retry.** The day only reloads when the day or trip changes. | `plan_tabs/export_tab.dart:768` |
| **F12** | Med | 10 | **Device export swallows per-passage cue failures** (`catch (_) {}`) and still says *"Exported …"*. | `plan_tabs/export_tab.dart:1067` |
| **F13** | Low | 3 | **A drag with a side under 200 m is ignored with no message** (#628's guard). The Author sees nothing happen. | `map/trip_area_map.dart:156` |
| **F14** | Low | 9 | **Shrinking the area and removing anchors makes two undo steps** (*Remove N places* and *Change the trip area*) for one decision. | `screens/trip_area_screen.dart:106` |
| **F15** | Low | 6 | **Anchors have two editors:** the Layers tab's *Anchors* view and the Content tab panel. The two duplicate-promotion snackbars point at different ones. | `plan_tabs/layers_tab.dart:412`; `plan_tabs/proposals_view.dart:379` |
| **F16** | Low | 6 | **The Content tab is a second node-placement map.** It has no route line and no gesture panel or Cancel, and it centres on `segment.start`, which is null for a node-built passage. | `plan_tabs/content_tab.dart:84` |
| **F17** | Low | 6, 7, 8 | **Copy leaks internals.** Labels carry FR numbers (*FR106*, *FR108*, *FR25*, *FR109*). One sentence names a *"Curation"* tab that doesn't exist. *Segment* and *passage* are used for the same thing (*Add segment*, *Select a segment*). | `widgets/anchor_promotion_panel.dart:941`, `:972`, `:1172`; `widgets/weights_rail.dart:1302`; `plan_tabs/logistics_tab.dart:505`; `plan_tabs/content_tab.dart:67` |
| **F18** | Low | 7 | **A day that has passages, with none selected, offers no map action.** The node-built path (#626) can only start a passage on an *empty* day. A second one on the same day has to go through New Route. | `plan_tabs/route_tab.dart:600–655` |
| **F19** | Low | 1 | **The sidecar start screen says "Plotting the route graph"** while the engine is only starting. No graph is involved yet. | `widgets/sidecar_gate.dart:73` |
| **F20** | Low | 6 | **Tapping a candidate on a trip with no days does nothing** and says nothing. | `plan_tabs/layers_tab.dart:390` |
| **F21** | Low | 7 | **Diagnose is disabled with an empty tooltip** when bands exist but nothing is solved yet. | `widgets/weights_rail.dart:551` |
| **F22** | Low | 3 | **The location error says "continue and place the map yourself"**, but *Continue* re-runs the geocode. The way on is *Use Buncombe County* or clearing the field. | `widgets/trip_location_prompt.dart:147`, `:163` |
| **F23** | Low | 10 | **Per-day export overwrites same-named files** in the chosen folder without asking. | `plan_tabs/export_tab.dart:1147` |
| **F24** | Low | 3 | **Trip extent's ← says "Back to the location prompt"** but lands on the Library, because the prompts were dialogs over it. Going forward asks for modes and location again. | `screens/trip_area_screen.dart:164` |

**Proposed grouping into issues.** These group by fix, not one issue per finding:
1. **Node-built passages through the output pipeline:** F1, F2, F16. This is the #626/#640 follow-on. The fix is one helper that resolves a passage's effective start (`routeSolveInputs`) for cues, Diagnose and the Content map.
2. **Stale re-solve honours the day's planning mode:** F3.
3. **New Route opened from the shell:** F4, F6, F7. Target the picked day, drop the creation chrome, and send *Choose area* to the trip area.
4. **Routing readiness inside the shell:** F5.
5. **Export and print dead ends and silent failures:** F9, F10, F11, F12, F23.
6. **Library card actions:** F8. Deep-link the tab, and hide *Export backup* until L3 (#127).
7. **Copy and consistency sweep:** F13, F14, F15, F17, F19, F20, F21, F22, F24.

---

## 12 · Diff against the drawn flows (`Plotlines_Author_Flows_MVP.md` v1.6)

| Drawn flow | What the code does | Verdict |
|---|---|---|
| **Flow 1:** modes → location → bbox → layers → first route; the region graph gates routing only | Matches, as STEP 1–4 of 4. Routing readiness is shown on New Route only. | Matches. Readiness inside the shell is missing (**F5**). |
| **Flow 1:** a roster-only clone runs initiation; other scopes skip it | Matches (`runsTripInitiation`). | Matches. |
| **Flow 2:** select layers → candidates → promote / proposals | Matches. A candidate tap promotes in one step with its role taken from affinity. | Matches. Two anchor editors (**F15**). |
| **Flow 4:** Explore and Compose; switch with no work lost | Matches in the rail. | Matches. The stale re-solve ignores the mode (**F3**). |
| **Flow 4:** conflict named, relaxations offered | Diagnose → conflict dialog → apply. | Matches, except for node-built passages (**F2**). |
| **Flow 5 / Coverage:** C4 alternates and C5 waypoints listed as *not drawn* | Both are built: the draft / move bars (#324, #344), plus node placement (#588) and route-by-nodes (#626, #640). | **The drawn set is behind the code.** Flow 11 lives only in the design skill. |
| **Flow 6:** cue sheet, reveal-aware, print; export GPX / TCX / FIT, stale-gated, print blocks with no override | Gating matches. Cues are missing for node-built passages. | **F1**, **F10**. |
| **Flow 8:** *never a silent failure* | Silent at **F1**, **F2**, **F9**, **F12**, **F13**, **F20**. | Six violations. |
| **Flow 8:** waits are not failures (D67, #573) | Holds in the curation tabs and on New Route. Inside the shell, a routing wait reads as an error. | **F5**. |
| **Flow 9:** stale, not chased; the stale list resolves or drops | Matches. | Matches, apart from **F3**. |
| **Flow 10:** undo is one step per authored edit | Holds, except the shrink-and-remove path. | **F14**. |
| **Not in any drawn flow:** library card actions, sidecar gate, READ tab print | Built (G2 is P1). | Drawn here for the first time. |

---

## 13 · Keeping this current

- Re-trace a stage when a PR changes its screens. The `file:line` refs in §11 go stale first, so
  re-check them, and give the change log a row.
- Any new Author flow gets a widget-level flow test, shaped like `route_by_nodes_flow_test.dart`,
  that walks its main path. That makes a broken step in this diagram a failing test.
- When a finding is fixed, strike it in §11 and remove its red outline from the diagram in the
  same PR.

## Change log

| Version | Change |
|---|---|
| **1.0** | First code trace, 2026-10-07, at `a3245b3`. Eleven diagrams (the spine plus ten stages) and 24 findings (F1–F24). Diff against `Plotlines_Author_Flows_MVP.md` v1.6. |
