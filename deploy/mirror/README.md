# Plotlines mirror — tree layout and Caddy front end

Issue #256 (Phase 1.2, epic #264): the §6.3/§6.4 production layout, the
licence artifacts §6.0/Q6 and addendum finding **1a** require, and the
bucket-portable paths §6.0/**Q6** requires. Read
`docs/Plotlines_OSM_Acquisition_Review.md` §6 and
`docs/Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md` findings
**L4**/**G3** before changing anything here.

Phase 1.1 (#255, the physical Pi 5 + NVMe host) and later Phase 1 steps
(#257 basemap stand-in, #258/#260 the Geofabrik pull client and
`MIRROR_STATE.json`'s real content, #261 pointing the sidecar at the
mirror) are separate issues. This directory is the part of #256 that is a
repo artifact: the tree scaffold, the Caddy config, and the licence
notices. Everything here is deployed to the Pi; nothing here is Python
application code.

## Deploying to the Pi

```
scp -r deploy/mirror pi:/opt/plotlines-mirror
ssh pi
cd /opt/plotlines-mirror
sudo ./build_tree.sh /srv/plotlines-mirror
docker compose up -d
```

`build_tree.sh` is idempotent — re-running it never overwrites
`MIRROR_STATE.json` once it exists (that file's real content is #258/#260's
job), and only ever (re)writes Plotlines' own static `COPYRIGHT.txt` files
and creates directories. Basemap and Geofabrik payload files themselves are
copied/pulled in by #257 and #258/#260 respectively — this script only
scaffolds the tree they land in.

## Verifying it

```
curl -I http://tiles.plotlines.app/basemap/protomaps/<build>/planet.pmtiles
curl -I http://tiles.plotlines.app/osm/geofabrik/<date>/<region>.osm.pbf
curl -H 'Range: bytes=0-99' -o /dev/null -w '%{http_code}\n' \
     http://tiles.plotlines.app/basemap/protomaps/<build>/planet.pmtiles   # expect 206
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
