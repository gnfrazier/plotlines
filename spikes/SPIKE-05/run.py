"""SPIKE-05 driver — ingest, classify, evaluate, and write results that carry no location.

Usage:
    python spikes/SPIKE-05/run.py [--files spikes/fit_files]

Two guarantees this file is responsible for, both checked rather than intended:

  * **No location data reaches `results/`.** Activities are relabelled by mode and
    sequence (`cycling-03`), so the two supplied files with place names in their filenames
    do not leak through the one channel that would otherwise carry them. `assert_clean()`
    re-reads what was written and fails the run if a coordinate-shaped number or a source
    filename appears in it.
  * **Nothing is scored on data it was fitted on.** See `eta.leave_one_out`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import classify  # noqa: E402
import eta  # noqa: E402
import ingest  # noqa: E402

RESULTS = HERE / "results"
DEFAULT_FILES = HERE.parent / "fit_files"


def build_dataset(folder: Path):
    paths = sorted(p for p in folder.iterdir()
                   if p.suffix.lower() in (".fit", ".gpx", ".tcx"))
    if not paths:
        raise SystemExit(f"no activity files in {folder}")

    staged, counters, failures = [], {}, []
    for path in paths:
        try:
            samples, session, fmt = ingest.load(path)
            declared = ingest.declared_mode(session)
            provisional = ingest.derive(samples, session, "provisional",
                                        declared or "cycling", fmt)
        except Exception as exc:                       # noqa: BLE001 - report, don't crash
            failures.append({"file_kind": path.suffix.lower().lstrip("."),
                             "error": f"{type(exc).__name__}: {exc}"})
            continue
        cls = classify.classify(provisional, declared)
        staged.append((provisional, cls, session, fmt))

    dataset = []
    for provisional, cls, session, fmt in sorted(staged, key=lambda s: s[1].mode):
        counters[cls.mode] = counters.get(cls.mode, 0) + 1
        label = f"{cls.mode}-{counters[cls.mode]:02d}"
        provisional.label = label
        provisional.mode = cls.mode
        dataset.append((provisional, cls))
    return dataset, failures


def assert_clean(payload: str, folder: Path) -> None:
    """Fail loudly if anything location-shaped survived into the results.

    Checks the two ways a leak could realistically happen: a source filename (two of which
    are place names), and a decimal that looks like a coordinate. The coordinate test is
    deliberately crude and will occasionally be a false positive — that is the correct
    direction to be wrong in.
    """
    for path in folder.iterdir():
        if path.stem and path.stem in payload:
            raise AssertionError(f"source filename leaked into results: {path.stem}")
    for match in re.finditer(r"-?\d{1,3}\.\d{5,}", payload):
        raise AssertionError(f"coordinate-shaped value in results: {match.group()}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", type=Path, default=DEFAULT_FILES)
    args = ap.parse_args()

    dataset, failures = build_dataset(args.files)
    print(f"ingested {len(dataset)} activities"
          + (f", {len(failures)} failed" if failures else ""))

    print(f"\n{'label':13} {'src':4} {'declared':>10} {'terrain':8} {'km':>7} "
          f"{'moving':>8} {'elapsed':>8} {'asc':>6} {'km/h':>6} {'cv':>5} flags")
    for act, cls in dataset:
        print(f"{act.label:13} {act.source_format:4} "
              f"{str(act.declared_sport):>10} {cls.terrain:8} {act.distance_km:7.2f} "
              f"{act.moving_s/60:7.1f}m {act.elapsed_s/60:7.1f}m {act.ascent_m:6} "
              f"{act.avg_moving_speed_kmh:6.2f} {act.speed_cv:5.2f} "
              f"{','.join(act.quality_flags) or '-'}")

    factories = [
        lambda: eta.FlatAverageModel("flat average (baseline — grade ignored)"),
        eta.LiteratureModel,
        lambda: eta.BinnedModel("personal grade-binned (FR16 custom/aggregated pace)"),
    ]

    evaluations = []
    for target in ("moving", "elapsed"):
        print(f"\n=== predicting {target} time (leave-one-out) ===")
        for factory in factories:
            ev = eta.leave_one_out(factory, dataset, target=target)
            evaluations.append(ev)
            # ASCII only: this prints to a Windows console under cp1252, where a '<='
            # glyph is a UnicodeEncodeError and takes the whole run down at the last step.
            print(f"  {ev.model:52} n={ev.n:2}  MAPE={ev.mape:5.1f}%  "
                  f"median={ev.median_ape:5.1f}%  worst={ev.worst_ape:5.1f}% "
                  f"({ev.worst_label})  <=10%:{ev.within_10pct}  <=20%:{ev.within_20pct}")
            per_mode = "  ".join(
                f"{m}={v['mape']}% (n={v['n']})" if v["mape"] is not None
                else f"{m}=n/a" for m, v in ev.by_mode.items())
            print(f"    by mode: {per_mode}")

    RESULTS.mkdir(parents=True, exist_ok=True)
    activities_payload = [
        {**{k: v for k, v in vars(act).items()},
         "classification": {
             "mode": cls.mode, "mode_source": cls.mode_source,
             "mode_confidence": cls.mode_confidence, "terrain": cls.terrain,
             "terrain_confidence": cls.terrain_confidence, "evidence": cls.evidence,
         }}
        for act, cls in dataset
    ]
    payload = json.dumps({"activities": activities_payload,
                          "ingest_failures": failures}, indent=2)
    assert_clean(payload, args.files)
    (RESULTS / "activities.json").write_text(payload, encoding="utf-8")

    eval_payload = json.dumps([vars(e) for e in evaluations], indent=2)
    assert_clean(eval_payload, args.files)
    (RESULTS / "eta_evaluation.json").write_text(eval_payload, encoding="utf-8")

    print(f"\nwrote {RESULTS / 'activities.json'} and {RESULTS / 'eta_evaluation.json'}"
          "\nboth verified free of filenames and coordinate-shaped values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
