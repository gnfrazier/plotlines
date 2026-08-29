"""The four rendering strategies ARCH Q15 puts on the table, each reduced to the
same output: given the candidates that fall in the viewport at a zoom, how many
*primitives of each kind* actually get rendered, and what does the Author lose.

    naive            every candidate is a hit-testable widget marker
    zoom_threshold   nothing below zoom Zt; everything above it (naive)
    cluster_grid     screen-space grid clustering; one glyph per occupied cell
    salience_gated   top-K by salience as widgets, the rest as canvas dots

`RenderPlan` is what `costmodel.py` prices. The boolean columns
(`salience_visible`, `overview_usable`, `map_to_list_exact`,
`promote_from_map_direct`) are the interaction properties the frame-time model
cannot see but N4a / FR99 require.
"""

from __future__ import annotations

from dataclasses import dataclass

from extract import Candidate
from geo import screen_xy

# area anchors (FR108): a candidate rendered as a filled polygon rather than a
# pin. We price it by its ring's vertex count; a candidate flagged is_area but
# without a reconstructed ring gets a nominal small ring.
NOMINAL_RING_VERTICES = 6


@dataclass(frozen=True)
class RenderPlan:
    strategy: str
    zoom: int
    in_viewport: int
    widget_markers: int
    canvas_dots: int
    cluster_glyphs: int
    polygon_vertices: int          # summed across area anchors actually drawn
    cluster_index_candidates: int  # candidates fed to a session-held cluster index
    # interaction properties -------------------------------------------------
    salience_visible: bool          # FR99: can the Author see which are notable?
    overview_usable: bool           # is the zoomed-out view informative, not blank?
    map_to_list_exact: bool         # tap any rendered thing -> its card (N4a)
    promote_from_map_direct: bool   # FR99: promote without zooming/declustering
    notes: str = ""


def _area_vertices(cands: list[Candidate]) -> int:
    total = 0
    for c in cands:
        if c.is_area:
            total += len(c.ring) if c.ring else NOMINAL_RING_VERTICES
    return total


def naive(cands: list[Candidate], zoom: int, k: int, all_in_bbox: int) -> RenderPlan:
    return RenderPlan(
        strategy="naive",
        zoom=zoom,
        in_viewport=len(cands),
        widget_markers=len(cands),
        canvas_dots=0,
        cluster_glyphs=0,
        polygon_vertices=_area_vertices(cands),
        cluster_index_candidates=0,
        salience_visible=True,
        overview_usable=True,
        map_to_list_exact=True,
        promote_from_map_direct=True,
        notes="every candidate is a live widget; cost scales with density",
    )


# below this zoom, zoom_threshold renders nothing (a count badge, not markers)
DEFAULT_ZOOM_THRESHOLD = 13


def zoom_threshold(
    cands: list[Candidate], zoom: int, k: int, all_in_bbox: int,
    zt: int = DEFAULT_ZOOM_THRESHOLD,
) -> RenderPlan:
    if zoom < zt:
        return RenderPlan(
            strategy="zoom_threshold", zoom=zoom, in_viewport=len(cands),
            widget_markers=0, canvas_dots=0, cluster_glyphs=0, polygon_vertices=0,
            cluster_index_candidates=0,
            salience_visible=False, overview_usable=False,
            map_to_list_exact=False, promote_from_map_direct=False,
            notes=f"z<{zt}: nothing drawn — the overview is blank, N4a map->card impossible here",
        )
    base = naive(cands, zoom, k, all_in_bbox)
    return RenderPlan(**{**base.__dict__, "strategy": "zoom_threshold",
                        "notes": f"z>={zt}: identical to naive above the threshold"})


def cluster_grid(
    cands: list[Candidate], zoom: int, k: int, all_in_bbox: int, cell_px: int = 64
) -> RenderPlan:
    """Screen-space grid clustering. One glyph per occupied cell; a cell with a
    single candidate renders that candidate as a marker. Glyph count is bounded
    by screen area / cell area, never by candidate count."""
    from regions import VIEWPORT_PX

    if not cands:
        cells: dict[tuple[int, int], list[Candidate]] = {}
    else:
        clat = sum(c.lat for c in cands) / len(cands)
        clon = sum(c.lon for c in cands) / len(cands)
        cells = {}
        for c in cands:
            x, y = screen_xy(c.lat, c.lon, clat, clon, zoom, *VIEWPORT_PX)
            key = (int(x // cell_px), int(y // cell_px))
            cells.setdefault(key, []).append(c)

    singles = [members[0] for members in cells.values() if len(members) == 1]
    multi = [members for members in cells.values() if len(members) > 1]

    return RenderPlan(
        strategy="cluster_grid",
        zoom=zoom,
        in_viewport=len(cands),
        widget_markers=len(singles),
        canvas_dots=0,
        cluster_glyphs=len(multi),
        polygon_vertices=_area_vertices(singles),
        cluster_index_candidates=all_in_bbox,  # index built once over the bbox
        salience_visible=len(multi) == 0,      # a count glyph hides the castle
        overview_usable=True,
        map_to_list_exact=len(multi) == 0,     # tap a cluster -> ambiguous
        promote_from_map_direct=len(multi) == 0,
        notes=f"{len(cells)} occupied cells: {len(singles)} singles + {len(multi)} clusters",
    )


def salience_gated(
    cands: list[Candidate], zoom: int, k: int, all_in_bbox: int
) -> RenderPlan:
    """Top-K by salience are hit-testable widget markers; everything else is a
    canvas dot on one shared layer (visible, positioned, styled by salience —
    just not a widget and not individually hit-tested). K comes from the cost
    model: the most widgets that keep the p95 interaction frame under budget."""
    ranked = sorted(cands, key=lambda c: c.salience, reverse=True)
    top = ranked[:k]
    tail = ranked[k:]
    return RenderPlan(
        strategy="salience_gated",
        zoom=zoom,
        in_viewport=len(cands),
        widget_markers=len(top),
        canvas_dots=len(tail),
        cluster_glyphs=0,
        polygon_vertices=_area_vertices(top) + _area_vertices(tail),
        cluster_index_candidates=0,
        salience_visible=True,          # by construction the notable ones are the widgets
        overview_usable=True,           # dots keep the shape of the field
        map_to_list_exact=True,         # widgets: tree hit-test; dots: analytic scan
        promote_from_map_direct=True,   # top-K directly; a dot promotes as you zoom in
        notes=f"K={k}: {len(top)} widgets + {len(tail)} dots",
    )


STRATEGIES = {
    "naive": naive,
    "zoom_threshold": zoom_threshold,
    "cluster_grid": cluster_grid,
    "salience_gated": salience_gated,
}
