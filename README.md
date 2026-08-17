# Plotlines

**Your Journey, Your Story**

Planning a journey is much like planning to write a story. You have your characters, the friends who are going with you. The setting, where you are going and what you will see. Then the plot, a route to follow.

Creating a good story has an arc to it, establishing the characters, adding key points that make things interesting, navigating some struggle or obstacle to overcome, and reaching a conclusion where the characters arrive at a stopping point.

Plotlines enables multimodal adventure trips that include cycling, hiking, paddling, cross-country skiing, climbing, packrafting, riverboarding, canyoneering, and jumaring. Different ways to get yourself from here to there.

Getting there is part of the fun; sometimes the last mile to the trailhead or put-in is the most harrowing moment of the day. Routes for auto trips and notes for train and plane transport are easy to access.

Trip authors bring their expertise, deep knowledge of how group dynamics influence an experience, and personal flair to the adventure. From a rest stop at a historic clock tower, to a cycling leg with a bit of hiking to a scenic overlook, to a rest day where the lodging is convenient to hot springs, a sauna, and a supermarket. Authors are the most important people in creating the outline of the story.

When characters embark on the journey, they can sync the plan to their mobile app, view it on a webpage, or even print a paper copy of the routes, itineraries, cue sheets, POI notes, and author's plot points. Characters export daily routes to their preferred navigation device or application, whether it is Garmin, Coros, RideWithGPS, or another application that accepts GPX, FIT, or TCX files.

---

## Current focus: desktop MVP

This repo is building the **desktop MVP**: a local Plotlines client that generates
theme-weighted, multimodal-capable routes via a sidecar, curates them, and exports them — no
hosted service, no accounts, no sync, no Web, no mobile field execution. See
`docs/Plotlines_MVP_Scope_and_Setup.md` §1 for the exact in/out-of-scope line.

**Status:** the Flutter Author Desktop client is built and running end to end against a real
sidecar and a real basemap, and its UI matches `client/design`'s wireframe — not just the
same features, the same information architecture. Every trip opens into one persistent
**Trip Shell** with `Route / Logistics / Content / Export` tabs (an always-visible weights
rail, a day timeline strip, and A6 conflict diagnosis as a real modal dialog, not the
separate pushed screens this used to be), plus trip library search/grid-list, new-route (all
three shapes: loop, out-and-back, point-to-point, location search, and a blank-canvas /
generate-from-theme / import-GPX start method), node & narrative curation, real F1
turn-by-turn cue sheets, and GPX/GeoJSON/TCX export with real per-day splitting and content
toggles (waypoints, cue sheet, alternates). The basemap renders real street, place, and water
labels now too — a one-session gap where the shipped style JSON was never actually run
through the label-fix transform SPIKE-14 had already worked out (`packaging/build_basemap_theme.py`
is that fix, made a real committed pipeline step instead of a one-off probe). All of this is
verified against the rebuilt frozen sidecar binary, not just a source run, and against a real
launch of the built app. What's left is catalogued in `docs/Plotlines_MVP_Scope_and_Setup.md`
§8 — an arbitrary-region download pipeline (today every trip routes against the bundled
Boulder, CO fixture regardless of what A10's first-run prompt is given), Windows sidecar
lifecycle (no Windows box to verify FFI code against), and FIT export (gated on an unrun
spike) — nothing there is a hidden surprise, and nothing in the client fakes data to paper
over a gap.

## Docs

The planning docs live in `/docs` and are the source of truth:

- `docs/Plotlines_PRD.md` — what/why
- `docs/Plotlines_ARCHITECTURE.md` — how (tiers, principles, the sidecar model)
- `docs/Plotlines_MVP_Scope_and_Setup.md` — desktop MVP scope, repo layout, build/version
  pipeline. **§1.4 is the authoritative desktop-MVP story list** — the PRD's `[MVP]` tag
  covers field and account work this milestone does not build, and §1.1's capability table
  names several `[P1]` stories. §1.4 reconciles both and governs where they disagree.
- `docs/Plotlines_Research_Spikes.md` — feasibility unknowns
- `docs/schemas/trip_payload.schema.json` — **the trip payload contract, and source of
  truth for its shape** (SPIKE-20, ARCH D28). One document serving `plotlines-core`'s
  return type, drift's `trip.payload`, the hosted JSONB column, and the Flutter domain
  layer. Where an implementation disagrees with it, it wins.
- `docs/Plotlines - Spike Candidates.md` — **provenance, not source of truth.** A
  technology-choice note from the PRD work, filed 2026-08-15. Its four spike candidates
  became SPIKE-14 … SPIKE-17 and its other three rows are reconciled at the end of the
  spikes doc; read those, not this.

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

`core` and `service` are real: graph loading, scoring, routing (all three shapes), trip
composition, cue derivation, and geocoding are all wired into the FastAPI sidecar wrapper
(`/health`, `/segments/generate`, `/segments/envelope`, `/segments/diagnose`,
`/segments/cues`, `/days/compose`, `/trips/split`, `/geocode`) and work end to end against the
committed Boulder, CO fixture graph (`spikes/SPIKE-00/cache`). `client` is a real Flutter app,
not scaffolding — see **Running the desktop app** below. Remaining known gaps (an arbitrary-
region download pipeline, Windows sidecar lifecycle, FIT export) are tracked in
`docs/Plotlines_MVP_Scope_and_Setup.md` §8, not silently missing.

## Running the desktop app

The client always spawns its **own** sidecar process (ARCH §7.3, M12) — there's no "point it
at an already-running dev server" mode — so the sidecar binary has to be built at least once
before `flutter run` will get past the loading screen.

**1. Set up the Python side and build the sidecar** (from the repo root):

```bash
uv venv .venv
source .venv/bin/activate                 # .venv/Scripts/activate on Windows
uv pip install -e ./core -e ./service
uv pip install pyinstaller                # not a declared dependency yet — see packaging/README.md

./packaging/build_sidecar.sh pyinstaller-onedir
```

This produces `packaging/dist/pyinstaller-onedir/plotlines-sidecar/plotlines-sidecar`, which
`SidecarManager` (`client/lib/data/sidecar_manager.dart`) finds automatically via a
repo-relative dev fallback — no environment variable or flag needed. It also falls back to
the committed `spikes/SPIKE-00/cache` graph/DEM for the same reason: there's no region-download
pipeline yet (MVP doc §8), so every trip today routes against Boulder, CO regardless of what
the first-run location prompt is given.

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

First launch takes a few seconds while the sidecar loads the graph (M13's honest "starting"
screen, escalating its message if it runs long) before handing off to the trip library.

The basemap only covers the Boulder, CO fixture region — `client/assets/tiles/` (496 vector
tiles, committed) was exploded once from SPIKE-14's `spikes/SPIKE-14/tiles/boulder.pmtiles`
via the vendored `spikes/SPIKE-14/tools/pmtiles` CLI; panning elsewhere shows an honest "no
basemap tiles here" label rather than a blank map. `client/assets/map_style/style_{light,dark}.json`
(also committed) are generated from the mirrored Protomaps theme by
`packaging/build_basemap_theme.py` — real street, place, and water labels, not just polygons
and lines; rerun that script if `spikes/SPIKE-14/harness/assets/style_*.json` ever changes
upstream. No regeneration step needed to run the app — both the tiles and the generated
style are already in the repo.

`flutter test` and `flutter analyze` both run clean from `client/` and are worth checking
before a PR.

