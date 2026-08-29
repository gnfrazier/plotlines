import strategies
from extract import Candidate


def _grid(n, salience_hi=10):
    """n candidates on a coarse lat/lon grid around Asheville; the first
    `salience_hi` get salience 0.9, the rest 0.2."""
    out = []
    for i in range(n):
        out.append(
            Candidate(
                id=f"node/{i}",
                lat=35.5 + (i % 20) * 0.002,
                lon=-82.6 + (i // 20) * 0.002,
                salience=0.9 if i < salience_hi else 0.2,
                layer="historic",
                role_affinity="narrative",
                type="historic=monument",
                title=f"c{i}",
            )
        )
    return out


def test_naive_renders_every_candidate_as_a_widget():
    cands = _grid(300)
    plan = strategies.naive(cands, 12, 305, 300)
    assert plan.widget_markers == 300
    assert plan.canvas_dots == 0
    assert plan.salience_visible and plan.overview_usable


def test_zoom_threshold_blank_below_threshold():
    cands = _grid(300)
    below = strategies.zoom_threshold(cands, 10, 305, 300)
    assert below.widget_markers == 0
    assert not below.overview_usable  # the hard-fail the band logic keys on

    above = strategies.zoom_threshold(cands, 15, 305, 300)
    assert above.widget_markers == 300


def test_cluster_grid_bounds_glyphs_by_screen_not_count():
    dense = strategies.cluster_grid(_grid(1200), 12, 305, 1200)
    drawn_dense = dense.widget_markers + dense.cluster_glyphs
    # 1200 candidates collapse to a screen-bounded handful of primitives
    assert drawn_dense < 0.05 * 1200
    # and 24x more candidates do not mean 24x more primitives
    tiny = strategies.cluster_grid(_grid(50), 12, 305, 50)
    drawn_tiny = tiny.widget_markers + tiny.cluster_glyphs
    assert drawn_dense < drawn_tiny * 6
    # a clustered view aggregates salience away
    assert not dense.salience_visible
    assert dense.cluster_index_candidates == 1200


def test_salience_gated_keeps_top_k_as_widgets_rest_as_dots():
    cands = _grid(500, salience_hi=50)
    plan = strategies.salience_gated(cands, 12, 305, 500)
    assert plan.widget_markers == 305
    assert plan.canvas_dots == 195
    assert plan.salience_visible and plan.promote_from_map_direct
    # the widgets are the high-salience ones
    assert plan.widget_markers >= 50


def test_salience_gated_below_k_is_all_widgets():
    plan = strategies.salience_gated(_grid(40), 14, 305, 40)
    assert plan.widget_markers == 40
    assert plan.canvas_dots == 0


def test_area_anchors_contribute_polygon_vertices():
    cands = [
        Candidate("way/1", 35.5, -82.6, 0.8, "leisure", "narrative",
                  "leisure=park", "P", ring=((35.5, -82.6), (35.51, -82.6), (35.51, -82.59))),
    ]
    plan = strategies.naive(cands, 13, 305, 1)
    assert plan.polygon_vertices == 3
