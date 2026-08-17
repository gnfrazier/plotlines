# plotlines_client

The Plotlines Flutter desktop client (Author Desktop, MVP). `lib/presentation/` implements
the wireframe at `client/design/Plotlines Author Desktop.dc.html` — see `client/design/README.md`
for its origin and scope notes. `lib/` is layered per ARCH §9.1: `presentation/`, `state/`,
`domain/`, `data/`.

## Status

Built and running end to end against a real sidecar and a real basemap, verified against the
rebuilt frozen sidecar binary (not just a source run) — see the repo root
[`README.md`](../README.md) for the full picture and `docs/Plotlines_MVP_Scope_and_Setup.md`
§8 for exactly what's still open. In this client specifically:

- **Trip library** (G2a) — save, reopen, list, local-only (drift/SQLite, `lib/data/app_database.dart`).
- **New route** (Epic A) — mode, all three shapes (loop / out-and-back / point-to-point),
  theme, via-nodes, target distance, and location search (`GET /geocode`).
- **Route planner** (Epic A/B/C/D) — per-segment weight and band editing, live A6 conflict
  diagnosis, a real Protomaps vector basemap (Boulder, CO fixture region only — see below).
- **Node & narrative curation** (Epic E) — notes, media captions, narrative arc stage,
  narration trigger distance (authoring only; playback is field execution, out of scope).
- **Cue sheet + export** (Epic F) — real F1 turn-by-turn cues (`POST /segments/cues`), with
  an honest fallback to an authored-stops list if that call fails; GPX, GeoJSON, and TCX
  export, all written client-side (`lib/data/export/`). FIT is disabled — gated on an unrun
  spike (SPIKE-16), not guessed at.
- **Settings** (K5/K8), **About/attribution** (K10).

## Prerequisites

This client never talks to anything but its own sidecar (ARCH §9.1 — `RoutingClient` holds a
`127.0.0.1` base URL and nothing above the Data layer knows it), and it spawns that sidecar
itself rather than connecting to one you start separately. **The sidecar binary has to be
built once before `flutter run` will get past the loading screen** — see the repo root
[`README.md`](../README.md#running-the-desktop-app) for that half (Python venv, `uv`,
`packaging/build_sidecar.sh`). Everything below assumes that's done.

- **Flutter SDK** with Linux desktop enabled (`flutter config --enable-linux-desktop`); run
  `flutter doctor` to confirm. Needs a working display — WSLg provides this on WSL2.

## Running it

```bash
flutter pub get
(cd packages/plotlines_ui && flutter pub get)
flutter run -d linux
```

`packages/plotlines_ui` is a path dependency (real code, not reference — see its own README),
so it needs its own `flutter pub get` the first time and after any of its own dependency
changes. First launch takes a few seconds while the sidecar loads the route graph (M13's
honest "starting" screen, escalating its message if it runs long) before handing off to the
trip library.

The basemap only covers the Boulder, CO fixture region — `assets/tiles/` (496 vector tiles,
committed) was exploded once from SPIKE-14's `spikes/SPIKE-14/tiles/boulder.pmtiles`; panning
elsewhere shows an honest "no basemap tiles here" label rather than a blank map. No
regeneration needed to run the app.

## Testing

```bash
flutter analyze lib/ test/
flutter test
```

Both run clean and are worth checking before a PR. `test/vector_tile_provider_test.dart` and
`test/export_writers_test.dart` exercise real output (a real tile parses as valid MVT, both
map themes parse, and all three export writers produce well-formed GeoJSON/GPX/TCX) rather
than just checking the app boots.

## Layout

```
lib/
├── domain/        # pure Dart trip payload model — mirrors docs/schemas/trip_payload.schema.json
├── data/          # RoutingClient (sidecar HTTP), SidecarManager (M12 lifecycle), drift storage,
│                  # export/ (GPX/GeoJSON/TCX writers)
├── state/         # Riverpod providers
└── presentation/  # screens/, widgets/, map/ — built against client/design/
```
