"""Test one of the four options RESULTS.md §2.2 left open for the missing labels.

The Linux pass established that **no basemap text renders at all**, on either renderer
version, and listed four possible fixes without choosing: a Protomaps v3 theme, a reduced
Plotlines-authored theme, upstream expression support, or drawing labels as Flutter
widgets. Only one of those is cheap enough to test rather than argue about, and it is the
one most likely to be chosen anyway — so this probe builds it.

**The diagnosis is narrower than "labels are unsupported".** Reading the extracted v4
themes, every symbol layer is well-formed and only its `text-field` is exotic: a nest of
`case` / `coalesce` / `is-supported-script` / `format` implementing multi-script name
fallback (render the local-script name and a Latin transliteration on two lines, unless
the script is unsupported, unless there is no `name:en`, …). `vector_tile_renderer` logs
`WARN: Unsupported expression syntax` and draws nothing. Everything *else* about the
layer — the source layer, the filter, the placement, the sizes, the halo, the zoom
ramps — is ordinary.

So this rewrites exactly one property per symbol layer and touches nothing else:

    "text-field": [<40 lines of multi-script fallback>]   →   ["get", "name"]

`["get", "name"]` rather than a `coalesce` of `name:en` and `name`, because a fallback
chain is precisely the construct under suspicion — testing the fix and a second unknown
at the same time would tell us nothing when it fails. Plotlines' MVP is English-language
and US-region (PRD §4.1), so the plain `name` is not a compromise for the MVP; it *is* a
compromise for any later locale work, and that is the trade this file exists to make
visible rather than to hide.

**A second rewrite, found by running the first.** With `text-field` fixed, nine of the ten
symbol layers drew and one did not: `pois` still logged five warnings, all tracing to its
*filter* rather than its text —

    ["in", ["get", "kind"], ["literal", ["beach", "forest", …]]]     # expression form
    ["in", "kind", "beach", "forest", …]                             # legacy form

The renderer implements the legacy form (`roads_labels_major` filters that way and draws
fine) and not the expression form, so the filter evaluates to nothing and the layer is
dropped whole — taking park, peak and beach names with it. `downgrade_in_filter` converts
one to the other; they are exactly equivalent.

That is the shape of the whole finding: the missing labels were never a missing *feature*,
they were two constructs a style could avoid.

Output: `harness/assets/style_labels.json`, which the harness picks up unmodified as
`SPIKE14_THEME=labels`.
"""

from __future__ import annotations

import json
from pathlib import Path

SPIKE = Path(__file__).resolve().parent.parent
ASSETS = SPIKE / "harness" / "assets"
SRC = ASSETS / "style_light.json"
DST = ASSETS / "style_labels.json"


def downgrade_in_filter(node):
    """`["in", ["get", K], ["literal", [v, …]]]` → `["in", K, v, …]`, recursively."""
    if not isinstance(node, list):
        return node
    if (len(node) == 3 and node[0] == "in"
            and isinstance(node[1], list) and len(node[1]) == 2 and node[1][0] == "get"
            and isinstance(node[2], list) and len(node[2]) == 2 and node[2][0] == "literal"
            and isinstance(node[2][1], list)):
        return ["in", node[1][1], *node[2][1]]
    return [downgrade_in_filter(child) for child in node]


def main() -> None:
    style = json.loads(SRC.read_text(encoding="utf-8"))
    text_fixed, filter_fixed = [], []
    for layer in style["layers"]:
        if layer.get("type") != "symbol":
            continue
        layout = layer.get("layout") or {}
        if "text-field" not in layout:
            continue
        layout["text-field"] = ["get", "name"]
        # The icon sprite is a separate unresolved dependency (the themes reference a
        # sprite sheet we never extracted). Leaving icon-image in place would risk
        # attributing a missing sprite to a missing label.
        layout.pop("icon-image", None)
        text_fixed.append(f'{layer["id"]} ({layer.get("source-layer")})')

        if "filter" in layer:
            downgraded = downgrade_in_filter(layer["filter"])
            if downgraded != layer["filter"]:
                layer["filter"] = downgraded
                filter_fixed.append(layer["id"])

    DST.write_text(json.dumps(style), encoding="utf-8")
    print(f"wrote {DST.name}")
    print(f"  text-field simplified on {len(text_fixed)} symbol layers:")
    for name in text_fixed:
        print(f"    {name}")
    print(f"  'in' filter downgraded on {len(filter_fixed)}: {', '.join(filter_fixed) or '-'}")


if __name__ == "__main__":
    main()
