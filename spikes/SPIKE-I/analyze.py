"""SPIKE-I — every published figure, derived offline from `raw/probe.json.gz`.

    .venv/bin/python analyze.py

Touches no network and no clock. Everything it needs is in `raw/`, so every
number in `results/RESULTS.md` reproduces without querying the Overpass commons
again (ARCH §14 P7) and without moving under the next reader — SPIKE-C's rule,
for SPIKE-D's reason, and the same split SPIKE-E used.

This module grades; it does not decide. The thresholds all live in `bands.py`,
which was committed before `probe.py` was first executed, and nothing here may
reach past them. If a cell is close to a band, it is on the wrong side of it or
the right one — there is no third option and no place in this file to write one.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from typing import Any

SPIKE = Path(__file__).resolve().parent
RAW = SPIKE / "raw"
RESULTS = SPIKE / "results"

import sys  # noqa: E402

sys.path.insert(0, str(SPIKE))

import bands  # noqa: E402
import egress  # noqa: E402


def load_raw() -> dict[str, Any]:
    with gzip.open(RAW / "probe.json.gz", "rt") as fh:
        return json.load(fh)


#: The arms that are **candidate configurations** — the ones a Phase 3
#: implementation could actually be, and therefore the ones the bands grade.
#:
#: The probe runs four path-T arms per cell because two harness variables turned
#: out to matter, and both were discovered by reading osmnx rather than by
#: reading the results:
#:
#:   raw vs buffered     osmnx queries a polygon buffered by 500 m and truncates
#:                       to the trip bbox only after simplification and
#:                       component selection have run on the buffered graph. A
#:                       clip taken at the raw trip bbox is therefore a
#:                       *known-wrong input*, not a design option.
#:   vertex vs intersects  the shipped clip selects a way when one of its nodes
#:                       is inside the box; Overpass selects when the geometry
#:                       intersects at all.
#:
#: Grading a deliberately-wrong arm against a band would make the band
#: meaningless — every run would RESCOPE on an arm built to fail. So the
#: non-canonical arms are measured, reported with their numbers, and named as
#: diagnostics. What they are *for* is pricing the mistake: "how bad is it if
#: Phase 3 clips at the raw bbox" is a number Phase 3 wants, and it is only
#: available because the wrong arm was run.
CANONICAL_ARMS = ("T/buffered/vertex", "R/buffered")


def _cell_results(raw: dict[str, Any], *, canonical_only: bool = True
                  ) -> list[bands.CellResult]:
    """Turn the probe record into the objects `bands.classify` grades.

    One translation decision worth naming: with the attic control in place both
    snapshots are the same instant, so `attribute_differences` can attribute
    nothing and every difference is unattributed by construction. That is the
    strict reading and it is deliberate — under a shared snapshot a difference
    *cannot* be drift, so calling it unattributed is not harshness, it is the
    only correct label.
    """
    out: list[bands.CellResult] = []
    for key, cell in raw.get("cells", {}).items():
        if "error" in cell:
            continue
        tag_losses = (cell.get("tags") or {}).get("losses", {})
        for path_key, cmp in (cell.get("parity") or {}).items():
            if canonical_only and path_key not in CANONICAL_ARMS:
                continue
            local = (cell.get("locals") or {}).get(path_key, {})
            if "error" in local:
                continue
            path = (bands.Path.TRANSPORT if path_key.startswith("T/")
                    else bands.Path.REIMPLEMENTATION)
            read = local
            lengths = cmp["length_delta_m"]
            out.append(bands.CellResult(
                region=f"{key}:{path_key}",
                network_type=cell["network_type"],
                path=path,
                # B0, derived — never asserted. A way the golden graph is built
                # from is a way Overpass kept, so a way id in the golden and not
                # in the local is a false reject by the local filter (SPIKE-E's
                # shape) and the reverse is a false accept.
                #
                # Graded on path T only. Path R's way set is pyrosm's own
                # network-type vocabulary, not osmnx's filter, so counting its
                # differences as "filter" errors would attribute a deliberate
                # implementation difference to a veto it is not in scope for —
                # B1/B2 grade path R, as the ladder intends.
                filter_false_rejects=(
                    cmp["way_filter"]["false_rejects"]
                    if path is bands.Path.TRANSPORT else 0
                ),
                filter_false_accepts=(
                    cmp["way_filter"]["false_accepts"]
                    if path is bands.Path.TRANSPORT else 0
                ),
                golden_nodes=cmp["nodes"]["golden"],
                unattributed_node_diff=(cmp["nodes"]["only_golden"]
                                        + cmp["nodes"]["only_local"]),
                golden_edges=cmp["edges"]["golden"],
                unattributed_edge_diff=(cmp["edges"]["only_golden"]
                                        + cmp["edges"]["only_local"]),
                edge_key_stability=cmp["edge_keys"]["stability"],
                rekeyed_on_single_edge_uv=cmp["edge_keys"]["rekeyed_on_single_edge_uv"],
                golden_scc=cmp["scc"]["golden"],
                local_scc=cmp["scc"]["local"],
                golden_scc_ratio=cmp["scc"]["golden_ratio"],
                local_scc_ratio=cmp["scc"]["local_ratio"],
                length_delta_p99_m=lengths.get("p99", 0.0),
                length_delta_max_m=lengths.get("max", 0.0),
                # B5 is a per-cell veto and is attached to the cell's canonical
                # path-T build only, so one tag loss is reported once rather
                # than once per path.
                tag_losses=(tag_losses if path_key == "T/buffered/vertex" else {}),
            ))
    return out


def _clip_results(raw: dict[str, Any]) -> list[bands.ClipResult]:
    out: list[bands.ClipResult] = []
    for key, cell in raw.get("cells", {}).items():
        for label, clip in (cell.get("clips") or {}).items():
            if "wall_s" not in clip:
                continue  # reused clip, no fresh timing
            out.append(bands.ClipResult(
                bbox_key=f"{key}:{label}",
                # Set by the server-side leg, never by this one. A dev-box
                # figure cannot reach PARITY (addendum 2c) and saying so here
                # is what keeps that honest.
                measured_on_mirror=bool(clip.get("measured_on_mirror", False)),
                p95_wall_s=clip["wall_s"],
                peak_rss_mb=clip.get("peak_rss_mb", 0.0),
                output_fraction=clip.get("output_fraction", 0.0),
            ))
    return out


def _egress(raw: dict[str, Any]) -> dict[str, Any]:
    figures = []
    seen: set[str] = set()
    for key, cell in raw.get("cells", {}).items():
        if "error" in cell or cell.get("spans_two_extracts"):
            continue
        extracts = cell.get("extracts") or []
        if not extracts:
            continue
        region = extracts[0]["path"].rsplit("/", 1)[-1]
        if region in seen:
            continue
        clip = (cell.get("clips") or {}).get("raw/complete_ways")
        if not clip:
            continue
        seen.add(region)
        figures.append(egress.RegionFigures(
            region=region,
            extract_bytes=extracts[0]["bytes"],
            clip_bytes=clip["output_bytes"],
            bbox_km2=cell.get("area_km2", 0.0),
        ))
    return egress.arithmetic(figures)


def _diagnostics(raw: dict[str, Any]) -> dict[str, Any]:
    """The non-canonical arms, with their numbers and no verdict.

    These are the cost of a mistake Phase 3 could make, priced. They are kept
    out of `classify` and reported in full — which is the opposite of dropping
    them, and the distinction matters: a reader must be able to see that the raw
    -bbox arm was run, what it cost, and why it is not being graded.
    """
    everything = _cell_results(raw, canonical_only=False)
    canonical = {c.region for c in _cell_results(raw, canonical_only=True)}
    out = {}
    for c in everything:
        if c.region in canonical:
            continue
        out[c.region] = {
            "band_if_it_had_been_graded": bands._cell_band(c).value,
            "nodes": {"golden": c.golden_nodes, "diff": c.unattributed_node_diff},
            "edges": {"golden": c.golden_edges, "diff": c.unattributed_edge_diff},
            "way_filter_false_rejects": c.filter_false_rejects,
            "way_filter_false_accepts": c.filter_false_accepts,
            "scc": {"golden": c.golden_scc, "local": c.local_scc},
            "length_delta_max_m": c.length_delta_max_m,
        }
    return out


def analyze() -> dict[str, Any]:
    raw = load_raw()
    cells = _cell_results(raw)
    clips = _clip_results(raw)

    verdict = bands.classify(tuple(cells), tuple(clips))
    unmet = bands.unmet_reasons(tuple(cells), tuple(clips))

    per_cell = {}
    for c in cells:
        per_cell[c.region] = {
            "path": c.path.value,
            "network_type": c.network_type,
            "band": bands._cell_band(c).value,
            "nodes": {"golden": c.golden_nodes, "diff": c.unattributed_node_diff},
            "edges": {"golden": c.golden_edges, "diff": c.unattributed_edge_diff},
            "edge_key_stability": c.edge_key_stability,
            "scc": {"golden": c.golden_scc, "local": c.local_scc,
                    "delta_fraction": c.scc_delta_fraction},
            "length_delta_max_m": c.length_delta_max_m,
            "tag_losses": c.tag_losses,
        }

    return {
        "spike": "SPIKE-I",
        "issue": 265,
        "verdict": verdict.value,
        "vetoes": bands.veto_reasons(tuple(cells)),
        "unmet": unmet,
        "attic_control": raw.get("attic_control"),
        "settings": raw.get("settings"),
        "per_cell": per_cell,
        "canonical_arms": list(CANONICAL_ARMS),
        "diagnostic_arms": _diagnostics(raw),
        "clips": {
            c.bbox_key: {
                "band": bands.clip_band(c).value,
                "wall_s": c.p95_wall_s,
                "peak_rss_mb": c.peak_rss_mb,
                "output_fraction": c.output_fraction,
                "measured_on_mirror": c.measured_on_mirror,
            }
            for c in clips
        },
        "egress_q6": _egress(raw),
        "offline_b9": {
            k: v.get("offline") for k, v in raw.get("cells", {}).items()
            if v.get("offline")
        },
        "raw_cells": raw.get("cells", {}),
    }


def main() -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)
    result = analyze()
    dest = RESULTS / "results.json"
    dest.write_text(json.dumps(result, indent=2, default=str))

    print(f"verdict: {result['verdict'].upper()}")
    if result["vetoes"]:
        print("\nVETOES (B0/B5 — outside the band ladder):")
        for v in result["vetoes"]:
            print(f"  - {v}")
    if result["unmet"]:
        print(f"\nunmet ({len(result['unmet'])}):")
        for u in result["unmet"][:40]:
            print(f"  - {u}")
    print(f"\nwrote {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
