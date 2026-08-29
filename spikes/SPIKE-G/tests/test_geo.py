import math

import geo


def test_viewport_shrinks_with_zoom():
    prev_area = None
    for z in (8, 10, 12, 14, 16):
        s, w, n, e = geo.viewport_bbox(35.5, -82.5, z, 1280, 720)
        area = (n - s) * (e - w)
        assert n > s and e > w
        if prev_area is not None:
            # each zoom level quarters the ground area (2x each axis)
            assert area < prev_area / 3.5
        prev_area = area


def test_viewport_centered_on_point():
    s, w, n, e = geo.viewport_bbox(40.0, -105.0, 12, 1280, 720)
    assert s < 40.0 < n
    assert w < -105.0 < e


def test_in_bbox():
    bb = (10.0, 20.0, 30.0, 40.0)
    assert geo.in_bbox(20.0, 30.0, bb)
    assert not geo.in_bbox(5.0, 30.0, bb)
    assert not geo.in_bbox(20.0, 50.0, bb)


def test_screen_xy_center_is_window_center():
    x, y = geo.screen_xy(35.5, -82.5, 35.5, -82.5, 13, 1280, 720)
    assert math.isclose(x, 640.0, abs_tol=1e-6)
    assert math.isclose(y, 360.0, abs_tol=1e-6)


def test_geodesic_area_of_a_square():
    # ~1 km square near the equator
    d = 1000.0 / 111_320.0
    ring = [(0.0, 0.0), (0.0, d), (d, d), (d, 0.0)]
    area = geo.geodesic_area_m2(ring)
    assert 0.9e6 < area < 1.1e6


def test_geodesic_area_degenerate():
    assert geo.geodesic_area_m2([(0.0, 0.0), (1.0, 1.0)]) == 0.0
