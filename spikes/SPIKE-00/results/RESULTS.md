# SPIKE-00 results — Frozen sidecar packaging

**Run:** 2026-08-13 · **Verdict: the sidecar model holds (ARCH D1 confirmed).** A frozen
binary containing `plotlines-core` + `plotlines-service` and the full native geospatial
stack spawns as a child process, serves FastAPI on loopback, generates a real route, and
terminates cleanly on SIGTERM — at sizes and startup times comfortably inside what
ARCH §4 budgeted. No blocking failure was found. Desktop MVP can proceed on the
architecture as written.

**One gap, stated up front:** this ran on **one** desktop platform (Linux x86_64 /
WSL2), not the two the spike's "done when" bar requires. See [Outstanding](#outstanding).

**Decisions produced:** Q4 → **PyInstaller `--onedir`**. Q5 → **bundle in the
installer**. Both recorded with revisit triggers in [`packaging/TODO.md`](../../../packaging/TODO.md).

---

## 1. Environment

| | |
|---|---|
| Platform | Linux 6.18 x86_64 (WSL2, Ubuntu 24.04), 16 cores, 15 GB RAM |
| Python | 3.12.12 (uv-managed, `python-build-standalone`) |
| Key deps | osmnx 2.1.1, rasterio 1.5.1, shapely 2.1.2, pyproj 3.7.2, geopandas 1.1.4, pandas 3.0.5, numpy 2.5.2, fastapi 0.141.1, uvicorn 0.52.3 |
| Freezers | PyInstaller 6.22.0 · Nuitka 4.1.3 (gcc 13.3) |
| Workload | Real OSM bike graph, downtown Boulder CO — **5,052 nodes / 12,872 edges** (6.2 MB GraphML) + a 512×512 GeoTIFF DEM |

The request used throughout: start → 1 via-node → end, under the `quiet_scenic` weight
profile, exercising networkx (solve), shapely/GEOS (geometry), rasterio/GDAL (elevation)
and numpy (node snapping) on every call.

**Every build returned the identical route — 4,985.0 m, 85 nodes, matching the unfrozen
source run exactly.** That equivalence is the correctness result that matters most: the
freezers are not silently changing behaviour.

---

## 2. Headline numbers

All builds strip `pyogrio` (see §5). Cold start is wall-clock from `Popen()` to
`/health` reporting `ready: true`, **median of 5 runs on an idle machine**, and includes
process spawn, interpreter boot, importing the whole geospatial stack, loading the
6.2 MB graph, and opening the DEM.

| Build | Ships as | On disk | Compressed¹ | Cold start → ready | Build time |
|---|---|---|---|---|---|
| Source (unfrozen) | — | 392 MB² | — | **0.93 s** | — |
| **PyInstaller onedir** ⭐ | tree | 267 MB | **68.9 MB** | **1.25 s** | **16 s** |
| PyInstaller onefile | 1 file | **93.0 MB** | 91.7 MB | 2.15 s | 57 s |
| Nuitka standalone | tree | 365 MB | 81.1 MB | **1.08 s** | 755 s |

¹ `tar \| xz -9` — a proxy for what an installer actually carries.
² site-packages only, excluding the interpreter.
⭐ the shipping configuration.

**Route generation is not the cost.** Once ready, a full loopback round-trip for a
via-node route is **21–27 ms** (~20 ms of it the solve itself) in every build, frozen or
not. Cold start dominates by ~50×, which is precisely why §7.3 specifies a *readiness*
check rather than a liveness check.

**Freezing costs ~0.3 s of startup.** Source 0.93 s → best frozen 1.08 s. The overhead
of being frozen is small; the overhead of *onefile* is not (see §4).

---

## 3. Lifecycle conformance (ARCH §7.3)

`harness/lifecycle.py` is stdlib-only on purpose — it stands in for the Flutter client,
which has no Python, so the binary must be drivable by something that knows nothing
about Python packaging.

| §7.3 requirement | Result (all builds) |
|---|---|
| Find free port, spawn with `--port/--mode/--cache-dir` | ✅ |
| Poll `/health` until ready | ✅ |
| Health is **readiness, not liveness** | ✅ reports `loading` → `ready`; never claims ready mid-load |
| Real route over loopback | ✅ 4,985 m / 85 nodes, identical to source |
| SIGTERM → graceful exit | ✅ exit 0 in ~0.39 s; **SIGKILL never needed** |
| No orphaned process group | ✅ clean across all 20 runs |

### Named failure modes — all fail *honestly*

A silent hang is what the architecture explicitly forbids. None of these hang:

| Failure | Behaviour |
|---|---|
| **Missing/empty cache dir** | `/health` → `{"status":"failed","detail":"FileNotFoundError: no cached graph at …"}`; `/segments/generate` → **503** with the reason. Reports the problem instead of hanging or crashing. |
| **Port already in use** | Exits **rc=3** immediately with `[errno 98] address already in use` — detectable by the parent, retryable on a new port. |
| **Non-loopback bind in sidecar mode** | Refused, rc=2. The §7.1 trust boundary is enforced by the binary, not by convention. |

### Version-lock (ARCH §12.1 / risk A8) — verified, and it caught a real bug

`packaging/version.lock` is baked in at build time; `/health` and `--version` both
surface it. `--version` deliberately works without `--cache-dir`, so the client can run
the A8 check *before* spawning anything.

**Proof it's genuinely bundled:** with the repo's `version.lock` temporarily set to
`9.9.9-not-bundled`, the built binaries still reported `0.0.1` — they read their bundled
copy, not the source tree.

**The bug this caught:** the first Nuitka build reported `version: unknown`. The lookup
was gated on `sys.frozen`, which PyInstaller sets and **Nuitka does not** (it sets
`__compiled__`). A sidecar reporting `unknown` would make the client's mismatch check
compare against nothing — an A8 failure that fails *silently*, which is the worst kind.
`service/plotlines_service/version.py` now probes every candidate location
unconditionally rather than branching on a freezer-specific flag. Re-verified: Nuitka
now reports `0.0.1`.

---

## 4. Q4 — PyInstaller vs. Nuitka

Both freezers produced a working sidecar returning an identical route, so the choice
came down to everything around that.

| | PyInstaller onedir | Nuitka standalone |
|---|---|---|
| Cold start | 1.25 s | **1.08 s** (−0.17 s, 14%) |
| Size on disk | **267 MB** | 365 MB (+98 MB) |
| Compressed (what ships) | **68.9 MB** | 81.1 MB (+18%) |
| Build time | **16 s** | 755 s (**47× slower**) |
| Toolchain | pip-installable | C toolchain + `patchelf` |
| Version-lock | worked first try | needed the `sys.frozen` fix (§3) |

**→ PyInstaller.** Nuitka is genuinely a little faster to start, but 0.17 s does not buy
a 47× slower build, +98 MB, and a heavier toolchain. The reason Nuitka's usual advantage
barely shows up here: startup is dominated by importing the geospatial stack and loading
the graph — I/O and native-library work that compiling Python bytecode to C does not
speed up.

### `--onedir`, not `--onefile` — the less obvious half

Onefile re-extracts its entire payload to a temp directory on **every single launch**:

- **2.15 s vs 1.25 s** to ready — a 72% penalty paid on every app start.
- And it is **not** smaller where it counts: compressed for shipping, onedir is
  **68.9 MB vs onefile's 91.7 MB**. Onefile's 93 MB single file is already compressed
  internally, so it barely shrinks further, while the onedir tree compresses well.

Onefile is smaller only as a bare file on disk — a number that matters to nobody, since
installers ship compressed. Onedir is faster *and* smaller in the form users download.

---

## 5. Where the size goes — and the 87 MB that shouldn't be there

Unstripped PyInstaller onedir (`_internal`, 340 MB):

| Component | Size |
|---|---|
| `pyogrio.libs` | **80 MB** |
| `rasterio.libs` | **67 MB** |
| `rasterio` | 48 MB |
| `libpython3.12.so` | 31 MB |
| `numpy.libs` | 28 MB |
| `pyproj` + `pyproj.libs` | 32 MB |
| `pandas` | 18 MB |
| `numpy` | 14 MB |
| everything else | ~22 MB |

**`pyogrio` and `rasterio` each vendor a complete, separate GDAL build** — ~147 MB of
GDAL in one binary, roughly half of it duplication. `pyogrio` arrives transitively
(osmnx → geopandas), and nothing on the sidecar's path uses it: the sidecar reads
GraphML and GeoTIFF, not shapefiles or GeoPackage.

Excluding it: **354 → 267 MB (−87 MB, −25%)**, route unchanged, lifecycle suite green.
Now the default in `packaging/build_sidecar.sh`.

> **Tripwire.** This exclusion fails at *runtime*, not build time. Precisely two calls
> break: **`geopandas.read_file()` and `GeoDataFrame.to_file()`** — the OGR driver
> paths. Anything reading a shapefile, GeoPackage, or other OGR vector format needs
> pyogrio back. The warning is attached to the exclusion in the build script.

**GeoJSON export/import (FR43, FR68, FR70/71) does *not* need pyogrio** — verified by
building a probe binary with the same exclusions and running it:

| Path | In the frozen binary |
|---|---|
| RFC-7946 write + read via `shapely.geometry.mapping`/`shape` + `json` | ✅ round-trips geometry exactly |
| Heterogeneous feature properties (FR68's routes/waypoints/hazards) | ✅ |
| `GeoDataFrame.to_json()` (pure-Python geopandas) | ✅ |
| `GeoDataFrame.to_file(driver="GeoJSON")` / `read_file()` | ❌ ImportError |
| GPX/TCX XML via stdlib `ElementTree`; `.zip` via `zipfile` | ✅ |

`geopandas` and `shapely` both ship (geopandas is pure Python so it lives in the PYZ,
not as a directory in `_internal`); `pyogrio` and `fiona` are genuinely absent —
0 occurrences in the binary. So `export/` must write GeoJSON as JSON rather than via
`to_file`. That is the better implementation anyway: FR43/FR68 require *custom feature
properties per node type*, and OGR's driver forces one flat schema across all features,
which fights the heterogeneous layer set (routes, alternates, waypoints, rest stops,
transitions, hazards) those requirements name.

A second win was taken by writing code rather than flags: osmnx's `nearest_nodes`
requires **scikit-learn** on an unprojected graph, which would pull scikit-learn *and*
scipy in for one k-NN query. `core/plotlines_core/graph/loader.py` uses a vectorised
haversine over the node array instead — exact, fast enough at MVP graph sizes, and free
in binary size.

---

## 6. Build failures hit, and their fixes

Every one of these passed a naive `import` smoke test and failed on a real request.
This is the concrete value the spike bought; each is now encoded in
`packaging/build_sidecar.sh`.

| # | Failure | Cause | Fix |
|---|---|---|---|
| 1 | `ModuleNotFoundError: rasterio.serde` | rasterio's Cython layer imports submodules dynamically; static analysis can't see them | `--collect-submodules rasterio,pyproj` |
| 2 | `PackageNotFoundError: no metadata for osmnx` | osmnx calls `importlib.metadata.version("osmnx")` at import; `.dist-info` isn't bundled by default | `--copy-metadata osmnx,click,attrs,pydantic` |
| 3 | GDAL/PROJ runtime data missing | `proj.db` and GDAL's data dir are data files, not importable modules | `--collect-data rasterio,pyproj,osmnx` |
| 4 | Nuitka: `FATAL: … requires 'patchelf'` | Nuitka shells out to patchelf for standalone ELF builds | Installed the **PyPI `patchelf` wheel** into the venv — no `sudo`, no system package change |
| 5 | Sidecar reported `version: unknown` under Nuitka | lookup gated on `sys.frozen`, which Nuitka doesn't set | Probe all candidate paths unconditionally (§3) |
| 6 | `--version` refused to run without `--cache-dir` | CLI bug — but the client needs `--version` *before* choosing a cache dir | Made `--cache-dir` conditionally required |

Failures 1–3 share a shape worth remembering: **the geospatial stack breaks freezers
through dynamic imports and out-of-band data files, not through ordinary imports.** Any
new dependency should be assumed guilty until the lifecycle harness passes a fresh
build. The harness exits non-zero on failure, so it works as a CI gate unchanged.

---

## 7. What this does *not* prove

- **Only one OS.** Linux x86_64 only. macOS (signing, notarization, arm64) and Windows
  (antivirus false-positives on frozen binaries are common and sometimes severe) are
  unmeasured.
- **Nothing about mobile.** Android untested; **iOS remains risk A1** and this spike does
  not touch it. ARCH §4.1's precompute-and-download recommendation stands unchanged.
- **A small graph.** 5k nodes loads in 0.37 s. Metro-scale or multi-region graphs will
  move cold start — §7.3's "timeout generous — cold graph load is slow" exists for that
  reason. Cold start scales with **graph size**, not binary size.
- **Not the routing implementation.** The frozen core is deliberately thin. Route
  quality, loop shapes, via-node semantics (SPIKE-01), and conflict relaxation
  (SPIKE-02) are untouched.
- **Synthetic elevation.** The DEM is generated, not real. It exercises the GDAL read
  path — which is the packaging question — but the elevation *numbers* are meaningless.
- **No signing.** Unsigned binaries; signing may change startup behaviour on macOS.

---

## Outstanding

1. **Run this on a second desktop OS** — the spike's own "done when" bar, and the one
   thing keeping SPIKE-00 from fully closed. Build script and harness are portable.
   Windows matters most: it's where frozen-binary antivirus trouble lives.
2. **Re-measure at realistic graph scale** before treating ~1.2 s as the cold-start
   figure the UI's wait-state design assumes.
3. **Wire the client half of the version check.** The sidecar half is done and verified;
   the Flutter client doesn't exist yet.
4. **Put the lifecycle harness in CI** against a freshly built binary, so a dependency
   bump that breaks freezing is caught at merge rather than at release.
