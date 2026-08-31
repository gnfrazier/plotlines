"""Story F3 — the FIT course writer (`plotlines_core.export.fit`).

Ported from `spikes/SPIKE-16/tests/`. Pins the container invariants (CRC, header,
declared size), the reveal gate at the byte boundary (punch-list §6A.2), the
FR45 course-point-type fidelity, and the four F3 tasks SPIKE-16 named in the
issue #69 comment: word-boundary name truncation, FR108 areas dropped from FIT,
FR107 role offsets honoured, and a named `file_id.manufacturer`.
"""

from __future__ import annotations

import struct

import pytest
from fit_helpers import decode
from plotlines_core.export import (
    AreaAnchor,
    CourseExport,
    CoursePoint,
    ExportContents,
    TrackPoint,
    export_course_fit,
    fit_cue_name,
)
from plotlines_core.export._fit_encoder import fit_crc16
from plotlines_core.export._fit_profile import COURSE_POINT_TYPE, degrees
from plotlines_core.export.fit import FIT_MANUFACTURER, FIT_NAME_BYTE_CEILING

_START_UNIX = 1_726_000_000
_CANARY = "CANARY-6A2 the mash tuns are under the collapsed springhouse floor"

REQUIRED_TYPES = ["left", "water", "food", "danger", "generic"]


def _track() -> list[TrackPoint]:
    pts = []
    lat, lon, d = 35.5846, -82.5771, 0.0
    for i in range(33):
        lat += 0.00062
        lon += 0.00033
        d += 78.0
        pts.append(TrackPoint(lat=lat, lon=lon, distance_m=d, elevation_m=632.0 + 0.6 * i))
    return pts


def _course(**overrides) -> CourseExport:
    tp = _track()

    def at(frac: float) -> tuple[float, float, float]:
        p = tp[int(frac * (len(tp) - 1))]
        return p.lat, p.lon, p.distance_m

    lat_j, lon_j, d_j = at(0.36)
    lat_s, lon_s, d_s = at(0.20)
    lat_c, lon_c, d_c = at(0.94)
    lat_w, lon_w, d_w = at(0.58)
    lat_o, lon_o, d_o = at(0.47)
    lat_h, lon_h, d_h = at(0.83)
    lat_x, lon_x, d_x = at(0.72)

    cps = [
        CoursePoint("pp-junction", "left", "Bear left at the greenway split",
                    lat_j, lon_j, d_j,
                    note="Stay river-side; the right fork climbs to the road."),
        CoursePoint("pp-spring", "water", "Riverside spring tap", lat_s, lon_s, d_s,
                    note="Potable; last water before the depot."),
        CoursePoint("pp-depot-cafe", "food", "Depot cafe", lat_c, lon_c, d_c,
                    note="Opens 07:00. Cash only."),
        CoursePoint("pp-washout", "danger", "Washout — dismount", lat_w, lon_w, d_w,
                    note="Trail edge undercut after high water. Walk it.",
                    hazard=True),
        CoursePoint("pp-overlook", "generic", "River overlook", lat_o, lon_o, d_o,
                    note="Worth the stop."),
        # held until arrival — must not reach the bytes
        CoursePoint("pp-still-site", "generic", "Old still site", lat_h, lon_h, d_h,
                    note=_CANARY, reveal="on_arrival"),
        # FR107 — a station role carried ~40 m off its anchor's point
        CoursePoint("pp-shuttle-pickup", "generic", "Shuttle pickup (offset)",
                    lat_x + 40 / 111_320, lon_x + 40 / 111_320, d_x,
                    note="Pin sits ~40 m off-trail at the lot.",
                    reveal="always_visible"),
    ]
    areas = [AreaAnchor("area-rail-district", "Depot rail district",
                        [(35.597, -82.566), (35.598, -82.564),
                         (35.596, -82.563), (35.595, -82.565)])]
    kwargs = {
        "title": "French Broad Greenway — Depot Run",
        "start_unix": _START_UNIX,
        "nominal_speed_mps": 4.4,
        "track": tp,
        "course_points": cps,
        "areas": areas,
        "sport": "cycling",
    }
    kwargs.update(overrides)
    return CourseExport(**kwargs)


# --- container invariants ------------------------------------------------

def test_output_has_fit_signature_and_14_byte_header():
    data = export_course_fit(_course()).data
    assert data[0] == 14
    assert data[8:12] == b".FIT"


def test_header_and_file_crc_are_valid():
    data = export_course_fit(_course()).data
    assert fit_crc16(data[:12]) == struct.unpack("<H", data[12:14])[0]
    assert fit_crc16(data[:-2]) == struct.unpack("<H", data[-2:])[0]


def test_declared_data_size_matches_actual():
    data = export_course_fit(_course()).data
    assert struct.unpack("<I", data[4:8])[0] == len(data) - 14 - 2


def test_crc16_arc_canonical_check_value():
    assert fit_crc16(b"123456789") == 0xBB3D


def test_crc16_is_seedable_continuable():
    a, b = b"the mash tuns", b" are under the floor"
    assert fit_crc16(a + b) == fit_crc16(b, fit_crc16(a))


def test_empty_track_is_rejected():
    with pytest.raises(ValueError):
        export_course_fit(_course(track=[]))


# --- structure ---------------------------------------------------------

def test_message_order_and_record_count():
    dec = decode(export_course_fit(_course()).data)
    names = [m.name for m in dec.messages]
    assert names[0] == "file_id"
    assert names[1] == "file_creator"
    assert "course" in names[:4]
    assert len(dec.of("record")) == len(_course().track)
    assert names[-1] == "event"


def test_file_id_manufacturer_is_the_named_constant():
    dec = decode(export_course_fit(_course()).data)
    assert dec.of("file_id")[0].get(1) == FIT_MANUFACTURER


def test_message_index_contiguous():
    dec = decode(export_course_fit(_course()).data)
    idx = [m.get(254) for m in dec.of("course_point")]
    assert idx == list(range(len(idx)))


# --- FR45 course-point fidelity --------------------------------------

def test_all_required_course_point_types_present():
    dec = decode(export_course_fit(_course()).data)
    got = {m.get(5) for m in dec.of("course_point")}
    for name in REQUIRED_TYPES:
        assert COURSE_POINT_TYPE[name] in got, name


def test_revealed_note_rides_in_the_course_point_name():
    dec = decode(export_course_fit(_course()).data)
    spring = next(m for m in dec.of("course_point")
                  if "spring tap" in m.get(6, "").lower())
    assert "potable" in spring.get(6, "").lower()


# --- reveal gate at the byte boundary (§6A.2) -----------------------

def test_unrevealed_note_text_absent_from_output_bytes():
    data = export_course_fit(_course()).data
    assert _CANARY.encode("utf-8") not in data


def test_unrevealed_plot_point_produces_no_course_point():
    result = export_course_fit(_course())
    dec = decode(result.data)
    assert "pp-still-site" in result.withheld
    assert not any("still" in (m.get(6) or "").lower() for m in dec.of("course_point"))


def test_positive_control_canary_is_in_the_fixture():
    # absence in the bytes is the writer dropping it, not the fixture lacking it
    assert any(cp.note == _CANARY for cp in _course().course_points)


def test_hazard_is_exported_even_when_not_reveal_always():
    dec = decode(export_course_fit(_course()).data)
    danger = [m for m in dec.of("course_point")
              if m.get(5) == COURSE_POINT_TYPE["danger"]]
    assert len(danger) == 1
    assert "dismount" in danger[0].get(6, "").lower()


# --- FR107 role offsets (SPIKE-16 F3 task 3) -------------------------

def test_role_offset_point_exported_at_offset_not_anchor():
    course = _course()
    dec = decode(export_course_fit(course).data)
    off_src = next(cp for cp in course.course_points if cp.id == "pp-shuttle-pickup")
    off_cp = next(m for m in dec.of("course_point")
                  if "offset" in (m.get(6) or "").lower())
    assert abs(degrees(off_cp.get(2)) - off_src.lat) < 1e-6
    assert abs(degrees(off_cp.get(3)) - off_src.lon) < 1e-6


# --- FR108 areas (SPIKE-16 F3 task 2) ------------------------------

def test_area_anchors_dropped_from_fit_by_default():
    result = export_course_fit(_course())
    assert "area-rail-district" in result.areas_dropped
    dec = decode(result.data)
    assert not any("rail district" in (m.get(6) or "").lower()
                   for m in dec.of("course_point"))


def test_area_centroid_point_emitted_when_opted_in():
    result = export_course_fit(_course(), area_centroid_points=True)
    assert result.areas_dropped == ()
    dec = decode(result.data)
    area_cp = next(m for m in dec.of("course_point")
                   if "rail district" in (m.get(6) or "").lower())
    assert 35.594 < degrees(area_cp.get(2)) < 35.599
    assert -82.567 < degrees(area_cp.get(3)) < -82.562


# --- FR44 contents toggles ------------------------------------------

def test_contents_toggle_drops_course_points_and_elevation():
    dec = decode(export_course_fit(
        _course(),
        contents=ExportContents(track=True, elevation=False,
                                course_points=False, notes_in_names=False),
    ).data)
    assert dec.of("course_point") == []
    assert all(m.get(2) is None for m in dec.of("record"))


def test_notes_in_names_toggle_drops_the_note_only():
    dec = decode(export_course_fit(
        _course(),
        contents=ExportContents(notes_in_names=False),
    ).data)
    spring = next(m for m in dec.of("course_point")
                  if "spring tap" in m.get(6, "").lower())
    assert "potable" not in spring.get(6, "").lower()


# --- SPIKE-16 F3 task 1: word-boundary name truncation ------------

def test_short_name_and_note_pass_through_untouched():
    assert fit_cue_name("Depot cafe", "Cash only", cap=40) == "Depot cafe — Cash only"


def test_long_note_is_cut_on_a_word_boundary_not_mid_word():
    out = fit_cue_name("Bear left at the split",
                       "Stay river-side; the right fork climbs to the road", cap=30)
    assert len(out) <= 31          # cap chars, plus the ellipsis marker
    assert out.endswith("…")
    # the last real token before the ellipsis is a whole word
    assert out[:-1].rstrip().split()[-1].isalpha()


def test_name_never_exceeds_the_byte_ceiling():
    out = fit_cue_name("х" * 50, "многобайтовое примечание здесь и ещё немного",
                       cap=60)
    assert len(out.encode("utf-8")) <= FIT_NAME_BYTE_CEILING


def test_writer_applies_name_cap_parameter():
    dec = decode(export_course_fit(_course(), name_cap=16).data)
    assert all(len(m.get(6, "")) <= 17 for m in dec.of("course_point"))
