# OSM Data Acquisition — Review and Plan

**Date:** 2026-09-02, revised 2026-09-03 · **Branch at review:** `fix/232-overpass-status-failover`
**Scope:** how Plotlines acquires OSM data for the routing graph, curation candidates, and geocoding
**Status:** **accepted 2026-09-03; fully filed 2026-09-03.** Phase 0 is #241–#253 + #269 under epic **#254**;
Phase 1 is #255–#263 + #270 under epic **#264**; Phase 2 is #265–#267 under epic **#268**; Phase 3 is
#273–#278 under epic **#272**; Phase 4 is #280–#282 under epic **#279**; Phase 5 is #284–#287 under
epic **#283**. Every numbered checklist item in §13 now has an issue behind it. The six §12 open questions
are **answered** — see §12; the answers change §6, and those changes are folded in below rather than left
as an appendix.
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
  basemap/protomaps/20250101/planet.pmtiles             # matches MIRROR_ARCHIVE_URL exactly
  basemap/protomaps/20250101-wnc/corridor.pmtiles       # 1b: the SPIKE-14 stand-in, honestly named
  osm/COPYRIGHT.txt                                     # © OpenStreetMap contributors, ODbL 1.0
  osm/geofabrik/2026-09-01/index-v1.json                # only if its own licence checks out — 1a
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
  need rather than re-serving their index.
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

The clip's cost profile — CPU, disk IO, and behaviour under concurrency — is exactly what §9 says
Phase 3 does *not* prove for free. Rehearsing it here is how that stops being a surprise.

### 6.8 Reachability: open or client-restricted *(1d)*

Decide before the mirror is internet-reachable, not after. An open mirror is legal and makes us an
unintentional public extract service on our own bandwidth; a restricted one needs a client
identification story that does not become an auth system. Either answer is defensible; leaving it
undecided until the first traffic bill is not.

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

**7.2 SPIKE-J — packaging the native dependency** *(the distribution spike)* — **#266**

PyInstaller freeze survival for pyosmium/pyrosm on **all four targets**: Linux, macOS x86,
macOS arm, Windows. Risk **A5**. See §11.2 — this is the item most likely to consume a week
unexpectedly, and it is independent of 7.1, so it can run in parallel.

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

**11.2 The native dependency lands on risk A5.** pyosmium is a C++ extension (libosmium, protozero,
expat, bz2), needed frozen on four targets. Native extensions are where cross-platform freezes
break, and A5 already flags 150–300 MB per platform stacking on offline packages.

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

## 12. Open questions — **answered 2026-09-03**

The six questions this document opened are decided. Options and trade-offs are laid out in the
[licensing addendum](Plotlines_OSM_Acquisition_Review_Licensing_Addendum.md) §5; the answers below
are the addendum's recommendations, adopted as written.

| | Question | **Decision** | Consequence |
|---|---|---|---|
| **Q1** | Extract granularity | **C — mirror-side clip to the trip bbox**, with **D** (mirror states *and* serve clips) as the stated fallback if offline bbox-editing turns out to matter | The client never sees a region extract. Dissolves Q3, removes the client-side native dependency and the GPL question (L1). §6.7 |
| **Q2** | Pin cadence and ownership | **B — monthly pin, named owner, release-checklist gate**, with **C's monitoring built anyway** | `MIRROR_STATE.json` + mirror age on the sidecar's per-layer `/health`. §6.6 |
| **Q3** | Where the covering-set merge happens | **Dissolved by Q1-C** — there is no covering set and no merge | The way-deduplicating merge never lands on the client, which was the plan's hardest correctness surface (§11.7) |
| **Q4** | ODbL redistribution sign-off | **A — write `docs/Plotlines_Licensing_Position.md`**, decide against the OSMF community guidelines, record as an ARCH D-number | Filed as **#253**, in **Phase 0** — not a Phase 3 gate, because share-alike is already implicated by today's sharing surfaces (addendum L2) |
| **Q5** | Keep the interactive Overpass affordance | **A — keep public instances, hard-capped**, budget named as ours to spend | The caps are mechanical (addendum P4): bbox area below `max_query_area_size` so it can never subdivide, concurrency 1, a per-day budget that fails closed with an honest message, no automatic retry. Phase 5 |
| **Q6** | Egress budget when web lands | **D + C — clip server-side, put remaining bulk on zero-egress object storage** | Egress drops by roughly the ratio of bbox area to region area. §6.3's layout must stay a bucket layout (§6.0) |

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
    ourselves instead. *(1a / L4)*
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

21. ~~File~~ and run **SPIKE-I** (parity, tags, clip strategy, sizes), with its parity bands
    pre-registered and the clip measured **server-side**. *(§7.1, 2b, 2c — filed as #265)*
22. ~~File~~ and run **SPIKE-J** (freeze matrix) — **filed as #266**, in parallel with 21, and much smaller than first
    drafted: Q1-C removes the client-side native clip dependency, so what remains is whatever the
    frozen client still needs. *(§7.2, 2a)*
23. Confirm the §12 answers against the spike evidence — in particular whether offline
    bbox-editing forces Q1's D fallback, and Q6's egress arithmetic.

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
24b. Decide the offline bbox-edit posture on SPIKE-I's evidence: accept Q1-C as shipped, or take
    Q1's **D** fallback. Shaped as fix-or-record, like #250. *(§6.7, Q1 — filed as #278)*

**Then — Phase 5, the policy gate** *(epic #283)*

25. Add the §10 policy gate and Q5's mechanical caps. *(§10, P4 — filed as **#284** the
    third-party-host refusal, **#285** the capped live-refresh affordance and its four numbers.
    §10's other two gates already shipped in Phase 0 as #251.)*
25a. Give back: an "improve this in OSM" hand-off, and the OSMF/Geofabrik sponsorship decision.
    *(§10 closing — filed as #286)*
26. Revisit ARCH **A23** / **A23a** and Punchlist **2A.3** — mark local extracts measured, and
    record the decision as a new ARCH **D**-number, plus the doc amendments owed by #269, #270 and
    §12. *(filed as #287)*

**When web is on the table — Phase 4** *(epic #279)*

27. Phase 4 (hosted clip) inherits §6.7's endpoint rather than starting from nothing; its
    concurrency profile is still a named measurement. *(§9 — filed as **#280** the hosted clip,
    **#281** the concurrency measurement, **#282** binding the licensing position to the served
    surface per L2)*
