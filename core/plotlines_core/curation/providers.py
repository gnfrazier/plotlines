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
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Iterable, Protocol

from .notability import RULESET_VERSION, RawFeature, score_with_taxonomy
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
    area_m2 = None
    ring: tuple[tuple[float, float], ...] | None = None
    if geometry.geom_type in ("Polygon", "MultiPolygon"):
        area_m2 = _approx_area_m2(geometry, centroid.y)
        poly = geometry if geometry.geom_type == "Polygon" else max(
            geometry.geoms, key=lambda g: g.area)
        ring = tuple((float(x), float(y)) for x, y in poly.exterior.coords)
    return RawFeature(id=feature_id, coord=(centroid.x, centroid.y), tags=tags,
                      area_m2=area_m2, geometry=ring)


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
    """The batched Overpass extraction engine for the six built-in OSM
    layers. One network call answers every layer asked for in the same
    `fetch`, so this is *not* one-provider-per-layer — `BuiltinOsmLayerProvider`
    below wraps it to satisfy §14.2's per-layer `LayerProvider` shape while
    the six siblings still share one round trip (`SharedOsmFetch`).

    `.licence` stays a bare `"ODbL"` string here for backward compatibility
    with callers that predate the reconciliation; `OSM_LICENCE` is the
    `LayerLicence` the registry path uses.
    """

    licence = "ODbL"

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        import osmnx as ox
        import requests

        from ..osm_identity import apply_osm_http_identity, overpass_settings

        # Issue #241 / review §3.4: the candidate path must not query Overpass
        # as osmnx's stock UA either. A headless entrypoint already stamps the
        # build version; this is the floor for a caller that reaches curation
        # without importing `graph.regions`.
        apply_osm_http_identity()

        tags = osm_tags_for(layers)
        if not tags:
            return []
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
        with overpass_settings():
            try:
                gdf = ox.features_from_bbox(
                    (bbox.west, bbox.south, bbox.east, bbox.north), tags)
            except ox._errors.InsufficientResponseError:
                # A 200 with zero elements is a true answer about this
                # bbox/layer — no such feature here — not an outage (mirrors
                # #248's NoRoutableWaysError distinction on the graph path).
                return []
            except (requests.exceptions.RequestException,
                    ox._errors.ResponseStatusCodeError) as exc:
                raise CandidateFetchUnavailable(
                    "the map-data service didn't answer for this layer — "
                    "try again in a moment, or narrow the trip area."
                ) from exc
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
        "geometry": ([[x, y] for x, y in f.geometry]
                     if f.geometry is not None else None),
    }


def _raw_feature_from_json(d: dict) -> RawFeature:
    geom = d.get("geometry")
    lon, lat = d["coord"]
    return RawFeature(
        id=d["id"],
        coord=(float(lon), float(lat)),
        tags=dict(d.get("tags") or {}),
        area_m2=(float(d["area_m2"]) if d.get("area_m2") is not None else None),
        geometry=(tuple((float(x), float(y)) for x, y in geom)
                  if geom is not None else None),
    )


class SharedOsmFetch:
    """One bbox -> one `OsmLayerProvider.fetch` call, shared by the six
    per-layer `BuiltinOsmLayerProvider` instances registered against it
    (SPIKE-H §1's recorded bend: §14.2's per-instance shape is right for a
    plugin — one dataset, one provider — and would turn one Overpass query
    into six for a batched built-in source). `engine` is injectable so a
    test can feed committed fixtures instead of hitting the commons.

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
                 cache_layout: "CacheLayout | None" = None) -> None:
        self._engine = engine or OsmLayerProvider()
        self._cache: dict[tuple[float, float, float, float], list[RawFeature]] = {}
        self._disk = cache_layout

    def features_for(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        key = (bbox.west, bbox.south, bbox.east, bbox.north)
        if key in self._cache:
            return self._cache[key]

        from_disk = self._read_disk(key)
        if from_disk is not None:
            self._cache[key] = from_disk
            return from_disk

        # Always fetch every built-in layer for this bbox, once, so a second
        # per-layer sibling reads the cache rather than re-querying.
        features = self._engine.fetch(bbox, set(LAYERS))
        self._cache[key] = features
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
