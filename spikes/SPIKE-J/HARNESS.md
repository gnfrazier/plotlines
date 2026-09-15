# SPIKE-J harness — pre-registered bands

**Issue:** [#266](https://github.com/gnfrazier/plotlines/issues/266) · **Epic:**
[#268](https://github.com/gnfrazier/plotlines/issues/268) · written before the
first measurement, house style per SPIKE-I/SPIKE-21.

## 0. What changed the shape of this spike before it ran

Two things happened between #266 being filed and this harness being written,
and both narrow the question rather than widen it:

- **SPIKE-I (#265) closed the dependency choice.** Item 3 of #266's spike
  question treated pyosmium-vs-pyrosm as open. It is not: SPIKE-I measured
  path T (pyosmium read → osmnx's own `_create_graph`) as bit-identical to
  golden osmnx output across five cells, and pyrosm as 5.7×–128× node-inflated.
  Verdict: "do **not** adopt pyrosm." So this spike freezes **pyosmium only**.
- **Only Linux is available locally.** Windows build dependencies are
  unsatisfied on this machine and there is no macOS hardware at all. The three
  targets this can't reach locally run on GitHub-hosted `windows-latest`,
  `macos-13` (x86_64) and `macos-14` (arm64) runners instead — see `README.md`
  for why hosted runners rather than acquired hardware. *(Amended 2026-09-15,
  runner label only, no band changed: `macos-13` is retired and never
  scheduled; the x86_64 leg ran on `macos-15-intel`. `RESULTS.md` §3.)* Every band below
  applies identically to a locally-run leg and a CI-run leg.

## 1. What gets measured, and how

**Not a separate probe binary's own tree** — a **same-day, same-runner,
same-flags pair**: `packaging/build_sidecar.sh pyinstaller-onedir` (untouched,
real production script) built fresh, and `spikes/SPIKE-J/build_probe.sh`
(a fork of it — see that script's own header for why not a flag on the real
one) built immediately after on the same runner. The probe's entry point
imports `plotlines_service.__main__` unused, specifically so its import graph
is a **superset** of the real sidecar's rather than a leaner comparison that
would understate osmium's cost (see `probe_entry.py`'s comment — an earlier
draft of this harness measured the leaner tree and got a negative delta,
which is what caught the bug).

The controlled-pair design exists because diffing against SPIKE-00's
2026-08-13 numbers would confound osmium's cost with three weeks of ordinary
dependency drift (osmnx 2.1.1, rasterio 1.5.1, pyproj 3.8.0 today vs.
SPIKE-00's pinned versions) — the delta reported here is always
`probe_bytes − baseline_bytes` on the **same build, same day, same runner**.

**Read + build**: the frozen probe is invoked against a tiny, fully synthetic
`.osm.pbf` (`fixture.py` — never a real Geofabrik download, same convention as
`service/tests/mirror_clip_fixtures.py`). This is *not* a parity fixture —
SPIKE-I already measured parity against real extracts. It exists only to
prove the frozen binary can drive pyosmium's real two-pass file-reading C
extension end to end and hand real output to osmnx's graph pipeline, on each
target.

## 2. Bands

| | band | rationale |
|---|---|---|
| **F1** build | PyInstaller onedir completes on every target, exit 0 | the literal "does it freeze" question |
| **F2** launch | frozen binary starts and exits 0 with no native-loader error | distinguishes "the C extension linked" from "the C extension loaded" — SPIKE-00 §6 found geospatial deps break at import time via dynamic imports, not build time |
| **F3** read + build | `{"ok": true, "nodes": ≥2, "edges": ≥1}` on stdout | a truncated or empty read must not look like a pass |
| **F4** size delta | reported per target; **PARITY if ≤20 MB uncompressed / ≤5 MB compressed, RESCOPE outer bound is A5's 150–300 MB per-platform budget being exceeded on the *whole app*, not this delta alone** | osmium's compiled extension is small (pyosmium wheels run a few MB on PyPI); 20 MB uncompressed is a generous multiple of that to allow for statically-linked expat/zlib, and the number that actually matters for A5 is the frozen sidecar's *total*, which SPIKE-00 measured at 68.9 MB (Linux, compressed) / 51.7 MB (Windows) against a 150–300 MB budget — headroom this delta would have to be large to threaten |
| **F5** no-GPL-binary | `check_no_gpl.py` exits 0 on every target | addendum 2a / L1, non-negotiable, mechanical not remembered |

**F1–F3 and F5 are veto bands** — any target failing one is a **RESCOPE**
finding for that target regardless of what the others say, per §8's own
language ("a negative on Windows or macOS arm is the kind of result that
sends §8 back to the drawing board"). F4 alone does not veto; it restates A5.

## 3. What this harness does not measure

- **Cold-start time.** SPIKE-00 already measured the sidecar's cold-start
  budget and found it dominated by importing the geospatial stack and loading
  the graph, not by binary size. Adding one small compiled extension is not
  expected to move that number meaningfully, and this spike doesn't re-run
  SPIKE-00's lifecycle harness to confirm it — a stated limitation, not an
  oversight.
- **Real-extract read performance.** SPIKE-I already measured clip and read
  cost against real Geofabrik extracts server-side; this harness's fixture is
  bytes small enough to be irrelevant to timing.
- **Windows/macOS build-dependency remediation.** This spike routes around the
  local Windows toolchain gap via CI rather than fixing it, per the
  conversation that scoped this run — fixing the local toolchain is not this
  spike's problem to solve.
