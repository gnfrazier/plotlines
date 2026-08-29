"""SPIKE-G — orchestrator and self-check gate.

    python spikes/SPIKE-G/run.py --dry-run     # offline self-checks (CI-safe)

`--dry-run` re-derives the figures RESULTS.md commits to, straight from SPIKE-A's
committed extracts and the pre-registered coefficients, and asserts the verdict
still reproduces. It touches no network. It exits non-zero if the spike's own
conclusions stop reproducing.

There is no `--live` here. The live measurement is a Flutter-harness run on two
desktop GPUs (HARNESS.md); this environment is software-raster only. SPIKE-13
took the same shape when its live half needed infrastructure that did not exist.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import regions as R  # noqa: E402
from analyze import analyze_region, summarize  # noqa: E402


def _check(cond: bool, label: str) -> bool:
    print(f"  [{'ok' if cond else 'FAIL'}] {label}")
    return bool(cond)


def dry_run() -> int:
    ok = True

    # 1. cut-K did not drift from what RESULTS.md quotes
    for plat, pinned in R.PINNED_CUT_K.items():
        ok &= _check(R.cut_k(plat) == pinned, f"cut_k({plat}) == {pinned}")

    # 2. the three regions reconstruct with every candidate positioned
    regions_out = [analyze_region(r) for r in R.REGIONS]
    for ro in regions_out:
        ok &= _check(
            ro["candidates_v1_2_0"] > 0 and ro["area_anchor_count"] > 0,
            f"{ro['region']}: {ro['candidates_v1_2_0']} candidates, "
            f"{ro['area_anchor_count']} area anchors",
        )

    s = summarize(regions_out)

    # 3. the verdict RESULTS.md commits to
    ok &= _check(
        s["recommended_strategy"] == "salience_gated",
        f"recommended strategy is salience_gated (got {s['recommended_strategy']})",
    )
    ok &= _check(
        s["per_strategy_bands"]["zoom_threshold"]["worst"] == "red",
        "zoom_threshold is RED (blank overview is a hard intent failure)",
    )
    ok &= _check(
        s["per_strategy_bands"]["naive"]["worst"] == "red",
        "naive is RED (frame blows the budget at bbox density)",
    )
    ok &= _check(
        s["per_strategy_bands"]["cluster_grid"]["worst"] == "amber",
        "cluster_grid is AMBER (fits, but aggregates salience away)",
    )
    ok &= _check(
        s["per_strategy_bands"]["salience_gated"]["per_region"]["lwr"] == "green",
        "salience_gated is GREEN in the sparse region (lwr)",
    )

    # 4. the density ceiling brackets the shipped ruleset and the flood
    ceiling = s["gpu_display_density_ceiling"]
    ok &= _check(
        R.REGIONS["sgv"].candidates_v1_2_0 < ceiling < R.REGIONS["sgv"].candidates_v1_1_0,
        f"GPU density ceiling {ceiling} is above the shipped ruleset "
        f"({R.REGIONS['sgv'].candidates_v1_2_0}) and below the v1.1.0 flood "
        f"({R.REGIONS['sgv'].candidates_v1_1_0})",
    )

    # 5. A16 lands near ~1.15 GB and above SPIKE-14's ~1 GB
    a16 = s["a16_restated"]["budget_mb"]
    ok &= _check(1024 < a16 < 1280, f"A16 restated at {a16} MB (SPIKE-14 was ~1024)")

    # 6. selection latency never exceeds the usable ceiling on GPU for the
    #    recommended strategy
    worst_sel = 0.0
    for ro in regions_out:
        for zp in ro["strategies"]["salience_gated"]["by_zoom"].values():
            worst_sel = max(worst_sel, zp["windows-gpu"]["selection"]["worst_ms"])
    ok &= _check(worst_sel <= 250, f"salience_gated worst selection latency {worst_sel} ms <= 250")

    print("\nSPIKE-G self-check:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    if "--dry-run" in argv or len(argv) == 1:
        return dry_run()
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
