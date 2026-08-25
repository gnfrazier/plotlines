# Plotlines

**Your Journey, Your Story**

Planning a journey is much like planning to write a story. You have your characters, the friends who are going with you. The setting, where you are going and what you will see. Then the plot, a route to follow.

Creating a good story has an arc to it, establishing the characters, adding key points that make things interesting, navigating some struggle or obstacle to overcome, and reaching a conclusion where the characters arrive at a stopping point.

Plotlines enables multimodal adventure trips that include cycling, hiking, paddling, cross-country skiing, climbing, packrafting, riverboarding, canyoneering, and jumaring. Different ways to get yourself from here to there.

Getting there is part of the fun; sometimes the last mile to the trailhead or put-in is the most harrowing moment of the day. Routes for auto trips and notes for train and plane transport are easy to access.

Trip authors bring their expertise, deep knowledge of how group dynamics influence an experience, and personal flair to the adventure. From a rest stop at a historic clock tower, to a cycling leg with a bit of hiking to a scenic overlook, to a rest day where the lodging is convenient to hot springs, a sauna, and a supermarket. Authors are the most important people in creating the outline of the story.

When characters embark on the journey, they can sync the plan to their mobile app, view it on a webpage, or even print a paper copy of the routes, itineraries, cue sheets, POI notes, and author's plot points. Characters export daily routes to their preferred navigation device or application, whether it is Garmin, Coros, RideWithGPS, or another application that accepts GPX, FIT, or TCX files.

---

## Scope: desktop MVP

This repo builds the **desktop MVP**: a local Plotlines client that generates
theme-weighted, multimodal-capable routes via a sidecar, curates them, and exports them — no
hosted service, no accounts, no sync, no Web, no mobile field execution. See
`docs/Plotlines_PRD_v2.md` §5 and §8, and `docs/Plotlines_MVP_Redirection_Punchlist.md`, for
the exact in/out-of-scope line.

## Docs

The planning docs live in `/docs` and are the source of truth:

- `docs/Plotlines_PRD_v2.md` — what/why
- `docs/Plotlines_ARCHITECTURE_v2.md` — how (tiers, principles, the sidecar model)
- `docs/Plotlines_MVP_Redirection_Punchlist.md` — build order, acceptance, and
  verification checklist. Read this alongside the PRD; it calls out several places where
  the PRD's recomposed (v2.0) model contradicts older readings that may still be lying
  around in a branch or an earlier conversation.
- `docs/Plotlines_Author_Flows_MVP.md` — the Author's flows as Mermaid diagrams, each
  mapped to the FRs and stories it covers.
- `docs/Plotlines_Research_Spikes.md` — feasibility unknowns.
- `docs/schemas/trip_payload.schema.json` — **the trip payload contract, and source of
  truth for its shape** (SPIKE-20, ARCH D28). One document serving `plotlines-core`'s
  return type, drift's `trip.payload`, the hosted JSONB column, and the Flutter domain
  layer. Where an implementation disagrees with it, it wins.

## Monorepo layout

```
plotlines/
├── core/            # plotlines-core — pure Python routing library (P1: no fastapi import)
├── service/         # plotlines-service — FastAPI wrapper (sidecar now, hosted later)
├── client/          # Flutter app (desktop first) — domain/data/state/presentation built
│   ├── lib/         #   Author Desktop: trip library, new route, planner, cue sheet/export,
│   │                #   settings, about — see client/lib/domain/README.md for the payload layer
│   ├── design/      #   imported Claude Design reference — wireframes, brand guide,
│   │                #   UI gallery, CSS tokens, specimen cards
│   └── packages/    #   plotlines_ui — the design system as a Flutter package
│                    #   (a path dependency; compiles clean, fonts vendored offline)
├── packaging/        # frozen-binary build, installers, signing; version.lock is the
│                     # single source of truth both client and sidecar stamp themselves with
├── docs/             # PRD, architecture, MVP scope, research spikes
│   └── schemas/      #   trip_payload.schema.json — the one contract core, drift and
│                     #   the Dart domain layer all read (SPIKE-20, ARCH D28)
└── .github/workflows/  # CI — the P1 boundary lint (core must not import fastapi) and
                      # the trip-payload schema check
```

## Getting started (desktop dev)

Toolchain, verified for WSL/Ubuntu:

- **Python 3.11+** with working `venv`/`pip` (on Debian/Ubuntu: `python3.12-venv` and
  `python3-pip` if missing) — plus `libgdal-dev`, `libgeos-dev`, `libproj-dev`, and
  `build-essential` for the geospatial stack `core/pyproject.toml` declares
  (osmnx, shapely, rasterio, numpy, networkx).
- **[uv](https://github.com/astral-sh/uv)** for Python dependency management.
- **Flutter SDK** with Linux desktop enabled (`flutter config --enable-linux-desktop`);
  run `flutter doctor` to confirm. Needs a working display — WSLg provides this on WSL2.
- **Git.**

`core` and `service` wire graph loading, scoring, routing (all three shapes), trip
composition, cue derivation, geocoding, region acquisition, and basemap tile serving into a
FastAPI sidecar wrapper (`/health`, `POST /regions`, `/segments/generate`, `/segments/envelope`,
`/segments/diagnose`, `/segments/cues`, `/days/compose`, `/trips/split`, `/geocode`,
`GET /tiles/{z}/{x}/{y}`). Routing is **region-scoped, on demand** (issue #154): the Author's own
trip bbox, drawn at trip initiation (FR120), is what gets built into a routable graph via
`POST /regions` and Overpass — never a committed fixture. `spikes/SPIKE-00/cache`'s Boulder
graph is a **test fixture** now (pre-seeded into a region's cache path in
`service/tests/test_regions.py` to test the cross-region-422 case without a network call), not
something the app loads at startup or falls back to. `client` is a Flutter app; **Running the
desktop app** below is Linux-first (there's no `client/windows` platform scaffold yet), and
the sidecar's own Windows process-control gap is tracked in `packaging/TODO.md`.

## Running the desktop app

The client always spawns its **own** sidecar process (ARCH §7.3, M12) — there's no "point it
at an already-running dev server" mode — so the sidecar binary has to be built at least once
before `flutter run` will get past the loading screen.

**1. Set up the Python side and build the sidecar** (from the repo root). On Windows, run
this step from **Git Bash** — `build_sidecar.sh` is one script for Linux, macOS, and
Windows on purpose (see `packaging/README.md`), and it isn't a PowerShell/cmd script:

```bash
uv venv .venv
source .venv/bin/activate                 # .venv/Scripts/activate on Windows
uv pip install -e ./core -e ./service
uv pip install pyinstaller                # not a declared dependency yet — see packaging/README.md

./packaging/build_sidecar.sh pyinstaller-onedir
```

This produces `packaging/dist/pyinstaller-onedir/plotlines-sidecar/plotlines-sidecar`, which
`SidecarManager` (`client/lib/data/sidecar_manager.dart`) finds automatically via a
repo-relative dev fallback — no environment variable or flag needed. `--cache-dir` points at a
real OS app-support directory (`path_provider`'s `getApplicationSupportDirectory()`), where
per-region graph and tile caches build up as trips get their own bboxes (`regions/{key}/...`)
— there is no fixture fallback here any more.

Rebuild the binary any time `core/` or `service/` change — it's a frozen snapshot, not a live
reload.

**2. Fetch Flutter dependencies** (client app + the local `plotlines_ui` package):

```bash
cd client
flutter pub get
(cd packages/plotlines_ui && flutter pub get)
```

**3. Run it:**

```bash
flutter run -d linux
```

First launch takes a few seconds while the sidecar starts (M13's honest "starting"
screen, escalating its message if it runs long) before handing off to the trip library, which
opens on a real map under the outline of the shipped Buncombe County, NC home region
(`HomeRegion`, FR96/A10) — a constant, shipped basemap with no download of any kind, distinct
from any trip's own bbox.

Basemap tiles are served by the sidecar (`GET /tiles/{z}/{x}/{y}`, FR92/FR93; issue #154) — the
client never reads a tile file off local disk. Two sources back that endpoint, both read
through `core/plotlines_core/tiles/`: (a) the committed home-region archive,
`service/plotlines_service/data/home_region.pmtiles` (~8.3 MB, z0-14, extracted from SPIKE-14's
`spikes/SPIKE-14/tiles/wnc-corridor.pmtiles` with the vendored `spikes/SPIKE-14/tools/pmtiles`
CLI — z14 was the highest zoom that stayed under the ~15 MB budget FR96 implies for a shipped
asset), and (b) a bbox-scoped on-demand cache extracted for each ensured trip region (FR94),
built alongside its graph in `POST /regions`'s background thread. Panning outside both areas
shows an honest, viewport-based "no basemap tiles here" notice — never a substituted region —
rather than a blank map. `client/assets/map_style/style_{light,dark}.json` (still a committed
client asset — styling, not tile data) are generated from the mirrored Protomaps theme by
`packaging/build_basemap_theme.py`; rerun that script if
`spikes/SPIKE-14/harness/assets/style_*.json` ever changes upstream.

`flutter test` runs clean from `client/`. `flutter analyze` currently surfaces a handful of
lint-level `info`s in real client code plus a few `error`s inside `client/design` — the
imported design reference has its own `pubspec.yaml` and isn't `flutter pub get`'d, so its
`google_fonts` import doesn't resolve. Both are worth running before a PR; neither is a
regression to chase down as part of a docs change.

