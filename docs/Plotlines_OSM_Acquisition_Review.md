# OSM Data Acquisition — Review and Plan

**Date:** 2026-09-02, revised 2026-09-03 · **Branch at review:** `fix/232-overpass-status-failover`
**Scope:** how Plotlines acquires OSM data for the routing graph, curation candidates, and geocoding
**Status:** **accepted 2026-09-03; fully filed 2026-09-03.** Phase 0 is #241–#253 + #269 under epic **#254**;
Phase 1 is #255–#263 + #270 under epic **#264**; Phase 2 is #265–#267 under epic **#268**; Phase 3 is
#273–#278 under epic **#272**; Phase 4 is #280–#282 under epic **#279**; Phase 5 is #284–#287 under
epic **#283**. Every numbered checklist item in §13 now has an issue behind it. The six §12 open questions
are **answered** — see §12; the answers change §6, and those changes are folded in below rather than left
as an appendix.
**Executed:** Phase 0 closed 2026-09-04 (#254, all fourteen mitigations); Phase 1 closed 2026-09-13
(#264, the mirror, its `/clip` endpoint, the live rehearsal runbook); Phase 2 closed 2026-09-16 (#268,
SPIKE-I/SPIKE-J, the software-notice bundle); Phase 3 closed 2026-09-17 (#272, the transport swap
itself — #273–#278 — and reachable from the app since #434); the acquisition decision is recorded as
ARCH **D63** (#287, 2026-09-17), which also closes out ARCH **A23**/**A23a** and Punchlist **2A.3**.
**Open:** Phase 4 (#279, hosted) and the rest of Phase 5 (#283 — #284, #285, #286; §10's policy gate and
give-back are not yet built, though two of its three test gates shipped early as #251).
**Open issues in view:** [#238](https://github.com/gnfrazier/plotlines/issues/238), [#239](https://github.com/gnfrazier/plotlines/issues/239), [#240](https://github.com/gnfrazier/plotlines/issues/240), [#154](https://github.com/gnfrazier/plotlines/issues/154), [#144](https://github.com/gnfrazier/plotlines/issues/144)
**Documents in view:** ARCH **A23** / **A23a** / §8.3 / §11 / §12, PRD **FR1** / **FR92** / **FR94** / **FR95** / **FR120** / **FR121**, Punchlist **2A.3**

---

## Summary

There is a better way, and the architecture already contains it — applied to the wrong data.

For basemap tiles, Plotlines made a deliberate decision and made it *mechanical*: **mirror the
source, extract per-bbox, never hotlink a third party.** `core/plotlines_core/tiles/mirror.py`
pins a build (`PROTOMAPS_BASEMAP_BUILD = "20250101"`), names Plotlines-controlled storage, and
raises `HotlinkRefused` if anyone points the extractor at a third-party host. FR92/FR95 back it.

For *the same underlying data* — OSM — routing, curation and geocoding do exactly what that policy
forbids: hotlink volunteer-operated public hosts, with a full multi-thousand-km² query per trip
bbox, under a `User-Agent` that names someone else's library. #238's measurements (22 build
attempts / 44 Overpass requests in 40 minutes, boxes from 21×23 km to 56×74 km) are the load
profile that earns an IP-level block, which is what the dev machine got.

**The decision proposed here:** move bulk OSM acquisition to mirrored Geofabrik extracts clipped
per-bbox; keep only small, interactive, user-initiated Overpass use; and make the policy mechanical
so it cannot erode. Sequenced so the load stops *this week*, before any of the migration lands.

---

# Part I — The case

## 1. The requirement is not the constraint

**FR1** (`docs/Plotlines_PRD_v2.md:417`) reads:

> The routing engine generates routes on an OSMnx graph via the FastAPI backend on Desktop and Web.

That pins the graph *representation and library*. It says nothing about acquisition. **The string
"Overpass" appears zero times in the PRD.** Overpass is an inherited implementation detail of
`ox.graph_from_bbox` — never a decision anyone made, and nothing in the requirement set stops it
being replaced.

So #238, #239 and #240 are three fixes to latency and politeness management on a transport that
should not be in the hot path at all. Each is correct in isolation; together they absorb variance
rather than removing it.

The risk register already says this. ARCH **A23** (rated HIGH after SPIKE-D) closes with:

> Local extracts for repeatedly-used regions (§12) remain the only mitigation that removes the
> variance rather than absorbing it — **still unmeasured.**

Punchlist **2A.3** repeats it verbatim. That sentence has stood since 2026-08-28 with no issue
behind it.

## 2. What the code does today

Three independent consumers, all live-network, none mirrored:

| Consumer | Call site | Upstream |
|---|---|---|
| Routing graph | `graph/regions.py` → `ox.graph_from_bbox` | public Overpass, 2 endpoints, retry + failover |
| Curation candidates | `curation/providers.py` → `ox.features_from_bbox` | public Overpass, single `ox.settings.overpass_url`, no failover |
| Geocoding | `service/…/app.py:1385` `/geocode` → `ox.geocode_to_gdf` | public **Nominatim** |

The graph path has had real hardening (#229 endpoint list, #232 `ResponseStatusCodeError` in
`TRANSIENT_OVERPASS_ERRORS`, `dedupe_endpoints`). The candidate path has none of it. The geocoding
path has not been considered at all, and Nominatim carries its own usage policy.

Confirmed against the installed **osmnx 2.1.1**:

```
http_user_agent      = 'OSMnx Python package (https://github.com/gboeing/osmnx)'
http_referer         = 'OSMnx Python package (https://github.com/gboeing/osmnx)'
requests_timeout     = 180
overpass_rate_limit  = True          # but see §3.4 — we disable it on failover
cache_folder         = './cache'     # CWD-relative; see §3.2
max_query_area_size  = 2_500_000_000 # 2,500 km² — osmnx auto-splits above this
```

## 3. Findings not currently filed

### 3.1 A23's *first* mitigation is not built for candidates

`CacheLayout.candidate_set()` (`core/plotlines_core/cache_layout.py:125-130`) reserves the on-disk
slot and **nothing reads or writes it.** The only candidate cache is `SharedOsmFetch._cache`
(`curation/providers.py`), an in-process dict. It dies on every sidecar restart — and M12's
health-poll watchdog restarts the sidecar precisely when a heavy build saturates it.

A23 measured warm re-read at **1.75 s against 15.8 s cold**, and called it *"the only measurement
with no run-to-run variance."* Cheapest available win; no new dependency.

### 3.2 osmnx's own response cache is misconfigured on the candidate path

`configure_overpass_cache()` is called only inside `ensure_graph`, and only *past* the warm-cache
early return:

```
core/plotlines_core/graph/regions.py:371    if out_path.exists() and not force:  ->  return
core/plotlines_core/graph/regions.py:376    configure_overpass_cache(cache_dir)
```

So `/candidates` and `/geocode` run with `ox.settings.cache_folder` at its CWD-relative `./cache`
default. Observed in the working tree at review time — untracked, outside the cache root:

```
service/cache/5e6329101d85...json   722 KB   2026-09-02 08:40
service/cache/549fdfc38422...json   243 B    2026-09-02 08:41   -> {"elements": []}
```

The second file is **#239's empty response**, cached where nothing will ever look for it again.
#154's "stray responses land in `cache/` and `client/cache/`" complaint is still true, on the paths
nobody checked.

### 3.3 #238's mechanism is mis-stated, and the fix depends on getting it right

#238 reads *"every bbox drag commits a full-area query."* The map does not behave that way:
`client/lib/presentation/map/trip_area_map.dart` proposes only on pointer-**up**
(`_onPointerUp:154`, `_onCornerPointerUp:190`). Nothing fires mid-drag.

The 5-in-30s burst is five *completed* gestures, each accepted into `tripBboxProvider`, each
recomputing `tripRegionKeyProvider` (`client/lib/state/trip_bbox_provider.dart:58-63`), which POSTs
`/regions` immediately.

**Debouncing pointer events would fix nothing.** The settle window belongs on the accepted-bbox →
`ensureRegion` edge.

### 3.4 We identify ourselves as somebody else

`tiles/extract.py:59` sets `User-Agent: plotlines-sidecar/1` on every tile range request. **No
Overpass or Nominatim call sets one.** They inherit osmnx's default (§2), so every request Plotlines
makes to donated infrastructure is attributed to the OSMnx library, and an operator investigating
the load is pointed at an unrelated maintainer's GitHub repository. Their only remaining lever is to
block the IP — which is what happened in #232.

Politeness is mechanical on the tile path and entirely absent on the OSM path.

## 4. Licence versus usage policy — two separate obligations

Worth separating, because only one of them is currently satisfied.

**Licence (ODbL) — satisfied.** `OSM_LICENCE` in `curation/providers.py` declares
`ODbL-1.0` / `© OpenStreetMap contributors` / the OSM copyright URL, `GET /attribution` enumerates
it dynamically, and `attribution.assert_attribution_complete` makes a missing credit a build
failure. Nothing to fix for API consumption. **This changes when we redistribute** — see §11.6.

**Usage policy — not satisfied.** The Overpass API public instances exist for *interactive and
small* queries; the operators direct anyone needing bulk data to planet dumps or extracts. That is
Geofabrik, and it is the same conclusion §6 reaches on engineering grounds. Multi-thousand-km²
extracts committed on every accepted bbox, requeued without cooldown, with the rate limit disabled
from attempt two onward and no identifying User-Agent, is precisely the use operators have asked
people not to make of donated capacity. Nominatim's policy adds its own identification and
request-rate requirements that `/geocode` has never been checked against.

**Adopting Geofabrik extracts is not generosity. It is doing what the services we depend on have
asked bulk consumers to do.** Adding more public mirrors would spread the same load onto another
volunteer operator instead of fixing it — which `regions.py` already argues against in its own
`DEFAULT_OVERPASS_ENDPOINTS` docstring, and then does not act on.

---

# Part II — The plan

Five phases. **Phase 0 stands alone** — it is worth doing whether or not anything after it is
approved, and it is the phase that stops the harm.

## 5. Phase 0 — Reduce load and identify ourselves (this week, no new dependencies)

Nothing here requires the migration, a spike, or a new dependency.

**5.1 Send a contactable `User-Agent` and referer** on every Overpass and Nominatim call. Set
`ox.settings.http_user_agent` and `ox.settings.http_referer` to a string naming Plotlines, its
version, and a contact URL, at sidecar startup. One line; closes §3.4. *Ship first — it is the
change that lets an operator talk to us instead of blocking us.*

**5.2 Move `configure_overpass_cache` to sidecar startup**, out of `ensure_graph` (§3.2), so
osmnx's own response cache functions on the candidate and geocode paths and stops writing to a
CWD-relative directory.

**5.3 Write the candidate disk cache** into the slot `CacheLayout.candidate_set()` already
reserves (§3.1). Removes repeat queries outright; A23's 1.75 s vs 15.8 s.

**5.4 Re-enable `overpass_rate_limit` on failover.** `graph/regions.py:397-400` currently honours
the server's advertised slot pause only on endpoint 0 / attempt 1 and disables it thereafter —
dropping politeness at exactly the moment we retry hardest. #240 wants it off for latency; the
resolution is to **keep the politeness and fix the latency differently**, with a cheap connect
probe (short-timeout socket open) so we never enter a 60 s slot-pause for a host whose socket will
not open. Closes the #238/#240 tension in favour of the operator.

**5.5 Settle window and supersede-in-flight** on the accepted-bbox → `ensureRegion` edge, **not**
on gestures (§3.3). Ends the five-builds-in-thirty-seconds pattern. Closes #238's first mechanism.

**5.6 Failure cooldown with a cap** between a settled failure and the next requeue. Ends indefinite
retry against a dead endpoint. Closes #238's second mechanism.

**5.7 Give the empty response its own error type** (#239) whose `str()` is a finished sentence, the
way `OverpassUnavailable` already is — the drawn area has no routable ways for this mode, not "we
couldn't reach the service."

**5.8 Audit `/geocode` against Nominatim's usage policy** — request rate, identification, and
whether results are cached rather than re-queried. Not previously considered.

**Regression tests** for 5.4–5.7 belong beside #232's, in `core/tests/test_graph_regions.py`, which
already asserts the no-retry-on-empty behaviour.

## 6. Phase 1 — Local Geofabrik mirror (Raspberry Pi 5 + NVMe + Caddy)

The production mirror is static object storage: files, byte ranges, TLS. A Pi serving static files
with correct `Range` support **is that, at small scale** — this is not a mock to be thrown away, it
is a rehearsal.

### 6.0 What the §12 answers changed here *(2026-09-03)*

Three of the six answers land on this phase and one of them changes its shape, so read §6 with
them applied rather than as originally drafted:

- **Q1 = C** (mirror-side clip to the trip bbox; the client never sees a region extract). **The
  "keep it dumb, no API, no logic" rule is now half true.** The mirror still serves pinned region
  extracts as immutable static files — that is what the clip reads, and it is what Q1-D falls back
  to — but it also grows **one** endpoint: bbox in, clipped `.osm.pbf` out. That is a real cost
  against this section's original discipline and it is taken deliberately: the Pi stops rehearsing
  "static files with byte ranges" alone and starts rehearsing **the hosted clip of §9**, which §9
  currently carries as an unmeasured future risk. Everything beyond that one endpoint stays dumb.
- **Q2 = B + C's monitoring.** `MIRROR_STATE.json` (§6.6) is no longer just a marker — a monthly
  pin bump with a named owner and a release-checklist gate, plus mirror age reported through the
  sidecar's existing per-layer `/health` surface.
- **Q6 = D + C.** Clip server-side so the bytes on the wire are small, and keep whatever bulk
  remains on zero-egress object storage later. That makes §6.3's layout a **bucket layout that
  happens to be on a Pi today**: no path may depend on a filesystem, a directory listing, or a
  server-side rewrite, or the eventual move to R2/B2 stops being a hostname change.

**Amended 2026-09-24 (ARCH D67, epic #516):** "everything beyond that one endpoint stays dumb" no longer holds. The mirror gains a *fill worker* beside the store: a miss queues an upstream fetch of the covering area instead of being a final answer. The store itself stays dumb — immutable paths, plain files, a bucket layout — so the hostname-change property above is kept.

The addendum's Phase 1 amendments (**1a**–**1d**) are folded into §6.3, §6.6 and §6.8 below.

### 6.1 Why the Pi and not the dev box

Our spikes measure things against pre-registered bands. A file server on the box under measurement
puts its own CPU and page cache inside every clip-time and download-time number — measuring a
memcpy and calling it a download. The Pi gives a real network path, a real disk, and contention
that is not ours. It is also always-on at a stable name, and the 1 GbE ceiling (~110 MB/s) is closer
to a real user's download than localhost is. Note the ceiling when reading numbers rather than
trying to remove it.

### 6.2 Hardware

**NVMe, not SD.** Serving hundreds of MB off an SD card dominates every measurement and teaches us
nothing true. A 500 GB–1 TB NVMe on the Pi 5's PCIe HAT is ample for a handful of state extracts
plus the existing `spikes/SPIKE-14/tiles/wnc-corridor.pmtiles`. **Do not put a planet archive on
it** — regional extracts only.

### 6.3 Directory layout — mirror production exactly

So the eventual swap is a hostname change and nothing else. Paths are build-pinned, hence
immutable.

```
/srv/plotlines-mirror/
  MIRROR_STATE.json                                     # freshness marker + covered regions — see 6.6
  COPYRIGHT.txt                                         # 1a: ODbL notice for the whole tree
  basemap/protomaps/20250101/planet.pmtiles             # matches MIRROR_ARCHIVE_URL — still unprovisioned; ARCH D65 (2026-09-21) makes per-region on-demand extraction the accepted answer instead
  basemap/protomaps/20250101-wnc/corridor.pmtiles       # 1b: real extract since #394/#457, TTL-refreshed — no longer the SPIKE-14 stand-in
  osm/COPYRIGHT.txt                                     # © OpenStreetMap contributors, ODbL 1.0
  osm/geofabrik/2026-09-01/index-v1.json                # licence checked (#259) — mirrored — 1a
  osm/geofabrik/2026-09-01/north-america/us/north-carolina.osm.pbf
  osm/geofabrik/2026-09-01/north-america/us/north-carolina.osm.pbf.md5
```

Two amendments from the addendum are in that tree and are not optional:

- **1a — the licence artifacts.** The moment `tiles.plotlines.app` is internet-reachable and
  serving `.osm.pbf`, Plotlines is a public redistributor of an OSM database, and the notice
  obligation attaches to the **distribution channel**, not just to the app UI. One file per
  directory, in the layout from the start. Separately: `index-v1.json` is Geofabrik's own region
  geometry — their cut lines, their naming — and its licence is **unverified**. Check it before
  mirroring it; if it is unclear, derive the covering-set geometry from the bboxes we actually
  need rather than re-serving their index. *(Resolved 2026-09-06 under #259: Geofabrik's own
  stated Open Data policy covers data it produces/refines, which is what the index is — it is
  mirrored, with a notice citing that policy distinct from the ODbL statement.)*
- **1b — the stand-in gets an honest path.** A file named `planet.pmtiles` containing one corridor
  makes every bbox outside WNC a silent miss that looks like a mirror bug, and makes
  "build-pinned paths are immutable" untrue for the one file most likely to be swapped. Its own
  build id, and `MIRROR_STATE.json` records which regions the archive actually covers.

### 6.4 Caddyfile

```caddyfile
http://tiles.plotlines.app {
	root * /srv/plotlines-mirror
	file_server

	# Build-pinned paths are immutable.
	header /basemap/* Cache-Control "public, max-age=31536000, immutable"
	header /osm/*     Cache-Control "public, max-age=31536000, immutable"

	log {
		output file /var/log/caddy/mirror.log
	}
}
```

Three details that matter:

- **The `http://` scheme prefix is required.** Without it Caddy attempts automatic HTTPS via ACME
  for a domain it cannot validate, and fails to start.
- **No `encode`.** `.pmtiles` and `.osm.pbf` are already compressed, and on-the-fly compression
  breaks byte-range semantics — which is exactly what `tiles/extract.py:http_range_source` needs.
- **Do not serve this with `python -m http.server`.** `SimpleHTTPRequestHandler` ignores `Range` and
  returns the whole file with a `200`, so PMTiles reads would silently pull the entire archive per
  lookup and we would conclude the approach is slow.

**Run Caddy containerized, not as a native package install.** Docker is already the Pi5's
operating pattern (companion QA elevation proxy, §12.1-adjacent, uses it for the same reason —
sidestepping aarch64 native-dependency packaging rather than fighting it). The official `caddy`
image with this Caddyfile mounted read-only and `/srv/plotlines-mirror` bind-mounted read-only
gives an identical result with no apt-managed Caddy version to track separately from the rest of
this box's services, and trivial teardown/rebuild. Nothing above changes: the Caddyfile content,
the immutable build-pinned paths, and the `http://` scheme requirement are unaffected by how the
process is launched.

### 6.5 Hostname — exercise the real code path

`classify_upstream` (`tiles/mirror.py`) matches on **hostname only and is scheme-agnostic**. So
pointing `tiles.plotlines.app` at the Pi's LAN address in local DNS makes
`http://tiles.plotlines.app/...` classify as `MIRROR` — **no TLS, no `--allow-unmirrored-tiles`, no
code change**, exercising the real `resolve_upstream` path rather than the dev escape hatch.

Start with the low-friction form (`--tiles-upstream http://pi.local/... --allow-unmirrored-tiles`,
both flags already exist in `service/plotlines_service/__main__.py`), then move to the DNS override
once it is boring. `/etc/hosts` on the dev box is the zero-infrastructure fallback if the local
resolver is inconvenient.

### 6.6 Sync and freshness

Pull each region from Geofabrik **once**, verify against the published `.md5`, and iterate against
the Pi forever after. All spike iteration then costs an upstream nothing — which is the mistake we
are unwinding on the Overpass side, so we should not repeat it on the Geofabrik side.

`MIRROR_STATE.json` records the pinned build date, a per-region pull timestamp, **and which
regions each archive actually covers** (1b). That file is where §11.3's "we become the
availability" gets rehearsed.

**Pull etiquette — rules, not prose (1c).** "On a cron" with no cadence, no conditional request and
no UA is the same unexamined automation that produced #232, aimed at a different operator. So:

- **At most daily.** Geofabrik's files update daily; anything faster downloads the same bytes.
- **Conditional first.** `HEAD` / `If-Modified-Since`, or compare the published `.md5`, and skip
  the body when unchanged.
- **Identified.** The same Plotlines User-Agent #241 introduces — one contactable string across
  every upstream we touch.
- **Backs off on error** rather than retrying on the next tick.

**Pin cadence and monitoring (Q2 = B + C's monitor).** The pin bumps **monthly**, one named owner
does it, and the release checklist blocks on it — the same discipline `PROTOMAPS_BASEMAP_BUILD`
already has, where a missed month is *visible*. The monitor is built anyway and is the part §11.3
says is missing: `MIRROR_STATE.json` plus a **mirror-age field on the sidecar's per-layer
`/health`** (the N4 surface), so staleness is loud rather than silently permanent.

### 6.7 The one endpoint: mirror-side clip *(Q1 = C)*

The client resolves nothing and downloads no region extract. It sends a trip bbox and receives one
clipped `.osm.pbf`. This dissolves Q3 outright (no covering set, no way-deduplicating merge on the
least observable machine we have), removes the client-side native dependency, and removes the
GPL question with it (addendum L1) — the clip runs in one place we control.

Two constraints on it from day one:

- **No GPL-licensed binary.** The clip goes through **pyosmium's Python API**, not the
  `osmium` CLI: osmium-tool is GPL-3.0, libosmium/pyosmium are BSD-2-Clause (addendum L1).
- **Q1-D stays reachable.** The pinned region extracts remain served as plain immutable files, so
  "pull a state extract deliberately for a trip you know is coming" is a configuration decision
  later and not a rebuild. Offline bbox *editing* is the case that would force D; that is a
  measurement, not a guess, and SPIKE-I is where it gets made.
- **Containerize this service, same reasoning as §6.4's Caddy note.** pyosmium is a C++ extension
  (libosmium) — exactly the class of aarch64 packaging risk the companion QA elevation proxy's
  Dockerfile exists to sidestep for rasterio/GDAL. Pin a base image with a known-good pyosmium
  wheel (or build it once in the image) rather than fighting apt/pip on the Pi directly; Docker is
  already this box's operating pattern by the time #262 lands.

- **The licence notice travels with the clip** *(issue #364)*. `COPYRIGHT.txt` states the notice
  obligation as attaching to "the distribution channel, not to the presence of a file on disk" —
  and `/clip` is a **second channel**: Caddy's `reverse_proxy /clip*` matcher terminates the
  request before `file_server` runs, so a caller here never reads that file. A clip is an
  *extraction*, which makes its output a **Derivative** Database under ODbL (§4.3), not a Produced
  Work like the basemap archive. Every `/clip` 200 therefore carries the licence id, the
  attribution, and the terms URL in its own headers, plus a standard `Link: …; rel="license"`;
  `/health` states the same. Header values stay US-ASCII (`(c)`, not `©`) — Starlette emits header
  values as latin-1, so the typographic glyph goes out as a byte that is not valid UTF-8 and breaks
  a client decoding headers before it sees the body. **Phase 4's hosted clip (§9, #280) inherits
  this**: it is the same Derivative Database over the same kind of channel.

The clip's cost profile — CPU, disk IO, and behaviour under concurrency — is exactly what §9 says
Phase 3 does *not* prove for free. Rehearsing it here is how that stops being a surprise.

**Measured — SPIKE-I (2026-09-13) and #402 (2026-09-18).** The rehearsal found two failures this
section had treated as settled. **Cost was O(region extract), not O(bbox)**: 432 s for a 64 km²
bbox out of the 428 MB North Carolina extract, 553 s for a 27 km² bbox out of California's
1.33 GB — a bbox 6× larger costing 6.8% more time, ~7–9× over the pre-registered ≤20 s / ≤60 s
bands. And **the two-extract path did not complete** (0 of 4): `MergeInputReader` buffered both
raw extracts, +3.9 GB in 5 s, 502 to the caller — the default path for every western-North-
Carolina bbox, because rectangular header boxes for NC and TN overlap by 2.7° of longitude. Both
were fixed the same day and the request path of `mirror_clip.py` was left alone: **#376** clips
each covering extract first and merges the few-MB outputs (never a raw path, asserted by test);
**#375** pre-cuts at pin time — `geofabrik_pull.py --precut-wnc-corridor` runs the same
`clip_bbox` against `WNC_CORRIDOR_BBOX` and pins the result in place of the sources, so the
per-request scan is already small. **Re-measured on the live Pi under #402**: the same Asheville
cell went from **617 s on the full-state pin to ~102 s on the precut pin**, an 83% reduction that
tracks the 6.4× drop in pinned-extract size — the cost is O(pinned extract), and `/clip` is still
**~1.7× over the ≤60 s outer band** (#439). #402 also narrowed `select_covering_extracts` by each
extract's real `.poly` boundary (pulled alongside the `.osm.pbf`), cut peak RSS 2,842 → 1,770 MB
with a disk-backed location index, shipped an opt-in clip cache keyed on `(pin, bbox)`, declined a
spatial index as engineering for a requirement this one-corridor mirror does not have, and fixed a
live defect where precut output carried no header box (an out-of-corridor bbox paid a full scan
before 404-ing; now 2 s). Strategy question answered too: `complete_ways` is the floor, not one of
three options. The Release Checklist's OSM re-pin carries the `--precut-wnc-corridor` flag for this
reason — skipping it silently regresses `/clip` to a full-state scan.

### 6.7a Offline bbox-edit posture — C confirmed, D rejected *(2026-09-17, issue #278)*

SPIKE-I (#265) measured the one thing this section deferred: "Author edits the bbox on a
mountain with no signal." The two halves of that question point opposite ways, and both are
now numbers rather than a guess.

**B9 — D's precondition is real.** Against the pre-registered ≥90% "C holds" band, a bbox
edit distribution fixed before the run (shrink 0.5–0.95, nudge 0–25% of span, grow 1.05–2.0,
equal weight) found only **38.2–48.2% servable** from the graph the client already holds
(48.2% urban / 38.0% rural). Shrinks are fully servable (100%); nudges and grows are not
(13–34% and 1–10%) because the held graph covers only the trip bbox plus osmnx's own ~500 m
buffer — roughly 7% of a typical trip bbox's span. **So an Author editing the bbox offline
hits an unservable edit more often than not**, and even a nominally "servable" shrink
truncates an already-simplified, already-component-pruned graph rather than rebuilding one:
measured 0.6–1.6% node divergence from a fresh build at the shrunk extent (boulder-bike
6,371 vs. 6,409 nodes; viroqua-bike 1,491 vs. 1,516).

**§3 rejects D as the answer to it.** D's mechanism is a client-pulled region extract,
re-clipped locally when the bbox changes offline. The clip it would run is the same one
measured server-side in §6.7/§3 above: **432–553 s wall time and 1.9–7.2 GB peak RSS on a
Raspberry Pi 5** — hardware with more headroom than most client devices — with no
predictable relationship between an extract's size and its memory cost, and a two-extract
case that pushed the mirror's own process to ~7 GB before #376's fix inverted the merge
order. Running that same operation on the client, offline, on weaker hardware, in the field,
is not the "configuration decision later" §6.7 and the addendum's Q1 promised: it reopens
**L1**'s native pyosmium dependency on every platform and un-freezes **#266**'s freeze
matrix, for an operation that costs minutes and multiple gigabytes with no way to size it in
advance from the inputs.

**Decision: C stays as shipped. D is not taken.** Recorded as ARCH **D62**
(`Plotlines_ARCHITECTURE_v2.md` §18/D-number table). The "D is a configuration decision
later, not a rebuild" line in the addendum's Q1 section is corrected, not confirmed — it was
true of *storing pinned extracts as static files*, which the mirror already does and which
this decision does not touch, and false of *what a client would have to do with one offline*,
which is the half SPIKE-I actually measured.

**What an Author sees, offline, editing the bbox (FR120, FR121):**

- **Nudging or growing** past the held graph's buffered coverage cannot be served offline —
  the bytes to serve it do not exist on the device and D is not there to fetch them. This is
  **already the shipped behaviour**: `RegionState`'s extract/graph capability (#274/#275)
  reports `failed:<reason>` / not-ready when the mirror is unreachable, exactly FR121's
  existing disabled-with-reason contract — never a silent failure on click, never a block on
  the rest of the app. The still-covered portion of the trip — including every
  already-promoted anchor — remains fully usable. No change is owed here.
- **Shrinking is where C's offline story is worth improving, and the improvement is decided
  but not yet built.** SPIKE-I measured that truncating the graph the client already holds
  serves 100% of shrinks, at a small, disclosed cost (0.6–1.6% node divergence from a fresh
  build for the new extent). **Decided target:** a shrink truncates the held graph
  immediately rather than reporting not-ready, with routing/cue-sheet capabilities for the
  shrunk trip marked **provisional** — the same "stated reason, honest progress" pattern
  FR121 uses for not-ready, applied to "correct once reconnected" instead of "not yet
  available" — until a real rebuild completes online. **Today**, before that mechanism is
  built, a shrink offline behaves identically to a nudge or grow: an honest
  `failed:<reason>` capability report, not a provisional graph. The truncation mechanism is
  filed as **#432**. Independent of whether it is built yet, FR120's no-lost-anchor
  guarantee is unconditional and does not bend for connectivity: any promoted anchor outside
  the new bounds is shown to the Author, who keeps it (bbox unchanged), moves the bounds, or
  removes it explicitly — never silently discarded.
- **On reconnection**, the region-build path already shipped for FR91/FR120 runs for the new
  extent precisely as it would for any bbox change online: no special-cased "resume," since a
  bbox edit already means "re-run extraction and enrichment for the changed area" whether or
  not a provisional graph existed in between.

### 6.8 Reachability: open or client-restricted *(1d)*

Decide before the mirror is internet-reachable, not after. An open mirror is legal and makes us an
unintentional public extract service on our own bandwidth; a restricted one needs a client
identification story that does not become an auth system. Either answer is defensible; leaving it
undecided until the first traffic bill is not.

**Decision — adopted 2026-09-12: split, the shape Q1-C already implies.** Plain static payloads
(region extracts, the basemap archive, `COPYRIGHT.txt`) stay open — that is §6's "stay dumb"
discipline, and it is bytes, not compute; Caddy's `file_server` route is unchanged. `/clip` is the
one endpoint Q1-C added that also spends CPU per request ("an open clip endpoint is an open CPU
endpoint"), so it is the one that is restricted, by two independent mechanisms rather than one:

- **A shared Plotlines-client key**, `X-Plotlines-Client-Key`, checked against `--client-key` /
  `MIRROR_CLIP_CLIENT_KEY` with a constant-time comparison. This is explicitly **not** an auth
  system: the key identifies "a Plotlines-built client," never a person, device, or account; there
  is no signup, no issuance flow, and no per-key state beyond the rate-limit window below. Planning
  a trip needs no sign-in before or after this change — D41/D57's offline-first posture is
  untouched. Unset (the default) leaves `/clip` open, which is the correct default for the local
  Pi rehearsal and for hermetic tests; production sets the env var when the container starts.
- **A per-client-IP rate ceiling** (`--rate-limit-per-minute`, default 30), enforced on `/clip`
  regardless of whether a key is configured, since the CPU cost is the same either way. In-memory,
  fixed-window, single-process (this service never runs with `--workers > 1`, so there is no
  cross-process state to reconcile) — an operational abuse guard, not per-user tracking: nothing
  here persists past the rolling window or a process restart, and it is keyed on request IP, never
  an identity.

Either failure returns immediately as a finished JSON body (`401 unauthorized_client` /
`429 rate_limited`) — never a hang, never a stack trace — satisfying the acceptance criterion
independent of which posture a given deployment chooses. Nothing about this touches what the FR138
privacy statement says leaves the device (#252): the sidecar became the first caller of `/clip` in
Phase 3 (#274), and the recipient the statement names is "the Plotlines mirror," unchanged by
whether that mirror happens to gate the request on a shared key. Implemented in
`service/plotlines_service/mirror_clip.py`; `service/tests/test_mirror_clip_server.py` covers both
mechanisms.

**How a shipped client carries the key (#434, 2026-09-17).** The Flutter app is what spawns the
sidecar, so it is the app that has to hand over `--mirror-clip-url` and `--mirror-clip-client-key`
— and until #434 it handed over neither, which left every stock desktop install on the Overpass
fallback with `capabilities.extract = {"configured": false}` no matter what Phase 3 had landed in
the service. `client/lib/data/sidecar_upstreams.dart` now resolves the four upstream flags from
a process environment variable, then a build-time `--dart-define`, then a built-in default; the
mirror URL defaults to `https://tiles.plotlines.app` (pinned by test to `tiles/mirror.py`'s
`MIRROR_HOST`), and the key has **no default and no literal anywhere in the tree** — it enters a
release build from the builder's secret store through `--dart-define`, exactly as any other deploy
secret does, and a test fails if that define ever grows a `defaultValue`. A key baked into a
distributed binary is extractable by anyone holding the binary; that is the accepted meaning of a
shared client key here (bandwidth and CPU bounding, not authentication), and the reason it is
passed on the sidecar's argv rather than hidden. The privacy statement (FR138) was reworded in the
same commit to name the recipients in the order the shipped app now tries them: the mirror first,
Overpass as the fallback.

## 7. Phase 2 — Spikes

Two spikes, in this order, plus one build task. Letters continue the punch-list series, which
ran A–H. **The phase is epic #268.** Both spikes are filed and entered in
[`Plotlines_Research_Spikes.md`](Plotlines_Research_Spikes.md): **SPIKE-I is #265, SPIKE-J is
#266**; the addendum's **2d** notice bundle is **#267**.

**7.1 SPIKE-I — local extract and graph parity** *(the correctness spike)* — **#265**

1. **Graph parity against osmnx.** Not a smoke test — node/edge counts, edge keys, geometry, and
   the largest strongly-connected component, checked against a golden osmnx-built graph. Ranks
   first because §11.1 is the sharpest risk.
2. **Tag survival** — that `PLOTLINES_WAY_TAGS` and the node `barrier` tags come through the clip
   and the graph build. This is the #206 class of defect, where a rule keyed on an un-downloaded
   tag goes silently inert on every real graph.
3. **Clip time and clip strategy** for a realistic trip bbox, including `osmium extract`'s
   `simple` / `complete_ways` / `smart` trade-off, and the border case where a bbox spans two
   extracts (§11.7).
4. **Extract size per region**, and what it implies for the mirror and for first-run download.

> **Run 2026-09-13 — RESCOPE, and the failure is not where §11.1 put it.** Bands pre-registered
> and committed before the first measurement (addendum G5/2b). **Graph parity is exact** through
> the *transport* swap — clipped `.osm.pbf` → Overpass-shaped elements → osmnx's own
> `_create_graph`: identical node and edge sets, 100% edge-key stability, identical largest SCC,
> 0.0 m max per-edge delta, zero `PLOTLINES_WAY_TAGS` losses, on `bike` and on `drive` (where it
> reproduces SPIKE-E's `track`/`service` drop exactly rather than accidentally fixing it).
> pyrosm, the *reimplementation*, is 5.6×–16.4× node-inflated and was rejected — so §11.1's
> re-validation budget was not owed for the graph, and #276 confirmed SPIKE-A's goldens exact on
> the extract-built graph. **What failed is §6.7's clip**, measured server-side on the Pi 5 per
> addendum 2c: **432–553 s / 1.9–7.2 GB, O(region extract) not O(bbox)**, and the two-extract
> border path **0 of 4 completing** (`MergeInputReader` buffering raw extracts, OOM, 502) — which,
> because `select_covering_extracts` compared rectangular header boxes, was the *default* path
> for every western-North-Carolina bbox. Both fixed the same day: **#375** pre-cuts pinned
> extracts to the served corridor at pull time, **#376** merges the few-MB clipped outputs rather
> than the raw extracts. `complete_ways` is the floor, not one of three options (`smart` +54% for
> one node; `simple` cannot reach parity because Overpass's `(way…;>;)` returns complete ways).
> Extract sizes recorded; Q6's egress arithmetic discharged (~325× reduction, a rounding error);
> the offline bbox-edit measurement fired D's trigger (38–48% servable) and D was rejected on the
> clip's own cost (§6.7a, D62). **Re-measured on the live Pi 2026-09-18 (#402, PR #438):
> 617 s → 101.65 s / 101.73 s on the precut pin — 83% off, tracking the 6.4× smaller extract,
> still ~1.7× over the ≤60 s outer band; residual #439.** `spikes/SPIKE-I/results/RESULTS.md`.

**7.2 SPIKE-J — packaging the native dependency** *(the distribution spike)* — **#266**

PyInstaller freeze survival for pyosmium/pyrosm on **all four targets**: Linux, macOS x86,
macOS arm, Windows. Risk **A5**. See §11.2 — this is the item most likely to consume a week
unexpectedly, and it is independent of 7.1, so it can run in parallel.

> **Run 2026-09-13/15 — PARITY on all four targets.** pyosmium (the only candidate left after
> SPIKE-I rejected pyrosm) freezes, launches, reads and builds a graph on Linux, Windows,
> macOS x86 and macOS arm, at **+3.4–4.5 MB uncompressed per platform**; the no-GPL-binary check
> passes on each. §11.2's week was not consumed. `spikes/SPIKE-J/results/RESULTS.md`.

## 8. Phase 3 — Desktop and mobile extract path

Replaces the *transport*, not the interfaces: `ensure_graph(region, cache_dir)` keeps its
signature, `OsmLayerProvider.fetch(bbox, layers)` keeps its, `LayerProvider` never knows.

1. **Resolve** trip bbox → covering set of extracts, from the mirrored `index-v1.json`. Plural from
   day one — Buncombe County is ~30 km from Tennessee and not much further from South Carolina and
   Georgia, so the border case lands where we start (§11.7).
2. **Download** the covering extracts from the Plotlines mirror. Triggered by the Author declaring
   the extent — FR120's moment — and reported through the FR121 capability channel with honest
   progress, the same contract the graph build already uses. **Not at install or first launch**;
   that would violate ARCH D41/D57's no-eager-download posture, whereas an extent-triggered pull
   does not.
3. **Clip** per-bbox with `osmium extract`, cached under `CacheLayout` keyed by `trip_bbox_key` —
   a sibling of the tile and elevation caches, one policy, three payloads (ARCH §8.1).
4. **Build** the routing graph and the candidate features from the clip. `osm_tags_for()` already
   generates the tag filter the candidate side needs.

Freshness is **per-trip**: a trip pins the build it started on and does not shift under the Author
mid-planning; a new trip gets whatever is current. Same discipline as `PROTOMAPS_BASEMAP_BUILD`.
This removes client-side diff application from the plan entirely — diffs are applied server-side to
keep the mirror current, and clients only ever see a pin.

**The pin is written into the payload (L7, #270/#277).** `trips.provenance.build_provenance` is the
one producer of `Provenance`; `osm_source` carries `geofabrik:<pin>` off the clip's own directory
(`Region.graph_source_path`) once a mirror clip exists, and `overpass:<fetch-date>` only on the
Overpass fallback. A trip built from a stale pin is therefore distinguishable from a fresh one in
the payload itself, not just on the mirror's own `MIRROR_STATE.json` — which is what keeps a quiet,
months-old pin (§11.3) from reaching an Author's data as well as ops.

## 9. Phase 4 — Web and hosted

ARCH §11 has already decided this (line 944):

> The candidate cache is Desktop/Mobile only — Web curation reads from the hosted service per
> request, since a browser is not the right home for a bbox-scale candidate set.

So on web the hosted service holds the extracts and clips per request; users hold nothing and
download nothing. **PBF distribution to browsers is never required.**

The sequencing works in our favour: Phases 1–3 build the mirror and the clip tooling that Phase 4
reuses server-side. The MVP is not a stopgap, it is the first half of the real thing. What Phase 3
does *not* prove is the hosted clip's CPU and disk-IO profile under concurrency — that is a
separate measurement when web is on the table, not a free inheritance.

## 10. Phase 5 — Make the policy mechanical

Every decision above erodes. The tile path learned this and encoded it as `HotlinkRefused`; the OSM
path has the same policy living only as prose in a `DEFAULT_OVERPASS_ENDPOINTS` docstring, which is
why the endpoint list kept growing.

- A gate equivalent to `HotlinkRefused` that refuses a third-party Overpass host in the default
  configuration.
- A test that fails if the default endpoint list regrows.
- A test asserting a non-default `http_user_agent` is set before any OSM request goes out.

**Keep a small, polite Overpass use — do not eliminate it.** A user-initiated, small-bbox "refresh
from live OSM" affordance is precisely what the public instances are for, and it recovers the
freshness workflow §11.4 gives up. Good citizenship is proportionate usage, not abstinence.

**And give back.** Sponsor or donate — the OSM Foundation, and Geofabrik if we become a heavy
consumer of their diffs; if Plotlines is commercial this is cheap and correct. Our Authors are
outdoors people who find unmapped trailheads and closed gates, so an "improve this in OSM"
affordance is a real contribution to the commons the product is built on, not a gesture.

---

# Part III — What this costs

## 11. What this trades away

This is not "remove a dependency." It is **trading a volatile dependency we do not control for a
stable one we have to operate.** The right trade for an offline-first, locally-authored product
that already runs a tile mirror — but the costs are real and should be priced, not discovered.

**11.1 Graph parity is the sharpest risk, and it is not the tag check.** `ox.graph_from_bbox` does
far more than download: `network_type` filtering (where SPIKE-E already found `drive` silently
dropping `highway=track` and `highway=service`), way splitting at intersections, simplification,
and strong-component truncation. pyrosm is a *different implementation of the same idea*; node IDs,
edge keys and geometry need not match. Everything calibrated to date was measured on osmnx output —
SPIKE-A's golden candidate sets, SPIKE-G's density model and its ~2,800-marker ceiling, the scoring
weights, cue derivation. A structural difference shifts those calibrations in ways no node-count
assertion catches. Budget for re-validation against a golden set.
*Measured — SPIKE-I, 2026-09-13:* the risk split in two and answered oppositely. The **transport**
swap (clip → Overpass-shaped elements → osmnx's own builder) is **bit-exact** on every band, so the
re-validation was not owed for the graph — #276 confirmed SPIKE-A's goldens exact and SPIKE-G's
ceiling unchanged on the extract-built graph. The **reimplementation** (pyrosm) is 5.6×–16.4×
node-inflated and is exactly the graph none of those calibrations were taken against; it was
rejected and must not return as "a second implementation for comparison."

**11.2 The native dependency lands on risk A5.** pyosmium is a C++ extension (libosmium, protozero,
expat, bz2), needed frozen on four targets. Native extensions are where cross-platform freezes
break, and A5 already flags 150–300 MB per platform stacking on offline packages.
*(Measured by SPIKE-J, 2026-09-15: it survives on all four targets, and it costs 1.5–1.9 % of
the sidecar — A5's 150–300 MB is confirmed with osmium in, not widened; the pressure is the
geospatial stack.)*

**11.3 We become the availability.** Today an Overpass outage is someone else's problem and it is
loud and transient. After, a mirror cron that silently stopped three months ago looks identical to a
working mirror. Mirror-freshness monitoring becomes required ops surface that does not exist today.
The failure mode moves from loud-and-transient to quiet-and-permanent, which is the worse of the two.

**11.4 Freshness regresses for our most engaged users.** Overpass is minutes-fresh. Pinned builds
mean an Author who has just added a trailhead to OSM will not see it until the pin moves. People
who plan backcountry trips and people who edit OSM overlap heavily. Mitigation in §10.

**11.5 Egress scales with trips, not users.** Overpass bandwidth is free and someone else's.
Per-trip pinning means an active Author re-pulls a regional extract for each new trip in a new
region. Cheap at a hundred users, a line item at scale. Mitigable — re-pull only when the local pin
is stale by *N* — but it introduces a cost curve where none exists today.

**11.6 ODbL changes shape when we redistribute.** Consuming an API makes Plotlines a user.
Mirroring extracts and handing a client a clipped `.pbf` makes Plotlines a distributor of a
**Derivative Database**, where share-alike attaches differently than to the **Produced Work**
reasoning the tile pipeline uses (`mirror.py`: *"ODbL, as a Produced Work from OSM data"*). The
attribution machinery is good (§4), so this is likely a paragraph rather than a problem — but it is
a genuinely new obligation and should be checked, not assumed to inherit.

**11.7 Clipping a graph is not clipping tiles.** Tiles are independent squares and clipping is
lossless per tile. A road network is connected, so a bbox cut severs ways. `osmium extract` offers
`simple` / `complete_ways` / `smart` strategies with real differences in cost and completeness, and
merging two adjacent extracts means deduplicating ways present in both. Overpass handled this
invisibly; it is a correctness surface we are taking ownership of.
*Measured — SPIKE-I, 2026-09-13, with the strategies implemented through pyosmium rather than
selected by osmium-tool flag (addendum L1):* `complete_ways` is the floor — `simple` leaves dangling
references and cannot reach parity because Overpass's `(way…;>;)` has been returning complete ways
all along, and `smart` costs +54% wall time for exactly one extra node. The two-extract merge was
the surface that actually failed (0 of 4 completing) and #376 owns the fix; #402 then found the
second defect this paragraph predicts — clipped output with no declared coverage — and fixed it.

## 12. Open questions — **answered 2026-09-03**

The six questions this document opened are decided. Options and trade-offs are laid out in the
[licensing addendum](Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md) §5; the answers below
are the addendum's recommendations, adopted as written.

| | Question | **Decision** | Consequence |
|---|---|---|---|
| **Q1** | Extract granularity | **C — mirror-side clip to the trip bbox**, confirmed as final. **D's fallback trigger fired (38–48% of offline bbox edits are unservable) but D itself was rejected on measurement** — the local re-clip it requires costs 432–553 s / 1.9–7.2 GB even server-side on a Raspberry Pi 5 | The client never sees a region extract. Dissolves Q3, removes the client-side native dependency and the GPL question (L1). §6.7, §6.7a, ARCH **D62** — SPIKE-I / #278, 2026-09-17 |
| **Q2** | Pin cadence and ownership | **B — monthly pin, named owner, release-checklist gate**, with **C's monitoring built anyway** | `MIRROR_STATE.json` + mirror age on the sidecar's per-layer `/health`. §6.6 |
| **Q3** | Where the covering-set merge happens | **Dissolved by Q1-C** — there is no covering set and no merge | The way-deduplicating merge never lands on the client, which was the plan's hardest correctness surface (§11.7) |
| **Q4** | ODbL redistribution sign-off | **A — write `docs/Plotlines_Licensing_Position.md`**, decide against the OSMF community guidelines, record as an ARCH D-number | Filed as **#253**, in **Phase 0** — not a Phase 3 gate, because share-alike is already implicated by today's sharing surfaces (addendum L2) |
| **Q5** | Keep the interactive Overpass affordance | **A — keep public instances, hard-capped**, budget named as ours to spend | The caps are mechanical (addendum P4): bbox area below `max_query_area_size` so it can never subdivide, concurrency 1, a per-day budget that fails closed with an honest message, no automatic retry. Phase 5 |
| **Q6** | Egress budget when web lands | **D + C — clip server-side, put remaining bulk on zero-egress object storage.** *Amended 2026-09-21 (issue #457, ARCH **D65**): this answer's "D" half never covered the basemap's own bulk — a purchased whole-planet Protomaps build stayed unprovisioned, with no mechanism to refresh even the one region the mirror carried. The **basemap-tile reading is corrected**: TTL-refreshed on-demand `pmtiles extract` against Protomaps' hosted daily build, through the mirror, for a small named-region list — never a planet archive on object storage. The **OSM-extract half is unchanged** — `/clip` still clips Geofabrik state files server-side per trip bbox (D63), and pinned bulk state files still live on the Pi's NVMe, not object storage | Egress drops by roughly the ratio of bbox area to region area. §6.3's layout must stay a bucket layout (§6.0) |

**One measurement still owed against Q6.** §11.5's premise — "an active Author re-pulls a regional
extract for each new trip in a new region" — is arithmetic once SPIKE-I reports extract sizes
(§7.1(4)) and we guess at trips-per-Author-per-region. Q1-C makes it much smaller; it does not make
it unnecessary to check.

---

# Part IV — Execution

## 13. Ordered checklist

**Now — Phase 0, no dependencies, no approvals needed**

1. Set `http_user_agent` / `http_referer` to a Plotlines string with a contact URL, at sidecar
   startup. *(§5.1 — do this first, today.)*
2. Move `configure_overpass_cache` to startup; verify nothing writes to `./cache` any more, and
   delete the stray `service/cache/` and `cache/` directories. *(§5.2)*
3. Write the candidate disk cache into `CacheLayout.candidate_set()`. *(§5.3)*
4. Re-enable `overpass_rate_limit` on failover; add the cheap connect probe. *(§5.4 — closes #240)*
5. Add the settle window and supersede-in-flight on the accepted-bbox edge. *(§5.5 — closes #238)*
6. Add the failure cooldown and cap. *(§5.6 — closes #238)*
7. Add the empty-area error type and its message contract test. *(§5.7 — closes #239)*
8. Audit `/geocode` against Nominatim's usage policy. *(§5.8)*
9. Add regression tests for 4–7 in `core/tests/test_graph_regions.py`.
9a. Bring the routing graph under `assert_about_attribution_complete` as a static obligation —
    it is in neither half of the gate today, and its ODbL credit is currently inherited from the
    basemap by accident. *(L6, 3b — filed as #269, pulled forward from Phase 3+)*

**Next — Phase 1, the mirror** *(epic #264; the §12 answers are applied here)*

10. Fit the NVMe to the Pi 5; confirm it is the boot/data device, not SD. *(§6.2)*
11. Install Caddy; create `/srv/plotlines-mirror` with the §6.3 layout, **including
    `COPYRIGHT.txt` and the ODbL notices** — the tree must be portable to object storage
    unchanged. *(§6.3, 1a, Q6)*
12. Write the §6.4 Caddyfile — `http://` prefix, no `encode`, immutable cache headers.
13. Copy `spikes/SPIKE-14/tiles/wnc-corridor.pmtiles` in **under its own honest build id**, record
    its covered regions in `MIRROR_STATE.json`, and verify a byte-range read works end to end via
    `tiles/extract.py:http_range_source`. *(§6.3, 1b)*
14. Verify `index-v1.json`'s licence before mirroring it; if unclear, derive covering-set geometry
    ourselves instead. *(1a / L4 — resolved 2026-09-06: Geofabrik's stated Open Data policy
    covers it; mirrored with notice. See the addendum's L4 correction and issue #259.)*
15. Pull the first state extract from Geofabrik through a client that is **≤daily, conditional,
    identified and backs off** — not a bare cron. Verify the `.md5`. *(§6.6, 1c)*
16. Point the sidecar at it with `--tiles-upstream` + `--allow-unmirrored-tiles`; confirm a region
    build works against the Pi.
17. Add the local DNS record for `tiles.plotlines.app`; re-run 16 **without** the flag and confirm
    `classify_upstream` returns `MIRROR`. *(§6.5)*
18. Write `MIRROR_STATE.json`; report mirror age on the sidecar's per-layer `/health`; put the pin
    bump on the release checklist with a named owner. *(§6.6, Q2)*
19. Stand up the **mirror-side clip endpoint** — bbox in, clipped `.osm.pbf` out, pyosmium API and
    no GPL binary — so SPIKE-I can measure the clip server-side. *(§6.7, Q1-C, L1)*
20. Decide and record whether the mirror is open or client-restricted once internet-reachable.
    *(§6.8, 1d)*
20a. Populate `Provenance` on every written payload and add the OSM source-pin field to
    `$defs/provenance` — it is declared and never constructed today, while the client already
    reads it. Agree the identifier format with 18. *(L7, 3a-i, Q2 — filed as #270)*

**Then — Phase 2, the spikes** *(epic #268)*

21. ~~File and run **SPIKE-I** (parity, tags, clip strategy, sizes), with its parity bands
    pre-registered and the clip measured **server-side**~~ — **run 2026-09-13, RESCOPE in the clip not
    the graph** (#265): transport-swap parity exact, pyrosm rejected, the clip 432–553 s / O(extract)
    and the two-extract path dead, both fixed same day (#375/#376) and re-measured live 2026-09-18
    (#402: ~102 s, residual #439). *(§7.1, 2b, 2c)*
22. ~~File and run **SPIKE-J** (freeze matrix)~~ — **run 2026-09-13/15, PARITY on all four targets** (#266). Much smaller than first
    drafted: Q1-C removes the client-side native clip dependency, so what remained was the reader, and
    it freezes everywhere at +3.4–4.5 MB. *(§7.2, 2a)*
23. ~~Confirm the §12 answers against the spike evidence — in particular whether offline
    bbox-editing forces Q1's D fallback, and Q6's egress arithmetic.~~ **Done — Q1 by #278
    (2026-09-17, item 24b below: C confirmed, D rejected on measurement, ARCH D62); Q6 by SPIKE-I
    §4 (~325× egress reduction — a rounding error, arithmetic discharged). The other four answers
    stand unchanged.**

23a. Generate the dependency notice bundle at freeze time — the software-licence counterpart to
    FR101's data-attribution gate, and where SPIKE-J's no-GPL-binary answer lives.
    *(L5, 2d — filed as #267)*

**After the spikes report — Phase 3** *(epic #272)*

23b. Carry the pin as a **mirror build id** and propagate it to exports — the remaining half of
    3a, gated on the extract path existing. `export/` references neither provenance nor
    attribution today. *(L7, 3a-ii — filed as #277)*

24. Build the bbox → mirror-clip → build path behind FR121 capability reporting. *(§8 — filed as
    **#273** the fourth `CacheLayout` payload, **#274** the extent-triggered download, **#275** the
    transport swap under `ensure_graph` / `OsmLayerProvider.fetch`)*
24a. Re-validate the osmnx-era calibrations — SPIKE-A's golden candidate sets, SPIKE-G's density
    model and its ~2,800-marker ceiling, the scoring weights, SPIKE-21's cue derivation. §11.1 says
    to budget for this; a node-count assertion does not catch it. *(§11.1 — filed as #276)*
24b. ~~Decide the offline bbox-edit posture on SPIKE-I's evidence: accept Q1-C as shipped, or take
    Q1's **D** fallback.~~ **Decided 2026-09-17: C confirmed, D rejected on measurement** — D's
    trigger fired (38–48% of offline edits unservable) but its mechanism costs 432–553 s /
    1.9–7.2 GB even server-side on the Pi mirror; taking it client-side would reopen L1 and
    #266's freeze matrix for no offline win. Recorded as ARCH **D62** and §6.7a's offline
    bbox-edit spec: nudge/grow already disable with reason via #274/#275's shipped capability
    reporting; a shrink's provisional-graph improvement is the decided target, filed as **#432**,
    not yet built. FR120's no-lost-anchor guarantee holds unconditionally either way.
    *(§6.7a, Q1 — #278)*

**Then — Phase 5, the policy gate** *(epic #283)*

25. Add the §10 policy gate and Q5's mechanical caps. *(§10, P4 — filed as **#284** the
    third-party-host refusal, **#285** the capped live-refresh affordance and its four numbers.
    §10's other two gates already shipped in Phase 0 as #251.)*
25a. Give back: an "improve this in OSM" hand-off, and the OSMF/Geofabrik sponsorship decision.
    *(§10 closing — filed as #286)*
26. ~~Revisit ARCH **A23** / **A23a** and Punchlist **2A.3** — mark local extracts measured, and
    record the decision as a new ARCH **D**-number, plus the doc amendments owed by #269, #270 and
    §12.~~ **Done 2026-09-17 (#287).** A23 restated with SPIKE-I's measured clip cost and its
    same-day fix (#375/#376), re-rated HIGH → MEDIUM — #402 then re-measured the fix live 2026-09-18
    (617 s → ~102 s, still over band, residual #439; A23 stays Medium on that); A23a
    revisited — the `osmnx` defects are unpatched, only their exposure shrank. Recorded as ARCH
    **D63**. Punchlist 2A.3 ticked. §12.2/§13.4's attribution wording (#269) and §8's payload-pin
    note (#270) confirmed landed; ARCH §12's stale "heavier query" claim corrected and pointed at
    this document instead of restating it. Both review documents carry the execution record above.

**When web is on the table — Phase 4** *(epic #279)*

27. Phase 4 (hosted clip) inherits §6.7's endpoint rather than starting from nothing; its
    concurrency profile is still a named measurement. *(§9 — filed as **#280** the hosted clip,
    **#281** the concurrency measurement, **#282** binding the licensing position to the served
    surface per L2)*
