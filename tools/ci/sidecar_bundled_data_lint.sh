#!/usr/bin/env bash
# Issue #509 — a frozen sidecar 500'd on every `/layers` call because
# `core/plotlines_core/curation/config/layer_defaults.json` was never
# bundled: `packaging/build_sidecar.sh`'s `COLLECT_DATA` array covered
# rasterio/pyproj/osmnx/osmium but not `plotlines_core` itself, and nothing
# caught it because all three test suites run against source, never a frozen
# artifact. `curation/defaults.py::resolve_default_layers` reads that file
# via `Path(__file__).parent` — the pattern this codebase uses for
# package-local config — which only resolves in the frozen build if the
# owning package is in `COLLECT_DATA` (preserves the package's own internal
# layout under `_internal/<package>/...`) or the file is named in an
# `--add-data` line (a chosen destination, read back via `sys._MEIPASS` —
# see `tiles_paths.py`/`version.py`).
#
# This is the cheap, no-toolchain half of the fix: it can't run a real
# freeze, so it can't prove the file lands in the bundle, but it can catch
# the next config file added under core/plotlines_core/ without a matching
# bundling line — a grep, same shape as the P1/reveal gates.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_script="$root/packaging/build_sidecar.sh"

mapfile -t data_files < <(find "$root/core/plotlines_core" -type f ! -name '*.py' ! -name '*.pyc')

if [[ ${#data_files[@]} -eq 0 ]]; then
  echo "OK: no non-Python data files under core/plotlines_core/"
  exit 0
fi

fail=0
for f in "${data_files[@]}"; do
  base="$(basename "$f")"
  rel="${f#"$root"/}"
  if grep -qE 'COLLECT_DATA(=|\+=)\(.*\bplotlines_core\b' "$build_script"; then
    continue
  fi
  if grep -q -- "--add-data.*$base" "$build_script"; then
    continue
  fi
  echo "::error::$rel is a non-Python data file under core/plotlines_core/ but packaging/build_sidecar.sh neither collects plotlines_core's package data (COLLECT_DATA) nor --add-data's it by name — it will be missing from the frozen sidecar (issue #509's failure mode: a Path(__file__)-relative read 500s only in the frozen build)"
  fail=1
done

[[ "$fail" -eq 0 ]] && echo "OK: every non-Python data file under core/plotlines_core/ is reachable by the frozen sidecar"
exit "$fail"
