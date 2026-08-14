#!/usr/bin/env python
"""Run SPIKE-01, SPIKE-02, and SPIKE-03 over one shared setup.

    .venv/bin/python spikes/run_routing_spikes.py [01 02 03]

The three routing spikes ask different questions of the same substrate, so they share
one `Bench`: graphs parsed once, edge features warmed once, via-points derived the
same deterministic way. Run separately they would each pay that setup again and, worse,
could disagree — a conflict SPIKE-02 explains must be a conflict SPIKE-03 measured on
the same graph, or neither result means anything.

Exits non-zero if a spike's own self-checks fail, so this works as a CI gate.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

SPIKES = Path(__file__).resolve().parent
sys.path.insert(0, str(SPIKES / "shared"))

from harness import Bench, write_results  # noqa: E402


def _load(spike: str):
    """Import `spikes/SPIKE-0N/run.py`. The directory names are not valid module
    names, so this goes through the loader directly rather than fighting the path."""
    path = SPIKES / f"SPIKE-{spike}" / "run.py"
    spec = importlib.util.spec_from_file_location(f"spike_{spike}_run", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _self_check(spike: str, payload: dict) -> list[str]:
    """Per-spike pass/fail. These are the claims the RESULTS docs rest on."""
    failures = []
    if spike == "01":
        for row in payload["via_sweep"]:
            if row.get("error"):
                continue
            if row["via_count"] and not row["hit_via"]:
                failures.append(f"01: {row['region']}/{row['theme']} skipped a via-node")
            if not row["closed"]:
                failures.append(f"01: {row['region']}/{row['theme']} loop did not close")
        if len({r["solver"] for r in payload["primitive_identity"]}) != 1:
            failures.append("01: route shapes did not share one solver")
    elif spike == "02":
        totals = payload["totals"]
        if totals["false_positives"]:
            failures.append(f"02: {totals['false_positives']} false conflict(s)")
        if totals["kind_correct"] != totals["scenarios"]:
            failures.append(
                f"02: classified {totals['kind_correct']}/{totals['scenarios']}")
    elif spike == "03":
        if not payload["grid"]:
            failures.append("03: empty grid")
        for key, env in payload["envelopes"].items():
            if "climb_m" not in env:
                failures.append(f"03: no climbing envelope for {key}")
    return failures


def main(argv: list[str]) -> int:
    wanted = argv or ["01", "02", "03"]
    failures: list[str] = []

    with Bench.setup() as bench:
        environment = bench.environment()
        print(json.dumps(environment["regions"], indent=2))
        for spike in wanted:
            module = _load(spike)
            payload = module.run(bench)
            payload["environment"] = environment
            checks = _self_check(spike, payload)
            payload["self_check"] = {"passed": not checks, "failures": checks}
            path = write_results(f"SPIKE-{spike}", payload)
            failures.extend(checks)
            print(f"SPIKE-{spike}: {'ok' if not checks else 'FAILURES'} -> {path}")
            for line in checks:
                print(f"  ! {line}")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
