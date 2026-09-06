# Plotlines Release Checklist — Data Pins

Two build pins live outside the app's own version number and do not move when the app releases.
Both are the same shape: a dated build, mirrored on Plotlines-controlled infrastructure, that the
renderer or the routing/candidate pipeline was built and validated against. Neither bumps itself,
and neither failing to bump fails loudly — a pin that silently stopped advancing looks identical to
a working one until someone notices the data is stale (`docs/Plotlines_OSM_Acquisition_Review.md`
§11.3). This checklist is the mechanism that makes a missed bump visible instead: **an item here
that is not checked is a release that ships on a data pin nobody re-confirmed.**

Adopted 2026-09-03 as the decision behind **Q2** (`docs/
Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md`, "Pin cadence and ownership"): monthly
cadence, one named owner, and the monitor (`GET /health`'s `capabilities.mirror`, `core/
plotlines_core/tiles/mirror_state.py`) built regardless of how often the pin actually moves.

## Owner

**Greg Frazier** bumps both pins below. Not "a maintainer" — Q2 is explicit that ownership named as
a role rather than a person is the failure mode this checklist exists to prevent.

## Items

- [ ] **Protomaps basemap build** — `PROTOMAPS_BASEMAP_BUILD` in
      `core/plotlines_core/tiles/mirror.py`. Bump when a new Protomaps Basemap build has been
      acquired and mirrored (`deploy/mirror/copy_basemap_standin.sh` today, for the WNC-corridor
      stand-in; the real planet build once #257's scope widens). Bumping this is a visual-regression
      event against the renderer theme (ARCH A15/D24), not a silent version swap — re-check the
      theme against the new build before shipping.
- [ ] **Geofabrik mirror pin** — `MIRROR_STATE.json`'s `geofabrik.pinned_date`, bumped by running
      `deploy/mirror/geofabrik_pull.py --pinned-date <today>` for every mirrored region (issue #258;
      cadence and monitor: issue #260). Monthly, or sooner if an Author-visible defect traces to
      stale OSM data.

## Verifying a bump

```
python3 deploy/mirror/geofabrik_pull.py --root /srv/plotlines-mirror \
    --region north-america/us/north-carolina --pinned-date $(date -u +%F) --pull-index
```

Then confirm the monitor agrees the mirror is current:

- `GET /health`'s `capabilities.mirror.stale` is `false` — once a sidecar is pointed at the mirror's
  `MIRROR_STATE.json` via `--mirror-state-url` (issue #261 wires this in production; today, point it
  at the file directly: `--mirror-state-url /srv/plotlines-mirror/MIRROR_STATE.json` or the mirror's
  own served URL).
- Absent that flag, read `MIRROR_STATE.json` directly and confirm `geofabrik.pinned_date` and every
  region's `checked_at` are current, and `basemap.build_id`'s leading date is within
  `plotlines_core.tiles.mirror_state.MAX_PIN_AGE_DAYS` (45 days — the monthly cadence plus a grace
  window, not itself the cadence).

A missed month is exactly what `capabilities.mirror.stale = true` is for: this checklist is what
turns "nobody noticed" into "the next release is blocked until someone does."
