"""Trip -> FIT *course* bytes, with the reveal gate applied at the byte boundary.

This is `plotlines_core.export`'s FIT arm (ARCH §6.1 `export_trip`, §7.2
`POST /trips/{id}/export`, §13.3). It is pure Python with no dependency — the
SPIKE-16 verdict (issue #163): the FFI-against-Garmin's-SDK alternative buys no
fidelity and costs a native per-platform dependency (risk A5), the FIT SDK
redistribution obligation, and a fork of one format off the shared code path.

`CourseExport` is the language-neutral course model this writer consumes — the
shape `export_trip` reduces a `Trip` payload (`trips/payload.py`,
`docs/schemas/trip_payload.schema.json`) to for the FIT arm: one track, its
elevation, and the ordered course points. It mirrors
`spikes/SPIKE-16/results/fixture.json`, which is also Arm B's input in
`spikes/SPIKE-16/HARNESS.md`. The `Trip` -> `CourseExport` reduction (days ->
single or per-day files per FR44, cue modifiers -> turn enums, node kinds and
anchor roles -> course-point types) is the rest of story F3 and builds on this.

The four F3 implementation tasks SPIKE-16 named (issue #69 comment) are handled
here:

1.  **`course_point.name` truncation** cuts on a *word* boundary at a device
    cue-list cap (`FIT_CUE_NAME_CAP`), not mid-word as the spike writer did, with
    a hard 64-byte ceiling (`FIT_NAME_BYTE_CEILING`). The exact floor is a
    `HARNESS.md` device measurement; `name_cap` is a parameter so it can be
    pinned without a code change.
2.  **Area anchors (FR108) have no FIT slot.** They are dropped by default
    (recorded in `FitExport.areas_dropped`) — areas are GPX/GeoJSON-only in the
    export-contents UI until `HARNESS.md` shows an on-device centroid point reads
    better. `area_centroid_points=True` opts into a single `generic` course
    point at each polygon's centroid.
3.  **Role offsets (FR107) export cleanly** — a `CoursePoint` carries its own
    `lat`/`lon`, so an offset role lands at its offset position, not its
    anchor's. Verified by SPIKE-16; covered by a test here.
4.  **`file_id.manufacturer`** is the named constant `FIT_MANUFACTURER`
    (development id `255`, which devices accept) rather than a literal buried in
    the writer — one line to swap when Plotlines has a Garmin-issued id.

Reveal gate (punch-list §6A.2): an unrevealed narrative course point contributes
**no `course_point` message and no name string** — the decision is applied before
a byte is written, so the assertion is on the bytes. Hazards are never withheld
(PRD §1.5).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from plotlines_core.export._fit_encoder import FitEncoder
from plotlines_core.export._fit_profile import (
    COURSE_POINT_TYPE,
    EVENT_TIMER,
    EVENT_TYPE_START,
    EVENT_TYPE_STOP_ALL,
    FILE_COURSE,
    SPORT,
    altitude_raw,
    centroid,
    distance_raw,
    fit_time,
    semicircles,
)

#: `file_id.manufacturer`. `255` is FIT's "development / not a real manufacturer"
#: id; head units accept it. Garmin issues manufacturer ids on request — swap
#: this one constant (and `FIT_PRODUCT`) when Plotlines has one. (SPIKE-16.)
FIT_MANUFACTURER = 255
FIT_PRODUCT = 1
FIT_SOFTWARE_VERSION = 1

#: Practical `course_point.name` cap, in characters. Garmin head units have
#: historically shown ~15-30 characters of a course point's name in the cue list
#: (`spikes/SPIKE-16/HARNESS.md`); 30 keeps the most note text while staying
#: inside that window. The measured floor is a device-run finding — pass a lower
#: `name_cap` to `export_course_fit` once `HARNESS.md` pins it.
FIT_CUE_NAME_CAP = 30

#: Absolute ceiling on the encoded `course_point.name` string, in bytes. The
#: spike writer's hard cap; kept as a backstop behind the word-boundary cut.
FIT_NAME_BYTE_CEILING = 64

_ELLIPSIS = "…"

#: `reveal` values that mean "this content ships" (schema `reveal_policy` plus
#: the spike fixture's spelling). Anything else is held for arrival.
_REVEALED_VALUES = frozenset({"always", "always_visible"})


# --------------------------------------------------------------- input model

@dataclass
class TrackPoint:
    """One vertex of the routed line. `elevation_m` absent => no altitude written."""

    lat: float
    lon: float
    distance_m: float
    elevation_m: float | None = None


@dataclass
class CoursePoint:
    """One marker on the course. `lat`/`lon` are the point's own position —
    already the role's offset position (FR107) where it has one."""

    id: str
    cp_type: str            # a `_fit_profile.COURSE_POINT_TYPE` key
    name: str
    lat: float
    lon: float
    distance_m: float
    note: str | None = None
    hazard: bool = False
    reveal: str = "always"  # "always" / "always_visible" ship; else held (§6A.2)


@dataclass
class AreaAnchor:
    """An FR108 area promoted onto the trip. FIT has no polygon slot for it."""

    id: str
    name: str
    polygon: list[tuple[float, float]]   # (lat, lon) ring
    reveal: str = "always"
    hazard: bool = False


@dataclass
class CourseExport:
    """The language-neutral course model the FIT writer consumes."""

    title: str
    start_unix: float
    nominal_speed_mps: float
    track: list[TrackPoint] = field(default_factory=list)
    course_points: list[CoursePoint] = field(default_factory=list)
    areas: list[AreaAnchor] = field(default_factory=list)
    sport: str = "generic"


@dataclass
class ExportContents:
    """FR44 selectable contents, for the FIT arm. `variants` / `cue_sheet` are
    other formats' concerns; here the toggles that change the byte stream."""

    track: bool = True
    elevation: bool = True
    course_points: bool = True
    notes_in_names: bool = True


@dataclass
class FitExport:
    """`export_course_fit` result: the bytes plus what the reveal gate and the
    FR108 policy left out, for the caller's export report / the harness."""

    data: bytes
    withheld: tuple[str, ...] = ()        # course-point ids dropped by the reveal gate
    areas_dropped: tuple[str, ...] = ()   # area-anchor ids with no FIT representation


# ------------------------------------------------------------------ helpers

def _is_revealed(*, reveal: str, hazard: bool) -> bool:
    """A course point's content reaches export only if its role's reveal policy
    ships it, or it is a hazard (hazards are never withheld — PRD §1.5)."""
    return bool(hazard) or reveal in _REVEALED_VALUES


def fit_cue_name(name: str, note: str | None, *, cap: int = FIT_CUE_NAME_CAP) -> str:
    """The `course_point.name` string: the marker name, then its note where it
    fits, cut on a **word** boundary at `cap` characters and hard-capped at
    `FIT_NAME_BYTE_CEILING` bytes (SPIKE-16 F3 task 1).

    The device shows an icon for the point's type, so the note is where the
    Author's words actually live; it rides in `name` because `course_point` has
    no separate description field.
    """
    combined = f"{name} — {note}" if note else name
    out = _clip_to_words(combined, cap)
    while len(out.encode("utf-8")) > FIT_NAME_BYTE_CEILING:
        stripped = out[:-1].rstrip() if out.endswith(_ELLIPSIS) else out
        out = _clip_to_words(stripped, max(1, len(stripped) - 4))
    return out


def _clip_to_words(text: str, cap: int) -> str:
    """`text` cut to at most `cap` characters (plus a trailing ellipsis), never
    through the middle of a word."""
    if cap <= 0:
        return ""
    if len(text) <= cap:
        return text
    head = text[:cap]
    if text[cap].isalnum() and head[-1:].isalnum():   # cut fell mid-word
        space = head.rfind(" ")
        if space > 0:
            head = head[:space]
    return head.rstrip(" —-") + _ELLIPSIS


# ----------------------------------------------------------------- the writer

def export_course_fit(
    course: CourseExport,
    *,
    contents: ExportContents | None = None,
    name_cap: int = FIT_CUE_NAME_CAP,
    area_centroid_points: bool = False,
) -> FitExport:
    """Encode `course` as a FIT course file.

    Message order matches Garmin's own course exporter and the file class of the
    reference activities in `spikes/fit_files/`::

        file_id -> file_creator -> course -> event(start)
          -> [record ...] -> [course_point ...] -> lap -> event(stop)
    """
    contents = contents or ExportContents()
    track = course.track
    if not track:
        raise ValueError("CourseExport.track is empty — a FIT course needs a line")

    t0 = course.start_unix
    speed = course.nominal_speed_mps
    enc = FitEncoder()

    def clock(distance_m: float) -> int:
        return fit_time(t0 + (distance_m / speed if speed else 0.0))

    # ---- file_id / file_creator ---------------------------------------
    enc.write("file_id", {
        0: FILE_COURSE,
        1: FIT_MANUFACTURER,
        2: FIT_PRODUCT,
        3: 0xA5A5A5A5,
        4: fit_time(t0),
        5: 1,
    })
    enc.write("file_creator", {0: FIT_SOFTWARE_VERSION, 1: 1})

    # ---- course -----------------------------------------------------
    enc.write("course", {
        4: SPORT.get(course.sport, SPORT["generic"]),
        5: course.title[:FIT_NAME_BYTE_CEILING],
    })

    # ---- event: timer start ---------------------------------------
    enc.write("event", {253: fit_time(t0), 0: EVENT_TIMER, 1: EVENT_TYPE_START})

    # ---- record stream ------------------------------------------
    if contents.track:
        for tp in track:
            rec = {
                253: clock(tp.distance_m),
                0: semicircles(tp.lat),
                1: semicircles(tp.lon),
                5: distance_raw(tp.distance_m),
                6: round(speed * 1000) if speed else None,
            }
            if contents.elevation and tp.elevation_m is not None:
                rec[2] = altitude_raw(tp.elevation_m)
            enc.write("record", rec)

    # ---- course_point stream (reveal gate applied to the bytes) ------
    withheld: list[str] = []
    areas_dropped: list[str] = []
    if contents.course_points:
        idx = 0
        for cp in course.course_points:
            if not _is_revealed(reveal=cp.reveal, hazard=cp.hazard):
                withheld.append(cp.id)
                continue
            note = cp.note if contents.notes_in_names else None
            enc.write("course_point", {
                254: idx,
                1: clock(cp.distance_m),
                2: semicircles(cp.lat),
                3: semicircles(cp.lon),
                4: distance_raw(cp.distance_m),
                5: COURSE_POINT_TYPE.get(cp.cp_type, COURSE_POINT_TYPE["generic"]),
                6: fit_cue_name(cp.name, note, cap=name_cap),
            })
            idx += 1

        # FR108 areas — no native FIT slot (SPIKE-16 F3 task 2)
        for area in course.areas:
            if not _is_revealed(reveal=area.reveal, hazard=area.hazard):
                withheld.append(area.id)
                continue
            if not area_centroid_points:
                areas_dropped.append(area.id)
                continue
            lat, lon = centroid(area.polygon)
            enc.write("course_point", {
                254: idx,
                2: semicircles(lat),
                3: semicircles(lon),
                5: COURSE_POINT_TYPE["generic"],
                6: fit_cue_name(area.name, None, cap=name_cap),
            })
            idx += 1

    # ---- lap + timer stop ---------------------------------------
    total_m = track[-1].distance_m
    last_t = t0 + (total_m / speed if speed else 0.0)
    enc.write("lap", {
        253: fit_time(last_t),
        2: fit_time(t0),
        3: semicircles(track[0].lat),
        4: semicircles(track[0].lon),
        5: semicircles(track[-1].lat),
        6: semicircles(track[-1].lon),
        7: round((last_t - t0) * 1000),
        8: round((last_t - t0) * 1000),
        9: distance_raw(total_m),
    })
    enc.write("event", {253: fit_time(last_t), 0: EVENT_TIMER, 1: EVENT_TYPE_STOP_ALL})

    return FitExport(
        data=enc.getvalue(),
        withheld=tuple(withheld),
        areas_dropped=tuple(areas_dropped),
    )
