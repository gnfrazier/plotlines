# SPIKE-H — LayerProvider contract validation at Leg 2.5

**Run:** 2026-08-28 · **Issue:** [#160](https://github.com/gnfrazier/plotlines/issues/160)
**Covers:** PRD **FR100**, FR101, FR97, FR98, FR105 · stories **N3** [MVP], **N5** [P1] · ARCH §14.1/§14.2 (breaking **B4**), **D47**, **Q8**

---

## Verdict

**The contract as specified in §14.2 holds — for the built-in OSM layers and two real, unlike external sources — but only after one change that belongs at the extension point, not in the plugin.**

SPIKE-D (#159) found that `core/plotlines_core/curation/providers.py` ships a reduced `LayerProvider` (a bare `licence: str`, `fetch(bbox, layers) -> list[RawFeature]`) rather than ARCH §14.2's `licence -> LayerLicence`, `taxonomy -> TypeTaxonomy`, `fetch_candidates(bbox) -> list[Candidate]`, `load_state() -> LayerLoadState`. This spike built the second shape (`spikes/SPIKE-H/contract.py`) and tested it against:

- **the built-in OSM taxonomy**, wrapped around the real `OsmLayerProvider.fetch` and the real `taxonomy.TAXONOMY` (no reimplementation);
- **NPS Public Points of Interest** (`mapservices.nps.gov`, ArcGIS MapServer REST, point geometry, keyless, federal) — real, live, loadable;
- **NC Highway Historical Markers** (`gis2.ncdcr.gov`, ArcGIS MapServer REST, point geometry) — real, live, **blocked by the licence gate**;
- **US Scenic Byways, NC layer** (`geo.dot.gov`, ArcGIS MapServer REST, polyline/route geometry, federal) — real, live, loadable, deliberately exercising the geometry question rather than co-location.

| # | Question | Result |
|---|---|---|
| 1 | Built-in OSM as `LayerProvider`, no privileged path? | **Yes, with one bend recorded** — see §1. |
| 2 | One unlike plugin against the *unchanged* protocol? | **Yes — two of them, live**, plus the licence-blocked third. See §2. |
| 3 | Point *and* area geometry in one call? | **No.** `Candidate` has no geometry field at all — not even the scalar `area_m2` `RawFeature` briefly carries survives past scoring. A 40 km, 1,457-vertex byway and a single lat/lon pin are the same shape once they reach a `Candidate`. See §3. |
| 4 | Affinity makes co-location generic, no core change? | **Yes, and this is the strongest result.** A real NPS POI type, scored by its own taxonomy inside its own provider, merges with real OSM candidates in `analyze_colocation` untouched — **14 mixed-source proposals**, two carrying the `station` affinity from a real `Mile Marker` type. See §4. |
| 5 | Licence gate enforced? | **Yes — and it blocked a real source**, not a synthetic one. NC Highway Historical Markers publishes no licence/credit anywhere in its own service metadata (verified live); the registry never queries it. See §5. |
| 6 | Per-layer load state, incl. a real failure? | **Yes.** A real 3 s network delay reported as `loading`, then `ready`; a real nonexistent ArcGIS layer id reported `failed:RuntimeError: ... 404 Layer not found`, with every other layer unaffected. See §6. |
| 7 | Q8 input-half — packaging/distribution? | Recommendation given — see §7. |

**The one required fix is at the extension point, and §14.4 permits it.** `notability.score_notability(features, live_layers)` matches every feature against one module-level `TAXONOMY` tuple — fine for a single built-in source, but a plugin's own types can only be scored if either its rows are merged into that global tuple (a core-code edit, once per plugin — exactly what §14.4 forbids) or scoring is parameterised on a taxonomy the caller supplies. `fetch_candidates(bbox) -> list[Candidate]`'s own signature says the latter: a provider scores against *its own* taxonomy and returns finished candidates. `contract.score_with_taxonomy` in this spike is `score_notability`'s matching logic with that one change — built once, used by every provider including the built-in ones, never touched again when a new plugin loads. That is the extension point being fixed, not a special case being added.

---

## 1. Built-in OSM as `LayerProvider`

`spikes/SPIKE-H/osm_layer_provider.py` wraps the real `OsmLayerProvider.fetch` and the real `TAXONOMY`. Reading SPIKE-D's committed `spikes/SPIKE-D/raw/trip-all.json.gz` (TRIP bbox, Grandfather Mountain/Linville — extraction itself is SPIKE-D's question, already answered, and re-querying the same bbox against public Overpass days later would repeat exactly the A23 risk that spike's own results warn about):

| Layer | Taxonomy rows | Candidates |
|---|---:|---:|
| amenity | 12 | 90 |
| historic | 2 | 10 |
| leisure | 2 | 22 |
| man_made | 4 | 2 |
| natural | 3 | 95 |
| sight | 4 | 71 |
| **total** | | **290** |

**Where it bent — one real tension, not a defect.** §14.2's `fetch_candidates(self, bbox)` takes no `layers` argument, so read literally, "the built-in layers must be expressed as `LayerProvider` implementations" (§14.2) means six instances, one per ARCH layer. But `OsmLayerProvider.fetch` is one Overpass network call regardless of how many layers are requested in the same call — six separate instances each calling `fetch` independently would turn one query into six. The adapter resolves this with `SharedOsmFetch`: one bbox → one underlying fetch, shared by all six sibling instances, each still satisfying the protocol on its own (its own `taxonomy` slice, its own `fetch_candidates`). **This is the cheapest possible negative result the issue asked §1 to look for**: the per-instance shape is right for a plugin (one dataset, one provider), and slightly wrong for a batched built-in source that the shape was implicitly modelled on — a real plugin author would not hit this, because a real plugin is one dataset, not six sharing a private batch API.

## 2. A real, unlike plugin against the unchanged protocol

Three real ArcGIS MapServer REST sources, chosen for heterogeneity (state vs. federal, point vs. polyline, credited vs. uncredited), queried live 2026-08-28:

| Source | Geometry | Records (TRIP or TOUR) | Licence | Outcome |
|---|---|---:|---|---|
| NPS Public Points of Interest | point | 97 raw → 82 candidates | `US-PD-Fed`, satisfiable | **loaded** |
| NC Highway Historical Markers | point | 4 | none declared | **blocked** (§5) |
| US Scenic Byways (NC) | polyline | 14 raw → 10 candidates | `US-PD-Fed`, satisfiable | **loaded**, geometry lost (§3) |

Neither loadable source required a single line of `core/` code. NPS's 97 raw POIs span 12 `POITYPE` values; this spike's taxonomy (`nps_pois_provider.py`) covers 9 of them (Waterfall, Overlook, Peak, Bridge, Mountain Pass, Visitor Center, Campground, Picnic Area, Mile Marker → `station`), leaving `Gate`/`Parking Lot` unmatched by choice (the same "not every value earns a row" discipline `taxonomy.py` already applies to OSM) and 3 `Hospital`-tagged records unmatched by necessity — there is no hospital on the Blue Ridge Parkway; it is the source's own tagging error, not a Plotlines qualification question, and it fell out for free rather than needing a gate.

## 3. Is area/route geometry first-class?

**No — tested directly against the ARCH §14.2/D37 claim, not repeated.** ARCH states `ShapeDataProvider` "is the reason area support is an extension rather than a rewrite." `ShapeDataProvider` is declared in `core/plotlines_core/providers/__init__.py` and has **zero implementations anywhere in the codebase.** More to the point, the data shapes `fetch_candidates` actually returns cannot receive one:

- `RawFeature.coord` is a single `(lon, lat)` point. `RawFeature.area_m2` is a **scalar**, used once, by `leisure=park`'s FR98(b) qualification gate — it answers "is this polygon big enough," never "what is its boundary."
- `Candidate` — what `fetch_candidates` actually returns — has **no area field of any kind**. Not even the scalar survives scoring. `feature_from_geometry` computes `area_m2` from a real Shapely polygon and then, three calls later, it is gone.
- **149 of 429** raw OSM features in the TRIP bbox carry a real `area_m2` (parks, water bodies, building footprints). None of that reaches a `Candidate`.
- The Scenic Byways provider queried 10 real routes carrying **9,961 real vertices and 781 km of path length**. `feature_from_geometry`'s `geometry.centroid` call does not raise on a `LineString` — it happily returns one point — so a 40+ km byway becomes indistinguishable from a single pin, silently. `USScenicBywaysProvider` reports the discarded vertex/length data in `tags` purely so this spike could measure the loss; nothing downstream reads it, and `tags: dict[str, str]` is not a geometry channel by any reasonable reading.

**"Point and area geometry in one call" is true only in the weakest sense** — a single `fetch_candidates` response can contain a mix of point-derived and polygon-derived candidates (OSM already does this every call) — and **false in the sense ARCH D37 actually needs**: FR108's rest-day-on-a-polygon and area-entry triggers require the boundary itself to survive to something a route/trigger engine can read, and today nothing does. This is a gap between the *provider* protocol (`ShapeDataProvider`'s protocol declaration) and the *data* protocol (`Candidate`), not a gap in `ShapeDataProvider` itself.

## 4. Affinity-driven co-location, no core change — with real data

D47/SPIKE-B (#169) already proved this at the `Candidate` level with a synthetic plugin taxonomy (`battlefield`/`manor_house`/`crag` → `narrative`/`station`, `core/tests/test_curation_colocate.py`). This spike proves the same claim **one layer down, through a real provider's own `taxonomy` and `fetch_candidates`**, merged with real OSM output:

- **372 candidates** (290 OSM + 82 NPS), **30 cluster proposals**, **zero changes to `colocate.py`** — it only ever reads `Candidate.role_affinity`, which is exactly why this works.
- **14 of 30 proposals mix an NPS candidate with a non-NPS one** — real duplicate-and-adjacent detection across sources for the same physical places: *Boulder Field Overlook*, *Yonahlossee Overlook*, *Grandfather Mountain Overlook* each pair an OSM `tourism=viewpoint` with the NPS POI for the same overlook.
- **2 proposals carry the `station` affinity**, from real `Mile Marker` records — *Bear Den Falls* (an OSM viewpoint + two NPS POIs + a mile marker → `narrative+station`) and *Lost Cove Cliffs Overlook (MP 310)*. D47 names `station` as the affinity that "gives the station role its first path from analysis, which the recipe form never had" — this is that path exercised with a real type from a real, unrelated dataset, not the worked example.

**A finding worth flagging, not fixing here:** the OSM/NPS pairs above are the *same physical overlook* reported by two sources as two candidates. Co-location currently treats that as a correct 2-member cluster (which, spatially, it is) rather than a duplicate to merge. FR102-FR105a describe clustering, not deduplication, so this is in scope — just outside what this spike was asked to test.

## 5. Licence gate — real sources

Verified live, 2026-08-28: `NC_Highway_Historical_Markers`'s own `MapServer?f=json` reports `copyrightText: ""`; its `documentInfo.Author` is empty; its layer-0 `info/metadata` XML's `dataIdInfo/resConst/Consts/useLimit` is empty. Nothing in the service — the only channel this spike had — states redistribution terms. NC's public-records statute (G.S. Ch. 132) governs *access*, which is not the same question. `NCHighwayMarkersProvider.licence.satisfiable` is honestly `False`, and `LayerRegistry.register_plugin` never calls it:

```
plugin_nc_markers        failed:licence_unsatisfiable
plugin_nps_pois          ready
```

The gate runs **at registration**, from `provider.licence`, before `load_state()` or any query — D45's requirement, and the reason the four NC markers this spike fetched directly (§2, for the mechanism test) never reach the registry-mediated pipeline a real Author's session would use.

**A second finding:** neither of the two *loadable* real sources publishes a machine-readable licence field either — `NPS_Public_POIs` happens to carry a `copyrightText` string that doubles as attribution, and Scenic Byways carries none at all (its `LayerLicence` in this spike asserts 17 U.S.C. §105 and the publisher's identity, not anything read off the response). **A `LayerLicence` is authored metadata, not derived data, for every real-world source this spike tried** — which matches how `core/plotlines_core/curation/providers.py:OsmLayerProvider.licence` already works today (a hardcoded `"ODbL"` string, not anything read from Overpass). FR101's gate is doing real work regardless — it is what turned "the publisher said nothing" into a refusal instead of a guess.

## 6. Per-layer load state

`spikes/SPIKE-H/registry.py` (adapted from SPIKE-D's `plugin_layers.py:LayerRegistry` to the real protocol) exercised against two real cases:

- **Slow:** a real 3.29 s network fetch (`delay_s=3.0`, first live run — a warm re-run reads the cache and completes in effectively 0 s, correctly, since only an actual fetch should pay the simulated latency) reports `loading` for its duration and `ready` on completion, without touching any other layer's state.
- **Broken:** pointing `NPS_Public_POIs`'s provider at layer id 99 — a real ArcGIS layer id, off by one class, that does not exist on that MapServer — produces a genuine upstream response (`404 Layer not found`), which `fetch_candidates_all` catches, subtracts, and reports:
  ```
  plugin_nps_broken   failed:RuntimeError: ArcGIS error querying nps_broken_layer_demo
                       (.../NPS_Public_POIs/MapServer/99/query): 404 Layer not found
  ```
  Every built-in and the other plugin layer stayed `ready` throughout — N2's "one plugin layer failing never blocks the others" held, against a real failure rather than a raised `Exception("boom")`.

This is the same shape SPIKE-D's `plugin_layers.py` demonstrated with stub providers; this spike's contribution is running it against a real, non-cooperative upstream (an ArcGIS server returning a normal error body over HTTP 200, which `arcgis_common.cached_get` has to read out of the JSON rather than trust the status code for) instead of a `raise` statement written to look like one.

## 7. Q8, input half — packaging and distribution

**Recommendation: a plugin data layer ships as an ordinary installable Python package, discovered via `importlib.metadata` entry points, never fetched or exec'd at runtime.**

- **Distribution mechanism:** a standard wheel/sdist installed into the same environment as `plotlines-core` (pip/uv, exactly as `plotlines-core`'s own dependencies are installed) — not a URL the app downloads and imports itself. Runtime dynamic-code-fetch is a P7 ("external resources are borrowed, never trusted as infrastructure") and supply-chain problem the moment it exists; installing a package is a decision a human or a deployment pipeline makes once, auditable the same way any other dependency is.
- **Discovery:** an entry-point group (e.g. `plotlines.layer_providers`), each entry resolving to a `LayerProvider`-shaped object. No base class to subclass — the protocol is structural (as it already is in ARCH), so a plugin package's only obligation is to expose something with the four members, which keeps a plugin author from needing to import anything from `plotlines-core` beyond the data types (`BBox`, `Candidate`, `RawFeature`) it already has to produce.
- **Licence is authored in the package, at install time, not derived at runtime.** §5's finding — that real sources rarely self-declare a machine-readable licence — means `LayerLicence` has to be something a human writes into the plugin, the same way this spike had to write one for all three real sources tested. The registration gate (D45) is what makes an honest, empty declaration safe rather than a guess.
- **Versioning:** pin like any other dependency in the deployment's lockfile; surface the installed plugin's own version string through `/health`'s per-layer detail (the same discipline A8 already applies to core/sidecar version mismatch), so a stale plugin is visible rather than silently different from what an Author expects.
- **Credentials:** a keyed source (the NPS Data API, not tested live here — no key available in this environment, see Left open) resolves its own key from its own config/env var. Core has no generic credential-storage concept to build for this, which is consistent with P3 ("server-side state is exceptional and enumerable") — a plugin's key is the plugin's problem, not a new core surface.

---

## Deliverables

- `spikes/SPIKE-H/` — `contract.py` (the reconciled `LayerProvider`, `LayerLicence`, `LayerLoadState`, `score_with_taxonomy`), `osm_layer_provider.py`, `arcgis_common.py`, `nc_markers_provider.py`, `nps_pois_provider.py`, `scenic_byways_provider.py`, `registry.py`, `run_spike.py`
- `spikes/SPIKE-H/raw/*.json.gz` — committed, real ArcGIS REST responses (152 KB total), so a re-run never re-queries `gis2.ncdcr.gov` / `mapservices.nps.gov` / `geo.dot.gov`
- `spikes/SPIKE-H/results/RESULTS.md`, `results/run_spike.json`
- `docs/Plotlines_Research_Spikes.md` — SPIKE-H entry
- **No product code changed** — same discipline as SPIKE-D: this is a second spike-local prototype of the corrected contract, not a patch to `core/`. Suites untouched: core/service tests not re-run by this spike, none of their inputs changed.

### Doc edits this implies — *not made here*

1. **ARCH §14.2** — should state explicitly that a `LayerProvider`'s `taxonomy` is consulted by its *own* `fetch_candidates`, not merged into a shared table; §14.2's prose already implies this (`fetch_candidates(bbox) -> list[Candidate]`, already scored) but does not say it, which is exactly the ambiguity `core/plotlines_core/curation/providers.py` resolved the wrong way.
2. **ARCH D37 / the `ShapeDataProvider` claim (§14.2, "already existed and is the reason area support is an extension rather than a rewrite")** — needs a correction or a scoping note: the *provider-side* protocol existing is not the same claim as area geometry surviving into `Candidate`, and today it does not. FR108's polygon-entry triggers need a geometry-carrying path from provider to trigger engine that does not exist yet.
3. **PRD N2 / ARCH §8.3** — SPIKE-D already flagged the per-layer `/health` gap; this spike's `registry.py` is a second working prototype of the same shape, now validated against a real broken upstream rather than only stub providers.

### Left open, deliberately

1. **A keyed REST+JSON source (NPS Data API)** — issue #160 names it explicitly for on-device key handling. No API key was available in this environment (registration-gated, not anonymous). The `ArcGIS`-family sources tested are keyless by design, so key handling itself is untested; §7's recommendation (a plugin resolves its own key) is a design position, not a measurement.
2. **Deduplication across sources** — §4's finding that the same physical overlook produces two candidates from two providers is real and unaddressed; FR102-FR105a describe clustering, and whether a cluster of exactly two same-place candidates from different sources should promote differently than a genuine multi-feature cluster is a product question, not this spike's.
3. **A geometry-carrying path for `ShapeDataProvider`.** §3 establishes that none exists; designing one (a `Shape` type on `Candidate`, or a parallel `fetch_shapes` call whose output reaches triggers/export) is follow-on work, not scoped here.
4. **Package/entry-point mechanics beyond the recommendation.** §7 is a position, not a working `pyproject.toml` + entry-point demo; the three providers here are imported directly by `run_spike.py`; nothing in this spike exercises `importlib.metadata` discovery.
