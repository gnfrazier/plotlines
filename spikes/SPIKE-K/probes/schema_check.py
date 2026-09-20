"""The issue's "known risk to check first": does each style address the schema
the corridor archive actually carries?

Static, not visual. A style that names a `source-layer` the archive does not
have draws nothing for that layer without an error — MapLibre treats an
unknown source-layer as "no features here" — so a screenshot alone can't
distinguish "renders cleanly" from "renders nothing and looks tidy". This
probe reads the archive's own `vector_layers` metadata off the PMTiles header
(the layer names and per-layer field names Planetiler wrote) and, per style,
reports:

  * every `source-layer` the style references, and whether the archive has it;
  * every attribute key the style reads in a filter or a data-driven property
    (`["get", K]`, legacy `["==", K, …]` / `["in", K, …]`, `["has", K]`,
    `{"property": K}`), and whether that layer carries it.

Output is a Markdown table on stdout and `results/schema_check.json`, so the
README's per-style column is copied from a measurement rather than typed.

Run from the spike root:

    python3 probes/schema_check.py [--archive URL]

Reads the archive header over HTTP (one small range request) via the SPIKE-14
`pmtiles` CLI; no tiles are fetched.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

SPIKE_ROOT = Path(__file__).resolve().parent.parent
STYLES_DIR = SPIKE_ROOT / "harness" / "styles"
PMTILES_CLI = SPIKE_ROOT.parent / "SPIKE-14" / "tools" / "pmtiles"
DEFAULT_ARCHIVE = (
    "http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles"
)

# Style order matters for the report: candidates first, then the two
# risk-check styles the harness keeps loadable as evidence.
STYLE_ORDER = [
    "protomaps_light",
    "protomaps_dark",
    "protomaps_grayscale",
    "protomaps_white",
    "protomaps_black",
    "omt_liberty",
    "omt_bright",
]

# Expression operators whose *first* argument is a property key in the
# legacy (deprecated) filter syntax — `["==", "class", "primary"]`.
LEGACY_KEY_OPS = {"==", "!=", "<", "<=", ">", ">=", "in", "!in", "has", "!has"}
# Keys the legacy syntax reserves for geometry / id, not data properties.
SPECIAL_KEYS = {"$type", "$id"}


def archive_layers(archive: str) -> dict[str, set[str]]:
    out = subprocess.run(
        [str(PMTILES_CLI), "show", "--metadata", archive],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    meta = json.loads(out)
    return {
        layer["id"]: set(layer.get("fields", {}).keys())
        for layer in meta["vector_layers"]
    }


def walk(expr, found: set[str]) -> None:
    """Collect every property key an expression reads."""
    if isinstance(expr, dict):
        # Legacy function syntax: {"property": "class", "stops": [...]}
        if "property" in expr:
            found.add(expr["property"])
        for v in expr.values():
            walk(v, found)
        return
    if not isinstance(expr, list) or not expr:
        return
    op = expr[0]
    if op in ("get", "has") and len(expr) >= 2 and isinstance(expr[1], str):
        # Expression form. `["get", K, obj]` reads from obj, not the feature —
        # only the 2-arg form is a feature read.
        if len(expr) == 2:
            found.add(expr[1])
    elif op in LEGACY_KEY_OPS and len(expr) >= 2 and isinstance(expr[1], str):
        if expr[1] not in SPECIAL_KEYS:
            found.add(expr[1])
    for sub in expr[1:]:
        walk(sub, found)


def style_reads(style: dict) -> dict[str, set[str]]:
    """source-layer -> set of property keys any of its layers read."""
    reads: dict[str, set[str]] = defaultdict(set)
    for layer in style["layers"]:
        sl = layer.get("source-layer")
        if sl is None:
            continue  # background / raster layers read no vector properties
        keys: set[str] = set()
        walk(layer.get("filter"), keys)
        for prop_block in ("paint", "layout"):
            for value in layer.get(prop_block, {}).values():
                walk(value, keys)
        reads[sl] |= keys
    return reads


def check(style_name: str, style: dict, archive: dict[str, set[str]]) -> dict:
    reads = style_reads(style)
    vector_layer_count = sum(1 for l in style["layers"] if l.get("source-layer"))
    per_layer = {}
    missing_layers = []
    missing_keys: dict[str, list[str]] = {}
    layers_by_source = defaultdict(int)
    for l in style["layers"]:
        if l.get("source-layer"):
            layers_by_source[l["source-layer"]] += 1
    for sl, keys in sorted(reads.items()):
        present = sl in archive
        if not present:
            missing_layers.append(sl)
            per_layer[sl] = {"present": False, "style_layers": layers_by_source[sl]}
            continue
        absent = sorted(k for k in keys if k not in archive[sl])
        if absent:
            missing_keys[sl] = absent
        per_layer[sl] = {
            "present": True,
            "style_layers": layers_by_source[sl],
            "keys_read": sorted(keys),
            "keys_absent": absent,
        }
    dead_layers = sum(layers_by_source[sl] for sl in missing_layers)
    return {
        "style": style_name,
        "vector_layers_in_style": vector_layer_count,
        "source_layers_referenced": sorted(reads),
        "source_layers_missing": missing_layers,
        "style_layers_on_missing_source_layers": dead_layers,
        "keys_absent_by_layer": missing_keys,
        "per_layer": per_layer,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--archive", default=DEFAULT_ARCHIVE)
    args = ap.parse_args()

    archive = archive_layers(args.archive)
    print(f"archive: {args.archive}")
    print(f"archive vector_layers: {', '.join(sorted(archive))}\n")

    results = []
    for name in STYLE_ORDER:
        path = STYLES_DIR / f"{name}.json"
        if not path.exists():
            print(f"skip {name}: {path} missing", file=sys.stderr)
            continue
        results.append(check(name, json.loads(path.read_text()), archive))

    print("| style | vector layers | source-layers referenced | missing from archive | style layers dead | keys read but absent |")
    print("|---|---|---|---|---|---|")
    for r in results:
        missing = ", ".join(r["source_layers_missing"]) or "—"
        absent = (
            "; ".join(f"{sl}: {', '.join(ks)}" for sl, ks in r["keys_absent_by_layer"].items())
            or "—"
        )
        print(
            f"| {r['style']} | {r['vector_layers_in_style']} | "
            f"{len(r['source_layers_referenced'])} | {missing} | "
            f"{r['style_layers_on_missing_source_layers']}/{r['vector_layers_in_style']} | {absent} |"
        )

    out = SPIKE_ROOT / "results" / "schema_check.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"archive": args.archive, "archive_layers": {k: sorted(v) for k, v in archive.items()}, "styles": results}, indent=2) + "\n")
    print(f"\nwrote {out.relative_to(SPIKE_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
