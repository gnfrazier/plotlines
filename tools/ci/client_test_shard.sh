#!/usr/bin/env bash
#
# Run one file-level shard of the Flutter client suite.
#
# `flutter test --total-shards N --shard-index i` exists, but it shards by
# *test*, not by file: every shard still compiles and spins up all ~215 test
# files and then runs a quarter of what is in them. Measured on the whole
# suite, ~60 % of the CPU is that per-file compile/isolate spawn, so a
# test-level shard kept ~75-95 % of the cost and saved almost nothing. Handing
# each shard a disjoint slice of the file list is what actually divides the
# work — a file-level quarter measured ~200 s CPU against ~800 s for the whole
# suite, and shards stay real `flutter test` runs, so a failure still names
# its file.
#
# Files are sorted before slicing so the split is deterministic for a given
# tree, and modulo-assigned so consecutive files (e.g. the 25
# `current_trip_provider_*_test.dart` files) spread across shards rather than
# landing in one. Adding a test file rebalances on its own; nothing here
# carries a count (#235 C).
#
# Usage: tools/ci/client_test_shard.sh <shard-index> <shard-count> [flutter test args...]
#   e.g. tools/ci/client_test_shard.sh 0 4
# Run from anywhere; it cds into client/.

set -euo pipefail

index="${1:?shard index (0-based) required}"
count="${2:?shard count required}"
shift 2

cd "$(dirname "${BASH_SOURCE[0]}")/../../client"

mapfile -t files < <(find test -name '*_test.dart' | sort | awk -v n="$count" -v i="$index" 'NR % n == i')

if [ "${#files[@]}" -eq 0 ]; then
  echo "shard $index of $count: no files (is the count larger than the suite?)" >&2
  exit 1
fi

echo "shard $index of $count: ${#files[@]} files" >&2
exec flutter test "$@" "${files[@]}"
