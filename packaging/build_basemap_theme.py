"""Generate `client/assets/map_style/style_{light,dark}.json` from the mirrored
Protomaps Basemap themes at `spikes/SPIKE-14/harness/assets/` (ARCH D24).

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

Run from the repo root:  python packaging/build_basemap_theme.py
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "spikes" / "SPIKE-14" / "harness" / "assets"
DST_DIR = ROOT / "client" / "assets" / "map_style"
THEMES = ["light", "dark"]


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
    src = SRC_DIR / f"style_{name}.json"
    dst = DST_DIR / f"style_{name}.json"
    style = json.loads(src.read_text(encoding="utf-8"))

    text_fixed, filter_fixed, paint_fixed, zoom_filter_fixed = [], [], [], []
    for layer in style["layers"]:
        if layer.get("type") != "symbol":
            continue
        layout = layer.get("layout") or {}
        if "text-field" not in layout:
            continue
        layout["text-field"] = ["get", "name"]
        # The icon sprite is a separate unresolved dependency (the themes reference a
        # sprite sheet the tile pipeline never extracted) — leaving icon-image in place
        # would misattribute a missing sprite to a missing label.
        layout.pop("icon-image", None)
        text_fixed.append(f'{layer["id"]} ({layer.get("source-layer")})')

        if "filter" in layer:
            downgraded = downgrade_in_filter(layer["filter"])
            if downgraded != layer["filter"]:
                layer["filter"] = downgraded
                filter_fixed.append(layer["id"])

            stripped = strip_zoom_filter(layer["filter"])
            if stripped != layer["filter"]:
                layer["filter"] = stripped
                zoom_filter_fixed.append(layer["id"])

        if "paint" in layer:
            downgraded = downgrade_in_filter(layer["paint"])
            if downgraded != layer["paint"]:
                layer["paint"] = downgraded
                paint_fixed.append(layer["id"])

    dst.write_text(json.dumps(style), encoding="utf-8")
    print(f"wrote {dst.relative_to(ROOT)}")
    print(f"  text-field simplified on {len(text_fixed)} symbol layers:")
    for entry in text_fixed:
        print(f"    {entry}")
    print(f"  paint 'in' expression downgraded on {len(paint_fixed)}: {', '.join(paint_fixed) or '-'}")
    print(f"  zoom-comparison filter clause dropped on {len(zoom_filter_fixed)}: "
          f"{', '.join(zoom_filter_fixed) or '-'}")
    print(f"  'in' filter downgraded on {len(filter_fixed)}: {', '.join(filter_fixed) or '-'}")


def main() -> None:
    for name in THEMES:
        build_theme(name)


if __name__ == "__main__":
    main()
