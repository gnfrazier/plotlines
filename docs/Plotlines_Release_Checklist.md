# Plotlines Release Checklist — Data Pins

Two build pins live outside the app's own version number and do not move when the app releases: a
dated build, mirrored on Plotlines-controlled infrastructure, that the renderer or the
routing/candidate pipeline was built and validated against. Neither failing to advance fails
loudly — a pin that silently stopped advancing looks identical to a working one until someone
notices the data is stale (`docs/Plotlines_OSM_Acquisition_Review.md` §11.3). The Geofabrik pin
still needs a person to bump it by hand each cadence; the Protomaps basemap pin doesn't (issue
#457 — see below), but both still need the monitor watched, which is what this checklist is the
mechanism for: **an item here that is not checked is a release that ships on a data pin nobody
re-confirmed.**

Adopted 2026-09-03 as the decision behind **Q2** (`docs/
Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md`, "Pin cadence and ownership"): monthly
cadence, one named owner, and the monitor (`GET /health`'s `capabilities.mirror`, `core/
plotlines_core/tiles/mirror_state.py`) built regardless of how often the pin actually moves.

## Owner

**Greg Frazier** owns both pins below — bumping the Geofabrik one by hand, and confirming the
Protomaps basemap refresh cron is actually running for the other. Not "a maintainer" — Q2 is
explicit that ownership named as a role rather than a person is the failure mode this checklist
exists to prevent.

## Items

- [ ] **Protomaps basemap build** — issue #457 replaced the manual monthly bump with a repeatable,
      TTL-driven refresh: `deploy/mirror/protomaps_extract.py`, run from cron/systemd on the Pi
      (`--ttl-days`, default 30, env `PLOTLINES_TILES_TTL_DAYS`), re-probes Protomaps' hosted daily
      build and re-extracts any region whose `MIRROR_STATE.json` entry has aged past the TTL — no
      manual bump for this checklist's owner to run. `PROTOMAPS_BASEMAP_BUILD` in
      `core/plotlines_core/tiles/mirror.py` is now a **stable per-region path pin**
      (`WNC_CORRIDOR_BUILD_ID`, e.g.), not a build date to bump — a refresh overwrites the same file
      in place. What's still worth a manual check at release time: confirm the cron/systemd timer is
      actually running on the Pi (`capabilities.mirror.basemap.stale` on `GET /health` — see below),
      and re-check the renderer theme against the mirror's current basemap after any theme-affecting
      release. The theme is generated against one Protomaps Basemap build (ARCH A15/D24), so a
      *visual* regression from a rotated upstream build is a real risk the automated TTL refresh
      doesn't itself catch.
- [ ] **Geofabrik mirror pin** — `MIRROR_STATE.json`'s `geofabrik.pinned_date`, bumped by running
      `deploy/mirror/geofabrik_pull.py --pinned-date <today>` for every mirrored region (issue #258;
      cadence and monitor: issue #260). Monthly, or sooner if an Author-visible defect traces to
      stale OSM data. **Pass `--precut-wnc-corridor` on this run** (issue #375) — it re-clips the
      freshly-pulled full-state extracts down to the WNC corridor and re-pins the smaller result;
      skipping it on a bump silently regresses `/clip`'s wall time back to a full-state scan.

## Verifying a bump

```
python3 deploy/mirror/geofabrik_pull.py --root /srv/plotlines-mirror \
    --region north-america/us/north-carolina --region north-america/us/tennessee \
    --pinned-date $(date -u +%F) --pull-index --precut-wnc-corridor
```

`--precut-wnc-corridor` needs `plotlines-service` installed with its `mirror-clip`
extra (pyosmium) wherever this runs — the plain `--region`/`--pull-index` pulls above
need nothing beyond the standard library, so this is the one part of the command that
cannot simply run as bare `python3` on the Pi's own OS today. Run it from a machine
that has `uv sync --extra mirror-clip` against `service/`, with access to the same
`--root` tree (the mirror-clip container already carries this dependency for `/clip`
itself, but does not currently mount `deploy/mirror/geofabrik_pull.py` or a writable
mirror root — wiring that up, if it's the preferred way to run this monthly, is
separate from this checklist item).

Then confirm the monitor agrees the mirror is current:

- `GET /health`'s `capabilities.mirror.stale` is `false` — once a sidecar is pointed at the mirror's
  `MIRROR_STATE.json` via `--mirror-state-url` (issue #261 wires this in production; today, point it
  at the file directly: `--mirror-state-url /srv/plotlines-mirror/MIRROR_STATE.json` or the mirror's
  own served URL).
- Absent that flag, read `MIRROR_STATE.json` directly and confirm `geofabrik.pinned_date` and every
  region's `checked_at` are current, and `basemap.extracted_at` (the primary region's, mirrored to
  the top level by `protomaps_extract.py`) is within
  `plotlines_core.tiles.mirror_state.DEFAULT_BASEMAP_TTL_DAYS` (30 days — issue #457; distinct from
  `MAX_PIN_AGE_DAYS`, which is Geofabrik's own 45-day monthly-cadence-plus-grace-window number).

A missed month is exactly what `capabilities.mirror.stale = true` is for: this checklist is what
turns "nobody noticed" into "the next release is blocked until someone does."
