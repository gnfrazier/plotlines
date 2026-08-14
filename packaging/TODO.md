# packaging TODO — deferred decisions

Both of these are explicitly deferred per the setup prompt (ground rule 4) and the MVP
doc's build & version pipeline (§3). Do not pick one here — resolve during the sidecar
prototype (MVP doc §6, item 6).

## Q4 — Freezer choice: PyInstaller vs. Nuitka

Which tool freezes `service` + `core` into the per-platform sidecar binary. Open per
MVP doc §3, step 3. Decide once the sidecar is prototyped on the primary desktop
platform and the trade-offs (startup time, binary size, native-extension compatibility
with the geospatial stack) are actually measured.

## Q5 — Bundle vs. download

Whether the sidecar binary ships bundled inside the Flutter installer or is fetched
separately at first run. Open per MVP doc §3, step 4. Affects installer size, update
flow, and offline-first behavior (ARCH P2) — decide alongside Q4, not before.
