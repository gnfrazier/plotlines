# Plotlines Pi5 QA/UAT elevation proxy — issue #450

Companion to epic #264 (shares the Pi5 hardware — see `deploy/mirror/README.md`
for that side) and to **#304**, which built and merged the whole QA-scoped
elevation shape — `service/plotlines_service/elevation_proxy.py`,
`core/plotlines_core/elevation/qa_proxy_client.py`, the `--elevation-upstream`
sidecar flag, `service/Dockerfile.elevation-proxy` — but never its
deployment. This directory is that deployment: the Caddy front end, the
compose service, the licence-blank `.env` template, and the cache pre-warm
script. **Not** issue #148/FR87's production Phase 2 elevation build (ARCH
§12.1's "device → hosted cache → provider" shape, built for real, not QA
scale, elsewhere).

**The API key must never reach this repository.** It is supplied at
`docker compose up` time from a git-ignored `.env` in this directory — the
same discipline `service/.env.example` and `deploy/mirror/`'s
`MIRROR_CLIP_CLIENT_KEY` already use elsewhere in this repo. No QA/dev
tester machine ever sets `PLOTLINES_OPENTOPOGRAPHY_API_KEY` — only the Pi
holds it, which is the entire reason this proxy exists (see #304's own "Why"
section).

## Deploying to the Pi

This needs the full repo checked out on the Pi — the image build needs both
`core/` and `service/` as build context, the same reason
`deploy/mirror/README.md`'s `mirror-clip` service does:

```
ssh pi
git clone https://github.com/gnfrazier/plotlines.git ~/plotlines   # or pull, if already there
cd ~/plotlines
```

**Build the image natively on the Pi.** The Pi 5 is `aarch64`; a plain
`docker build` on an amd64 dev box produces an image that `docker load`s
successfully and then fails at run time with `exec format error` — the exact
trap `deploy/mirror/README.md`'s mirror-clip build documents. Building on
the Pi directly sidesteps it with no qemu/buildx setup:

```
docker build -f service/Dockerfile.elevation-proxy -t plotlines-elevation-proxy:latest .
```

(A cross-build from an amd64 dev box works too — see `deploy/mirror/README.md`
"Build and start the clip container" for the one-time `buildx`/`binfmt`
setup and the `docker save | ssh pi docker load` handoff — but native is the
one to reach for first, same reasoning as the mirror-clip image.)

**Configure the key**, once, from wherever this directory ends up on the Pi
(e.g. `~/plotlines/deploy/elevation`, or copied out to its own directory the
way `deploy/mirror/` is copied to `/opt/plotlines-mirror` — either is fine,
nothing here depends on a specific path the way the mirror's static tree
does):

```
cp .env.example .env
$EDITOR .env   # fill in PLOTLINES_OPENTOPOGRAPHY_API_KEY; leave KEY_TIER
               # blank unless this Pi holds a paid Enterprise key
```

**Start it:**

```
docker compose up -d
docker compose ps
```

If `.env` is missing or the key is blank, `docker compose up` refuses
immediately with the message named in `docker-compose.yml`'s
`${PLOTLINES_OPENTOPOGRAPHY_API_KEY:?...}` — before any container starts.
If the key is present but the elevation-proxy container still won't come up,
`docker compose logs elevation-proxy` distinguishes an unset key
(`MissingApiKey`, shouldn't reach this point given the compose-level check
above) from an unrecognised `PLOTLINES_OPENTOPOGRAPHY_KEY_TIER` (a hard
error by design — `core/plotlines_core/elevation/keys.py`'s `from_env`
refuses to default an unknown tier to the free one, since that would
silently claim non-commercial use).

## Verifying it

```
curl -s http://127.0.0.1:8090/health | python3 -m json.tool
```

Expect `{"ready": true, "remaining_calls_24h": 50, "next_free_at": null}`
(minus whatever this session has already spent). From a LAN machine, swap
`127.0.0.1` for the Pi's LAN address.

A real DEM fetch, to confirm the whole path end to end (bbox inside the
mirror's WNC corridor, so it also exercises a region this Pi is already
provisioned for):

```
curl -s -D - -o /tmp/test.tif \
  'http://127.0.0.1:8090/dem?west=-82.6&south=35.55&east=-82.5&north=35.62'
file /tmp/test.tif   # expect: TIFF image data
```

Run the same `curl` a second time — it should return near-instantly from
the on-disk cache rather than making another OpenTopography call (confirm
via `/health`'s `remaining_calls_24h`, which should be unchanged between the
two runs).

**Confirm ceiling exhaustion still degrades cleanly against the real
instance** (the acceptance criterion #304's tests already cover
hermetically — this is the live check). Do this deliberately and sparingly;
it spends real free-tier calls. Request enough distinct, previously-uncached
bboxes to exhaust the 50/24h ceiling, then confirm the next request returns
`503` with a `Retry-After` header and a `free_tier_exhausted` body, never a
crash or a hang:

```
curl -s -D - -o /dev/null \
  'http://127.0.0.1:8090/dem?west=<unused-bbox>'
```

## Rotating the key

If the key is ever exposed (committed by accident, leaked from a log,
compromised on the Pi):

1. Revoke it in OpenTopography's own account console and issue a new one —
   the account holder's step, outside this repo.
2. `$EDITOR deploy/elevation/.env` (or wherever it lives on the Pi) with the
   new value.
3. `docker compose up -d` — compose picks up the changed `.env` on the next
   `up`; `docker compose restart elevation-proxy` alone does **not** reread
   `.env`, since the old value was already baked into the running
   container's environment.
4. Grep this repo and its history for the old key value as a sanity check —
   it should never appear, since it was never a literal here to begin with.

Nothing else needs to change: QA/dev sidecars talk to this proxy, never to
OpenTopography directly, so a key rotation is invisible to every tester
machine.

## Pre-warming the cache

`prewarm_cache.py` is a standalone stdlib script (same deployment simplicity
as `deploy/mirror/geofabrik_pull.py` — no `pip install` needed, copy it
anywhere with network access to the proxy and run it):

```
python3 prewarm_cache.py --base-url http://127.0.0.1:8090/dem -- \
    -82.75,35.35,-82.35,35.70 \
    -83.10,35.65,-82.70,36.00
```

The `--` before the bbox list is required — every real bbox here has a
negative `west`, and without it argparse reads the first one as an
attempted option flag rather than a positional value.

Run it **before the QA/UAT testing window opens**, with the QA test plan's
own known trip bboxes (`west,south,east,north`, the same order
`plotlines_core.elevation.interface.BBox` and the proxy's `/dem` endpoint
use) — the two above are starting points, not a fixed list this script
ships with; substitute the trips the test plan actually names. Run it twice
in a row and compare timings: the first pass pays real OpenTopography fetch
time per bbox, the second should return near-instantly for every bbox that
succeeded, which is the same "cache absorbs a repeat" behaviour
`service/tests/test_elevation_proxy.py` already asserts hermetically —
this just takes it against the real deployed instance with real bboxes.

A failed bbox (free-tier exhaustion mid-run, a transient upstream error)
does not stop the rest of the list — the script reports failures to stderr
and exits non-zero at the end, so a CI-style caller can still tell success
from partial failure, but a slow network blip on bbox 3 of 12 doesn't lose
the other 11.

## Pointing QA/dev sidecars at it

Set `PLOTLINES_ELEVATION_UPSTREAM` to this proxy's `/dem` URL, alongside the
existing `PLOTLINES_MIRROR_URL` instructions (`client/README.md`'s upstream
table) — for example:

```
PLOTLINES_ELEVATION_UPSTREAM=http://<pi-LAN-address>:8090/dem \
PLOTLINES_MIRROR_URL=http://tiles.plotlines.app \
flutter run -d linux
```

**No tester machine ever sets `PLOTLINES_OPENTOPOGRAPHY_API_KEY`.** Only
this proxy holds it; a sidecar started with `--elevation-upstream` uses
`core/plotlines_core/elevation/qa_proxy_client.py`'s unauthenticated
fetcher instead of `OpenTopographyClient`, and carries no key on the wire at
all (`core/tests/test_elevation_qa_proxy_client.py` asserts exactly that).
Unset, as today, elevation stays `elevation_source_not_configured` — safe,
just uninformative; nothing breaks by leaving a sidecar unpointed at this
proxy.

## Why this isn't folded into `deploy/mirror/`

Same Pi, same hardware, deliberately separate Caddy instance, separate
compose stack, separate port, no shared config file. #304's own "Done when"
named this explicitly: "separate hostname from the OSM mirror — the
ToS/key-revocation risk profile differs from the mirror's ODbL
redistribution risk, so it shouldn't inherit whatever #263 decides about the
mirror's reachability." Concretely: the mirror's `/clip` endpoint is
client-key-gated *and* rate-limited but otherwise open to any caller that
holds the shared key (§263 — "not accounts, no per-user state"); this proxy
holds a single real third-party credential whose ToS caps total daily use
across every caller, so a reachability decision made for one must never
silently apply to the other. Folding them into one Caddy config would make
that coupling implicit instead of impossible.

## Deleting it

Safe to tear down entirely once the QA/UAT window closes or #148 lands with
its own production implementation (#304's own scoping, restated in #450):

```
docker compose down -v   # -v also drops the elevation_cache volume
```

No app code depends on this proxy existing — an unpointed sidecar (no
`--elevation-upstream`) behaves exactly as it does today.
