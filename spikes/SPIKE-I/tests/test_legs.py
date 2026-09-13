"""B8 (Q6 arithmetic) and B9 (the Q1-D trigger), plus the grading boundary.

These three are where a spike most easily fools itself: an arithmetic that reads
as a measurement, an edit distribution tuned after the fact, and a grader that
quietly drops the arms that would have failed.
"""

from __future__ import annotations

import gzip
import json
import sys
from pathlib import Path

SPIKE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SPIKE))

import analyze  # noqa: E402
import egress  # noqa: E402
import offline as O  # noqa: E402


# ------------------------------------------------------------------ B9 shape


BOX = (-105.30, 39.98, -105.23, 40.04)


def test_edits_are_deterministic():
    """Same seed, same edits. A re-run must grade against the same bboxes
    rather than a fresh sample that happens to be kinder."""
    assert O.generate_edits(BOX) == O.generate_edits(BOX)


def test_edit_distribution_is_the_pre_registered_one():
    edits = O.generate_edits(BOX)
    shapes = {s for s, _ in edits}
    assert shapes == {"shrink", "nudge", "grow"}
    assert len([1 for s, _ in edits if s == "shrink"]) == O.EDITS_PER_SHAPE


def test_every_shrink_is_inside_the_original_box():
    """Scaling about the centre by <1 cannot leave the box. If this ever fails,
    B9's coverage number is measuring a bug in the edit generator."""
    for shape, b in O.generate_edits(BOX):
        if shape == "shrink":
            assert O._contains(BOX, b)


def test_no_grow_is_inside_the_original_box():
    for shape, b in O.generate_edits(BOX):
        if shape == "grow":
            assert not O._contains(BOX, b)


def test_coverage_counts_the_buffer_as_real_coverage():
    """The held graph covers the *buffered* box, not the trip bbox. Ignoring the
    500 m ring would understate what offline editing can serve — and B9's whole
    job is deciding whether Q1-C survives, so understating it would trigger the
    D fallback on a harness artefact."""
    buffered = (BOX[0] - 0.01, BOX[1] - 0.01, BOX[2] + 0.01, BOX[3] + 0.01)
    tight, _ = O.measure_coverage(BOX, BOX)
    loose, _ = O.measure_coverage(BOX, buffered)
    assert loose["nudge"]["servable"] > tight["nudge"]["servable"]


# ------------------------------------------------------------------ B8 shape


def test_egress_reports_a_ratio_and_labels_the_guess():
    """The ratio is the part that survives being wrong about the population,
    which is the most likely thing about any figure here to be wrong."""
    figures = [
        egress.RegionFigures("colorado", 381_394_250, 2_300_000, 39.6),
        egress.RegionFigures("wisconsin", 292_703_422, 4_100_000, 249.8),
    ]
    out = egress.arithmetic(figures)
    assert out["assumptions"]["stated_as"].startswith("guess")
    assert all(r["ratio"] and r["ratio"] > 1 for r in out["rows"])
    assert {r["region"] for r in out["per_region"]} == {"colorado", "wisconsin"}


def test_egress_survives_no_measurements_without_inventing_any():
    assert "error" in egress.arithmetic([])


# ------------------------------------------------- the grading boundary itself


def _fake_probe(tmp_path: Path, *, raw_arm_diff: int) -> Path:
    """A probe record with one clean canonical arm and one deliberately-wrong
    diagnostic arm."""
    def cmp(node_diff: int):
        return {
            "nodes": {"golden": 1000, "local": 1000,
                      "only_golden": node_diff, "only_local": 0},
            "edges": {"golden": 2000, "local": 2000,
                      "only_golden": 0, "only_local": 0, "collisions": 0},
            "edge_keys": {"common": 2000, "same_key": 2000, "stability": 1.0,
                          "rekeyed_on_single_edge_uv": 0},
            "scc": {"golden": 1000, "local": 1000,
                    "golden_ratio": 1.0, "local_ratio": 1.0},
            "length_delta_m": {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0},
            "way_filter": {"false_rejects": 0, "false_accepts": 0,
                           "sample_false_rejects": [], "sample_false_accepts": []},
        }

    record = {
        "attic_control": {"honoured": True, "live_elements": 10,
                          "dated_2020_elements": 5},
        "cells": {
            "boulder-bike": {
                "network_type": "bike",
                "extracts": [{"path": "north-america/us/colorado",
                              "bytes": 381_394_250}],
                "area_km2": 39.6,
                "clips": {"raw/complete_ways": {"output_bytes": 2_300_000,
                                                 "wall_s": 12.0,
                                                 "peak_rss_mb": 900.0,
                                                 "output_fraction": 0.006}},
                "locals": {"T/buffered/vertex": {"nodes": 1000},
                           "T/raw/vertex": {"nodes": 1000}},
                "parity": {"T/buffered/vertex": cmp(0),
                           "T/raw/vertex": cmp(raw_arm_diff)},
                "tags": {"losses": {}},
            }
        },
    }
    dest = tmp_path / "probe.json.gz"
    with gzip.open(dest, "wt") as fh:
        json.dump(record, fh)
    return dest


def test_only_canonical_arms_are_graded(tmp_path, monkeypatch):
    """The raw-bbox arm is a *known-wrong input* — osmnx queries a buffered
    polygon, which is discoverable from its source and not from these results.
    Grading it would RESCOPE every run on an arm built to fail, which would make
    the band meaningless."""
    dest = _fake_probe(tmp_path, raw_arm_diff=500)
    monkeypatch.setattr(analyze, "RAW", tmp_path)
    out = analyze.analyze()
    # Every graded cell is clean, and the wrong arm is not among them...
    assert all("T/raw" not in k for k in out["per_cell"])
    assert all(v["band"] == "parity" for v in out["per_cell"].values())
    # ...but the run still does not reach PARITY overall, because its clip
    # figures are dev-box ones. That is `clip_band` refusing to let a local run
    # decide Q1-C (addendum 2c), not the raw arm leaking into the grade — the
    # distinction is exactly what the next two tests pin.
    assert out["verdict"] == "recalibrate"


def test_the_ungraded_arm_is_still_reported_in_full(tmp_path, monkeypatch):
    """Not grading it is not the same as dropping it. A reader must be able to
    see that the wrong arm was run and what it cost — that is the only reason
    running it was worth the time."""
    dest = _fake_probe(tmp_path, raw_arm_diff=500)
    monkeypatch.setattr(analyze, "RAW", tmp_path)
    out = analyze.analyze()
    diag = out["diagnostic_arms"]
    assert any("T/raw/vertex" in k for k in diag)
    entry = next(v for k, v in diag.items() if "T/raw/vertex" in k)
    assert entry["nodes"]["diff"] == 500
    assert entry["band_if_it_had_been_graded"] == "rescope"


def test_a_dev_box_clip_keeps_the_run_off_parity(tmp_path, monkeypatch):
    """Every clip in a local probe run is a dev-box figure, and addendum 2c says
    those cannot decide Q1-C. The verdict must reflect that even when every
    parity band is clean."""
    dest = _fake_probe(tmp_path, raw_arm_diff=0)
    monkeypatch.setattr(analyze, "RAW", tmp_path)
    out = analyze.analyze()
    assert out["clips"]
    assert all(not c["measured_on_mirror"] for c in out["clips"].values())
    assert any("not measured on the mirror" in u for u in out["unmet"])
