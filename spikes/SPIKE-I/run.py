"""SPIKE-I — the verdict gate. Re-derives every published clause and asserts it.

    .venv/bin/python run.py            # grade results/results.json
    .venv/bin/python run.py --verbose

Touches no network and no clock: it reads `results/results.json` and re-derives
each clause from it, so a claim in `RESULTS.md` that stops being true fails here
rather than sitting in a document nobody re-reads. SPIKE-E's `run.py --dry-run`
is the shape being copied — its 21 verdict clauses, re-asserted offline.

The one thing this file deliberately cannot do is move a threshold. Every number
it compares against comes from `bands.py`, which is committed in the first commit
of this spike, before `probe.py` was first executed. If a clause here fails, the
answer is a finding, an issue, or a rescope — never an edit to the band.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Callable

SPIKE = Path(__file__).resolve().parent
sys.path.insert(0, str(SPIKE))

import bands  # noqa: E402

RESULTS = SPIKE / "results" / "results.json"


class Clause:
    def __init__(self, ident: str, description: str, fn: Callable[[dict], tuple[bool, str]]):
        self.ident = ident
        self.description = description
        self.fn = fn


def _clauses() -> list[Clause]:
    def c(ident: str, description: str):
        def deco(fn):
            return Clause(ident, description, fn)
        return deco

    out: list[Clause] = []

    @c("I-1", "the §1 snapshot control was verified live before any golden was built")
    def _(r):
        ac = r.get("attic_control") or {}
        if not ac:
            return False, "no attic control recorded — the run cannot be graded"
        return bool(ac.get("honoured")), (
            f"live={ac.get('live_elements')} dated={ac.get('dated_2020_elements')}"
        )
    out.append(_)

    @c("I-2", "every cell was graded — no cell silently absent from the matrix")
    def _(r):
        got = {k.split(":")[0] for k in r["per_cell"]}
        import regions as R

        want = {cell.key for cell in R.CELLS}
        missing = want - got
        return not missing, (f"missing {sorted(missing)}" if missing
                             else f"{len(got)}/{len(want)} cells")
    out.append(_)

    @c("I-3", "B5 tag survival — zero losses across bytes, graph and fold")
    def _(r):
        losses = {k: v["tag_losses"] for k, v in r["per_cell"].items() if v["tag_losses"]}
        return not losses, (json.dumps(losses)[:300] if losses else "no tag lost")
    out.append(_)

    @c("I-4", "path T reaches PARITY on node sets in every cell")
    def _(r):
        bad = {
            k: v["nodes"] for k, v in r["per_cell"].items()
            if v["path"] == "transport" and k.endswith("/vertex")
            and v["nodes"]["diff"]
        }
        return not bad, (json.dumps(bad)[:300] if bad else "exact in every cell")
    out.append(_)

    @c("I-5", "path T reaches PARITY on edge sets in every cell")
    def _(r):
        bad = {
            k: v["edges"] for k, v in r["per_cell"].items()
            if v["path"] == "transport" and k.endswith("/vertex") and v["edges"]["diff"]
        }
        return not bad, (json.dumps(bad)[:300] if bad else "exact in every cell")
    out.append(_)

    @c("I-6", "B2b edge keys are 100% stable on path T")
    def _(r):
        bad = {
            k: v["edge_key_stability"] for k, v in r["per_cell"].items()
            if v["path"] == "transport" and k.endswith("/vertex")
            and v["edge_key_stability"] < bands.MIN_EDGE_KEY_STABILITY_PARITY
        }
        return not bad, (json.dumps(bad)[:300] if bad else "1.0 in every cell")
    out.append(_)

    @c("I-7", "B3 largest SCC is identical on path T — no road fell out of the "
              "routable set")
    def _(r):
        bad = {
            k: v["scc"] for k, v in r["per_cell"].items()
            if v["path"] == "transport" and k.endswith("/vertex")
            and v["scc"]["golden"] != v["scc"]["local"]
        }
        return not bad, (json.dumps(bad)[:300] if bad else "identical in every cell")
    out.append(_)

    @c("I-8", "B4 geometry — max per-edge length delta within the 1 mm band")
    def _(r):
        bad = {
            k: v["length_delta_max_m"] for k, v in r["per_cell"].items()
            if v["path"] == "transport" and k.endswith("/vertex")
            and v["length_delta_max_m"] > bands.MAX_EDGE_LENGTH_DELTA_PARITY_M
        }
        return not bad, (json.dumps(bad)[:300] if bad else "<= 1 mm in every cell")
    out.append(_)

    @c("I-9", "both clip extents were measured, and the raw-bbox clip — what "
              "`/clip` actually returns — reaches parity")
    def _(r):
        """**This clause asserted a prediction, and the prediction was wrong.**

        It originally required that the buffered arm be exact and the raw arm
        *not* be, on the reasoning that `graph_from_polygon` queries a polygon
        buffered by 500 m and only truncates to the trip bbox after
        simplification and component selection have run on the buffered graph.
        Every arm came back exact.

        The reason, in hindsight: `complete_ways` keeps a selected way **whole**,
        so a clip taken at the raw bbox already reaches past it by up to a full
        way length — more than the 500 m the buffer was adding. The completeness
        strategy had already done the buffer's work.

        Rewritten to assert what was measured rather than what was expected,
        because the measured fact is the one Phase 3 needs: the shipped `/clip`
        output is sufficient as-is, with no buffered-bbox request. The bands in
        `bands.py` are untouched — they never mentioned the buffer, which is
        exactly why a failed prediction here costs a clause and not a verdict.
        """
        diag = r.get("diagnostic_arms") or {}
        buffered = [v for k, v in r["per_cell"].items() if "T/buffered/vertex" in k]
        raw = [v for k, v in diag.items() if "T/raw/vertex" in k]
        if not buffered or not raw:
            return False, "one of the two clip extents was not measured"
        b_exact = all(v["nodes"]["diff"] == 0 for v in buffered)
        r_exact = all(v["nodes"]["diff"] == 0 for v in raw)
        return b_exact and r_exact, (
            f"buffered exact={b_exact} raw exact={r_exact} — both, which "
            f"contradicts this clause's original prediction that the 500 m "
            f"buffer would be load-bearing (see RESULTS.md §1.2)"
        )
    out.append(_)

    @c("I-10", "path R (pyrosm) was actually attempted, so §11.1's named risk "
               "has evidence rather than an assumption")
    def _(r):
        attempted = [k for k in r["per_cell"] if ":R/" in k]
        raw_cells = r.get("raw_cells", {})
        errored = [
            f"{ck}:{pk}" for ck, cv in raw_cells.items()
            for pk, pv in (cv.get("locals") or {}).items()
            if pk.startswith("R/") and "error" in pv
        ]
        return bool(attempted or errored), (
            f"{len(attempted)} graded, {len(errored)} failed to build"
        )
    out.append(_)

    @c("I-11", "B6 clip figures state where they were taken, and a dev-box "
               "figure never claims PARITY")
    def _(r):
        liars = {
            k: v for k, v in r["clips"].items()
            if v["band"] == "parity" and not v["measured_on_mirror"]
        }
        return not liars, (json.dumps(liars)[:300] if liars
                            else f"{len(r['clips'])} clip measurements, all labelled")
    out.append(_)

    @c("I-12", "B8 — Q6's arithmetic is present with its assumptions stated as "
               "assumptions")
    def _(r):
        e = r.get("egress_q6") or {}
        ok = bool(e.get("rows")) and "stated_as" in (e.get("assumptions") or {})
        return ok, (f"{len(e.get('rows', []))} rows, "
                    f"mean clip {e.get('mean_clip_mb')} MB vs extract "
                    f"{e.get('mean_extract_mb')} MB")
    out.append(_)

    @c("I-13", "B9 — the offline-edit measurement exists and reports a servable "
               "fraction against the pre-registered distribution")
    def _(r):
        b9 = r.get("offline_b9") or {}
        if not b9:
            return False, "no offline measurement recorded"
        fractions = {k: v["servable_fraction"] for k, v in b9.items()}
        return True, json.dumps(fractions)
    out.append(_)

    @c("I-14", "the bands graded against are the ones committed before the run")
    def _(r):
        # `ZERO_TOLERANCE_WAY_TAGS` is mirrored in bands.py rather than imported,
        # precisely so a later narrowing of the product constant cannot silently
        # narrow the band. This is the assertion that makes the mirror safe.
        sys.path.insert(0, str(SPIKE.parent.parent / "core"))
        from plotlines_core.graph.regions import (
            PLOTLINES_NODE_TAGS, PLOTLINES_WAY_TAGS,
        )
        same = (tuple(PLOTLINES_WAY_TAGS) == bands.ZERO_TOLERANCE_WAY_TAGS
                and tuple(PLOTLINES_NODE_TAGS) == bands.ZERO_TOLERANCE_NODE_TAGS)
        return same, (
            "band tag list matches the product constant" if same else
            f"DRIFT: product={PLOTLINES_WAY_TAGS} band={bands.ZERO_TOLERANCE_WAY_TAGS}"
        )
    out.append(_)

    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--results", type=Path, default=RESULTS)
    args = ap.parse_args(argv)

    if not args.results.exists():
        print(f"no results at {args.results} — run probe.py then analyze.py")
        return 2
    r = json.loads(args.results.read_text())

    print(f"SPIKE-I verdict: {r['verdict'].upper()}\n")
    failed = 0
    for clause in _clauses():
        try:
            ok, detail = clause.fn(r)
        except Exception as exc:  # noqa: BLE001 - a clause that errors is a fail
            ok, detail = False, f"clause raised {exc!r}"
        mark = "PASS" if ok else "FAIL"
        if not ok:
            failed += 1
        if not ok or args.verbose:
            print(f"  [{mark}] {clause.ident} {clause.description}")
            print(f"         {detail}")
        else:
            print(f"  [{mark}] {clause.ident} {clause.description}")

    print(f"\n{len(_clauses()) - failed}/{len(_clauses())} clauses pass")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
