"""Price a `RenderPlan` in the three currencies the spike question asks about:
frame time (against SPIKE-14's warm basemap frame), memory (against SPIKE-14's
~1 GB client budget), and selection latency (against a "feels instant" ceiling).

Every coefficient is imported from `regions.py`, where it is pre-registered with
its basis. This module only does arithmetic.
"""

from __future__ import annotations

from dataclasses import dataclass

import regions as R
from strategies import RenderPlan


@dataclass(frozen=True)
class FrameCost:
    platform: str
    warm: bool
    basemap_frame_ms: float     # SPIKE-14's frame, unmodified
    marker_add_ms: float        # what this plan adds on top
    dot_add_ms: float
    polygon_add_ms: float
    total_p95_ms: float
    over_budget: bool
    headroom_ms: float


def frame_cost(plan: RenderPlan, platform: str, warm: bool = True) -> FrameCost:
    base = R.BASEMAP_WARM_FRAME_MS[platform]["p95" if warm else "p50"]
    marker_ms = plan.widget_markers * R.WIDGET_MARKER_FRAME_US[platform].value / 1000.0
    # a cluster glyph is a widget too (it shows a count and is tappable)
    marker_ms += plan.cluster_glyphs * R.WIDGET_MARKER_FRAME_US[platform].value / 1000.0
    dot_ms = plan.canvas_dots * R.CANVAS_DOT_FRAME_US[platform].value / 1000.0
    poly_ms = plan.polygon_vertices * R.POLYGON_VERTEX_FRAME_US[platform].value / 1000.0
    total = base + marker_ms + dot_ms + poly_ms
    return FrameCost(
        platform=platform,
        warm=warm,
        basemap_frame_ms=base,
        marker_add_ms=round(marker_ms, 2),
        dot_add_ms=round(dot_ms, 2),
        polygon_add_ms=round(poly_ms, 2),
        total_p95_ms=round(total, 2),
        over_budget=total > R.FRAME_BUDGET_MS,
        headroom_ms=round(R.FRAME_BUDGET_MS - total, 2),
    )


@dataclass(frozen=True)
class MemoryCost:
    platform: str
    spike14_client_mb: float     # route + basemap, from SPIKE-14
    marker_add_mb: float
    dot_add_mb: float
    polygon_add_mb: float
    cluster_index_add_mb: float
    total_mb: float
    over_1gb: bool


def memory_cost(plan: RenderPlan, platform: str) -> MemoryCost:
    base = R.MEM_SPIKE14_CLIENT_BUDGET_MB[platform]
    marker_mb = (plan.widget_markers + plan.cluster_glyphs) * R.WIDGET_MARKER_RSS_KB.value / 1024.0
    dot_mb = plan.canvas_dots * R.CANVAS_DOT_RSS_KB.value / 1024.0
    poly_mb = plan.polygon_vertices * R.POLYGON_RSS_KB_PER_VERTEX.value / 1024.0
    idx_mb = plan.cluster_index_candidates * R.CLUSTER_INDEX_RSS_KB_PER_CANDIDATE.value / 1024.0
    total = base + marker_mb + dot_mb + poly_mb + idx_mb
    return MemoryCost(
        platform=platform,
        spike14_client_mb=base,
        marker_add_mb=round(marker_mb, 2),
        dot_add_mb=round(dot_mb, 2),
        polygon_add_mb=round(poly_mb, 2),
        cluster_index_add_mb=round(idx_mb, 2),
        total_mb=round(total, 1),
        over_1gb=total > 1024.0,
    )


@dataclass(frozen=True)
class SelectionCost:
    platform: str
    list_to_map_ms: float        # select a card -> map reacts
    map_to_list_ms: float        # tap the map -> card selected (incl. any rebuild)
    cluster_extent_ms: float     # highlight a cluster's extent
    rebuild_on_select_ms: float  # the MarkerLayer rebuild a naive setState triggers
    worst_ms: float
    feels_instant: bool          # <= 100 ms
    usable: bool                 # <= 250 ms  (the issue's "300 ms == unusable")


INSTANT_MS = 100.0
USABLE_MS = 250.0


def selection_cost(plan: RenderPlan, platform: str, members_per_cluster: int = 20) -> SelectionCost:
    l2m = R.LIST_TO_MAP_FIXED_MS.value

    # map -> list: hit-test the widget markers near the pointer + analytic scan
    # over the dots. Both are tiny; the real cost is the rebuild below.
    hit_widgets_ms = (plan.widget_markers + plan.cluster_glyphs) * R.HITTEST_WIDGET_US.value / 1000.0
    hit_dots_ms = plan.canvas_dots * R.HITTEST_ANALYTIC_US.value / 1000.0

    # a tap that calls setState on the MarkerLayer rebuilds every live widget once
    rebuild_ms = (plan.widget_markers + plan.cluster_glyphs) * R.SELECTION_REBUILD_US_PER_WIDGET.value / 1000.0

    m2l = hit_widgets_ms + hit_dots_ms + rebuild_ms

    extent_ms = members_per_cluster * R.CLUSTER_EXTENT_US_PER_MEMBER.value

    worst = max(l2m, m2l, extent_ms)
    return SelectionCost(
        platform=platform,
        list_to_map_ms=round(l2m, 2),
        map_to_list_ms=round(m2l, 2),
        cluster_extent_ms=round(extent_ms, 2),
        rebuild_on_select_ms=round(rebuild_ms, 2),
        worst_ms=round(worst, 2),
        feels_instant=worst <= INSTANT_MS,
        usable=worst <= USABLE_MS,
    )
