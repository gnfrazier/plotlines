#!/usr/bin/env python3
"""Spend the Pi5 elevation proxy's remaining 24h free-tier budget
pre-warming real strategic QA/UAT regions, in priority order, and use the
run to also confirm the ceiling-exhaustion live check
(deploy/elevation/README.md, "Confirm ceiling exhaustion still degrades
cleanly against the real instance"). Companion to prewarm_cache.py — reuses
its wire client rather than reimplementing it.

Unlike prewarm_cache.py and geofabrik_pull.py, this script is NOT
stdlib-only / copy-anywhere: it needs `shapely` and `pyproj` for real
corridor geometry via `priority_regions.py`. Debian's system Python refuses
a direct `pip install` (PEP 668, "externally-managed-environment"), and the
project's own convention for this (see .gitignore's note by `.venv/`, used
the same way by spikes/shared/regions.py) is a repo-root venv:

    python3 -m venv .venv && .venv/bin/pip install shapely pyproj
    .venv/bin/python deploy/elevation/prewarm_priority_regions.py --dry-run
    .venv/bin/python deploy/elevation/prewarm_priority_regions.py --proxy-root http://127.0.0.1:8090 --yes

This script's own footprint is trivial (HTTP calls plus light shapely
geometry computed once up front, not the tile-merge workload that's prone
to OOM on this box) — safe to run in place, no need to offload it
elsewhere.

Each `/dem` attempt spends real, non-refundable OpenTopography quota (50
calls/24h, FR87) even when it fails upstream — `OpenTopographyClient.fetch`
(core/plotlines_core/elevation/keys.py) records the call before issuing the
HTTP request, "over-counting is the safe direction for a licensing
ceiling." Between every attempt this script sleeps a random 63-126 seconds —
a courteous pace against OpenTopography, not just the Pi.

Priority order: North Carolina (full state) -> Blue Ridge Parkway (+100mi)
-> Skyline Drive (+50mi) -> Boundary Waters Canoe Area Wilderness ->
Yellowstone -> Lake Champlain (+50mi) -> Pacific Crest Trail (+15mi,
Campo CA northward). If the whole list completes without the proxy ever
returning a natural 503, the PCT corridor is re-tiled at a wider buffer
(doubling each round) to spend the remaining budget on more useful margin
around the trail rather than leave it unspent; if that *still* doesn't
exhaust the ceiling, one deliberate call against a bbox nothing else in this
run touches (`SYNTHETIC_CONFIRMATION_BBOX`) confirms the 503/Retry-After/
free_tier_exhausted degrade the README's acceptance check asks for.
"""

from __future__ import annotations

import argparse
import random
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prewarm_cache  # noqa: E402 - sibling import, path set above
from priority_regions import (  # noqa: E402
    MAX_TILE_AREA_KM2,
    MI_TO_KM,
    PCT_BUFFER_KM,
    RegionCandidate,
    SYNTHETIC_CONFIRMATION_BBOX,
    bbox_area_km2,
    build_priority_candidates,
    pct_tiles_with_wider_buffer,
)

DEFAULT_MIN_DELAY_S = 63.0
DEFAULT_MAX_DELAY_S = 126.0
#: Wide enough that some round's multiplier lands inside whatever budget is
#: actually left, verified empirically against a fresh 50-call window: round
#: 4 (16x -> a 240mi PCT buffer) alone produces ~34 tiles, comfortably
#: covering the ~20-40 calls a full run of the fixed regions plus the base
#: PCT pass tends to leave. Harmless to leave configured higher than needed —
#: the loop stops at the first natural 503 regardless of how many rounds
#: remain.
DEFAULT_WIDEN_ROUNDS = 6


@dataclass
class AttemptLog:
    candidate: RegionCandidate
    result: prewarm_cache.PrewarmResult | None  # None => skipped, never attempted
    skipped_reason: str | None
    remaining_after: int | None  # from /health, immediately after this attempt


@dataclass
class RunReport:
    health_before: dict
    health_after: dict | None = None
    attempts: list[AttemptLog] = field(default_factory=list)
    ceiling_confirmed: bool = False
    ceiling_confirmed_via: str | None = None  # "natural" | "widened-pct" | "synthetic"


def _safe_health(proxy_root: str, fallback: dict) -> dict:
    try:
        return prewarm_cache.query_health(proxy_root)
    except Exception:
        return fallback


def run(
    proxy_root: str,
    *,
    pct_buffer_km: float = PCT_BUFFER_KM,
    max_tile_area_km2: float = MAX_TILE_AREA_KM2,
    widen_rounds: int = DEFAULT_WIDEN_ROUNDS,
    min_delay_s: float = DEFAULT_MIN_DELAY_S,
    max_delay_s: float = DEFAULT_MAX_DELAY_S,
) -> RunReport:
    dem_url = f"{proxy_root.rstrip('/')}/dem"
    health_before = prewarm_cache.query_health(proxy_root)
    report = RunReport(health_before=health_before)

    any_attempt_made = False

    def attempt(c: RegionCandidate) -> prewarm_cache.PrewarmResult:
        nonlocal any_attempt_made
        if any_attempt_made:
            delay = random.uniform(min_delay_s, max_delay_s)
            print(f"... waiting {delay:.1f}s before the next call", file=sys.stderr)
            time.sleep(delay)
        any_attempt_made = True
        result = prewarm_cache.prewarm_one_detailed(dem_url, c.bbox)
        remaining_after = _safe_health(proxy_root, {}).get("remaining_calls_24h")
        report.attempts.append(AttemptLog(c, result, None, remaining_after))
        if (
            result.outcome is prewarm_cache.PrewarmOutcome.UPSTREAM_FAILED
        ):
            print(
                f"WARNING: {c.label} (tile {c.tile_index}/{c.tile_count}, "
                f"~{c.area_km2:,.0f} km2) was refused upstream (502) — the "
                "assumed ~450,000 km2 GEDTM30 area cap may not hold for this "
                "bbox shape. The call is still spent (recorded before the "
                "wire). Continuing, but check remaining outcomes carefully.",
                file=sys.stderr,
            )
        return result

    def mark_skipped(candidates: list[RegionCandidate], reason: str) -> None:
        for c in candidates:
            report.attempts.append(AttemptLog(c, None, reason, None))

    candidates = build_priority_candidates(
        pct_buffer_km=pct_buffer_km, max_tile_area_km2=max_tile_area_km2
    )

    if health_before.get("remaining_calls_24h") == 0:
        result = attempt(candidates[0])
        if result.outcome is prewarm_cache.PrewarmOutcome.EXHAUSTED:
            report.ceiling_confirmed = True
            report.ceiling_confirmed_via = "natural"
        mark_skipped(candidates[1:], "budget already exhausted before this run started")
        report.health_after = _safe_health(proxy_root, health_before)
        return report

    exhausted = False
    for idx, c in enumerate(candidates):
        result = attempt(c)
        if result.outcome is prewarm_cache.PrewarmOutcome.EXHAUSTED:
            report.ceiling_confirmed = True
            report.ceiling_confirmed_via = "natural"
            mark_skipped(candidates[idx + 1 :], "ceiling exhausted earlier in this run")
            exhausted = True
            break

    if not exhausted:
        for widen_round in range(1, widen_rounds + 1):
            wide = pct_tiles_with_wider_buffer(
                2**widen_round, base_buffer_km=pct_buffer_km,
                priority=7 + widen_round, max_tile_area_km2=max_tile_area_km2,
            )
            for idx, c in enumerate(wide):
                result = attempt(c)
                if result.outcome is prewarm_cache.PrewarmOutcome.EXHAUSTED:
                    report.ceiling_confirmed = True
                    report.ceiling_confirmed_via = "widened-pct"
                    mark_skipped(wide[idx + 1 :], "ceiling exhausted earlier in this run")
                    exhausted = True
                    break
            if exhausted:
                break

    if not exhausted:
        synthetic = RegionCandidate(
            region_key="synthetic",
            label="Synthetic confirmation bbox (remote, untouched elsewhere)",
            priority=99,
            tile_index=1,
            tile_count=1,
            bbox=SYNTHETIC_CONFIRMATION_BBOX,
            area_km2=bbox_area_km2(SYNTHETIC_CONFIRMATION_BBOX),
        )
        result = attempt(synthetic)
        report.ceiling_confirmed = result.outcome is prewarm_cache.PrewarmOutcome.EXHAUSTED
        report.ceiling_confirmed_via = "synthetic" if report.ceiling_confirmed else None

    report.health_after = _safe_health(proxy_root, health_before)
    return report


def print_report(report: RunReport) -> None:
    print("=== Pre-warm priority-region run ===")
    hb, ha = report.health_before, report.health_after or {}
    print(
        f"Health before: ready={hb.get('ready')} "
        f"remaining_calls_24h={hb.get('remaining_calls_24h')} "
        f"next_free_at={hb.get('next_free_at')}"
    )
    print(
        f"Health after:  ready={ha.get('ready')} "
        f"remaining_calls_24h={ha.get('remaining_calls_24h')} "
        f"next_free_at={ha.get('next_free_at')}"
    )
    print()

    order: list[str] = []
    by_region: dict[str, list[AttemptLog]] = {}
    for log in report.attempts:
        key = log.candidate.region_key
        if key not in by_region:
            by_region[key] = []
            order.append(key)
        by_region[key].append(log)

    totals = {"fetched": 0, "upstream_failed": 0, "exhausted": 0, "skipped": 0, "other": 0}
    for key in order:
        logs = by_region[key]
        label = logs[0].candidate.label
        n = len(logs)
        ok_n = 0
        print(f"[{logs[0].candidate.priority}] {label}")
        for log in logs:
            c = log.candidate
            if log.result is None:
                status = f"SKIPPED ({log.skipped_reason})"
                totals["skipped"] += 1
            elif log.result.outcome is prewarm_cache.PrewarmOutcome.OK:
                status = f"FETCHED ({log.result.bytes_len} bytes, {log.result.elapsed_s:.1f}s)"
                totals["fetched"] += 1
                ok_n += 1
            elif log.result.outcome is prewarm_cache.PrewarmOutcome.EXHAUSTED:
                retry = f", Retry-After={log.result.retry_after_s}s" if log.result.retry_after_s else ""
                status = f"REFUSED 503 free_tier_exhausted{retry}"
                totals["exhausted"] += 1
            elif log.result.outcome is prewarm_cache.PrewarmOutcome.UPSTREAM_FAILED:
                status = "REFUSED 502 upstream_fetch_failed"
                totals["upstream_failed"] += 1
            else:
                status = f"ERROR ({log.result.detail})"
                totals["other"] += 1
            print(
                f"    tile {c.tile_index}/{c.tile_count}  area={c.area_km2:>10,.0f} km2  "
                f"bbox={c.bbox}  {status}"
            )
        coverage = "FULL" if ok_n == n else ("PARTIAL" if ok_n else "NONE")
        print(f"    -> {ok_n}/{n} tiles OK, coverage={coverage}")

    print()
    print(
        f"Totals: {totals['fetched']} fetched, "
        f"{totals['upstream_failed']} upstream-failed(502), "
        f"{totals['exhausted']} exhausted(503), "
        f"{totals['skipped']} skipped, {totals['other']} other-errors"
    )
    via = report.ceiling_confirmed_via or "none"
    verdict = "CONFIRMED" if report.ceiling_confirmed else "NOT CONFIRMED"
    print(f"Ceiling-exhaustion live check: {verdict} (via={via})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--proxy-root",
        default="http://127.0.0.1:8090",
        help="the proxy's root URL, e.g. http://<pi-LAN>:8090 — not the "
        "/dem path itself (default: %(default)s)",
    )
    parser.add_argument(
        "--pct-buffer-miles", type=float, default=15.0,
        help="PCT corridor buffer width in miles (default: %(default)s)",
    )
    parser.add_argument(
        "--max-tile-area-km2", type=float, default=MAX_TILE_AREA_KM2,
        help="self-imposed per-request area cap, under OpenTopography's "
        "real ~450,000 km2 limit for 30m-class datasets (default: %(default)s)",
    )
    parser.add_argument(
        "--widen-rounds", type=int, default=DEFAULT_WIDEN_ROUNDS,
        help="how many PCT re-tile rounds (buffer doubling each round) to "
        "try if the base priority list never naturally exhausts the ceiling "
        "(default: %(default)s)",
    )
    parser.add_argument("--min-delay-s", type=float, default=DEFAULT_MIN_DELAY_S)
    parser.add_argument("--max-delay-s", type=float, default=DEFAULT_MAX_DELAY_S)
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the full candidate table and exit; no network calls at all",
    )
    parser.add_argument(
        "--yes", action="store_true",
        help="required to actually execute against the proxy — this spends "
        "real, non-refundable OpenTopography free-tier quota",
    )
    args = parser.parse_args(argv)

    pct_buffer_km = args.pct_buffer_miles * MI_TO_KM

    if args.dry_run:
        candidates = build_priority_candidates(
            pct_buffer_km=pct_buffer_km, max_tile_area_km2=args.max_tile_area_km2
        )
        total_area = 0.0
        for c in candidates:
            print(
                f"[{c.priority}] {c.region_key:<12} tile {c.tile_index}/{c.tile_count}  "
                f"area={c.area_km2:>10,.0f} km2  bbox={c.bbox}"
            )
            total_area += c.area_km2
        print(
            f"\n{len(candidates)} candidate tiles, {total_area:,.0f} km2 total "
            "(base priority list only — before any natural exhaustion or "
            "PCT widen-round fallback)"
        )
        return 0

    if not args.yes:
        print(
            "Refusing to run against the live proxy without --yes — this "
            "spends real, non-refundable OpenTopography free-tier quota. "
            "Use --dry-run to preview the candidate list first.",
            file=sys.stderr,
        )
        return 2

    try:
        report = run(
            args.proxy_root,
            pct_buffer_km=pct_buffer_km,
            max_tile_area_km2=args.max_tile_area_km2,
            widen_rounds=args.widen_rounds,
            min_delay_s=args.min_delay_s,
            max_delay_s=args.max_delay_s,
        )
    except Exception as exc:  # noqa: BLE001 - report and exit non-zero, never traceback
        print(f"ERROR: could not complete the run: {exc}", file=sys.stderr)
        return 1

    print_report(report)
    return 0 if report.ceiling_confirmed else 1


if __name__ == "__main__":
    raise SystemExit(main())
