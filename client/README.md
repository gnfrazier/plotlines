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

- **Trip library** (G2a) — save, reopen, list, local-only (drift/SQLite, `lib/data/app_database.dart`),
  with search and a grid/list toggle.
- **New route** (Epic A) — mode, all three shapes (loop / out-and-back / point-to-point),
  theme, via-nodes, target distance, location search (`GET /geocode`), and a start-method
  choice (blank canvas / generate from a theme / import GPX — the last honestly disabled,
  no parser yet).
- **The Trip Shell** (`lib/presentation/screens/trip_shell_screen.dart`) — one persistent
  window per trip with four tabs, matching `client/design`'s wireframe rather than the
  separate pushed screens this used to be:
  - **Route** — an always-visible weights/bands rail, the map, and a day timeline strip
    (transitions, day-limit breaches).
  - **Logistics** — day/rest-day management and C1-C3 per-day distance limits (this repo's
    own design; the wireframe names this tab but never mocks it — see `client/design/README.md`).
  - **Content** (Epic E) — node & narrative curation: notes, media captions, narrative arc
    stage, narration trigger distance (authoring only; playback is field execution, out of scope).
  - **Export** (Epic F) — real F1 turn-by-turn cues (`POST /segments/cues`), with an honest
    fallback to an authored-stops list if that call fails; GPX, GeoJSON, and TCX export
    (`lib/data/export/`), with real content toggles (waypoints/cue-sheet/alternates) and
    single-file-vs-per-day splitting. FIT is disabled — gated on an unrun spike (SPIKE-16),
    not guessed at.
  - A6 conflict diagnosis is a real centered modal dialog (`conflict_dialog.dart`), not an
    inline card.
- **Settings** (K5/K8), **About/attribution** (K10) — merged into one Preferences & About
  screen per the wireframe.

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
changes. First launch takes a few seconds while the sidecar starts (M13's honest "starting"
screen, escalating its message if it runs long) before handing off to the trip library — no
graph loads until an Author draws a trip bbox and `POST /regions` builds one for it.

Basemap tiles come from the sidecar (`GET /tiles/{z}/{x}/{y}`, issue #154) — the client no
longer bundles or reads a tile directory itself. Two areas have real basemap coverage: the
shipped Buncombe County, NC home region (a committed archive server-side) and, once ensured
via `POST /regions`, the Author's own trip bbox; panning elsewhere shows an honest,
viewport-based "no basemap tiles here" notice rather than a blank map. No regeneration needed
to run the app.

## Testing

```bash
flutter analyze lib/ test/
flutter test
```

Both run clean and are worth checking before a PR. `test/vector_tile_provider_test.dart` and
`test/export_writers_test.dart` exercise real output (a real tile parses as valid MVT, both
map themes parse, and all three export writers produce well-formed GeoJSON/GPX/TCX);
`test/trip_shell_screen_test.dart` pumps a real trip through the Trip Shell and switches
between all four tabs — the only test that exercises the shell/rail/timeline/drawer at all,
since the smoke test in `test/widget_test.dart` never routes past the trip library.

## Layout

```
lib/
├── domain/        # pure Dart trip payload model — mirrors docs/schemas/trip_payload.schema.json
├── data/          # RoutingClient (sidecar HTTP), SidecarManager (M12 lifecycle), drift storage,
│                  # export/ (GPX/GeoJSON/TCX writers, export_options.dart's content toggles)
├── state/         # Riverpod providers
└── presentation/
    ├── screens/       # trip_shell_screen.dart + plan_tabs/ (Route/Logistics/Content/Export),
    │                  # trip_library_screen.dart, new_route_screen.dart, settings_screen.dart
    ├── widgets/       # weights_rail.dart, day_timeline_strip.dart, conflict_dialog.dart,
    │                  # node_editor_sheet.dart, error_states.dart
    └── map/           # TapToPickMap, the vector tile provider
```
