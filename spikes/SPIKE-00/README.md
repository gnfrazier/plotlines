# SPIKE-00 — Frozen sidecar packaging

Time-boxed spike answering `docs/Plotlines_Research_Spikes.md` SPIKE-00: can
`plotlines-core` plus its native dependency tree (GDAL, GEOS, PROJ, rasterio, numpy,
shapely) be frozen into a standalone binary that the Flutter app spawns as a child
process, serves FastAPI on loopback, and shuts down cleanly — at acceptable size and
cold-start time?

**Results and the Q4/Q5 calls: [`results/RESULTS.md`](results/RESULTS.md)** (Linux x86_64).
**Second platform: [`results/WINDOWS.md`](results/WINDOWS.md)** — Windows 11 x86_64, which
closes the spike's two-platform bar and is where the process-lifecycle contract needed
changing.

## Layout

| Path | What it is |
|---|---|
| `build_fixture.py` | One-time, online. Downloads a real OSM bike graph and writes a synthetic DEM. |
| `fixtures/` | The downloaded graph + DEM. Committed — the spike must be reproducible offline. |
| `cache/` | What the sidecar is pointed at via `--cache-dir`. Copied from `fixtures/`. |
| `harness/lifecycle.py` | Stdlib-only driver for the full ARCH §7.3 spawn protocol. Runs on POSIX and Windows. |
| `harness/run_matrix.ps1` | Windows measurement pass — every build, plus the separate first-launch measurement. |
| `results/` | Measurements and the written-up findings. |

The build script itself is **not** here — it is `packaging/build_sidecar.sh`, because it
is real packaging infrastructure that outlives the spike.

## Reproducing

```bash
uv venv .venv && VIRTUAL_ENV=.venv uv pip install -e ./service pyinstaller nuitka patchelf
python spikes/SPIKE-00/build_fixture.py          # once, needs network
mkdir -p spikes/SPIKE-00/cache && cp spikes/SPIKE-00/fixtures/* spikes/SPIKE-00/cache/

./packaging/build_sidecar.sh pyinstaller-onedir
python3 spikes/SPIKE-00/harness/lifecycle.py \
  --cache-dir spikes/SPIKE-00/cache --label onedir --runs 3 \
  -- packaging/dist/pyinstaller-onedir/plotlines-sidecar/plotlines-sidecar
```

### On Windows

Same script, run from Git Bash (which is what `shell: bash` gives you on a
`windows-latest` runner); the venv lives in `.venv/Scripts` and the harness is invoked
with the native interpreter:

```powershell
uv venv --python 3.12 .venv
$env:VIRTUAL_ENV = "$PWD\.venv"; uv pip install -e ./core -e ./service pyinstaller nuitka
mkdir spikes\SPIKE-00\cache; copy spikes\SPIKE-00\fixtures\* spikes\SPIKE-00\cache\

bash ./packaging/build_sidecar.sh pyinstaller-onedir
.\spikes\SPIKE-00\harness\run_matrix.ps1        # every build + first-launch pass
```

`patchelf` is Linux-only — leave it out of the Windows install list.

The harness exits non-zero if the sidecar fails to become ready, returns a degenerate
route, needs a hard kill, or leaves orphan processes — so it works as a CI smoke test
unchanged, on either platform.

## Scope

This spike answers a *packaging* question. The routing code it freezes is deliberately
thin — a real weighted solve over a real graph, enough to put GEOS, GDAL, and numpy on
the request hot path, because a freezer that drops GDAL's data files passes a naive
import test and fails a real one. It is **not** the routing implementation. Route
quality, loop shapes, via-node constraints (SPIKE-01), and conflict relaxation
(SPIKE-02) are all out of scope here.
