"""LayerProvider — the extraction seam for candidate features (ARCH §14.2,
D40, D47). The built-in OSM layers live here, expressed *as* `LayerProvider`s
(ARCH §14.2's "proof of realness" test); a plugin's own `LayerProvider` ships
as its own installable package and is discovered via an entry point
(`plugins.discover_layer_providers`, FR100 — Leg 2.5's data-input contract).

**Reconciled with ARCH §14.2 for stories N2/N5 (2026-08-28).** The shipped
shape was a reduced `licence: str` + multi-layer `fetch(bbox, layers) ->
list[RawFeature]`; SPIKE-D (#159) found that a bare-list return leaves
per-layer state and per-layer failure with nowhere to live, which is the
direct cause of one bad layer 422-ing a whole extraction. SPIKE-H (#160)
validated the §14.2 shape below against the built-in OSM taxonomy and two
real external sources. `LayerRegistry` (`registry.py`) is what holds the
per-layer lifecycle on top.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Callable, Iterable, Protocol

from .notability import RULESET_VERSION, RawFeature, Shape, score_with_taxonomy
from .taxonomy import LAYERS, TAXONOMY, TypeRule, TypeTaxonomy

if TYPE_CHECKING:
    from ..cache_layout import CacheLayout

log = logging.getLogger("plotlines.curation.providers")

_EARTH_R_M = 6_371_000.0

# A layer's readiness lifecycle (ARCH §8.3, D48): a provider's own
# `load_state()` reports one of these; the registration-time licence gate
# (D45) is a separate registry-side refusal that can leave a layer `failed`
# even when its `load_state()` would honestly say `ready`.
PENDING, LOADING, READY, FAILED = "pending", "loading", "ready", "failed"


@dataclass(frozen=True)
class BBox:
    west: float
    south: float
    east: float
    north: float


@dataclass(frozen=True)
class LayerLicence:
    """FR101 / ARCH §12.2 / D45 — what a layer must declare before it is
    loadable. `id` and `attribution` are both required for `satisfiable`;
    a source that supplies neither is honestly unsatisfiable rather than
    guessed at, and the registry refuses to load it. `note` records where
    the value came from (the source's own metadata, or asserted by the
    integrator — the realistic case for most government REST sources, per
    SPIKE-H §5).

    A missing attribution on a *loaded* layer is a build failure, not a
    render-time warning — see `attribution.assert_attribution_complete`.
    """

    id: str = ""
    attribution: str = ""
    terms_url: str = ""
    note: str = ""

    @property
    def satisfiable(self) -> bool:
        return bool(self.id.strip()) and bool(self.attribution.strip())


@dataclass(frozen=True)
class LayerLoadState:
    """ARCH §8.3 / D48's per-layer readiness, returned by the provider
    itself. `progress` is observed fraction in 0..1 where the provider can
    report one; an honest range or elapsed-derived figure, never a fixed
    ETA (FR121 — acquisition runs ×2.96 slower while the Author works, so a
    constant estimate is wrong precisely when the Author is busiest)."""

    state: str = READY
    reason: str = ""
    progress: float | None = None

    def as_dict(self) -> dict:
        out: dict = {"state": self.state}
        if self.reason:
            out["reason"] = self.reason
        if self.progress is not None:
            out["progress"] = round(self.progress, 2)
        return out


class LayerProvider(Protocol):
    """ARCH §14.2 — what a curation data layer, built-in or plugin, must
    supply. Four members, structural (no base class to subclass):

    - `licence` — a `LayerLicence`, enforced at registration (D45/§12.2).
    - `taxonomy` — a `TypeTaxonomy` in which every type declares one primary
      role affinity and a salience weight (D47). This is what makes
      co-location analysis generic rather than recipe-driven: a plugin's
      types participate in clustering on the day they load, with no core
      change (ARCH §14.4).
    - `fetch_candidates(bbox)` — point *and* area geometry in one call,
      already notability-scored against this provider's own `taxonomy`
      (via `score_with_taxonomy`), returned as finished `Candidate`s.
    - `load_state()` — this layer's own readiness, so a large or remote
      dataset never blocks the workspace (§8.3, story N2).
    """

    @property
    def licence(self) -> LayerLicence: ...

    @property
    def taxonomy(self) -> TypeTaxonomy: ...

    def fetch_candidates(self, bbox: BBox) -> list["object"]: ...

    def load_state(self) -> LayerLoadState: ...


def osm_tags_for(layers: set[str]) -> dict[str, "bool | list[str]"]:
    """The `tags=` filter `osmnx.features_from_bbox` expects, derived from
    the taxonomy rather than hand-maintained separately from it. A wildcard
    rule (`historic=*`) asks Overpass for the whole key; a non-wildcard rule
    asks for its specific value alongside any sibling values already
    requested for that key.
    """
    tags: dict[str, object] = {}
    for rule in TAXONOMY:
        if rule.layer not in layers:
            continue
        if rule.is_wildcard:
            tags[rule.key] = True
            continue
        existing = tags.get(rule.key)
        if existing is True:
            continue  # a wildcard on this key already asks for everything
        values = set(existing) if isinstance(existing, (set, list)) else set()
        values.add(rule.value)
        tags[rule.key] = values
    return {k: (sorted(v) if isinstance(v, set) else v) for k, v in tags.items()}


def _approx_area_m2(geom, at_lat: float) -> float:
    """A rough equirectangular-projection area estimate — enough to clear
    FR98(b)'s area-threshold qualification check without pulling a
    projection library into this seam for one comparison against a round
    number (20,000 m^2). Not appropriate for anything precision-sensitive;
    `graph/loader.py`'s own haversine helpers are the pattern this follows
    for "good enough at MVP scale, cheap, no extra dependency."""
    import math

    lat_rad = math.radians(at_lat)
    m_per_deg_lat = math.pi * _EARTH_R_M / 180.0
    m_per_deg_lon = m_per_deg_lat * math.cos(lat_rad)
    minx, miny, maxx, maxy = geom.bounds
    # geom.area is in square degrees; rescale each axis to metres rather
    # than multiplying by a single squared scalar, since a degree of
    # longitude and a degree of latitude are not the same length.
    if (maxx - minx) <= 0 or (maxy - miny) <= 0:
        return 0.0
    return geom.area * m_per_deg_lon * m_per_deg_lat


def feature_from_geometry(feature_id: str, geometry, tags: dict[str, str]) -> RawFeature | None:
    """Pure conversion from a Shapely geometry + its OSM tags to a
    `RawFeature` — split out from `OsmLayerProvider.fetch` so it is
    unit-testable without a live Overpass call (mirrors how
    `graph/loader.py` keeps its geometry math free of the network/disk read
    that feeds it).
    """
    if geometry is None or geometry.is_empty:
        return None
    centroid = geometry.centroid
    coord = (centroid.x, centroid.y)
    area_m2 = None
    shape: Shape | None = None
    if geometry.geom_type in ("Polygon", "MultiPolygon"):
        area_m2 = _approx_area_m2(geometry, centroid.y)
        poly = geometry if geometry.geom_type == "Polygon" else max(
            geometry.geoms, key=lambda g: g.area)
        shape = Shape("polygon", tuple((float(x), float(y)) for x, y in poly.exterior.coords))
    elif geometry.geom_type in ("LineString", "LinearRing", "MultiLineString"):
        # Issue #403 / SPIKE-H §3: `geometry.centroid` does not raise on a
        # line, so a 40 km byway used to become one silent pin. Keep the
        # path, and pin it *on* the line — a U-shaped route's centroid can
        # sit kilometres off any part of it.
        line = _longest_merged_line(geometry)
        mid = line.interpolate(0.5, normalized=True)
        coord = (mid.x, mid.y)
        shape = Shape("line", tuple((float(x), float(y)) for x, y in line.coords))
    return RawFeature(id=feature_id, coord=coord, tags=tags, area_m2=area_m2, geometry=shape)


def _longest_merged_line(geometry):
    """One `LineString` for a line-shaped geometry. A `MultiLineString` is
    merged where its parts touch end-to-end (a byway split at county lines
    is one path, not several); if parts remain disjoint the longest is kept,
    mirroring the largest-polygon choice above rather than inventing a
    joining segment."""
    if geometry.geom_type != "MultiLineString":
        return geometry
    from shapely.ops import linemerge

    merged = linemerge(geometry)
    if merged.geom_type == "LineString":
        return merged
    return max(merged.geoms, key=lambda g: g.length)


#: ARCH §14.2's `LayerLicence` for the built-in OSM layers. Asserted by the
#: integrator (Overpass does not return a machine-readable licence field),
#: exactly as it was the bare string `"ODbL"` before this reconciliation.
OSM_LICENCE = LayerLicence(
    id="ODbL-1.0",
    attribution="© OpenStreetMap contributors",
    terms_url="https://www.openstreetmap.org/copyright",
    note="asserted by plotlines-core; Overpass returns no licence field.",
)


class CandidateFetchUnavailable(RuntimeError):
    """Overpass refused, errored, or was unreachable while `OsmLayerProvider`
    fetched this layer's candidates. Unlike `graph.regions.OverpassUnavailable`
    (issue #229), this is not backed by an endpoint list, retries, or
    failover — issue #250 / Phase 0.10 (Addendum G2, checklist 0d) decided
    the candidate path keeps single-endpoint, no-retry behaviour rather than
    duplicating `ensure_graph`'s failover loop onto a transport Phase 3
    (#272) deletes outright. What that decision still owes is an honest
    surface: like `OverpassUnavailable` and `NoRoutableWaysError`, this
    exception's `str()` is a finished, user-facing sentence, and
    `LayerRegistry.fetch_candidates_all` surfaces it verbatim rather than the
    generic `f"{type(exc).__name__}: {exc}"` raw-repr fallback it uses for
    every other provider exception — the same standard issue #248 set for
    the routing path."""


class OsmLayerProvider:
    """The batched OSM extraction engine for the six built-in layers. One
    call answers every layer asked for in the same `fetch`, so this is *not*
    one-provider-per-layer — `BuiltinOsmLayerProvider` below wraps it to
    satisfy §14.2's per-layer `LayerProvider` shape while the six siblings
    still share one round trip (`SharedOsmFetch`).

    `.licence` stays a bare `"ODbL"` string here for backward compatibility
    with callers that predate the reconciliation; `OSM_LICENCE` is the
    `LayerLicence` the registry path uses.

    **Issue #275 (Phase 3.3) — `cache_layout`.** When given, `fetch` first
    looks for an already-fetched mirror clip covering `bbox`
    (`graph.extract_fetch.find_reusable_extract` against
    `cache_layout.root` — the same file `graph.extract_fetch.ensure_extract`,
    issue #274, wrote, and the one `graph.regions.ensure_graph` also reads:
    one clip fetch, two readers, never two fetches for one bbox) and, when
    found, reads candidates from it with no network call at all. With no
    `cache_layout`, or no clip yet cached for this bbox, `fetch` falls back
    to the pre-#275 live Overpass call below, unchanged.
    """

    licence = "ODbL"

    def __init__(self, cache_layout: "CacheLayout | None" = None) -> None:
        self._cache_layout = cache_layout

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        tags = osm_tags_for(layers)
        if not tags:
            return []

        if self._cache_layout is not None:
            from ..graph.extract_fetch import find_reusable_extract

            bbox_tuple = (bbox.west, bbox.south, bbox.east, bbox.north)
            clip_path = find_reusable_extract(bbox_tuple, self._cache_layout.root)
            if clip_path is not None:
                return self._fetch_from_local_clip(clip_path, bbox_tuple, tags)

        import osmnx as ox
        import requests

        from ..osm_identity import (
            OVERPASS_LOCK_TIMEOUT_S,
            OverpassSettingsBusy,
            apply_osm_http_identity,
            overpass_settings,
        )

        # Issue #241 / review §3.4: the candidate path must not query Overpass
        # as osmnx's stock UA either. A headless entrypoint already stamps the
        # build version; this is the floor for a caller that reaches curation
        # without importing `graph.regions`.
        apply_osm_http_identity()

        # Issue #244 / licensing addendum G1: `overpass_url` and
        # `overpass_rate_limit` are process-global and `graph/regions.py`
        # drives them per endpoint during a routing-graph failover. Hold
        # `OSM_SETTINGS_LOCK` for this call (passing no `url`/`rate_limit`, so
        # it runs on the configured default endpoint and posture) rather than
        # racing a concurrent build's mutated globals on a FastAPI threadpool
        # sibling.
        #
        # Issue #250 / Phase 0.10 — decided **accepted, not fixed**: this call
        # stays single-endpoint with no retry and no failover, unlike
        # `graph.regions.ensure_graph`'s endpoint-list loop (#229/#232/#245).
        # The review's own consumer table already named this gap; building a
        # second failover implementation onto a transport the extract
        # migration (Phase 3, #272) removes entirely is effort spent on a
        # path with no future, and one implementation living in
        # `graph/regions.py` is worth more than two half-maintained copies.
        # Expiry condition: the day this module no longer imports `osmnx` (the
        # transport swap lands), this comment and `CandidateFetchUnavailable`
        # both go with it. Until then the honest half of the decision still
        # applies below — an Overpass failure here must read as a finished
        # sentence, never a raw exception repr (issue #248's standard).
        #
        # Issue #490 — `timeout=OVERPASS_LOCK_TIMEOUT_S` bounds the wait for
        # the lock itself: without it, a region build holding the lock for
        # the length of its own attempt (or longer, if osmnx is stuck inside
        # it) left this call waiting with no bound of its own, wedging every
        # `/candidates` request behind a build that might never finish.
        try:
            with overpass_settings(timeout=OVERPASS_LOCK_TIMEOUT_S):
                try:
                    gdf = ox.features_from_bbox(
                        (bbox.west, bbox.south, bbox.east, bbox.north), tags)
                except ox._errors.InsufficientResponseError:
                    # A 200 with zero elements is a true answer about this
                    # bbox/layer — no such feature here — not an outage
                    # (mirrors #248's NoRoutableWaysError distinction on the
                    # graph path).
                    return []
                except (requests.exceptions.RequestException,
                        ox._errors.ResponseStatusCodeError) as exc:
                    raise CandidateFetchUnavailable(
                        "the map-data service didn't answer for this layer — "
                        "try again in a moment, or narrow the trip area."
                    ) from exc
        except OverpassSettingsBusy as exc:
            raise CandidateFetchUnavailable(
                "the map-data service is busy with another request right "
                "now — try again in a moment, or narrow the trip area."
            ) from exc
        return [f for f in self._features_from_gdf(gdf) if f is not None]

    def _fetch_from_local_clip(
        self, clip_path: "Path", bbox_tuple: tuple[float, float, float, float],
        tags: dict,
    ) -> list[RawFeature]:
        """Issue #275: candidates from an already-clipped `.osm.pbf`, no
        network call. `clip_path` is converted to OSM XML (one pyosmium copy
        pass — `osmnx.features_from_xml` reads only that format, not `.pbf`
        directly) and handed to `osmnx.features_from_xml(..., polygon=...,
        tags=...)`, which calls the exact same internal `_create_gdf(...)`
        `features_from_bbox` calls for a live Overpass query — so the tag
        filter and the bbox-polygon clip behave identically to the transport
        this replaces, the same "swap the download, keep osmnx's own
        pipeline" discipline `graph.pbf_source` uses for the routing graph.
        """
        import os
        import tempfile
        from pathlib import Path

        import osmium
        import osmnx as ox
        from osmnx import utils_geo

        class _Copier(osmium.SimpleHandler):
            def __init__(self, writer) -> None:
                super().__init__()
                self._writer = writer

            def node(self, n) -> None:
                self._writer.add_node(n)

            def way(self, w) -> None:
                self._writer.add_way(w)

            def relation(self, r) -> None:
                self._writer.add_relation(r)

        fd, xml_name = tempfile.mkstemp(suffix=".osm")
        os.close(fd)
        xml_path = Path(xml_name)
        xml_path.unlink()  # osmium refuses to write over an existing file
        try:
            with osmium.SimpleWriter(str(xml_path)) as writer:
                _Copier(writer).apply_file(str(clip_path), locations=True)
            polygon = utils_geo.bbox_to_poly(bbox_tuple)
            try:
                gdf = ox.features_from_xml(str(xml_path), polygon=polygon, tags=tags)
            except ox._errors.InsufficientResponseError:
                # No feature in the clip matches `tags` — a true answer about
                # this bbox/layer, not an outage, exactly like the Overpass
                # branch's own `InsufficientResponseError` handling above.
                return []
        finally:
            xml_path.unlink(missing_ok=True)
        return [f for f in self._features_from_gdf(gdf) if f is not None]

    @staticmethod
    def _features_from_gdf(gdf) -> Iterable[RawFeature | None]:
        for idx, row in gdf.iterrows():
            feature_id = "/".join(str(p) for p in (idx if isinstance(idx, tuple) else (idx,)))
            tags = {
                str(k): str(v) for k, v in row.items()
                if k != "geometry" and v is not None and str(v) != "nan"
            }
            yield feature_from_geometry(feature_id, row.geometry, tags)


def _layer_set_version() -> str:
    """A short hash of the built-in OSM layer set *and* the Overpass tag
    filter it generates. This is ARCH §4.2's `layer_set_version` half of the
    candidate cache key: a persisted raw extract is stale the moment the set
    of layers, or the tags any of them selects, changes — even if
    `RULESET_VERSION` (which versions the *scores*) was not bumped in the
    same edit. Derived rather than hand-maintained so it cannot drift from
    `TAXONOMY`.
    """
    payload = json.dumps(
        {"layers": sorted(LAYERS), "tags": osm_tags_for(set(LAYERS))},
        sort_keys=True,
    )
    return hashlib.sha1(payload.encode()).hexdigest()[:12]


LAYER_SET_VERSION = _layer_set_version()


def _raw_feature_to_json(f: RawFeature) -> dict:
    return {
        "id": f.id,
        "coord": [f.coord[0], f.coord[1]],
        "tags": dict(f.tags),
        "area_m2": f.area_m2,
        "geometry": f.geometry.to_geojson() if f.geometry is not None else None,
    }


def _raw_feature_from_json(d: dict) -> RawFeature:
    geom = d.get("geometry")
    if isinstance(geom, list):
        # Entries written before #403 stored a bare exterior ring; a polygon
        # was the only kind that ever reached disk, so read it as one rather
        # than paying a cold re-fetch for a cache the key still matches.
        geom = {"type": "Polygon", "coordinates": [geom]}
    lon, lat = d["coord"]
    return RawFeature(
        id=d["id"],
        coord=(float(lon), float(lat)),
        tags=dict(d.get("tags") or {}),
        area_m2=(float(d["area_m2"]) if d.get("area_m2") is not None else None),
        geometry=Shape.from_geojson(geom) if geom is not None else None,
    )


#: How long `SharedOsmFetch` remembers a failed fetch for one bbox before
#: letting the next call retry the transport (issue #491, ARCH §8.6 rule 4 /
#: A30). Set to the same span as `service/plotlines_service/app.py`'s
#: `_CANDIDATE_FETCH_TIMEOUT_S`: long enough that the six sequential
#: per-layer calls one `/candidates` request makes for the same bbox always
#: share a single Overpass attempt (they run back-to-back on one thread, well
#: under a minute apart), short enough that a transport failure never reads
#: as a permanent one — the very next `/candidates` request, which cannot
#: even start until this one has finished or timed out
#: (`Readiness._candidate_fetch_pool` is one worker), gets a real attempt.
NEGATIVE_CACHE_TTL_S = 60.0


class SharedOsmFetch:
    """One bbox -> one `OsmLayerProvider.fetch` call, shared by the six
    per-layer `BuiltinOsmLayerProvider` instances registered against it
    (SPIKE-H §1's recorded bend: §14.2's per-instance shape is right for a
    plugin — one dataset, one provider — and would turn one Overpass query
    into six for a batched built-in source). `engine` is injectable so a
    test can feed committed fixtures instead of hitting the commons.

    A failed fetch is negative-cached for `NEGATIVE_CACHE_TTL_S` (issue
    #491) exactly as a successful one is cached indefinitely below — without
    it, one Overpass outage cost six sequential round trips, one per
    built-in layer, because only success was ever memoised.

    Two cache tiers (issue #243, ARCH A23's first mitigation, FR94):

    * **L1** — `self._cache`, an in-process dict. Dies on a sidecar restart,
      which M12's health-poll watchdog triggers precisely when a heavy build
      saturates the sidecar — the moment the cache is most valuable.
    * **L2** — `CacheLayout.candidate_set(bbox)` on disk, when a
      `cache_layout` is supplied. Survives the restart. The file records the
      `(layer_set_version, ruleset_version)` half of ARCH §4.2's key in its
      *contents* (the path is bbox-scoped only); a mismatch on either is a
      miss, so a ruleset bump never reads a stale extract. A23 measured the
      warm re-read at 1.75 s against 15.8 s cold.

    With no `cache_layout` the behaviour is exactly the pre-#243 L1-only one.
    """

    def __init__(self, engine: "OsmLayerProvider | None" = None, *,
                 cache_layout: "CacheLayout | None" = None,
                 clock: "Callable[[], float]" = time.monotonic) -> None:
        # Issue #275: the default engine gets the same `cache_layout` this
        # `SharedOsmFetch` was given, so `OsmLayerProvider.fetch` can find the
        # mirror clip `graph.extract_fetch.ensure_extract` cached for this
        # bbox at `cache_layout.root` — the L2 tier below caches the *scored*
        # candidates; this is what lets the *raw* fetch skip Overpass too.
        self._engine = engine or OsmLayerProvider(cache_layout=cache_layout)
        self._cache: dict[tuple[float, float, float, float], list[RawFeature]] = {}
        self._disk = cache_layout
        # Issue #491: a *failed* fetch used to go unmemoised — only success
        # was cached above — so `LayerRegistry.fetch_candidates_all`'s
        # sequential per-layer loop (six built-in layers, one bbox) repeated
        # the same doomed Overpass round trip once per layer during an
        # outage. `_failed` remembers the exception for `NEGATIVE_CACHE_TTL_S`
        # so the other five reuse it instead of re-dialling; `clock` is
        # injectable so a test can advance past the TTL without a real sleep.
        self._failed: dict[tuple[float, float, float, float], tuple[float, Exception]] = {}
        self._clock = clock

    def features_for(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        key = (bbox.west, bbox.south, bbox.east, bbox.north)
        if key in self._cache:
            return self._cache[key]

        cached_failure = self._failed.get(key)
        if cached_failure is not None:
            recorded_at, error = cached_failure
            if self._clock() - recorded_at < NEGATIVE_CACHE_TTL_S:
                raise error
            # TTL elapsed since the recorded failure — ARCH §8.6 rule 4: a
            # transport failure is transient, so the next attempt for this
            # bbox gets a real try rather than inheriting a stale one.
            del self._failed[key]

        from_disk = self._read_disk(key)
        if from_disk is not None:
            self._cache[key] = from_disk
            return from_disk

        # Always fetch every built-in layer for this bbox, once, so a second
        # per-layer sibling reads the cache rather than re-querying.
        try:
            features = self._engine.fetch(bbox, set(LAYERS))
        except Exception as exc:
            self._failed[key] = (self._clock(), exc)
            raise
        self._cache[key] = features
        self._failed.pop(key, None)
        self._write_disk(key, features)
        return features

    # -- L2 disk tier ----------------------------------------------------- #

    def _read_disk(
        self, key: tuple[float, float, float, float],
    ) -> list[RawFeature] | None:
        if self._disk is None:
            return None
        path = self._disk.candidate_set(key)
        try:
            doc = json.loads(path.read_text())
        except (OSError, ValueError):
            return None
        if not isinstance(doc, dict):
            return None
        if doc.get("layer_set_version") != LAYER_SET_VERSION:
            return None
        if doc.get("ruleset_version") != RULESET_VERSION:
            return None
        features = doc.get("features")
        if not isinstance(features, list):
            return None
        try:
            return [_raw_feature_from_json(item) for item in features]
        except (KeyError, TypeError, ValueError):
            log.warning("candidate cache at %s is unreadable; ignoring", path)
            return None

    def _write_disk(
        self, key: tuple[float, float, float, float], features: list[RawFeature],
    ) -> None:
        if self._disk is None:
            return
        path = self._disk.candidate_set(key)
        doc = {
            "layer_set_version": LAYER_SET_VERSION,
            "ruleset_version": RULESET_VERSION,
            "bbox": list(key),
            "features": [_raw_feature_to_json(f) for f in features],
        }
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.parent / f"{path.name}.tmp"
            tmp.write_text(json.dumps(doc))
            tmp.replace(path)  # atomic — a concurrent reader sees whole file or none
        except OSError as exc:
            log.warning("candidate cache write to %s failed: %s", path, exc)


class BuiltinOsmLayerProvider:
    """One built-in OSM layer, as a real §14.2 `LayerProvider`. Its
    `taxonomy` is the slice of `TAXONOMY` for this layer; `fetch_candidates`
    scores that slice via the same `score_with_taxonomy` a plugin uses.
    Built-in, synchronous, no warm-up — `load_state()` is always `ready`
    (D48: the built-in layers unlock curation immediately).
    """

    def __init__(self, layer: str, shared: SharedOsmFetch) -> None:
        if layer not in LAYERS:
            raise ValueError(f"not a built-in OSM layer: {layer!r}")
        self._layer = layer
        self._shared = shared

    @property
    def licence(self) -> LayerLicence:
        return OSM_LICENCE

    @property
    def taxonomy(self) -> TypeTaxonomy:
        return tuple(r for r in TAXONOMY if r.layer == self._layer)

    def fetch_candidates(self, bbox: BBox) -> list:
        features = self._shared.features_for(bbox, {self._layer})
        return score_with_taxonomy(features, self.taxonomy, live_layers={self._layer})

    def load_state(self) -> LayerLoadState:
        return LayerLoadState(READY)


def builtin_osm_providers(
    engine: "OsmLayerProvider | None" = None,
    *,
    cache_layout: "CacheLayout | None" = None,
) -> dict[str, BuiltinOsmLayerProvider]:
    """One `BuiltinOsmLayerProvider` per built-in OSM layer, all sharing one
    `SharedOsmFetch` so the six only ever cost one Overpass round trip.
    `cache_layout`, when given, adds the on-disk L2 tier (issue #243) so a
    fresh process re-reads the extract instead of re-querying Overpass."""
    shared = SharedOsmFetch(engine, cache_layout=cache_layout)
    return {layer: BuiltinOsmLayerProvider(layer, shared) for layer in sorted(LAYERS)}
