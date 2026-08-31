"""The findings the spike is actually here to defend: course-point fidelity and
the reveal gate at the byte boundary (punch-list §6A.2)."""

from course import build_course_fit
from fitdec import decode
from fixture import build_fixture
from profile import COURSE_POINT_TYPE, deg

REQUIRED = ["left", "water", "food", "danger", "generic"]


def _course():
    fx = build_fixture()
    return fx, decode(build_course_fit(fx))


def test_all_required_course_point_types_present():
    _, dec = _course()
    got = {m.get(5) for m in dec.of("course_point")}
    for name in REQUIRED:
        assert COURSE_POINT_TYPE[name] in got, name


def test_unrevealed_note_text_absent_from_output_bytes():
    fx = build_fixture()
    data = build_course_fit(fx)
    assert fx["reveal_canary"].encode("utf-8") not in data


def test_unrevealed_plot_point_produces_no_course_point():
    fx, dec = _course()
    cps = dec.of("course_point")
    withheld = build_course_fit.last_withheld
    assert "pp-still-site" in withheld
    assert len(cps) == len([p for p in fx["plot_points"] if p["id"] not in withheld])
    assert not any("still" in (m.get(6) or "").lower() for m in cps)


def test_hazard_is_exported_even_though_it_is_not_marked_reveal_always_semantically():
    # the washout carries hazard=True; hazards are never withheld (PRD 1.5)
    _, dec = _course()
    danger = [m for m in dec.of("course_point") if m.get(5) == COURSE_POINT_TYPE["danger"]]
    assert len(danger) == 1
    assert "dismount" in danger[0].get(6, "").lower()


def test_revealed_note_rides_in_the_course_point_name():
    _, dec = _course()
    cps = dec.of("course_point")
    spring = next(m for m in cps if "spring tap" in m.get(6, "").lower())
    assert "potable" in spring.get(6, "").lower()


def test_role_offset_point_exported_at_offset_not_anchor():
    fx, dec = _course()
    off_pp = next(p for p in fx["plot_points"] if p.get("offset_from"))
    off_cp = next(m for m in dec.of("course_point") if "offset" in (m.get(6) or "").lower())
    assert abs(deg(off_cp.get(2)) - off_pp["pos"][0]) < 1e-5
    assert abs(deg(off_cp.get(3)) - off_pp["pos"][1]) < 1e-5


def test_message_index_contiguous():
    _, dec = _course()
    idx = [m.get(254) for m in dec.of("course_point")]
    assert idx == list(range(len(idx)))


def test_record_count_equals_polyline_length_and_elevation_present():
    fx, dec = _course()
    recs = dec.of("record")
    assert len(recs) == len(fx["segment"]["polyline"])
    assert all(m.get(2) is not None for m in recs)  # altitude on every record


def test_contents_toggle_drops_course_points():
    fx = build_fixture()
    dec = decode(build_course_fit(fx, contents={"track": True, "elevation": False,
                                                "course_points": False, "notes_in_names": False}))
    assert dec.of("course_point") == []
    assert all(m.get(2) is None for m in dec.of("record"))  # elevation suppressed
