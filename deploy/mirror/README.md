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
scp -r deploy/mirror pi:/opt/plotlines-mirror
scp spikes/SPIKE-14/tiles/wnc-corridor.pmtiles pi:/opt/plotlines-mirror/wnc-corridor.pmtiles
ssh pi
cd /opt/plotlines-mirror
sudo ./build_tree.sh /srv/plotlines-mirror
sudo ./copy_basemap_standin.sh /srv/plotlines-mirror ./wnc-corridor.pmtiles
docker compose up -d
```

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

## The `index-v1.json` decision (finding L4)

The §6.3 tree diagram lists Geofabrik's `index-v1.json` conditionally —
"only if its own licence checks out." It doesn't, as of this issue: Geofabrik's
own technical documentation (`download.geofabrik.de/technical.html`) states
a site-wide footer copyright line ("Data/Maps Copyright ... Geofabrik GmbH
and OpenStreetMap Contributors ... ODbL 1.0") but nowhere grants terms for
redistributing the index file itself, distinct from the `.osm.pbf` extracts
it points at. That is exactly the "unclear" case L4 anticipates, and its
stated fallback is taken here: **`index-v1.json` is not mirrored.**
`build_tree.sh` never creates it, and `osm/COPYRIGHT.txt` says so. In its
place, `MIRROR_STATE.json` is Plotlines' own covering-set record — which
region/build-date pairs this mirror actually carries — populated from the
bboxes Plotlines has actually pulled rather than re-served from Geofabrik's
cartographic index. A definitive check of Geofabrik's terms (e.g. asking
them directly) is tracked separately under issue #259; this decision can be
revisited there without changing the tree layout, since the layout was
built to make `index-v1.json` optional rather than load-bearing.

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

It never touches `index-v1.json` — regions are named explicitly on the
command line rather than discovered from Geofabrik's own index, which
sidesteps needing that index at all while its licence is unverified
(#259). `service/tests/test_geofabrik_pull.py` proves the etiquette above
against a real (loopback) HTTP server and its own request log, not against
an internal "would have skipped" flag.

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
