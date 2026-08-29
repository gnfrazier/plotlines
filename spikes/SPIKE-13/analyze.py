"""SPIKE-13 step 3 — turn a run's raw observations into the verdict.

Runs entirely offline against a run file (`results/sample_run.json`, or a real one
produced by `run.py`). Re-running the analysis never re-sends mail, so every
published figure reproduces without touching a provider or a mailbox.

Run file shape (one object):

    {
      "provider": "postmark",
      "from_address": "login@auth.plotlines.app",
      "sent_at": "2026-08-29T00:00:00Z",
      "wait_window_seconds": 300,
      "observations": [
        {
          "recipient": "seed+01@gmail.com",
          "host": "gmail",
          "placement": "inbox",            # inbox | spam | missing
          "time_to_inbox_seconds": 6.2,    # null when placement != inbox
          "spf": "pass", "dkim": "pass", "dmarc": "pass"
        },
        ...
      ]
    }

`host` is the normalised mail-host bucket (see bands.MAJOR_CONSUMER_HOSTS), not the
literal domain — `hotmail.com`, `outlook.com`, and `live.com` all bucket to
`microsoft` because one inbound filter sits behind all three.
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict

from bands import HostResult, Rollup, classify, unmet_reasons
from bands import FALLBACK_CRITERIA, STAKE_CRITERIA


def percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile. `pct` in [0, 100]. Empty -> inf (a run that
    delivered nothing to the inbox has an infinitely bad latency, not a zero)."""
    if not values:
        return float("inf")
    s = sorted(values)
    # Standard nearest-rank: rank = ceil(p/100 * n), clamped to [1, n].
    rank = max(1, min(len(s), math.ceil(pct / 100 * len(s))))
    return s[rank - 1]


def _rate(count: int, total: int) -> float:
    return count / total if total else 0.0


def rollup(run: dict) -> Rollup:
    obs = run["observations"]
    total = len(obs)
    if total == 0:
        raise ValueError("run has no observations")

    inbox = [o for o in obs if o["placement"] == "inbox"]
    spam = [o for o in obs if o["placement"] == "spam"]
    missing = [o for o in obs if o["placement"] == "missing"]

    latencies = [
        float(o["time_to_inbox_seconds"])
        for o in inbox
        if o.get("time_to_inbox_seconds") is not None
    ]

    by_host: dict[str, list[dict]] = defaultdict(list)
    for o in obs:
        by_host[o["host"]].append(o)

    per_host = tuple(
        HostResult(
            host=host,
            inbox_rate=_rate(sum(1 for o in items if o["placement"] == "inbox"), len(items)),
            spam_rate=_rate(sum(1 for o in items if o["placement"] == "spam"), len(items)),
            missing_rate=_rate(
                sum(1 for o in items if o["placement"] == "missing"), len(items)
            ),
        )
        for host, items in sorted(by_host.items())
    )

    return Rollup(
        inbox_rate=_rate(len(inbox), total),
        spam_rate=_rate(len(spam), total),
        missing_rate=_rate(len(missing), total),
        p50_seconds=percentile(latencies, 50),
        p95_seconds=percentile(latencies, 95),
        per_host=per_host,
    )


def summarize(run: dict) -> dict:
    r = rollup(run)
    band = classify(r)
    return {
        "provider": run.get("provider"),
        "from_address": run.get("from_address"),
        "sample_size": len(run["observations"]),
        "verdict": band.value,
        "overall": {
            "inbox_rate": round(r.inbox_rate, 4),
            "spam_rate": round(r.spam_rate, 4),
            "missing_rate": round(r.missing_rate, 4),
            "p50_seconds": None if r.p50_seconds == float("inf") else round(r.p50_seconds, 1),
            "p95_seconds": None if r.p95_seconds == float("inf") else round(r.p95_seconds, 1),
        },
        "per_host": [
            {
                "host": h.host,
                "inbox_rate": round(h.inbox_rate, 4),
                "spam_rate": round(h.spam_rate, 4),
                "missing_rate": round(h.missing_rate, 4),
            }
            for h in r.per_host
        ],
        "why_not_stake": unmet_reasons(STAKE_CRITERIA, r),
        "why_not_fallback": unmet_reasons(FALLBACK_CRITERIA, r),
    }


def main(argv: list[str]) -> int:
    src = argv[1] if len(argv) > 1 else "results/sample_run.json"
    dst = argv[2] if len(argv) > 2 else "results/deliverability.json"
    with open(src) as fh:
        run = json.load(fh)
    result = summarize(run)
    with open(dst, "w") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")
    print(f"{src} -> {dst}")
    print(f"  verdict: {result['verdict'].upper()}  (n={result['sample_size']})")
    o = result["overall"]
    print(
        f"  inbox {o['inbox_rate']:.1%}  spam {o['spam_rate']:.1%}  "
        f"missing {o['missing_rate']:.1%}  p50 {o['p50_seconds']}s  p95 {o['p95_seconds']}s"
    )
    for reason in result["why_not_stake"]:
        print(f"  - not STAKE: {reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
