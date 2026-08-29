"""SPIKE-13 — orchestrator and self-check gate.

    python spikes/SPIKE-13/run.py --dry-run          # offline self-checks (CI-safe)
    python spikes/SPIKE-13/run.py --live seeds.json   # real send + poll + analyze

`--dry-run` re-derives every published figure from the committed sample run and
asserts the band logic still lands where RESULTS.md says it does. It touches no
network and is the form that belongs in CI. It exits non-zero if the spike's own
conclusions stop reproducing.

`--live` needs a seeds file (out of git — see probe.py) and a provider API key in
the environment. It sends `rounds` messages to every seed, polls each mailbox,
writes `results/run-<timestamp>.json`, and runs `analyze.py` over it.
"""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(__file__))

from analyze import percentile, rollup, summarize  # noqa: E402
from authcheck import AuthGrade, AuthRecords, grade, parse_dmarc, parse_spf  # noqa: E402
from bands import Band, HostResult, Rollup, classify  # noqa: E402

HERE = os.path.dirname(__file__)
SAMPLE = os.path.join(HERE, "results", "sample_run.json")


def _check(cond: bool, label: str) -> bool:
    print(f"  [{'ok' if cond else 'FAIL'}] {label}")
    return cond


def dry_run() -> int:
    ok = True

    # 1. percentile edge cases
    ok &= _check(percentile([], 50) == float("inf"), "percentile of empty is +inf")
    ok &= _check(percentile([5.0], 95) == 5.0, "percentile of singleton")
    ok &= _check(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50) == 5, "p50 nearest-rank")

    # 2. the committed sample analyses to the verdict RESULTS.md commits to
    with open(SAMPLE) as fh:
        sample = json.load(fh)
    result = summarize(sample)
    ok &= _check(result["verdict"] == "fallback", f"sample verdict is FALLBACK (got {result['verdict']})")
    ok &= _check(len(result["why_not_stake"]) > 0, "sample has a documented reason it is not STAKE")
    ok &= _check(result["why_not_fallback"] == [], "sample clears the FALLBACK bar")

    # 3. band boundaries
    perfect = Rollup(
        inbox_rate=1.0, spam_rate=0.0, missing_rate=0.0, p50_seconds=4.0, p95_seconds=12.0,
        per_host=(HostResult("gmail", 1.0, 0.0, 0.0), HostResult("yahoo", 1.0, 0.0, 0.0)),
    )
    ok &= _check(classify(perfect) is Band.STAKE, "a clean run classifies STAKE")

    one_bad_host = Rollup(
        inbox_rate=0.98, spam_rate=0.005, missing_rate=0.005, p50_seconds=5.0, p95_seconds=20.0,
        per_host=(HostResult("gmail", 1.0, 0.0, 0.0), HostResult("yahoo", 0.80, 0.20, 0.0)),
    )
    ok &= _check(
        classify(one_bad_host) is Band.BLOCK,
        "a great rollup with one host at 80% inbox is BLOCK, not STAKE",
    )

    # 4. authcheck parsing
    spf = parse_spf('"v=spf1 include:spf.example.net ~all"')
    ok &= _check(spf.present and spf.all_qualifier == "~", "SPF parse: mechanisms + ~all")
    dmarc = parse_dmarc("v=DMARC1; p=quarantine; pct=100; rua=mailto:d@plotlines.app")
    ok &= _check(dmarc.has_teeth and dmarc.rua == ["mailto:d@plotlines.app"], "DMARC parse: teeth + rua")
    records = AuthRecords(domain="auth.plotlines.app", spf=spf, dmarc=dmarc, dkim_selectors={"pm": True})
    ok &= _check(grade(records) is AuthGrade.STANDARD, "SPF + DKIM + DMARC quarantine grades STANDARD")

    print("\nSPIKE-13 self-check:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def live(seeds_path: str, provider: str, from_address: str, rounds: int, wait_window_s: int) -> int:
    from probe import Seed, poll_seed
    from providers import send_one

    with open(seeds_path) as fh:
        seeds = [Seed(**s) for s in json.load(fh)["seeds"]]

    sent_at = datetime.now(timezone.utc)
    observations: list[dict] = []
    for rnd in range(rounds):
        for seed in seeds:
            token = f"plotlines-spike13-{uuid.uuid4().hex[:12]}"
            subject = f"Your Plotlines sign-in link [{token}]"
            text = (
                "Someone asked to sign in to Plotlines with this email address.\n\n"
                f"Open this link to finish signing in (expires in 15 minutes):\n"
                f"https://auth.plotlines.app/verify/{token}\n\n"
                "If this wasn't you, you can ignore this email.\n"
            )
            send_one(provider, from_address, seed.address, subject, text)
            obs = poll_seed(seed, token, sent_at, wait_window_s)
            observations.append(obs.as_dict())
            print(f"  round {rnd + 1} {seed.host:10s} -> {obs.placement} "
                  f"({obs.time_to_inbox_seconds}s)")

    run = {
        "provider": provider,
        "from_address": from_address,
        "sent_at": sent_at.isoformat(),
        "wait_window_seconds": wait_window_s,
        "rounds": rounds,
        "observations": observations,
    }
    stamp = sent_at.strftime("%Y%m%dT%H%M%SZ")
    out = os.path.join(HERE, "results", f"run-{stamp}.json")
    with open(out, "w") as fh:
        json.dump(run, fh, indent=2)
    print(f"\nwrote {out}")

    r = rollup(run)
    print(f"verdict: {classify(r).value.upper()}  inbox {r.inbox_rate:.1%}  "
          f"spam {r.spam_rate:.1%}  p50 {r.p50_seconds:.0f}s  p95 {r.p95_seconds:.0f}s")
    return 0


def main(argv: list[str]) -> int:
    if "--dry-run" in argv or len(argv) == 1:
        return dry_run()
    if "--live" in argv:
        seeds_path = argv[argv.index("--live") + 1]
        provider = os.environ.get("SPIKE13_PROVIDER", "postmark")
        from_address = os.environ.get("SPIKE13_FROM", "login@auth.plotlines.app")
        rounds = int(os.environ.get("SPIKE13_ROUNDS", "20"))
        wait_window_s = int(os.environ.get("SPIKE13_WAIT", "300"))
        return live(seeds_path, provider, from_address, rounds, wait_window_s)
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
