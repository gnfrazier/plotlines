# Plotlines mirror — tree layout and Caddy front end

Issues #256 (Phase 1.2, epic #264) and #257 (Phase 1.3): the §6.3/§6.4
production layout, the licence artifacts §6.0/Q6 and addendum finding
**1a** require, the bucket-portable paths §6.0/**Q6** requires, and the
basemap stand-in's honest path (**G3**/**1b**, checklist item 13). Read
`docs/Plotlines_OSM_Acquisition_Review.md` §6 and
`docs/Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md` findings
**L4**/**G3** before changing anything here.

Phase 1.1 (#255, the physical Pi 5 + NVMe host) and later Phase 1 steps
(#258/#260 the Geofabrik pull client and `MIRROR_STATE.json`'s Geofabrik
content, #261 pointing the sidecar at the mirror) are separate issues. This
directory is the part of #256/#257 that is a repo artifact: the tree
scaffold, the Caddy config, the licence notices, and the basemap stand-in
copy step. Everything here is deployed to the Pi; nothing here is Python
application code (`copy_basemap_standin.sh` invokes `python3` only as a
scripting utility to merge one JSON key, the same role `jq` would play if
it were guaranteed present on the Pi).

## Deploying to the Pi

```
ssh pi 'mkdir -p /opt/plotlines-mirror'
scp -r deploy/mirror/. pi:/opt/plotlines-mirror/
scp spikes/SPIKE-14/tiles/wnc-corridor.pmtiles pi:/opt/plotlines-mirror/wnc-corridor.pmtiles
ssh pi
cd /opt/plotlines-mirror
sudo ./build_tree.sh /srv/plotlines-mirror
sudo ./copy_basemap_standin.sh /srv/plotlines-mirror ./wnc-corridor.pmtiles
docker compose up -d
```

The `mkdir` first and the trailing `/.` on the source matter. Modern
OpenSSH `scp` (the SFTP-based implementation, default since ~9.0 and what
current Raspberry Pi OS/Debian ship) `stat`s the destination before a
recursive copy and, unlike the old SCP-protocol `scp`, does **not**
auto-create a nonexistent top-level destination — a bare
`scp -r deploy/mirror pi:/opt/plotlines-mirror` against a Pi that has
never had that directory fails with `scp: stat remote: No such file or
directory` before anything is copied. Creating the directory first and
copying `deploy/mirror`'s *contents* into it (`/.` on the source, trailing
`/` on the destination) avoids the stat entirely and also avoids nesting
a `mirror/` subdirectory inside `/opt/plotlines-mirror` the way a bare
`scp -r deploy/mirror pi:/opt/plotlines-mirror` would if the destination
already existed. If you'd rather keep the original one-line form, forcing
the legacy protocol works too: `scp -O -r deploy/mirror pi:/opt/plotlines-mirror`
— but it needs `scp` on the Pi's end as well, which is standard on
Raspberry Pi OS but not guaranteed on a minimal image.

`build_tree.sh` is idempotent — re-running it never overwrites
`MIRROR_STATE.json` once it exists (that file's real content is #257's and
#258/#260's job), and only ever (re)writes Plotlines' own static
`COPYRIGHT.txt` files and creates directories.

`copy_basemap_standin.sh` (#257) must run after `build_tree.sh` — it copies
the SPIKE-14 corridor archive in under its own honest build id
(`basemap/protomaps/20250101-wnc/corridor.pmtiles`, never `planet.pmtiles`)
and merges `basemap.build_id`/`basemap.covered_regions` into
`MIRROR_STATE.json`, leaving its `geofabrik` key untouched. It's also
idempotent: re-running it overwrites the corridor file and the `basemap`
key cleanly, and errors clearly rather than guessing if `MIRROR_STATE.json`
doesn't exist yet or the source archive isn't where it was told to look.
`spikes/SPIKE-14/tiles/` is gitignored (a locally-built spike artifact), so
it has to be copied onto the Pi separately from `deploy/mirror` itself, as
above. Geofabrik payload files themselves are pulled in by #258/#260 —
neither script here reaches the network.

## Verifying it

```
curl -I http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles
curl -I http://tiles.plotlines.app/osm/geofabrik/<date>/<region>.osm.pbf
curl -H 'Range: bytes=0-99' -o /dev/null -w '%{http_code}\n' \
     http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles   # expect 206
curl http://tiles.plotlines.app/COPYRIGHT.txt
curl http://tiles.plotlines.app/osm/COPYRIGHT.txt
```

Each of the four acceptance criteria in #256 was exercised locally against
the checked-in `Caddyfile` (unchanged) and a scratch tree built by
`build_tree.sh`, using an unprivileged network namespace to bind port 80
without root: tree layout with both `COPYRIGHT.txt` files present, a clean
Caddy startup with `server is listening only on the HTTP port, so no
automatic HTTPS will be applied` (the `http://` prefix doing its job), a
`206` on a ranged GET, `Cache-Control: public, max-age=31536000, immutable`
on both `/basemap/*` and `/osm/*`, and both notice files served with `200`.
§6.5's DNS-override step (pointing the real `tiles.plotlines.app` hostname
at the Pi so `classify_upstream` returns `MIRROR`) is #261's job, not this
issue's.

A `curl -H Range` `206` proves Caddy serves ranges; it does not prove the
sidecar's actual extraction path works, which is what #257 asked for
("verify a byte-range read works end to end via `tiles/extract.py:
http_range_source` — the real code path, not `curl` alone"). Against the
live Pi, that's:

```
python3 -c "
from pathlib import Path
from plotlines_core.tiles.extract import extract_bbox
from plotlines_core.tiles.mirror import MIRROR_WNC_CORRIDOR_URL, WNC_CORRIDOR_BBOX
extract_bbox(MIRROR_WNC_CORRIDOR_URL, WNC_CORRIDOR_BBOX, Path('/tmp/out.pmtiles'),
             min_zoom=8, max_zoom=8, allow_unmirrored=True)
print('ok — a tile inside the corridor extracted via http_range_source')
"
```

(`allow_unmirrored=True` because §6.5's DNS override hasn't landed yet —
see above; once it has, this runs with no flag and `classify_upstream`
returns `MIRROR`.) `core/tests/test_wnc_corridor_standin.py` covers both
halves of this automatically and hermetically — a bbox inside the
corridor's real tile-address range extracts over a real range-serving HTTP
server, and a bbox outside it raises `NoTilesInBbox` rather than writing a
silent empty archive — against a small synthetic stand-in rather than the
real 118 MB archive, which is gitignored and not something CI can depend
on being present.

## Pointing the sidecar at the mirror by name (issue #261, §6.5)

`classify_upstream` (`core/plotlines_core/tiles/mirror.py`) matches on
**hostname only and is scheme-agnostic** — this is asserted, not just
observed, in `core/tests/test_tiles_mirror.py`
(`test_the_mirror_host_classifies_as_mirror_over_plain_http_no_tls`,
`test_a_lan_style_mirror_url_resolves_with_no_dev_flag`,
`test_hotlink_refusal_is_unaffected_by_the_mirror_being_scheme_agnostic`).
What's left is exercising that against the real Pi — two steps, in order,
run **on a machine on the Pi's LAN** (not in CI, and not from this
sandbox, which has no route to the Pi):

**1. Low-friction form first — the flag path.** Both flags already exist
in `service/plotlines_service/__main__.py`:

```
plotlines-sidecar --cache-dir /tmp/plotlines-cache --port 8765 \
    --tiles-upstream http://pi.local/basemap/protomaps/20250101-wnc/corridor.pmtiles \
    --allow-unmirrored-tiles
```

Then drive a region build against it (a bbox inside `WNC_CORRIDOR_BBOX`,
`-83.6, 35.2, -81.0, 36.4`) the same way the client would, and confirm the
tiles come from the Pi rather than the committed home-region archive.

**2. Then the DNS override, once step 1 is boring.** Add a local DNS
record (or an `/etc/hosts` line on the dev box — the zero-infrastructure
fallback) pointing `tiles.plotlines.app` at the Pi's LAN address, then
re-run **without** `--allow-unmirrored-tiles`:

```
plotlines-sidecar --cache-dir /tmp/plotlines-cache --port 8765 \
    --tiles-upstream http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles
```

The same region build must complete with no dev flags at all. Confirm in
a Python shell on that box that the real code path — not just the unit
test's synthetic assertion — agrees:

```
python3 -c "
from plotlines_core.tiles.mirror import classify_upstream, UpstreamKind
url = 'http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles'
kind = classify_upstream(url)
assert kind is UpstreamKind.MIRROR, kind
print('classify_upstream:', kind)
"
```

Last, confirm the gate isn't weakened: a genuine third-party host must
still be refused from that same box —

```
python3 -c "
from plotlines_core.tiles.mirror import resolve_upstream
resolve_upstream('http://tile.openstreetmap.org/planet.pmtiles')
"
```

— must raise `HotlinkRefused`.

Both steps require the physical Pi (built per §6.2-§6.4 / issue #256) and
a LAN or DNS override this repo's CI/dev sandbox has no path to — they are
a manual rehearsal, not something a hermetic test can stand in for. The
unit tests above prove the *code* is already scheme-agnostic and
hostname-only; running the two steps against the live Pi is what proves
the *deployment* exercises `resolve_upstream`'s shipped path instead of
the dev escape hatch.

## `{$MIRROR_ROOT}` / `{$MIRROR_LOG}`

The checked-in `Caddyfile` is otherwise byte-for-byte the §6.4 block, with
one deliberate addition: `root` and the log's `output file` are
env-var-substituted with the production paths as their **default**
(`/srv/plotlines-mirror`, `/var/log/caddy/mirror.log`) — Caddy resolves an
unset `{$VAR:default}` to `default`, so production behaviour is unchanged.
This is what let #256 validate the real, checked-in file against a scratch
tree instead of a hand-edited copy that could drift from what's committed.
It is also one step further in the Q6 "swap is a hostname change and
nothing else" direction: the root path becomes a config knob the same way
the hostname already is.

## The basemap stand-in's honest path (finding G3/1b)

§6.3's tree diagram lists two basemap paths:
`basemap/protomaps/20250101/planet.pmtiles`, which "matches
`MIRROR_ARCHIVE_URL` exactly," and
`basemap/protomaps/20250101-wnc/corridor.pmtiles`, "the SPIKE-14 stand-in,
honestly named." §6.2 is explicit that this Pi never carries the first
one — "do not put a planet archive on it, regional extracts only" — so
only the second path is real today. G3 named the contradiction: checklist
item 13, read literally, copied `wnc-corridor.pmtiles` into the
`planet.pmtiles` path, which would make a bbox outside WNC fail as a
silent miss indistinguishable from a mirror bug, and would make
"build-pinned paths are immutable" untrue for the one file most likely to
be swapped for a real planet build later.

`copy_basemap_standin.sh` takes the fix G3/1b names: its own build id
(`20250101-wnc`, not `20250101`) and its own filename (`corridor.pmtiles`,
never `planet.pmtiles`), plus a `MIRROR_STATE.json` entry
(`basemap.covered_regions`) naming the region and bbox it actually covers
— read directly off the archive's own PMTiles header, not asserted. That
bbox is also `plotlines_core.tiles.mirror.WNC_CORRIDOR_BBOX`, so core code
(and `extract_bbox`'s `NoTilesInBbox`) and the deploy tree agree on what
"covered" means without a second source of truth to drift from.
`MIRROR_ARCHIVE_URL` (the `planet.pmtiles` path) stays defined in
`mirror.py` for whenever the real Protomaps planet build is acquired, but
nothing points a default upstream at it yet, and nothing on the Pi answers
at that path today.

## The `index-v1.json` decision (finding L4, resolved by issue #259)

The §6.3 tree diagram lists Geofabrik's `index-v1.json` conditionally —
"only if its own licence checks out." Issue #256's own check (looking only
at `download.geofabrik.de/technical.html`'s footer copyright line) found
that unclear, and the mirror shipped without it as a result.

Issue #259 did the definitive check the earlier one deferred, and looked in
the right place: not the download server's footer, but Geofabrik's own
stated Open Data policy at
https://www.geofabrik.de/geofabrik/free.html. That page draws exactly the
distinction this decision needed — OSM data itself is ODbL, but "any data
we produce or refine can be distributed in any way and through any
channel," conditioned only on not restricting further redistribution or
modification. `index-v1.json`'s region geometries, cut lines, and metadata
are Geofabrik's own produced/refined data, not raw OSM data — exactly the
category that statement addresses. **`index-v1.json` is mirrored** as of
this issue, under `osm/geofabrik/<pinned_date>/index-v1.json`, with the
licence notice in `osm/COPYRIGHT.txt` citing the page above rather than the
ODbL statement that covers the `.osm.pbf` extracts.

`build_tree.sh` still never creates it — like the `.osm.pbf` extracts, it's
pulled over the network, which is `geofabrik_pull.py`'s job
(`--pull-index`, off by default; see below), not the offline scaffold
script's. `MIRROR_STATE.json` remains Plotlines' own covering-set record
regardless of whether the index has been pulled — a consumer resolves
*what this mirror actually serves* from `MIRROR_STATE.json`, never from the
index alone, since the index only ever describes what Geofabrik offers, not
what this mirror has pulled and verified.

No code today reads the mirrored index for region resolution (the
mirror-side clip is Phase 3/#272 — the transport swap — and doesn't exist
yet), so there is nothing yet to constrain to "reads only what we are
entitled to serve"; that constraint falls on whichever issue writes that
resolution code; the mirror's index-consumption is a stand-in until then.

## Geofabrik pull client (issue #258)

`geofabrik_pull.py` fills in `MIRROR_STATE.json`'s `geofabrik` key and the
`osm/geofabrik/` tree — the two things `copy_basemap_standin.sh` and
`build_tree.sh` deliberately leave alone. It's a standalone script (stdlib
only, no `pip install`) so it deploys the same way as everything else here:

```
scp deploy/mirror/geofabrik_pull.py pi:/opt/plotlines-mirror/geofabrik_pull.py
ssh pi
python3 /opt/plotlines-mirror/geofabrik_pull.py \
    --root /srv/plotlines-mirror \
    --region north-america/us/north-carolina \
    --pinned-date 2026-09-01
```

Run it by hand to bootstrap a new region (the WNC corridor's own state,
`north-america/us/north-carolina`, is the natural first one — checklist
item 15), or from cron/#260's monthly pin bump; its etiquette is enforced
in code regardless of how often it's invoked, so a misconfigured cron
cannot turn into repeated unconditional pulls:

- **at most daily** — a repeat run inside `--min-interval-hours` (default
  24) makes no request at all for a region;
- **conditional first** — outside that window, only the small `.md5` is
  fetched; the `.osm.pbf` body is skipped when its digest is unchanged;
- **identified** — every request carries `PLOTLINES_USER_AGENT`, the same
  contactable string issue #241 introduced for Overpass/Nominatim;
- **verify before publish** — the body downloads to a sibling temp file and
  is moved into place with `os.replace` only once its MD5 matches the
  published one; a mismatch fails the pull and leaves whatever was
  previously at that path untouched;
- **backs off on error** — each consecutive failure doubles the wait before
  the next attempt (capped at a week), and every failure is written into
  `MIRROR_STATE.json` (`geofabrik.regions.<region>.last_failure`) rather
  than only a log line — the surface #260's staleness monitor reads.

Regions are named explicitly on the command line rather than discovered
from Geofabrik's own index — a region's covering extent is a Plotlines
decision, not worth a network round-trip to look up. `index-v1.json`
itself is pulled only when `--pull-index` is passed (issue #259; see "The
`index-v1.json` decision" above for why it's mirrored at all), applying the
same etiquette with two substitutions Geofabrik's actual response forces:
an ETag-conditional GET stands in for regions' `.md5` cadence check
(Geofabrik publishes no digest for the index), and "the body parses as
JSON" stands in for the `.md5` match as the verify-before-publish gate.
`service/tests/test_geofabrik_pull.py` proves the etiquette above — for
both regions and the index — against a real (loopback) HTTP server and its
own request log, not against an internal "would have skipped" flag.

## Staleness monitor, cadence, and ownership (issue #260)

§11.3 names the cost the mirror takes on: "we become the availability." A cron that silently
stopped running looks identical to a working mirror until someone happens to SSH in and check —
the exact quiet-and-permanent failure mode the review's Q2 decision (adopted 2026-09-03) answers by
splitting cadence from monitoring:

- **Cadence is monthly, with one named owner** — **Greg Frazier** — and a release-checklist item
  that blocks a release on the bump, the same discipline `PROTOMAPS_BASEMAP_BUILD` already has. See
  `docs/Plotlines_Release_Checklist.md`.
- **The monitor is built regardless of cadence.** `MIRROR_STATE.json` already carries every
  timestamp it needs (`checked_at`, `pulled_at`, `last_failure`, `consecutive_failures` per region
  and for the index; `basemap.build_id`'s own leading date) — `core/plotlines_core/tiles/
  mirror_state.py`'s `mirror_health()` is a pure read over that state, and `GET /health`'s
  `capabilities.mirror` surfaces it on the sidecar's existing per-layer capability channel (story
  N4) rather than requiring anyone to open this file by hand. `--mirror-state-url` (a local path or
  the mirror's own served URL) points a sidecar at it; absent, `capabilities.mirror` reports
  `{"configured": false}` rather than a stale-looking reading for a source nobody named — this is
  the default today, since no sidecar is pointed at the mirror in production yet (#261).
  `core/tests/test_mirror_state.py` and `service/tests/test_health_mirror.py` cover the staleness
  math and the endpoint, including the case that matters most: a deliberately-stalled pull (a
  `checked_at` far past `MAX_PIN_AGE_DAYS`, the monthly cadence plus a grace window) reads as
  visibly stale rather than indistinguishable from a healthy mirror.

## The Provenance/Attribution pin format (finding L7)

A trip pins the OSM build it started on, and that pin belongs in the trip payload
(`trips/payload.py`'s `Provenance`/`Attribution`) — an exported cue sheet carrying "contains OSM
data, snapshot 2026-09-01" is a stronger notice than a bare credit, and without the pin, a trip
built from a stale mirror is indistinguishable from a fresh one. The payload *write* lands with the
extract path in Phase 3 (epic #264; #270/#277) — this issue only decides the *format*, so both ends
agree before that code exists: `core/plotlines_core/tiles/mirror_state.py`'s
`geofabrik_attribution_fields(state, region)` returns the four fields `Attribution(source, licence,
credit, url)` takes, with `credit` in the exact "contains OSM data, snapshot `<date>`" shape L7
names. It returns a plain `dict` rather than constructing `Attribution` itself, so `tiles` — a lower
layer — never has to import `trips`; Phase 3 calls
`Attribution(**geofabrik_attribution_fields(state, region))` directly.

## Bucket portability (Q6-C)

- Every path `build_tree.sh` creates is a plain nested directory — no
  symlink, no server-side rewrite. It maps 1:1 onto an object-storage key
  prefix (`basemap/protomaps/<build>/planet.pmtiles` is the same key
  whether served by Caddy's `file_server` or from R2/B2).
- `Cache-Control: public, max-age=31536000, immutable` is set by Caddy
  today; an object-storage bucket sets the equivalent metadata on the
  object itself at write time — either way, every served path is
  build-pinned and immutable, never mutated in place.
- Nothing here depends on a directory listing (Caddy's `file_server` serves
  named files; nothing lists `osm/geofabrik/` and expects a browsable
  index) or on any Caddy-specific rewrite/matcher beyond the two `header`
  directives, which have direct bucket-metadata equivalents.
