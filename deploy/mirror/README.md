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
ssh pi 'sudo mkdir -p /opt/plotlines-mirror && sudo chown "$(id -un)":"$(id -gn)" /opt/plotlines-mirror'
scp -r deploy/mirror/. pi:/opt/plotlines-mirror/
scp spikes/SPIKE-14/tiles/wnc-corridor.pmtiles pi:/opt/plotlines-mirror/wnc-corridor.pmtiles
ssh pi
cd /opt/plotlines-mirror
sudo ./build_tree.sh /srv/plotlines-mirror
sudo ./copy_basemap_standin.sh /srv/plotlines-mirror ./wnc-corridor.pmtiles
docker compose up -d
```

The `mkdir`/`chown` first and the trailing `/.` on the source both
matter, for two independent reasons:

- **Modern OpenSSH `scp`** (the SFTP-based implementation, default since
  ~9.0 and what current Raspberry Pi OS/Debian ship) `stat`s the
  destination before a recursive copy and, unlike the old SCP-protocol
  `scp`, does **not** auto-create a nonexistent top-level destination — a
  bare `scp -r deploy/mirror pi:/opt/plotlines-mirror` against a Pi that
  has never had that directory fails with `scp: stat remote: No such
  file or directory` before anything is copied. Creating the directory
  first and copying `deploy/mirror`'s *contents* into it (`/.` on the
  source, trailing `/` on the destination) avoids the stat entirely and
  also avoids nesting a `mirror/` subdirectory inside
  `/opt/plotlines-mirror` the way a bare
  `scp -r deploy/mirror pi:/opt/plotlines-mirror` would if the
  destination already existed.
- **`/opt` is root-owned** on a stock Debian/Raspberry Pi OS install
  (typically `root:root`, mode `755`), so a non-root user can't create
  anything under it — `mkdir -p /opt/plotlines-mirror` as an ordinary
  login user fails with `Permission denied` before `scp` even runs, and
  every subsequent file upload fails the same way. The `sudo mkdir` +
  `sudo chown` hands the freshly-created directory to your login user so
  the plain (non-root) `scp` that follows can write into it. This
  doesn't weaken anything later: `build_tree.sh` and
  `copy_basemap_standin.sh` still run under `sudo` explicitly for the
  part that actually needs root — writing under `/srv/plotlines-mirror`.

If you'd rather keep the original one-line form (skipping the
`mkdir`/`chown` step), forcing the legacy protocol works too —
`scp -O -r deploy/mirror pi:/opt/plotlines-mirror` — but it still needs
`/opt/plotlines-mirror` to be writable by whoever is running it (so
either run it as root, or `sudo chown` the directory first as above),
and it needs `scp` on the Pi's end as well, which is standard on
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

## The mirror-side bbox clip (issue #262, §6.7)

Q1-C: the client never resolves a covering set or sees a region extract —
it sends a trip bbox and gets back one clipped `.osm.pbf`. That's the one
dynamic endpoint the mirror grows, `POST`/`GET /clip`, implemented in
`service/plotlines_service/mirror_clip.py` and proxied to from the
Caddyfile's `reverse_proxy /clip*` (before its `file_server` catch-all —
`service/tests/test_mirror_clip_deploy_config.py` pins the ordering).

**Why it isn't in `deploy/mirror/` alongside `geofabrik_pull.py`.** That
script is stdlib-only so it deploys as a standalone file with no `pip
install`. The clip needs `pyosmium` — a C++ extension — so it's built as a
proper container from the full repo instead, the same pattern
`service/Dockerfile.elevation-proxy` already established for a different
native dependency (rasterio/GDAL):

```
docker build -f service/Dockerfile.mirror-clip -t plotlines-mirror-clip:latest .
docker save plotlines-mirror-clip:latest | ssh pi docker load
```

(or clone the full repo onto the Pi and build there directly). Then
`docker compose up -d` from this directory starts both `caddy` and
`mirror-clip` — see `docker-compose.yml`. `mirror-clip` publishes no host
port; only Caddy's `reverse_proxy` reaches it, over compose's own default
network (service-name DNS resolves `mirror-clip` — no extra `networks:`
block needed).

**No GPL-licensed binary anywhere in this path (addendum L1).** The clip
goes through pyosmium's Python API only (`osmium.SimpleHandler`,
`osmium.BackReferenceWriter`, `osmium.MergeInputReader`) — never the
`osmium` CLI (`osmium-tool` is GPL-3.0; pyosmium/libosmium are
BSD-2-Clause). `osmium` is declared as the `mirror-clip` **extra** in
`service/pyproject.toml`, not a base dependency of `plotlines-service` —
kept out of `packaging/build_sidecar.sh`'s frozen client binary, since
SPIKE-J (#266) hasn't yet measured whether pyosmium survives a PyInstaller
freeze on all four client targets. Reintroducing that dependency into every
desktop/mobile build ahead of that measurement would undo exactly what
Q1-C's "no client-side native clip dependency" was for.

**What it implements.** One completeness strategy — the pyosmium-native
equivalent of osmium-tool's `complete_ways`: any way with at least one node
in the requested bbox is written whole (not severed at the boundary, per
§11.7), completed via `osmium.BackReferenceWriter`; a relation is kept when
it references an included way or node. `simple` (truncate at the boundary)
and `smart` (multipolygon repair, nested-relation completion) are not
implemented — SPIKE-I (#265) is where that trade-off gets evidence rather
than a guess. The bbox-spans-two-extracts case (Buncombe County is ~30 km
from Tennessee) merges the covering extracts with `osmium.MergeInputReader`
first, deduplicating a border way that's present, whole, in both regional
cuts, before clipping.

**Coverage resolution reads only what's on disk.** `mirror_clip.py` never
consults the mirrored `index-v1.json` — that's Phase 3's job
(§8: "resolve trip bbox → covering set of extracts, from the mirrored
`index-v1.json`"), not this endpoint's. Instead it reads each pinned
extract's own PBF header box (real Geofabrik extracts always declare one)
and keeps any extract whose declared coverage might overlap the request —
treating a missing header box as *unknown, so kept* rather than excluded. A
bbox that matches no pinned extract's coverage, or matches one but selects
zero real features from it, is `NoMirrorCoverage` — a 404 with a
`{"error": "no_mirror_coverage", "message": "..."}` body, never a stack
trace (acceptance criterion 5).

**What's recorded, not yet what SPIKE-I measures.** Every successful clip
logs, and returns as response headers, wall time, output size, peak RSS
(`resource.getrusage(...).ru_maxrss` — process-lifetime, not perfectly
request-isolated; a controlled per-request measurement is SPIKE-I's job,
not this rehearsal's), and which region(s) it drew from. This satisfies
"the numbers Q1-C and Q6 both rest on" for a first look; SPIKE-I (#265,
still filed, not run) is where those numbers get pre-registered parity
bands and a real trip bbox against the actual pulled extracts, not a
synthetic fixture.

**The licence notice travels with the clip (issue #364).** `COPYRIGHT.txt`
puts the obligation on "the distribution channel, not the presence of a file
on disk", and `/clip` is a second channel — Caddy's `reverse_proxy /clip*`
matcher terminates the request before `file_server` runs, so a caller here
never reads that file. A clip is an *extraction*, so its output is a
**Derivative** Database under ODbL §4.3 rather than a Produced Work. Every
`/clip` 200 therefore carries its own notice:

```
X-Plotlines-Data-Licence:     ODbL-1.0
X-Plotlines-Data-Attribution: (c) OpenStreetMap contributors
X-Plotlines-Data-Terms:       https://www.openstreetmap.org/copyright
Link:                         <https://opendatacommons.org/licenses/odbl/1-0/>; rel="license"
```

`GET /health` on the clip service reports the same four facts as JSON. The
header credit is ASCII (`(c)`, not `©`) on purpose: Starlette emits header
values as latin-1, so the typographic glyph goes out as a byte that isn't
valid UTF-8 and breaks a client decoding headers before it ever reaches the
body. `/health`'s JSON and the `COPYRIGHT.txt` files carry the typographic
form; `test_mirror_clip_licence_notice.py` pins the two together and asserts
every header value stays ASCII.

`service/tests/test_mirror_clip.py` and `test_mirror_clip_server.py` cover
the clip logic and the HTTP contract hermetically, against tiny synthetic
`.osm.pbf` fixtures (`service/tests/mirror_clip_fixtures.py`) — including
the two-extract merge/dedup case and both coverage-miss paths. What they
cannot cover from this sandbox, the same way §6.5's DNS-override step
can't: an actual Caddy container proxying to an actual `mirror-clip`
container over the real Pi's Docker network, against the real pulled NC
extract. That's a live-Pi rehearsal, not a hermetic test's job.

## Reachability: open or client-restricted (issue #263, §6.8/1d)

Decided split. The mirror's plain static files (region extracts, the
basemap archive, the `COPYRIGHT.txt` notices) stay open — unchanged, no
config needed, that's what `file_server` in the Caddyfile already does.
`/clip` is the one endpoint that also spends CPU per request, so it alone
is restricted, by two independent mechanisms in `mirror_clip.py`:

- **A shared client key.** Set `MIRROR_CLIP_CLIENT_KEY` in the shell before
  `docker compose up` and every `/clip` request must carry it in the
  `X-Plotlines-Client-Key` header, or get an honest `401
  unauthorized_client`. This is deliberately not an account system — the
  key identifies "a Plotlines-built client," never a person, and there is
  no signup or per-key state. Left unset, `/clip` is open — the correct
  default for this local/dev rehearsal.
- **A per-client-IP rate ceiling**, `MIRROR_CLIP_RATE_LIMIT_PER_MINUTE`
  (default 30), enforced on `/clip` either way, since the CPU cost does not
  depend on whether a key is configured. In-memory, single-process, past
  it a caller gets an honest `429 rate_limited`.

Both are `mirror_clip.py` CLI flags (`--client-key`,
`--rate-limit-per-minute`) wired through `docker-compose.yml`'s
`mirror-clip.environment` block. See the module's own docstring and
`docs/Plotlines_OSM_Acquisition_Review.md` §6.8 for the full reasoning.
`service/tests/test_mirror_clip_server.py` covers both mechanisms
hermetically; setting a real key on the live Pi is an operator step, not
something a hermetic test can exercise.

## Live clip rehearsal — taking the Q1-C numbers (epic #264)

Everything above is hermetic or single-file. This is the operator step that
closes epic #264's second definition-of-done bullet:

> A trip bbox clipped server-side to an `.osm.pbf`, with wall time, output
> size and peak RSS recorded — the numbers Q1-C and Q6 both rest on.

The endpoint emits those three on every clip (headers and log, see above),
but until this runbook has been executed they have only ever been emitted
against tiny synthetic fixtures. **The mechanism existing is not the same
as the numbers existing**, and Q1-C — mirror-side clip over client-side
extract — is a cost argument that currently has no measured cost on either
side of it.

Same constraint as §6.5's DNS step: this needs LAN access to the Pi and
cannot be done from a coding-agent sandbox.

### 1. Pull real region extracts

The tree carries only the basemap stand-in until this runs.
`discover_region_extracts` resolves from `MIRROR_STATE.json`'s
`geofabrik.pinned_date` + `regions`, so before a pull **every clip 404s as
`no_mirror_coverage`** — which reads like a broken endpoint rather than an
empty tree. See "Geofabrik pull client (issue #258)" below for the client's
own conditional/backoff behaviour.

```
ssh pi
cd /opt/plotlines-mirror
python3 geofabrik_pull.py --root /srv/plotlines-mirror \
  --region north-america/us/north-carolina \
  --region north-america/us/tennessee \
  --pinned-date "$(date -u +%F)" -v
```

**Two regions on purpose.** North Carolina alone measures the ordinary
case; NC + TN is §11.7's border case, where a bbox spans two extracts and
`MergeInputReader` has to id-dedup a border way present whole in both
regional cuts. That merge is the expensive path, and it is the one Q1-C's
cost claim actually rests on — a single-extract number alone would
understate the endpoint. Expect a few hundred MB per region.

Verify the pull landed before going further:

```
python3 -c 'import json; g=json.load(open("/srv/plotlines-mirror/MIRROR_STATE.json"))["geofabrik"]; print("pinned_date:", g["pinned_date"]); print("regions:", sorted(g["regions"]))'
```

`python3`, not `jq`, throughout this section — `jq` is not installed on a
stock Raspberry Pi OS image and is not a dependency of anything else here,
which is the same reason `copy_basemap_standin.sh` shells out to `python3`
to merge its one JSON key.

Before any pull this prints `pinned_date: None` and `regions: []`; that is
the state in which every clip correctly 404s.

### 2. Build and start the clip container

`docker-compose.yml` names `plotlines-mirror-clip:latest`, which is this
repo's own image rather than a registry pull, and needs both `core/` and
`service/` as build context:

**The Pi 5 is `aarch64` and the dev box is `x86_64`, so where you build
matters.** A plain `docker build` on the dev box produces an amd64 image;
`docker load`ing it on the Pi appears to succeed and then fails at run time
with `exec format error`. Two ways round that, and the first is the one to
reach for:

```
# Simplest — build natively on the Pi. Needs the full repo (core/ + service/),
# not just this directory.
ssh pi
git clone https://github.com/gnfrazier/plotlines.git ~/plotlines   # or pull, if already there
cd ~/plotlines
docker build -f service/Dockerfile.mirror-clip -t plotlines-mirror-clip:latest .
```

```
# Or cross-build from the dev box, if you'd rather not compile on the Pi.
# One-time setup: the default `docker` driver refuses --platform with
# "Multi-platform build is not supported for the docker driver."
docker buildx create --use
docker run --privileged --rm tonistiigi/binfmt --install arm64

# Kept on one line on purpose: pasted a line at a time, a `\`-continued
# form loses the trailing `.` and buildx fails with the unhelpful
# "docker buildx build requires 1 argument". Run it from the repo root —
# `.` is the build context and must contain both core/ and service/.
docker buildx build --platform linux/arm64 -f service/Dockerfile.mirror-clip -t plotlines-mirror-clip:latest --load .

docker save plotlines-mirror-clip:latest | ssh pi docker load
```

The native build is slower but has no qemu in the loop, which matters here
for a second reason: this image exists to be *timed*. Keep the thing under
measurement as close to its production shape as possible — and note the
cross-build's one-time buildx/binfmt setup above is most of the reason the
native route is listed first.

**Before starting it, make sure the deploy itself is current.**
`/opt/plotlines-mirror`
is a copy of this directory taken at deploy time, so a Pi provisioned
before #262 has a `docker-compose.yml` with no `mirror-clip` service and a
`Caddyfile` with no `/clip*` route. The symptom is quiet rather than loud —
`docker compose up -d` reports `up 1/1` and `ps` lists only caddy, because
compose is not failing to find the image, it does not know the service
exists:

```
cd /opt/plotlines-mirror
grep -c mirror-clip docker-compose.yml   # 0 means the deploy predates #262
grep -c clip Caddyfile                   # ditto

# refresh from the repo checkout on the Pi (or scp -r from the dev box)
cd ~/plotlines && git pull
cp -r deploy/mirror/. /opt/plotlines-mirror/
cd /opt/plotlines-mirror && sudo ./build_tree.sh /srv/plotlines-mirror
```

Re-running `build_tree.sh` is safe with data in place — it only creates
directories and rewrites the two `COPYRIGHT.txt` files, and skips
`MIRROR_STATE.json` when it exists — and it is what refreshes the served
notice to the post-#364 text.

Then start it and check:

```
cd /opt/plotlines-mirror
sudo docker compose up -d
sudo docker compose restart caddy   # bind-mounted Caddyfile: `up -d` won't reload it
sudo docker compose ps
sudo docker compose exec mirror-clip \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8095/health').read().decode())"
```

**Check health from inside the container**, as above. `mirror-clip`
publishes no host port on purpose (only Caddy reaches it, over the compose
network) and Caddy proxies only `/clip*`, so `/health` is not reachable
from the Pi's own shell by either route — `curl localhost:8095/health`
fails identically whether the service is healthy or dead, which makes it
worse than useless as a check.

`/health` must list both regions under `pinned_extracts`, plus the
`licence` block (#364). If `caddy` is up and `mirror-clip` is missing or
`Restarting`, `docker compose logs mirror-clip` distinguishes the cases: no
such service (stale compose file, above), `exec format error` (architecture
mismatch, above), or an `ImportError` on a shared library (#369 — the
pyosmium wheel links `libexpat.so.1` from the system, which
`python:3.12-slim` does not ship; fixed in the Dockerfile, but an image
built before that fix will crash-loop until rebuilt).

### 3. Measure

**The one thing that will silently corrupt the numbers:** `peak_rss_kb` is
`getrusage(RUSAGE_SELF).ru_maxrss` — a **process-lifetime high-water
mark**, not a per-request figure. Every run after the first reports the
largest clip that container has *ever* served, so a series taken without
restarting reads as monotonically increasing memory that has nothing to do
with the bbox being measured. Restart between runs:

Run this **on the Pi** — it is where the container, the extracts and the
`sudo` already are, and it keeps the network out of a wall-time figure that
is supposed to be measuring a clip:

```
clip () {  # $1=label  $2=west $3=south $4=east $5=north
  ( cd /opt/plotlines-mirror && sudo docker compose restart mirror-clip ) >/dev/null
  sleep 3
  curl -s -D "/tmp/$1.hdr" -o "/tmp/$1.osm.pbf" \
    -H 'Host: tiles.plotlines.app' \
    "http://127.0.0.1/clip?west=$2&south=$3&east=$4&north=$5"
  grep -i '^x-plotlines-\|^link:' "/tmp/$1.hdr"
  ls -l "/tmp/$1.osm.pbf"
}
```

Paste the whole function in one go — a shell function pasted line by line
leaves the shell at a `>` continuation prompt.

From the dev box instead, swap `127.0.0.1` for the Pi's LAN address and the
restart line for `ssh pi 'cd /opt/plotlines-mirror && sudo docker compose
restart mirror-clip'`. Then say so when reporting the numbers: the wall
time is still server-side (the header is measured inside the handler), but
the download is not, so a large clip's apparent duration will include the
LAN transfer.

Pass `Host` explicitly either way. Caddy's site block is host-matched
(`http://tiles.plotlines.app { ... }`), so any other Host header silently
returns `200` with `Content-Length: 0` rather than erroring — the same trap
§6.5's rehearsal documents.

Suggested bboxes, as starting points rather than fixed values — substitute
a trip you would actually plan:

| Case | bbox (W,S,E,N) | What it exercises |
|---|---|---|
| Single extract | `-82.75,35.35,-82.35,35.70` | Asheville–Pisgah; the ordinary case |
| Border, two extracts | `-83.10,35.65,-82.70,36.00` | Crosses the NC/TN line — merge + dedup |
| Coverage miss | `-90.0,41.0,-89.6,41.3` | Must 404 `no_mirror_coverage`, never 500 |

Run each **three times**, restarting between, and report a range rather
than one sample. A23's finding on the osmnx path was that ×21 run-to-run
variance was the result, not the mean — a single clip timing would repeat
that mistake in the other direction.

While here, confirm #364's notice headers survive the proxy hop:
`x-plotlines-data-licence`, `-attribution`, `-terms`, and `link`. That is
the live check #364 deferred.

### 4. Where the numbers go

- **Epic #264** — primary. This is the DoD bullet holding the epic open, so
  that comment is the evidence it closes against. Include per-run wall
  time / output bytes / peak RSS / source regions, the pinned date and
  region list, and the Pi's hardware and storage context (the numbers mean
  nothing without the box they were taken on).
- **#265 (SPIKE-I)** — a pointer. SPIKE-I's item 3 is clip time and
  strategy on a realistic bbox, and its parity bands are meant to be
  *pre-registered*. These numbers are what the bands get registered
  against, so they need to exist before that spike is designed.
- **#262** — one line. Its close-out says "not tested live against the
  physical Pi"; a "rehearsed live, numbers on #264" closes that loop for
  anyone reading the story later.

Do **not** open `spikes/SPIKE-I/results/RESULTS.md` for these. This is a
first recording under uncontrolled conditions; filing it as the spike's
results would make it look like the pre-registered measurement it exists to
precede.

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
