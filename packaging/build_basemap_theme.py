"""Generate `client/assets/map_style/style_{light,dark,grayscale}.json` from the
mirrored Protomaps Basemap themes at `spikes/SPIKE-14/harness/assets/` (Light/Dark)
and `spikes/SPIKE-K/harness/styles/` (Grayscale) (ARCH D24).

SPIKE-14 found that `vector_tile_renderer` draws no basemap labels at all against the
unmodified Protomaps v4 themes — not a missing feature, but two specific expression
constructs it doesn't evaluate (`spikes/SPIKE-14/results/RESULTS.md` §2.2,
`spikes/SPIKE-14/probes/simplify_labels.py`):

1. `text-field`'s multi-script name-fallback expression (`case`/`coalesce`/
   `is-supported-script`/`format`) logs "Unsupported expression syntax" and draws
   nothing; a plain `["get", "name"]` renders. English/US-region MVP (PRD §4.1) makes
   this a real trade for later locale work, not a compromise for MVP itself.
2. The expression form of `in` — wherever it appears, not only in a top-level filter —
   the renderer only implements the legacy form, and the two are exactly equivalent.

The probe only proved this against `style_light.json`'s ten symbol layers, and only
against `in` inside a *filter*. Reproducing it here (both themes, via a real regression
test — `client/test/vector_tile_provider_test.dart`) surfaced two more instances the
probe didn't have coverage for, both confined to the `pois` layer:

3. The same expression-form `in` also appears inside a **paint** expression
   (`pois`'s `text-color`: `["case", ["in", ["get","kind"], ["literal", […]]], …]`) —
   the parser bails on the whole `case` when one branch is unparseable, so this silently
   drops the color rule, not just the filter. Fixed by downgrading `in` everywhere in the
   layer (paint and layout, not just filter), not only at the filter's top level.
4. `pois`'s filter also gates each feature by `[">=", ["zoom"], ["get", "min_zoom"]]` —
   Protomaps' per-feature "don't show this POI until zoom reaches its importance
   threshold" mechanism. The renderer has no current-zoom access inside filter
   evaluation at all (`logger.warn('Unsupported expression syntax: [zoom]')`) — not an
   expression-form quirk like the other three, an unimplemented capability. Fixed by
   dropping that clause: POIs in the `kind` allow-list render across the whole layer's
   zoom range instead of fading in progressively by importance. A real, visible trade,
   not a silent one — declared here rather than left as one more inexplicable gap.

This is that fix made real for both themes and committed to the pipeline rather than run
by hand once — D24 calls for "a scripted transform in the tile pipeline" specifically so
a mirrored upstream refresh re-derives the shipped theme instead of drifting from it.

Grayscale (issue #465, SPIKE-K #461 §6.3-6.4) has no source under SPIKE-14's harness —
that spike ran before Grayscale was evaluated — so its input is SPIKE-K's own generator
output (`spikes/SPIKE-K/probes/gen_protomaps_styles.mjs`, `@protomaps/basemaps` 5.7.2,
`namedFlavor("grayscale")`, already committed at `spikes/SPIKE-K/harness/styles/
protomaps_grayscale.json`). Running it through this module's transform surfaced a fifth
instance of the expression-form `in` bug (module docstring item 3): `landuse_park`, a
*fill* layer, carries the same `case`/`in`/`literal` construct in its `paint` that the
`pois` layer carries in its `text-color` — but items 1-4 above were all found and fixed
against Light/Dark's `pois` layer specifically, so the original `build_theme()` only ever
applied `downgrade_in_filter`/`strip_zoom_filter` to symbol layers carrying a
`text-field`. Grayscale ships no `pois` layer (no sprite sheet either, by upstream
definition — the two flavors with sprites are Light and Dark), so *that* bug doesn't
recur, but `landuse_park` sitting outside the symbol/text-field gate means it would have
kept its unparseable `paint` expression and silently lost every kind-specific fill color
under the same "parser bails on the whole `case`" failure mode. Fixed by widening
`downgrade_in_filter`/`strip_zoom_filter` to every layer's `filter`/`paint`/`layout`,
not only symbol layers with a `text-field` — confirmed a no-op against the committed
Light/Dark output (neither has a matching pattern outside that gate today), so this is a
strict widening, not a behaviour change for the two themes already shipping.

Grayscale's own upstream water-label colours (`#7a7a7a` on a `#a3a3a3`-`#d2d2d2`
landcover range) read 1.7-2.8:1 — well under WCAG 2.2 AA's 4.5:1 floor
(plotlines-constraints), the same class of defect #321 fixed for Light/Dark, just with
Grayscale's own numbers (its whole ramp sits in a narrower, lighter band than Light's).
`WATER_LABEL_CONTRAST_FIX` applies a themed override to the three water-label layers'
`text-color`/`text-halo-color`/`text-halo-width`, so the shipped file is a script step,
never a hand-patch the script itself can't reproduce — see issue #486 for the
pre-existing gap where #321's own Light/Dark values are *not* in this script yet and a
re-run of this module currently regresses them.

Run from the repo root:  python packaging/build_basemap_theme.py
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "spikes" / "SPIKE-14" / "harness" / "assets"
GRAYSCALE_SRC = ROOT / "spikes" / "SPIKE-K" / "harness" / "styles" / "protomaps_grayscale.json"
DST_DIR = ROOT / "client" / "assets" / "map_style"
THEMES = ["light", "dark", "grayscale"]


def _source_path(name: str) -> Path:
    if name == "grayscale":
        return GRAYSCALE_SRC
    return SRC_DIR / f"style_{name}.json"


_WATER_LABEL_LAYERS = {"water_waterway_label", "water_label_ocean", "water_label_lakes"}

# WCAG 2.2 AA (plotlines-constraints), computed against this theme's own committed
# landcover/water fills — see the module docstring. Light/Dark's #321 values are not
# listed here (issue #486): they are a pre-existing hand-patch on the committed file,
# not yet part of this script.
WATER_LABEL_CONTRAST_FIX = {
    "grayscale": {
        "text-color": "#333333",
        "text-halo-color": "#ffffff",
        "text-halo-width": 1,
    },
}


def _apply_water_label_contrast_fix(name: str, style: dict) -> list[str]:
    fix = WATER_LABEL_CONTRAST_FIX.get(name)
    if not fix:
        return []
    fixed = []
    for layer in style["layers"]:
        if layer["id"] in _WATER_LABEL_LAYERS:
            layer.setdefault("paint", {}).update(fix)
            fixed.append(layer["id"])
    return fixed


def downgrade_in_filter(node):
    """`["in", ["get", K], ["literal", [v, …]]]` -> `["in", K, v, …]`, recursively.

    Applied to a whole layer (paint + layout + filter), not just its filter — the
    expression form of `in` breaks a paint `case` exactly the same way it breaks a
    filter (item 3 in the module docstring).
    """
    if isinstance(node, dict):
        return {key: downgrade_in_filter(value) for key, value in node.items()}
    if not isinstance(node, list):
        return node
    if (
        len(node) == 3
        and node[0] == "in"
        and isinstance(node[1], list) and len(node[1]) == 2 and node[1][0] == "get"
        and isinstance(node[2], list) and len(node[2]) == 2 and node[2][0] == "literal"
        and isinstance(node[2][1], list)
    ):
        return ["in", node[1][1], *node[2][1]]
    return [downgrade_in_filter(child) for child in node]


_ZOOM_COMPARISON_OPS = {"==", "!=", "<", "<=", ">", ">="}


def strip_zoom_filter(node):
    """Drop any `[op, ["zoom"], …]` comparison from a *filter* tree (item 4).

    Only for filters — `["zoom"]` is fine, and used elsewhere in this theme, inside
    paint/layout expressions, which do have current-zoom access. Filters don't.
    """
    if not isinstance(node, list) or not node:
        return node
    if node[0] in ("all", "any", "none"):
        cleaned = [strip_zoom_filter(child) for child in node[1:]]
        cleaned = [child for child in cleaned if child is not None]
        return [node[0], *cleaned]
    if (
        len(node) == 3
        and node[0] in _ZOOM_COMPARISON_OPS
        and node[1] == ["zoom"]
    ):
        return None
    return node


def build_theme(name: str) -> None:
    src = _source_path(name)
    dst = DST_DIR / f"style_{name}.json"
    style = json.loads(src.read_text(encoding="utf-8"))

    text_fixed, filter_fixed, paint_fixed, layout_fixed, zoom_filter_fixed = [], [], [], [], []
    for layer in style["layers"]:
        # Items 1-4's fixes were found against Light/Dark's `pois` layer and written as
        # symbol/text-field-scoped; item 3 in particular (expression-form `in` inside
        # `paint`) is a general layer-shape bug, not a `pois`-specific or symbol-specific
        # one, and Grayscale's `landuse_park` (a *fill* layer) carries exactly that
        # construct. So `filter`/`paint`/`layout` are downgraded on every layer,
        # regardless of type — confirmed a no-op against the committed Light/Dark output.
        for prop in ("filter", "paint", "layout"):
            if prop not in layer:
                continue
            downgraded = downgrade_in_filter(layer[prop])
            if downgraded != layer[prop]:
                layer[prop] = downgraded
                (filter_fixed if prop == "filter" else
                 paint_fixed if prop == "paint" else layout_fixed).append(layer["id"])

        if "filter" in layer:
            stripped = strip_zoom_filter(layer["filter"])
            if stripped != layer["filter"]:
                layer["filter"] = stripped
                zoom_filter_fixed.append(layer["id"])

        if layer.get("type") != "symbol":
            continue
        layout = layer.get("layout") or {}
        if "text-field" not in layout:
            continue
        layout["text-field"] = ["get", "name"]
        # The icon sprite is a separate unresolved dependency (Light/Dark reference a
        # sprite sheet the tile pipeline never extracted; Grayscale ships no sprite at
        # all, by upstream definition) — leaving icon-image in place would misattribute
        # a missing sprite to a missing label.
        layout.pop("icon-image", None)
        text_fixed.append(f'{layer["id"]} ({layer.get("source-layer")})')

    contrast_fixed = _apply_water_label_contrast_fix(name, style)

    dst.write_text(json.dumps(style), encoding="utf-8")
    print(f"wrote {dst.relative_to(ROOT)}")
    print(f"  text-field simplified on {len(text_fixed)} symbol layers:")
    for entry in text_fixed:
        print(f"    {entry}")
    print(f"  'in' filter downgraded on {len(filter_fixed)}: {', '.join(filter_fixed) or '-'}")
    print(f"  paint 'in' expression downgraded on {len(paint_fixed)}: {', '.join(paint_fixed) or '-'}")
    print(f"  layout 'in' expression downgraded on {len(layout_fixed)}: {', '.join(layout_fixed) or '-'}")
    print(f"  zoom-comparison filter clause dropped on {len(zoom_filter_fixed)}: "
          f"{', '.join(zoom_filter_fixed) or '-'}")
    print(f"  WCAG AA water-label contrast fix applied on {len(contrast_fixed)}: "
          f"{', '.join(contrast_fixed) or '-'}")


def main() -> None:
    for name in THEMES:
        build_theme(name)


if __name__ == "__main__":
    main()
