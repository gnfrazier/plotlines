#!/usr/bin/env bash
#
# The full pre-push run: the three suites CI runs, plus the three toolchain-
# free gates, all at once. This is the "run the full suite plus the lint
# gates green" step of the build agreement, as one command.
#
# The suites run concurrently because they are independent processes with
# nothing in common — separate venvs, separate toolchains, separate temp
# dirs — and their wall times are very different: core finishes in seconds,
# service in ~15 s under xdist, the client in ~100 s on a 16-core machine.
# Run back to back they add up; run together the wall time is the client's.
# Each suite's output goes to its own file so interleaving never obscures a
# failure, and every file is printed in full at the end whether or not it
# passed — the point is to read the failure, not to guess which suite it
# was in.
#
# For the inner loop, keep pointing the tool at a file:
#   cd core    && uv run --frozen pytest tests/test_x.py
#   cd service && uv run --frozen pytest tests/test_x.py
#   cd client  && flutter test test/x_test.dart
#
# `-n auto` (pytest-xdist) sizes the service suite's worker count to the
# machine's vCPU count. On a big-core WSL box that means one worker per
# core, each importing service's full `core` dependency (osmnx/numpy/
# networkx) — run alongside `flutter test`'s own analyzer/VM footprint, two
# runs on 2026-09-20 drove combined RSS to 15-18 GB and the guest OOM-killer
# killed pytest and then needed the VM itself restarted. Set
# PLOTLINES_TEST_ALL_JOBS to cap the worker count (e.g. 4) when running
# locally on a high-core-count machine; CI's runners have few enough vCPUs
# that `auto` there was never the problem.
#
# Usage: tools/test_all.sh
#        PLOTLINES_TEST_ALL_JOBS=4 tools/test_all.sh
# Exit status is non-zero if any suite or gate failed.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
cd "$root"

service_jobs="${PLOTLINES_TEST_ALL_JOBS:-auto}"

run() {  # run <name> <working-dir> <command...>
  local name="$1" dir="$2"; shift 2
  ( cd "$dir" && "$@" ) > "$out/$name.log" 2>&1
  local rc=$?
  echo "$rc" > "$out/$name.rc"
}

started=$(date +%s)

run core    core    uv run --frozen pytest -q &
run service service uv run --frozen pytest -q -n "$service_jobs" &
run client  client  flutter test &
# Gates: cheap, no toolchain beyond python3. Sequential is fine.
run gate-reveal  . tools/ci/reveal_gate_lint.sh &
run gate-schema  . env PYTHONPATH=core python3 spikes/SPIKE-20/run.py --check-committed &
wait

# The P1 boundary gate inline — a grep, same as CI's.
if grep -rnE '^\s*(import fastapi|from fastapi)' core/plotlines_core/ > "$out/gate-p1.log" 2>&1; then
  echo "plotlines-core imported fastapi — violates P1 (ARCH §6.1, risk A7)" >> "$out/gate-p1.log"
  echo 1 > "$out/gate-p1.rc"
else
  echo "OK: no fastapi import found in core/plotlines_core/" > "$out/gate-p1.log"
  echo 0 > "$out/gate-p1.rc"
fi

status=0
for name in core service client gate-p1 gate-reveal gate-schema; do
  rc=$(cat "$out/$name.rc")
  echo
  echo "===================== $name (exit $rc) ====================="
  # Suites are chatty on success; show the tail. A failure gets the whole log.
  if [ "$rc" -eq 0 ]; then tail -n 5 "$out/$name.log"; else cat "$out/$name.log"; status=1; fi
done

echo
echo "total wall: $(( $(date +%s) - started )) s   logs: $out"
exit "$status"
