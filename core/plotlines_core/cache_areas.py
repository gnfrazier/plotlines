"""Held areas: which already-fetched area covers a bbox (ARCH D73, epic #641).

Before D73 every local cache was keyed on the **exact** trip bbox
(:func:`plotlines_core.cache_layout.trip_bbox_key`), so a trip one block
from another missed on all five payloads and fetched everything again, and
nothing was ever deleted. D73 makes the unit a *held area*: the bbox one
fetch covered, padded beyond the trip that asked for it (:func:`pad_bbox`).
Any trip whose bbox lies inside the area uses what it holds.

This module is the one place that answers "which held area covers this
bbox, and how fresh is each payload in it" (:meth:`AreaIndex.resolve`).
Routing, candidates, elevation and tiles all ask it the same question, so
none of them invents its own lookup, which is the mistake FR94 had to stop
tiles and elevation from making.

Payload files keep their :class:`~plotlines_core.cache_layout.CacheLayout`
paths, keyed on the *area's* bbox, so a pre-epic file is simply an area at
its own bbox and migrating is a matter of adopting it
(:meth:`AreaIndex.adopt_unindexed`, :meth:`AreaIndex.adopt_exact`).

**Retention.** Each payload has its own TTL, measured from fetch time
(:data:`TTL_DAYS`). An area is *referenced* while a live trip's stored bbox
lies inside it (:meth:`AreaIndex.set_references`). Until the first reference
set arrives, every area counts as referenced. :meth:`AreaIndex.prune`
deletes an unreferenced payload once it passes its TTL and never deletes a
referenced one for age.

**Privacy.** A record holds a bbox, payload paths, fetch times, pins and
versions. It holds no trip id, trip name or Author. The reference set is
kept in memory only, and the one trace of it on disk is each area's
``last_referenced_at``.

**Threads (ARCH §8.6, D66).** :meth:`AreaIndex.resolve` and
:meth:`AreaIndex.set_references` touch only memory and are safe on a
request thread. Everything that reads or writes disk (:meth:`register`,
:meth:`persist`, :meth:`adopt_unindexed`, :meth:`prune`) belongs on a
background pool. ``_lock`` is never held across I/O.
"""

from __future__ import annotations

import json
import logging
import math
import os
import shutil
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

from .cache_layout import (
    CANDIDATES_DIRNAME,
    ELEVATION_DIRNAME,
    EXTRACTS_DIRNAME,
    TILES_DIRNAME,
    BBox,
    CacheLayout,
    is_safe_pin,
    trip_bbox_key,
)
from .tiles.mirror_state import DEFAULT_BASEMAP_TTL_DAYS, MAX_PIN_AGE_DAYS

log = logging.getLogger(__name__)

#: The index file, at the cache root. One small JSON document; a lost or
#: corrupt one is rebuilt from the payload files themselves.
INDEX_FILENAME = "areas.json"

#: Bumped whenever the record shape changes. An index carrying any other
#: version is rebuilt from disk, never trusted.
INDEX_VERSION = 1

#: Where routing graphs live under the cache root (`graph.regions.Region
#: .graph_path`). Named here because the graph is the one payload whose
#: directory `CacheLayout` does not own.
REGIONS_DIRNAME = "regions"

PAYLOAD_EXTRACT = "extract"
PAYLOAD_CANDIDATES = "candidates"
PAYLOAD_ELEVATION = "elevation"
PAYLOAD_BASEMAP = "basemap"
_GRAPH_PREFIX = "graph:"

#: The network types a graph can be built for (`multimodal.modes`). Used to
#: name a pre-epic graph directory from a live trip's bbox
#: (:meth:`AreaIndex.adopt_exact`), since a graph file does not record its
#: own network type.
NETWORK_TYPES = ("bike", "walk", "all", "drive")

#: D73's elevation TTL. DEMs do not change, and FR87 limits calls, so it is
#: long.
ELEVATION_TTL_DAYS = 365.0

#: D73's TTL per payload, in days, measured from fetch time. A graph ages
#: with the extract it was built from.
TTL_DAYS = {
    PAYLOAD_EXTRACT: MAX_PIN_AGE_DAYS,
    PAYLOAD_CANDIDATES: MAX_PIN_AGE_DAYS,
    PAYLOAD_ELEVATION: ELEVATION_TTL_DAYS,
    PAYLOAD_BASEMAP: DEFAULT_BASEMAP_TTL_DAYS,
}
GRAPH_TTL_DAYS = MAX_PIN_AGE_DAYS

#: D73's padding rule: each side grows by this fraction of that dimension,
#: clamped to [PAD_MIN_M, PAD_MAX_M], and the padded box never exceeds
#: PAD_AREA_CAP_KM2. The cap comes from #630's graph-build cost (4–8 s and
#: 170–250 MB RSS per clip MB); #634 may tune it.
PAD_FRACTION = 0.10
PAD_MIN_M = 500.0
PAD_MAX_M = 2000.0
PAD_AREA_CAP_KM2 = 900.0

#: Containment slack, in degrees (~1 cm). A trip bbox equal to an area's
#: own bbox must count as contained despite float noise in a JSON round trip.
_EPS = 1e-7

_M_PER_DEG_LAT = 111_320.0
_DAY_S = 86_400.0


def graph_payload(network_type: str) -> str:
    """The payload name for a routing graph of `network_type`."""
    return f"{_GRAPH_PREFIX}{network_type}"


def is_graph_payload(payload: str) -> bool:
    return payload.startswith(_GRAPH_PREFIX)


def ttl_days(payload: str) -> float:
    """D73's TTL for `payload`, in days."""
    if is_graph_payload(payload):
        return GRAPH_TTL_DAYS
    return TTL_DAYS[payload]


def bbox_contains(outer: BBox, inner: BBox) -> bool:
    """Whether `inner` lies inside `outer`; an equal box counts."""
    return (outer[0] <= inner[0] + _EPS and outer[1] <= inner[1] + _EPS
            and outer[2] >= inner[2] - _EPS and outer[3] >= inner[3] - _EPS)


def bbox_intersects(a: BBox, b: BBox) -> bool:
    """Whether `a` and `b` overlap with positive area. A shared edge does
    not count: a tile that only touches an area's edge holds none of it."""
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def _area_deg2(bbox: BBox) -> float:
    return max(0.0, bbox[2] - bbox[0]) * max(0.0, bbox[3] - bbox[1])


def _side_m(bbox: BBox) -> tuple[float, float]:
    west, south, east, north = bbox
    mid_lat = math.radians((south + north) / 2.0)
    width = (east - west) * _M_PER_DEG_LAT * max(math.cos(mid_lat), 1e-6)
    height = (north - south) * _M_PER_DEG_LAT
    return width, height


def pad_bbox(bbox: BBox, *, area_cap_km2: float = PAD_AREA_CAP_KM2) -> BBox:
    """The area to fetch for a trip no held area covers (D73's padding
    rule), so nearby trips later land inside it.

    Each side grows by :data:`PAD_FRACTION` of that dimension, at least
    :data:`PAD_MIN_M` and at most :data:`PAD_MAX_M`. The padded box never
    exceeds `area_cap_km2`. A trip already at or over the cap is returned
    unpadded, and one near it is padded only up to it. The result is rounded
    outward to 5 dp, the precision :func:`trip_bbox_key` hashes at, so the
    area's key is stable and the box still contains the trip.
    """
    west, south, east, north = bbox
    width, height = _side_m(bbox)
    area_km2 = width * height / 1e6
    if area_km2 >= area_cap_km2:
        return bbox
    mx = min(max(PAD_FRACTION * width, PAD_MIN_M), PAD_MAX_M)
    my = min(max(PAD_FRACTION * height, PAD_MIN_M), PAD_MAX_M)
    padded_km2 = (width + 2 * mx) * (height + 2 * my) / 1e6
    if padded_km2 > area_cap_km2:
        # Scale both margins by k so the padded area lands on the cap:
        # 4·mx·my·k² + 2(w·my + h·mx)·k + (w·h − cap) = 0, positive root.
        a = 4 * mx * my
        b = 2 * (width * my + height * mx)
        c = width * height - area_cap_km2 * 1e6
        k = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
        mx, my = mx * k, my * k
    mid_lat = math.radians((south + north) / 2.0)
    dlon = mx / (_M_PER_DEG_LAT * max(math.cos(mid_lat), 1e-6))
    dlat = my / _M_PER_DEG_LAT
    scale = 10 ** 5
    return (
        max(-180.0, math.floor((west - dlon) * scale) / scale),
        max(-90.0, math.floor((south - dlat) * scale) / scale),
        min(180.0, math.ceil((east + dlon) * scale) / scale),
        min(90.0, math.ceil((north + dlat) * scale) / scale),
    )


@dataclass(frozen=True)
class PayloadRecord:
    """One payload held for an area. `path` is relative to the cache root
    (POSIX separators), so a moved cache root keeps working."""

    path: str
    fetched_at: float
    pin: str | None = None
    version: str | None = None

    def to_json(self) -> dict:
        d = {"path": self.path, "fetched_at": self.fetched_at}
        if self.pin is not None:
            d["pin"] = self.pin
        if self.version is not None:
            d["version"] = self.version
        return d

    @classmethod
    def from_json(cls, d: dict) -> "PayloadRecord":
        return cls(path=str(d["path"]), fetched_at=float(d["fetched_at"]),
                   pin=d.get("pin"), version=d.get("version"))


@dataclass
class AreaRecord:
    bbox: BBox
    payloads: dict[str, PayloadRecord] = field(default_factory=dict)
    last_referenced_at: float | None = None

    @property
    def key(self) -> str:
        return trip_bbox_key(self.bbox)

    def to_json(self) -> dict:
        return {
            "bbox": list(self.bbox),
            "payloads": {name: p.to_json() for name, p in sorted(self.payloads.items())},
            "last_referenced_at": self.last_referenced_at,
        }

    @classmethod
    def from_json(cls, d: dict) -> "AreaRecord":
        bbox = tuple(float(v) for v in d["bbox"])
        if len(bbox) != 4:
            raise ValueError("bbox must have four coordinates")
        return cls(
            bbox=bbox,  # type: ignore[arg-type]
            payloads={str(k): PayloadRecord.from_json(v)
                      for k, v in (d.get("payloads") or {}).items()},
            last_referenced_at=(float(d["last_referenced_at"])
                                if d.get("last_referenced_at") is not None else None),
        )


@dataclass(frozen=True)
class AreaHit:
    """:meth:`AreaIndex.resolve`'s answer: the area that covers the asked
    bbox and the payload it holds. `stale` is true past the payload's TTL;
    a stale hit is still a hit, and story 8 (#649) decides what to do."""

    area_bbox: BBox
    payload: str
    path: Path
    fetched_at: float
    pin: str | None
    version: str | None
    stale: bool
    age_days: float

    @property
    def area_key(self) -> str:
        return trip_bbox_key(self.area_bbox)

    def covers_exactly(self, bbox: BBox) -> bool:
        """Whether the area *is* `bbox` (to the key's precision), so nothing
        needs deriving from it."""
        return trip_bbox_key(bbox) == self.area_key


@dataclass(frozen=True)
class Pruned:
    """One payload :meth:`AreaIndex.prune` removed, for the log line."""

    area_bbox: BBox | None
    payload: str
    path: Path
    bytes_freed: int
    reason: str


def _now_s() -> float:
    return time.time()


def _size(path: Path) -> int:
    if path.is_dir():
        return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())
    try:
        return path.stat().st_size
    except OSError:
        return 0


class AreaIndex:
    """The held-area index for one cache root (see the module docstring).

    `clock` returns epoch seconds and is injected by tests, which never
    sleep. One instance per root per process: use :meth:`for_root` outside
    tests so every caller shares one in-memory view.
    """

    _instances: dict[Path, "AreaIndex"] = {}
    _instances_lock = threading.Lock()

    def __init__(self, root: str | Path, *, clock: Callable[[], float] = _now_s,
                 load: bool = True) -> None:
        self.root = Path(root)
        self.layout = CacheLayout(self.root)
        self._clock = clock
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._areas: dict[str, AreaRecord] = {}
        #: The live trips' bboxes, or None before the first set arrives
        #: (every area then counts as referenced).
        self._references: tuple[BBox, ...] | None = None
        if load:
            self.load()

    @classmethod
    def for_root(cls, root: str | Path) -> "AreaIndex":
        """The process-wide index for `root`, created (and loaded) once."""
        key = Path(root).resolve()
        with cls._instances_lock:
            index = cls._instances.get(key)
            if index is None:
                index = cls(key)
                cls._instances[key] = index
            return index

    @property
    def index_path(self) -> Path:
        return self.root / INDEX_FILENAME

    # -- load / persist / rebuild ------------------------------------------ #

    def load(self) -> None:
        """Read the index. A missing, corrupt or wrong-version file is
        rebuilt from the payload files on disk (and written back)."""
        try:
            doc = json.loads(self.index_path.read_text())
            if not isinstance(doc, dict) or doc.get("version") != INDEX_VERSION:
                raise ValueError(f"index version {doc.get('version') if isinstance(doc, dict) else None!r}")
            areas = {}
            for item in doc.get("areas") or []:
                record = AreaRecord.from_json(item)
                areas[record.key] = record
        except FileNotFoundError:
            areas = None
        except (OSError, ValueError, KeyError, TypeError) as exc:
            log.warning("area index at %s unreadable (%s); rebuilding from disk",
                        self.index_path, exc)
            areas = None
        with self._lock:
            self._areas = areas or {}
        if areas is None:
            self.rebuild()

    def rebuild(self) -> int:
        """Forget the in-memory index and re-adopt every payload file on
        disk. Returns the number of payloads adopted."""
        with self._lock:
            self._areas = {}
        return self.adopt_unindexed()

    def persist(self) -> None:
        """Write the index atomically (temp file, then rename)."""
        with self._lock:
            doc = {"version": INDEX_VERSION,
                   "areas": [a.to_json() for _, a in sorted(self._areas.items())]}
        body = json.dumps(doc, indent=1)
        with self._write_lock:
            self.root.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=self.root, prefix=".areas-", suffix=".part")
            try:
                with os.fdopen(fd, "w") as out:
                    out.write(body)
                os.replace(tmp, self.index_path)
            except BaseException:
                Path(tmp).unlink(missing_ok=True)
                raise

    # -- lookups (memory only; safe on a request thread) ------------------- #

    def _rel(self, path: Path) -> str:
        path = Path(path)
        try:
            return path.resolve().relative_to(self.root.resolve()).as_posix()
        except ValueError:
            return path.as_posix()

    def _abs(self, rel: str) -> Path:
        p = Path(rel)
        return p if p.is_absolute() else self.root / p

    def _stale(self, payload: str, record: PayloadRecord, now: float) -> tuple[bool, float]:
        age = max(0.0, (now - record.fetched_at) / _DAY_S)
        return age > ttl_days(payload), age

    def resolve(self, bbox: BBox, payload: str, *, version: str | None = None,
                allow_stale: bool = True) -> AreaHit | None:
        """The held area that covers `bbox` and holds `payload`, or `None`.

        A fresh area beats a stale one, and among equals the smallest wins
        (it gives the smallest graph to truncate). With `version`, only a
        payload recorded at exactly that version counts (candidate sets).
        A stale hit carries ``stale=True`` unless `allow_stale` is false.
        """
        now = self._clock()
        best: tuple[tuple[bool, float], AreaHit] | None = None
        with self._lock:
            records = list(self._areas.values())
        for area in records:
            rec = area.payloads.get(payload)
            if rec is None or not bbox_contains(area.bbox, bbox):
                continue
            if version is not None and rec.version != version:
                continue
            stale, age = self._stale(payload, rec, now)
            if stale and not allow_stale:
                continue
            rank = (stale, _area_deg2(area.bbox))
            if best is None or rank < best[0]:
                best = (rank, AreaHit(
                    area_bbox=area.bbox, payload=payload, path=self._abs(rec.path),
                    fetched_at=rec.fetched_at, pin=rec.pin, version=rec.version,
                    stale=stale, age_days=age))
        return best[1] if best else None

    def intersecting(self, bbox: BBox, payload: str) -> list[AreaHit]:
        """Every held area that overlaps `bbox` and holds `payload`, fresh
        before stale and smallest first — issue #675. `resolve` asks for an
        area that *contains* a bbox; a basemap tile at an area's edge is in
        that area's archive (an extract takes every intersecting tile) yet
        not inside its bbox, so `/tiles` asks this instead and lets the
        archive say whether it has the address."""
        now = self._clock()
        ranked: list[tuple[tuple[bool, float], AreaHit]] = []
        with self._lock:
            records = list(self._areas.values())
        for area in records:
            rec = area.payloads.get(payload)
            if rec is None or not bbox_intersects(area.bbox, bbox):
                continue
            stale, age = self._stale(payload, rec, now)
            ranked.append(((stale, _area_deg2(area.bbox)), AreaHit(
                area_bbox=area.bbox, payload=payload, path=self._abs(rec.path),
                fetched_at=rec.fetched_at, pin=rec.pin, version=rec.version,
                stale=stale, age_days=age)))
        ranked.sort(key=lambda r: r[0])
        return [hit for _, hit in ranked]

    def reserve(self, bbox: BBox) -> BBox:
        """The bbox to fetch for a new area around `bbox` (:func:`pad_bbox`)."""
        return pad_bbox(bbox)

    def holds(self, area_bbox: BBox, payload: str) -> bool:
        """Whether the area at exactly `area_bbox` has a record for `payload`."""
        with self._lock:
            area = self._areas.get(trip_bbox_key(area_bbox))
            return area is not None and payload in area.payloads

    def areas(self) -> list[AreaRecord]:
        """A snapshot of every area record (copies; safe to read)."""
        with self._lock:
            return [AreaRecord(a.bbox, dict(a.payloads), a.last_referenced_at)
                    for a in self._areas.values()]

    def indexed_paths(self) -> set[Path]:
        with self._lock:
            return {self._abs(p.path).resolve()
                    for a in self._areas.values() for p in a.payloads.values()}

    # -- writes ------------------------------------------------------------ #

    def register(self, area_bbox: BBox, payload: str, path: Path, *,
                 fetched_at: float | None = None, pin: str | None = None,
                 version: str | None = None, persist: bool = True) -> None:
        """Record that `area_bbox` now holds `payload` at `path`. Replaces any
        earlier record of the same payload for the same area (a refresh)."""
        rec = PayloadRecord(path=self._rel(path),
                            fetched_at=self._clock() if fetched_at is None else fetched_at,
                            pin=pin, version=version)
        area_bbox = tuple(float(v) for v in area_bbox)  # type: ignore[assignment]
        key = trip_bbox_key(area_bbox)
        with self._lock:
            area = self._areas.get(key)
            if area is None:
                area = AreaRecord(bbox=area_bbox)
                if self._references is not None and self._is_referenced(area_bbox):
                    area.last_referenced_at = self._clock()
                self._areas[key] = area
            area.payloads[payload] = rec
        if persist:
            self.persist()

    def forget(self, area_bbox: BBox, payload: str, *, persist: bool = True) -> None:
        key = trip_bbox_key(area_bbox)
        with self._lock:
            area = self._areas.get(key)
            if area is None:
                return
            area.payloads.pop(payload, None)
            if not area.payloads:
                del self._areas[key]
        if persist:
            self.persist()

    # -- references (story 6, #647) ---------------------------------------- #

    @property
    def references_known(self) -> bool:
        with self._lock:
            return self._references is not None

    def _is_referenced(self, area_bbox: BBox) -> bool:
        refs = self._references
        return refs is None or any(bbox_contains(area_bbox, r) for r in refs)

    def is_referenced(self, area_bbox: BBox) -> bool:
        """Whether a live trip's bbox lies inside `area_bbox`. True for every
        area until the first reference set arrives (nothing is pruned on a
        guess)."""
        with self._lock:
            return self._is_referenced(area_bbox)

    def set_references(self, bboxes: Iterable[BBox]) -> dict:
        """Replace the live-trip reference set. Memory only: stamps
        ``last_referenced_at`` on each referenced area and returns counts.
        The caller persists on a background pool."""
        refs = tuple(tuple(float(v) for v in b) for b in bboxes)
        now = self._clock()
        with self._lock:
            self._references = refs  # type: ignore[assignment]
            referenced = 0
            for area in self._areas.values():
                if self._is_referenced(area.bbox):
                    area.last_referenced_at = now
                    referenced += 1
            total = len(self._areas)
        return {"references": len(refs), "areas": total, "referenced": referenced}

    def references(self) -> tuple[BBox, ...] | None:
        with self._lock:
            return self._references

    # -- adoption: migration and rebuild (story 7, #648) ------------------- #

    def adopt_exact(self, bbox: BBox, *, persist: bool = True) -> int:
        """Adopt pre-epic files keyed on exactly `bbox` (a live trip's), so
        the area is indexed even when its files carry no readable extent: a
        graph directory names neither its bbox nor its network type. Returns
        the number adopted."""
        from .graph import regions as region_lib

        indexed = self.indexed_paths()
        adopted = 0
        candidates: list[tuple[str, Path, str | None]] = [
            (PAYLOAD_BASEMAP, self.layout.tile_archive(bbox), None),
            (PAYLOAD_ELEVATION, self.layout.elevation_raster(bbox), None),
        ]
        for nt in NETWORK_TYPES:
            region = region_lib.region_for(bbox, nt)
            candidates.append((graph_payload(nt), region.graph_path(self.root), None))
        if self.layout.extracts_dir.is_dir():
            for pin_dir in self.layout.extracts_dir.iterdir():
                if pin_dir.is_dir() and is_safe_pin(pin_dir.name):
                    candidates.append((PAYLOAD_EXTRACT, self.layout.osm_extract(bbox, pin_dir.name),
                                       pin_dir.name))
        for payload, path, pin in candidates:
            if not path.is_file() or path.resolve() in indexed:
                continue
            if payload == PAYLOAD_EXTRACT and not self._newer_extract(bbox, pin):
                continue
            target = path.parent if is_graph_payload(payload) else path
            self.register(bbox, payload, path, fetched_at=target.stat().st_mtime,
                          pin=pin, persist=False)
            adopted += 1
        if adopted and persist:
            self.persist()
        return adopted

    def _newer_extract(self, bbox: BBox, pin: str | None) -> bool:
        """Whether `pin` is at least as new as the extract already indexed
        for `bbox` (two pins for one area: keep the newest)."""
        hit = None
        with self._lock:
            area = self._areas.get(trip_bbox_key(bbox))
            if area is not None:
                hit = area.payloads.get(PAYLOAD_EXTRACT)
        if hit is None or hit.pin is None or pin is None:
            return True
        return pin >= hit.pin

    def adopt_unindexed(self) -> int:
        """Adopt every payload file on disk that is not yet indexed and whose
        own header names its extent: the migration from pre-epic exact-bbox
        caches, and the rebuild after a lost index. Reads file headers, so
        it belongs on a background pool. Returns the number adopted."""
        indexed = self.indexed_paths()
        adopted = 0
        for payload, path, pin in self._payload_files():
            if path.resolve() in indexed:
                continue
            try:
                found = _read_extent(payload, path)
            except Exception as exc:  # noqa: BLE001 — an unreadable file is not adopted
                log.info("area index: not adopting %s (%s)", path, exc)
                continue
            if found is None:
                continue
            bbox, version, nt = found
            name = graph_payload(nt) if payload == "graph" else payload
            if self.holds(bbox, name):
                # The area already has this payload (a refresh replaced the
                # file): leave the old one unindexed, so the prune pass
                # removes it once it is past its TTL and nothing reads it.
                continue
            target = path.parent if payload == "graph" else path
            self.register(bbox, name, path, fetched_at=target.stat().st_mtime,
                          pin=pin, version=version, persist=False)
            adopted += 1
        if adopted:
            log.info("area index: adopted %d payload file(s) under %s", adopted, self.root)
        self.persist()
        return adopted

    def _payload_files(self) -> Iterable[tuple[str, Path, str | None]]:
        """Every payload file on disk, as (payload kind, path, pin). Temp
        files (dot-prefixed, ``.part``, ``.tmp``) are never payloads."""
        def files(d: Path, suffix: str) -> Iterable[Path]:
            if not d.is_dir():
                return []
            return sorted(p for p in d.iterdir()
                          if p.is_file() and p.name.endswith(suffix)
                          and not p.name.startswith("."))

        for p in files(self.root / TILES_DIRNAME, ".pmtiles"):
            yield PAYLOAD_BASEMAP, p, None
        for p in files(self.root / ELEVATION_DIRNAME, ".tif"):
            yield PAYLOAD_ELEVATION, p, None
        for p in files(self.root / CANDIDATES_DIRNAME, ".json"):
            yield PAYLOAD_CANDIDATES, p, None
        extracts = self.root / EXTRACTS_DIRNAME
        if extracts.is_dir():
            for pin_dir in sorted(extracts.iterdir()):
                if pin_dir.is_dir() and is_safe_pin(pin_dir.name):
                    for p in files(pin_dir, ".osm.pbf"):
                        yield PAYLOAD_EXTRACT, p, pin_dir.name
        regions = self.root / REGIONS_DIRNAME
        if regions.is_dir():
            for d in sorted(regions.iterdir()):
                g = d / "graph.graphml"
                if g.is_file():
                    yield "graph", g, None

    # -- pruning (story 7, #648) ------------------------------------------- #

    def prune(self, *, in_use: Iterable[Path] = (),
              current_versions: dict[str, str] | None = None,
              extra_references: Iterable[BBox] = ()) -> list[Pruned]:
        """One retention pass (D73). Does nothing until references are known.

        * An unreferenced payload past its TTL is deleted with its record.
        * A referenced payload is never deleted for age.
        * A candidate set at a version other than `current_versions`'s can
          never be used again and is deleted whatever its references.
        * A payload file nothing indexes is deleted once its mtime is past
          its TTL. Run :meth:`adopt_unindexed` first so only files with no
          readable extent are left.
        * Extract pin directories left with no file are removed
          (:meth:`CacheLayout.sweep_stale_extracts`).

        A path in `in_use` (an open archive, a raster a sampler holds), or
        one the OS refuses to delete (Windows keeps open files), is skipped
        and retried on the next pass. `extra_references` are bboxes that
        count as referenced for this pass only (the trips open right now,
        which may not be saved yet).
        """
        if not self.references_known:
            return []
        in_use_set = {Path(p).resolve() for p in in_use}
        extra = tuple(tuple(float(v) for v in b) for b in extra_references)
        current_versions = current_versions or {}
        now = self._clock()
        pruned: list[Pruned] = []

        def _delete(path: Path, payload: str) -> int | None:
            target = path.parent if is_graph_payload(payload) or payload == "graph" else path
            if path.resolve() in in_use_set or target.resolve() in in_use_set:
                return None
            freed = _size(target)
            try:
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink(missing_ok=True)
            except OSError as exc:
                log.info("area prune: %s held open or locked (%s); retrying next pass",
                         target, exc)
                return None
            return freed

        for area in self.areas():
            referenced = self.is_referenced(area.bbox) or any(
                bbox_contains(area.bbox, b) for b in extra)
            for payload, rec in area.payloads.items():
                stale, _age = self._stale(payload, rec, now)
                want = current_versions.get(payload)
                obsolete = want is not None and rec.version != want
                if not obsolete and (referenced or not stale):
                    continue
                path = self._abs(rec.path)
                freed = _delete(path, payload)
                if freed is None:
                    continue
                self.forget(area.bbox, payload, persist=False)
                reason = "version" if obsolete else "ttl"
                pruned.append(Pruned(area.bbox, payload, path, freed, reason))
                log.info("area prune: area=%s payload=%s reason=%s freed=%d path=%s",
                         list(area.bbox), payload, reason, freed, path)

        indexed = self.indexed_paths()
        for kind, path, _pin in list(self._payload_files()):
            if path.resolve() in indexed:
                continue
            target = path.parent if kind == "graph" else path
            try:
                age = (now - target.stat().st_mtime) / _DAY_S
            except OSError:
                continue
            ttl = GRAPH_TTL_DAYS if kind == "graph" else TTL_DAYS[kind]
            if age <= ttl:
                continue
            freed = _delete(path, kind)
            if freed is None:
                continue
            pruned.append(Pruned(None, kind, path, freed, "unindexed"))
            log.info("area prune: unindexed payload=%s freed=%d path=%s", kind, freed, path)

        keep_pins = {rec.pin for a in self.areas() for name, rec in a.payloads.items()
                     if name == PAYLOAD_EXTRACT and rec.pin}
        for pin_dir in self.layout.sweep_stale_extracts(None, keep_pins=keep_pins,
                                                        only_empty=True):
            pruned.append(Pruned(None, PAYLOAD_EXTRACT, pin_dir, 0, "empty-pin"))
        self.persist()
        return pruned

    def stale_payloads(self, bbox: BBox) -> list[AreaHit]:
        """Every payload a trip at `bbox` would resolve to that is past its
        TTL — what story 8 (#649) refreshes on open."""
        with self._lock:
            names = {name for a in self._areas.values() if bbox_contains(a.bbox, bbox)
                     for name in a.payloads}
        hits = [self.resolve(bbox, name) for name in sorted(names)]
        return [h for h in hits if h is not None and h.stale]


def _read_extent(kind: str, path: Path) -> tuple[BBox, str | None, str | None] | None:
    """(bbox, version, network type) a payload file's own header names, or
    `None` when it names none."""
    if kind == PAYLOAD_BASEMAP:
        from .tiles.archive import Archive

        with Archive(path) as archive:
            return archive.info().bounds, None, None
    if kind == PAYLOAD_ELEVATION:
        import rasterio

        with rasterio.open(path) as ds:
            b = ds.bounds
            return (b.left, b.bottom, b.right, b.top), None, None
    if kind == PAYLOAD_CANDIDATES:
        doc = json.loads(path.read_text())
        bbox = doc.get("bbox")
        if not isinstance(bbox, list) or len(bbox) != 4:
            return None
        return (tuple(float(v) for v in bbox), candidate_version(  # type: ignore[return-value]
            doc.get("layer_set_version"), doc.get("ruleset_version")), None)
    if kind == PAYLOAD_EXTRACT:
        import osmium

        reader = osmium.io.Reader(str(path), osmium.osm.osm_entity_bits.NOTHING)
        try:
            box = reader.header().box()
        finally:
            reader.close()
        if not box.valid():
            return None
        return (box.bottom_left.lon, box.bottom_left.lat,
                box.top_right.lon, box.top_right.lat), None, None
    if kind == "graph":
        source = path.with_name("source.json")
        try:
            doc = json.loads(source.read_text())
        except (OSError, ValueError):
            return None
        bbox, nt = doc.get("bbox"), doc.get("network_type")
        if not isinstance(bbox, list) or len(bbox) != 4 or not isinstance(nt, str):
            return None
        return tuple(float(v) for v in bbox), None, nt  # type: ignore[return-value]
    return None


def candidate_version(layer_set_version, ruleset_version) -> str:
    """The one string a candidate set's two versions (ARCH §4.2) are
    recorded and compared as."""
    return f"{layer_set_version}/{ruleset_version}"


__all__ = [
    "AreaHit", "AreaIndex", "AreaRecord", "PayloadRecord", "Pruned",
    "PAYLOAD_BASEMAP", "PAYLOAD_CANDIDATES", "PAYLOAD_ELEVATION", "PAYLOAD_EXTRACT",
    "NETWORK_TYPES", "TTL_DAYS", "GRAPH_TTL_DAYS", "ELEVATION_TTL_DAYS",
    "bbox_contains", "candidate_version", "graph_payload", "is_graph_payload",
    "pad_bbox", "ttl_days",
]
