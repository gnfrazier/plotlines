"""The slice of the FIT Profile a *course* file needs — and nothing else.

Ported into `plotlines-core` from `spikes/SPIKE-16/profile.py` (SPIKE-16, issue
#163). FIT's full profile defines ~200 messages and thousands of fields; a course
export touches **seven** messages, and that sub-profile has not changed across FIT
protocol 1.0 -> 2.0. A device parses by message/field *number*, never by name.

`basis`: FIT SDK 21.x `Profile.xlsx`, sheets "Messages" and "Types". Every number
used here was cross-checked against the message inventory decoded from the real
`.fit` files in `spikes/fit_files/`.
"""

from __future__ import annotations

import math

# --------------------------------------------------------------- base types
# type name -> (type byte, size, struct code, invalid value)
BASE_TYPES: dict[str, tuple[int, int, str, int]] = {
    "enum":    (0x00, 1, "B", 0xFF),
    "sint8":   (0x01, 1, "b", 0x7F),
    "uint8":   (0x02, 1, "B", 0xFF),
    "sint16":  (0x83, 2, "h", 0x7FFF),
    "uint16":  (0x84, 2, "H", 0xFFFF),
    "sint32":  (0x85, 4, "i", 0x7FFFFFFF),
    "uint32":  (0x86, 4, "I", 0xFFFFFFFF),
    "string":  (0x07, 0, "s", 0x00),
    "uint8z":  (0x0A, 1, "B", 0x00),
    "uint16z": (0x8B, 2, "H", 0x0000),
    "uint32z": (0x8C, 4, "I", 0x00000000),
    "byte":    (0x0D, 1, "B", 0xFF),
}
BASE_TYPE_BY_BYTE = {v[0]: k for k, v in BASE_TYPES.items()}

# ----------------------------------------------------------------- messages
MESG: dict[str, int] = {
    "file_id":      0,
    "file_creator": 49,
    "event":        21,
    "course":       31,
    "lap":          19,
    "record":       20,
    "course_point": 32,
}

# field number -> (name, base type) — only the fields a course writer sets
FIELDS: dict[str, dict[int, tuple[str, str]]] = {
    "file_id": {
        0: ("type", "enum"),            # 6 = course
        1: ("manufacturer", "uint16"),
        2: ("product", "uint16"),
        3: ("serial_number", "uint32z"),
        4: ("time_created", "uint32"),  # date_time
        5: ("number", "uint16"),
    },
    "file_creator": {
        0: ("software_version", "uint16"),
        1: ("hardware_version", "uint8"),
    },
    "event": {
        253: ("timestamp", "uint32"),
        0: ("event", "enum"),          # 0 = timer
        1: ("event_type", "enum"),     # 0 = start, 4 = stop_all
    },
    "course": {
        4: ("sport", "enum"),
        5: ("name", "string"),
    },
    "lap": {
        253: ("timestamp", "uint32"),
        2: ("start_time", "uint32"),
        3: ("start_position_lat", "sint32"),
        4: ("start_position_long", "sint32"),
        5: ("end_position_lat", "sint32"),
        6: ("end_position_long", "sint32"),
        7: ("total_elapsed_time", "uint32"),   # s * 1000
        8: ("total_timer_time", "uint32"),     # s * 1000
        9: ("total_distance", "uint32"),       # m * 100
    },
    "record": {
        253: ("timestamp", "uint32"),
        0: ("position_lat", "sint32"),    # semicircles
        1: ("position_long", "sint32"),   # semicircles
        2: ("altitude", "uint16"),        # (m + 500) * 5
        5: ("distance", "uint32"),        # m * 100
        6: ("speed", "uint16"),           # m/s * 1000
    },
    "course_point": {
        254: ("message_index", "uint16"),
        1: ("timestamp", "uint32"),
        2: ("position_lat", "sint32"),
        3: ("position_long", "sint32"),
        4: ("distance", "uint32"),        # m * 100
        5: ("type", "enum"),
        6: ("name", "string"),
        8: ("favorite", "enum"),
    },
}

# -------------------------------------------------------------------- enums
FILE_COURSE = 6
SPORT = {"cycling": 2, "hiking": 17, "running": 1, "paddling": 19,
         "walking": 11, "generic": 0}
EVENT_TIMER = 0
EVENT_TYPE_START = 0
EVENT_TYPE_STOP_ALL = 4

# course_point.type — the enum a head unit switches on to pick an icon and a
# turn/cue behaviour. Per SPIKE-16 (FR45 finding): FIT *has* a native slot for
# every marker type Plotlines produces, so "where the target format supports
# them" is, at the format level, all of them. Which head unit draws each one is
# the per-device table in `spikes/SPIKE-16/HARNESS.md` — that needs hardware.
COURSE_POINT_TYPE: dict[str, int] = {
    "generic": 0,
    "summit": 1,
    "valley": 2,
    "water": 3,
    "food": 4,
    "danger": 5,
    "left": 6,
    "right": 7,
    "straight": 8,
    "sharp_left": 9,
    "sharp_right": 10,
    "slight_left": 11,
    "slight_right": 12,
    "u_turn": 13,
    "segment_start": 14,
    "segment_end": 15,
    "first_category": 17,
    "second_category": 18,
    "third_category": 19,
    "fourth_category": 20,
    "general_distance": 24,
    "rest_area": 28,   # SDK 21.x — where present, a Plotlines "rest stop"
}

# --------------------------------------------------------- unit conversions
_SEMI = 2 ** 31 / 180.0
FIT_EPOCH_UNIX = 631065600  # 1989-12-31T00:00:00Z


def semicircles(deg_value: float) -> int:
    return round(deg_value * _SEMI)


def degrees(semi: int) -> float:
    return semi / _SEMI


def fit_time(unix_s: float) -> int:
    return round(unix_s - FIT_EPOCH_UNIX)


def altitude_raw(m: float) -> int:
    return round((m + 500.0) * 5.0)


def distance_raw(m: float) -> int:
    return round(m * 100.0)


def centroid(polygon: list[tuple[float, float]]) -> tuple[float, float]:
    """Area centroid (lat, lon) of a simple polygon, for the FR108 fallback.

    Falls back to the vertex mean for a degenerate ring (zero signed area).
    """
    pts = list(polygon)
    if pts and pts[0] == pts[-1]:
        pts = pts[:-1]
    n = len(pts)
    if n < 3:
        lat = sum(p[0] for p in pts) / n
        lon = sum(p[1] for p in pts) / n
        return lat, lon
    a = cx = cy = 0.0
    for i in range(n):
        x0, y0 = pts[i][1], pts[i][0]
        x1, y1 = pts[(i + 1) % n][1], pts[(i + 1) % n][0]
        cross = x0 * y1 - x1 * y0
        a += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    a *= 0.5
    if math.isclose(a, 0.0):
        lat = sum(p[0] for p in pts) / n
        lon = sum(p[1] for p in pts) / n
        return lat, lon
    return cy / (6.0 * a), cx / (6.0 * a)
