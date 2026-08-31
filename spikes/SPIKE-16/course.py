"""fixture -> FIT course bytes, with reveal policy applied at the byte boundary.

This is the shape `plotlines_core.export.export_trip(trip, "fit", contents,
reveal_view)` would take (ARCH §6.1). The reveal decision happens *here*, before
a byte is written — a plot point whose role is not revealed contributes no
`course_point` message and no name string at all. That is the §6A.2 posture:
assert on the bytes, not the code path.

Message order matches what Garmin's own course exporter emits and what the
reference activity files in `spikes/fit_files/` show for their file class:

    file_id -> file_creator -> course -> event(start)
      -> [record ...] -> [course_point ...] -> lap -> event(stop)
"""

from __future__ import annotations

from fitenc import FitEncoder
from profile import (
    COURSE_POINT_TYPE, EVENT_TIMER, EVENT_TYPE_START, EVENT_TYPE_STOP_ALL,
    FILE_COURSE, SPORT, altitude_raw, distance_raw, fit_time, semicircles,
)

MANUFACTURER_DEVELOPMENT = 255   # FIT's "development / not a real manufacturer" id
_GARMIN_NAME_CAP = 16            # course_point.name practical cap on many head units


def _revealed(pp: dict) -> bool:
    """A plot point's content reaches export only if its role's reveal policy is
    'always' (provision content, hazards, and Author-marked-visible narrative).
    Anything held for arrival is withheld here. Hazards are never withheld."""
    if pp.get("hazard"):
        return True
    return pp.get("reveal") == "always"


def build_course_fit(fixture: dict, *, contents: dict | None = None) -> bytes:
    contents = contents or {
        "track": True, "elevation": True, "course_points": True, "notes_in_names": True,
    }
    seg = fixture["segment"]
    poly = seg["polyline"]
    cum = seg["cumulative_m"]
    t0 = seg["start_unix"]
    speed = seg["nominal_speed_mps"]
    enc = FitEncoder()

    # ---- file_id / file_creator -------------------------------------------
    enc.write("file_id", {
        0: FILE_COURSE,
        1: MANUFACTURER_DEVELOPMENT,
        2: 1,
        3: 0xA5A5A5A5,
        4: fit_time(t0),
        5: 1,
    })
    enc.write("file_creator", {0: 1, 1: 1})

    # ---- course ----------------------------------------------------------
    name = fixture["trip"]["title"][:_GARMIN_NAME_CAP * 4]
    enc.write("course", {4: SPORT.get(fixture["trip"].get("sport", "generic"), 0), 5: name})

    # ---- event: timer start -------------------------------------------
    enc.write("event", {253: fit_time(t0), 0: EVENT_TIMER, 1: EVENT_TYPE_START})

    # ---- record stream -----------------------------------------------
    if contents.get("track", True):
        for (lat, lon, ele), d in zip(poly, cum):
            t = t0 + (d / speed if speed else 0)
            rec = {
                253: fit_time(t),
                0: semicircles(lat),
                1: semicircles(lon),
                5: distance_raw(d),
                6: int(round(speed * 1000)),
            }
            if contents.get("elevation", True):
                rec[2] = altitude_raw(ele)
            enc.write("record", rec)

    # ---- course_point stream (reveal applied) -----------------------------
    withheld = []
    if contents.get("course_points", True):
        idx = 0
        for pp in fixture["plot_points"]:
            if not _revealed(pp):
                withheld.append(pp["id"])
                continue
            lat, lon, _ele, d = pp["pos"]
            cp_name = pp["name"]
            if contents.get("notes_in_names", True) and pp.get("note"):
                # FR45: the note rides in the native point's name where it fits.
                cp_name = f"{pp['name']} — {pp['note']}"
            cp = {
                254: idx,
                1: fit_time(t0 + (d / speed if speed else 0)),
                2: semicircles(lat),
                3: semicircles(lon),
                4: distance_raw(d),
                5: COURSE_POINT_TYPE.get(pp["cp_type"], COURSE_POINT_TYPE["generic"]),
                6: cp_name[:_GARMIN_NAME_CAP * 4],
            }
            enc.write("course_point", cp)
            idx += 1

    # ---- lap + timer stop ----------------------------------------------
    last_t = t0 + (seg["total_m"] / speed if speed else 0)
    enc.write("lap", {
        253: fit_time(last_t),
        2: fit_time(t0),
        3: semicircles(poly[0][0]),
        4: semicircles(poly[0][1]),
        5: semicircles(poly[-1][0]),
        6: semicircles(poly[-1][1]),
        7: int(round((last_t - t0) * 1000)),
        8: int(round((last_t - t0) * 1000)),
        9: distance_raw(seg["total_m"]),
    })
    enc.write("event", {253: fit_time(last_t), 0: EVENT_TIMER, 1: EVENT_TYPE_STOP_ALL})

    data = enc.getvalue()
    build_course_fit.last_withheld = withheld    # for the harness/report
    return data
