import costmodel
import regions as R
from strategies import RenderPlan


def _plan(widgets=0, dots=0, glyphs=0, poly=0, idx=0):
    return RenderPlan(
        strategy="t", zoom=12, in_viewport=widgets + dots + glyphs,
        widget_markers=widgets, canvas_dots=dots, cluster_glyphs=glyphs,
        polygon_vertices=poly, cluster_index_candidates=idx,
        salience_visible=True, overview_usable=True,
        map_to_list_exact=True, promote_from_map_direct=True,
    )


def test_frame_cost_charges_nothing_for_an_empty_plan():
    fc = costmodel.frame_cost(_plan(), "windows-gpu")
    assert fc.total_p95_ms == R.BASEMAP_WARM_FRAME_MS["windows-gpu"]["p95"]
    assert not fc.over_budget


def test_frame_cost_widgets_are_more_expensive_than_dots():
    w = costmodel.frame_cost(_plan(widgets=500), "windows-gpu").marker_add_ms
    d = costmodel.frame_cost(_plan(dots=500), "windows-gpu").dot_add_ms
    assert w > d * 10


def test_naive_at_bbox_density_blows_the_budget_on_gpu():
    fc = costmodel.frame_cost(_plan(widgets=1200), "windows-gpu")
    assert fc.over_budget


def test_software_raster_headroom_is_tiny():
    # a couple of dozen widgets is enough to reach budget on llvmpipe
    fc = costmodel.frame_cost(_plan(widgets=30), "linux-swraster")
    assert fc.over_budget


def test_memory_cost_dominated_by_widgets_not_dots():
    mw = costmodel.memory_cost(_plan(widgets=1000), "windows-gpu")
    md = costmodel.memory_cost(_plan(dots=1000), "windows-gpu")
    assert mw.marker_add_mb > md.dot_add_mb * 50


def test_memory_stays_under_1gb_for_recommended_load():
    mc = costmodel.memory_cost(_plan(widgets=305, dots=3000, poly=2500, idx=0), "windows-gpu")
    assert not mc.over_1gb


def test_selection_latency_dominated_by_marker_layer_rebuild():
    naive = costmodel.selection_cost(_plan(widgets=1200), "windows-gpu")
    gated = costmodel.selection_cost(_plan(widgets=305, dots=900), "windows-gpu")
    assert naive.rebuild_on_select_ms > gated.rebuild_on_select_ms
    assert gated.usable
    # selection latency is a function of live widget count, not total density
    assert gated.map_to_list_ms < naive.map_to_list_ms


def test_list_to_map_is_not_density_sensitive():
    a = costmodel.selection_cost(_plan(widgets=50), "windows-gpu").list_to_map_ms
    b = costmodel.selection_cost(_plan(widgets=5000), "windows-gpu").list_to_map_ms
    assert a == b
