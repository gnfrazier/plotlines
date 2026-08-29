"""SPIKE-G — the fixed inputs: measured anchors and pre-registered coefficients.

Nothing in this file is computed by the spike. It is the two things the analysis
stands on:

1. **Measured anchors** — figures SPIKE-14 published for `flutter_map` +
   `vector_map_tiles` on Flutter desktop, and candidate densities SPIKE-A
   measured in three real trip-sized bboxes. These are quoted, not re-derived.

2. **Pre-registered coefficients** — the marker / polygon / hit-test cost model.
   Every coefficient is declared here *before* any result is read, with the
   basis it rests on, the same discipline SPIKE-13 used for its delivery bands
   and SPIKE-21 for its cues/km ceiling. Changing one of these is changing the
   spike's hypothesis and must come with a written reason.

The model is analytical because the live measurement needs the SPIKE-14 Flutter
harness on two desktop GPUs, which this environment does not have (WSLg is
software-raster only). SPIKE-13 took the same route — pre-registered bands plus
prior art plus a ready harness — when its live half needed infrastructure that
did not exist yet. `HARNESS.md` specifies the live re-measurement that upgrades
these estimates to numbers.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# --------------------------------------------------------------------------- #
# 1. Measured anchors — SPIKE-14 (spikes/SPIKE-14/results/RESULTS.md)
# --------------------------------------------------------------------------- #

FRAME_BUDGET_MS = 16.7  # 60 Hz

# Steady-state frame time with the vector basemap up, route drawn, viewport
# revisited ("warm"). This is the floor a marker layer draws *on top of* — the
# headroom for markers is (FRAME_BUDGET_MS - warm basemap frame).
BASEMAP_WARM_FRAME_MS = {
    # platform          p50    p95     source
    "linux-swraster": {"p50": 11.4, "p95": 15.5},  # §3.0, "Vector basemap, multi, warm"
    "windows-gpu": {"p50": 5.3, "p95": 7.6},        # §3.1, same row
}

# Cold (first view of a tile) is dominated by tile decode, not drawing, on both
# platforms — 14-47% of frames over budget on Linux, 13-16% on Windows. Markers
# do not change that cost; the model reports the cold tail as inherited from
# SPIKE-14 and unmodified, and measures markers against the *warm* frame.
BASEMAP_COLD_JANK_FRACTION = {
    "linux-swraster": 0.26,  # §3.0 "Vector basemap, multi, cold"
    "windows-gpu": 0.16,     # §3.1 same
}

# Memory. SPIKE-14: route-only RSS, and the delta the basemap adds.
MEM_ROUTE_ONLY_MB = {"linux-swraster": 280, "windows-gpu": 400}
MEM_BASEMAP_DELTA_MB = {"linux-swraster": 400, "windows-gpu": 700}
# "Budget the desktop client at ~1 GB on Windows" — SPIKE-14 recommendation 7.
MEM_SPIKE14_CLIENT_BUDGET_MB = {"linux-swraster": 700, "windows-gpu": 1000}

# Route geometry is free at up to 41k vertices (0% frames over budget, both
# platforms). The model therefore charges nothing for the route polyline.


# --------------------------------------------------------------------------- #
# 2. Measured anchors — SPIKE-A (spikes/SPIKE-A/results/RESULTS.md + golden sets)
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class RegionFacts:
    key: str
    place: str
    km2: float
    # Post-calibration candidate count, RULESET_VERSION 1.2.0 (the shipped ruleset).
    candidates_v1_2_0: int
    # Pre-calibration count, RULESET_VERSION 1.1.0 — the flood A20 warned about,
    # kept as the "ruleset regressed" stress ceiling.
    candidates_v1_1_0: int
    narrative: int
    provision: int


REGIONS: dict[str, RegionFacts] = {
    "avl": RegionFacts("avl", "Asheville & the French Broad, NC", 487, 715, 749, 194, 521),
    "lwr": RegionFacts("lwr", "Lower Wisconsin Riverway, WI", 693, 72, 63, 37, 35),
    "sgv": RegionFacts("sgv", "San Gabriel foothills, CA", 382, 1208, 5453, 321, 887),
}

# Where the reconstructed geometry comes from. SPIKE-A committed its Overpass
# pulls; SPIKE-G reads them read-only and never re-fetches.
SPIKE_A_DIR = "SPIKE-A"

# Co-location analysis (N4/N4a, FR102) collapses candidates into far fewer
# proposals — SPIKE-A's sgv top was "a run of viewpoints, then a nature reserve",
# i.e. tens not thousands. FR105a caps proposals at a reviewable count. The model
# treats a proposal overlay as this fraction of the candidate load; candidates
# are the worst case and the one the recommendation is sized to.
PROPOSAL_FRACTION_OF_CANDIDATES = 0.06


# --------------------------------------------------------------------------- #
# 3. Pre-registered cost coefficients  — declared before any result is read
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Coeff:
    value: float
    unit: str
    basis: str


# --- per-frame marker cost, during interaction (pan / zoom) ---------------- #
# A flutter_map `Marker` is a positioned **widget**, not a canvas primitive.
# MarkerLayer rebuilds and re-lays-out every marker each frame while the camera
# moves. Cost is layout + paint + compositing of a small RepaintBoundary-less
# subtree. No public flutter_map benchmark isolates this; the coefficient is set
# from the practitioner-consensus ceiling ("a few hundred markers before pan
# jank") back-solved against the SPIKE-14 warm headroom, and is the single most
# important number to confirm on the real harness.
WIDGET_MARKER_FRAME_US = {
    "linux-swraster": Coeff(45.0, "us/marker/frame",
        "back-solved: ~110 markers fills the 5 ms p50 warm headroom on llvmpipe"),
    "windows-gpu": Coeff(20.0, "us/marker/frame",
        "GPU compositing ~2x cheaper per SPIKE-14's 2-3x median finding"),
}

# --- per-frame canvas-dot cost (CustomPainter / Canvas.drawPoints) -------- #
# A salience-below-cut candidate drawn as a plain filled circle on one shared
# canvas: no widget, no per-frame layout, no hit-test tree entry. Batched draw.
CANVAS_DOT_FRAME_US = {
    "linux-swraster": Coeff(1.2, "us/dot/frame", "one addOval + drawPath in a batched Path, sw raster"),
    "windows-gpu": Coeff(0.4, "us/dot/frame", "same, GPU-batched"),
}

# --- per-frame filled-polygon cost (area anchors, FR108) ----------------- #
# flutter_map PolygonLayer, or a CustomPainter Path. Charged per vertex: a
# tessellated fill plus a stroked outline.
POLYGON_VERTEX_FRAME_US = {
    "linux-swraster": Coeff(2.5, "us/vertex/frame", "tessellate + fill + stroke, sw raster"),
    "windows-gpu": Coeff(0.8, "us/vertex/frame", "GPU tessellation"),
}

# --- memory per rendered primitive ------------------------------------- #
WIDGET_MARKER_RSS_KB = Coeff(9.0, "KB/marker",
    "Element + RenderObject + layer + the marker's own child widget subtree")
CANVAS_DOT_RSS_KB = Coeff(0.05, "KB/dot", "one Offset + style index in a flat list")
POLYGON_RSS_KB_PER_VERTEX = Coeff(0.12, "KB/vertex", "Offset list + cached tessellation")
# The clustering index (supercluster-style KD/hierarchy) built once over all
# candidates in the bbox, held for the session.
CLUSTER_INDEX_RSS_KB_PER_CANDIDATE = Coeff(0.4, "KB/candidate",
    "hierarchical point index, ~4 numbers + tree overhead per input point")

# --- selection / hit-test latency ------------------------------------- #
# map -> list: a tap. Widget markers hit-test through the widget tree
# (spatially pruned, but a MarkerLayer with N children still walks candidates).
HITTEST_WIDGET_US = Coeff(6.0, "us/widget-in-layer",
    "RenderBox.hitTest walk over MarkerLayer children near the pointer")
# Canvas dots have no hit-test tree entry; a tap is an analytic nearest-point
# scan the app runs itself over the in-viewport point list.
HITTEST_ANALYTIC_US = Coeff(0.03, "us/point", "dx*dx+dy*dy compare in a tight loop")
# The killer: if selection calls setState on the MarkerLayer, every live widget
# marker is rebuilt + re-laid-out once. This is a one-frame cost, not per-frame,
# but it lands on the tap.
SELECTION_REBUILD_US_PER_WIDGET = Coeff(40.0, "us/widget",
    "one synchronous rebuild+layout pass, ~ the per-frame cost without compositing")
# list -> map: O(1) id lookup + one camera animation. Not density-sensitive.
LIST_TO_MAP_FIXED_MS = Coeff(20.0, "ms", "one lookup + kick off a camera tween")
# cluster extent highlight: bbox / hull of the cluster's members.
CLUSTER_EXTENT_US_PER_MEMBER = Coeff(0.05, "ms per member -> us", "min/max over member coords")


# --------------------------------------------------------------------------- #
# 4. Viewport + zoom grid the analysis sweeps
# --------------------------------------------------------------------------- #

VIEWPORT_PX = (1280, 720)  # same as SPIKE-14's bench

# z10  ~ whole trip bbox visible (the overview — the case that must not be blank)
# z12  ~ a quarter of it
# z14  ~ SPIKE-14's bench zoom; neighbourhood
# z16  ~ placing an individual anchor
ZOOM_LEVELS = (10, 12, 14, 16)

PLATFORMS = ("linux-swraster", "windows-gpu")


# --------------------------------------------------------------------------- #
# 5. Salience-gate cut-K, per platform — DERIVED from the coefficients above,
#    but pinned here so the dry-run can assert it did not drift.
# --------------------------------------------------------------------------- #
# K = floor( (p95 warm headroom - co-resident allowance) / marker-frame-cost ).
# The allowance is the frame time the *rest* of the candidate layer needs at
# bbox density — the filled area anchors (FR108) and the canvas-dot tail — which
# the widget markers must not crowd out. Set to 3.0 ms from the sweep's worst
# observed polygon+dot frame add on GPU (~2 ms), plus margin.
CUT_K_CORESIDENT_ALLOWANCE_MS = 3.0


def cut_k(platform: str, allowance_ms: float = CUT_K_CORESIDENT_ALLOWANCE_MS) -> int:
    headroom_ms = FRAME_BUDGET_MS - BASEMAP_WARM_FRAME_MS[platform]["p95"] - allowance_ms
    per_marker_ms = WIDGET_MARKER_FRAME_US[platform].value / 1000.0
    return max(0, int(headroom_ms / per_marker_ms))


# linux-swraster: the p95 headroom is 1.2 ms before any allowance — the software
# raster floor cannot widget-render more than a couple of dozen markers, which
# is a documented AMBER, not the shipping target (SPIKE-14 §3.0).
PINNED_CUT_K = {"linux-swraster": 0, "windows-gpu": 305}
