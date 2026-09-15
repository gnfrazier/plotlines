# SPIKE-J — Packaging the native OSM dependency: results

**Issue:** [#266](https://github.com/gnfrazier/plotlines/issues/266) ·
**Epic:** [#268](https://github.com/gnfrazier/plotlines/issues/268) ·
**Bands:** [`../HARNESS.md`](../HARNESS.md), committed before the first measurement

---

## Verdict: **PARITY on all four targets — pyosmium ships**

| | F1 build | F2 launch | F3 read+build | F4 size delta (uncompressed) | F5 no-GPL |
|---|---|---|---|---|---|
| **linux-x86_64** (local, 2026-09-13) | pass | pass, `frozen: true` | pass — 4 nodes / 6 edges | **+4.47 MB** (1.60 %) | pass |
| **windows-x86_64** (CI `windows-latest`, 09-13 + 09-15) | pass | pass, `frozen: true` | pass — 4 / 6 | **+4.15 MB** (1.93 %) | pass |
| **macos-x86_64** (CI `macos-15-intel`, 2026-09-15) | pass | pass, `frozen: true` | pass — 4 / 6 | **+3.50 MB** (1.47 %) | pass |
| **macos-arm64** (CI `macos-14`, 09-13 + 09-15) | pass | pass, `frozen: true` | pass — 4 / 6 | **+3.42 MB** (1.52 %) | pass |

Every veto band (F1–F3, F5) passed on every target; F4 sits at a fifth of
its 20 MB PARITY ceiling on the worst platform. No RESCOPE finding anywhere.
§8 of the acquisition review does not go back to the drawing board.

## 1. Dependency choice — already decided, not re-litigated here

SPIKE-I (#265, closed 2026-09-13) measured pyosmium's path T as bit-identical
to golden osmnx output across five cells and pyrosm as 5.7×–128× node-inflated.
Its verdict: "do not adopt pyrosm." #266's item 3 treated this as open; it
closed before this spike ran. **This spike freezes pyosmium only.**

## 2. Linux — measured locally

Same-day, same-runner, same-flags pair (`packaging/build_sidecar.sh
pyinstaller-onedir` vs. `spikes/SPIKE-J/build_probe.sh`), per `HARNESS.md` §1:

| | baseline (real sidecar) | probe (+ osmium) | delta |
|---|---|---|---|
| uncompressed | 288,226,082 B (274.87 MB) | 292,915,607 B (279.35 MB) | **+4,689,525 B (+4.47 MB)** |
| compressed (`tar \| xz -9`) | 80,866,584 B (77.12 MB) | 81,901,236 B (78.11 MB) | **+1,034,652 B (+0.99 MB)** |

**F4: PARITY** — +4.47 MB uncompressed is well inside the ≤20 MB band, and
tiny against A5's 150–300 MB per-platform budget. Note this baseline
(77.1 MB compressed) is higher than SPIKE-00's 2026-08-13 figure of 68.9 MB —
three weeks of ordinary dependency drift (osmnx/rasterio/pyproj all moved),
not anything to do with osmium. This is exactly why the delta is measured as
a same-day pair rather than against the historical number.

**F1/F2/F3: pass.** The frozen probe launched and reported:

```json
{"ok": true, "ways_considered": 2, "elements_read": 7, "nodes": 4, "edges": 6,
 "read_s": 0.0126, "build_s": 0.002, "plotlines_way_tags_count": 15,
 "plotlines_node_tags_count": 1, "frozen": true}
```

`"frozen": true` confirms this ran the compiled binary, not a source
fallback. 4 nodes / 6 edges from the synthetic fixture's 5 nodes / 2 ways is
the expected shape (`largest_component` drops the fifth, disconnected-adjacent
node — the fixture's two ways share node 2, so both survive as one component;
see `fixture.py`).

**F5: pass, after fixing two false positives in the check itself** — worth
recording plainly rather than glossing over, same spirit as SPIKE-I's §1.2:

1. First run flagged `pandas==3.0.5` as GPL. It isn't — pandas's `METADATA`
   `License` field embeds several KB of the Python Software Foundation's own
   license-compatibility history, which happens to discuss the GPL at length
   in prose. A naive substring search over that field is a search over an
   essay, not a license identifier. Fixed by trusting only short
   (≤120-char, SPDX-ish) free-text fields and `Classifier: License ::`
   entries, which are curated and short by construction.
2. Second run flagged `pyinstaller==6.22.2` and
   `pyinstaller-hooks-contrib==2026.7` as GPL — correctly identified (they
   really are GPL-2.0-or-later), but wrongly in scope: neither ships inside
   the frozen artifact's site-packages tree. Only PyInstaller's compiled
   bootloader stub does, under the bootloader exception issue #267 already
   names as settled project-wide. Fixed by excluding the known build-only
   toolchain from the venv scan.
3. Third run flagged pyosmium's own package **directory** (`_internal/osmium/`,
   holding `_osmium.cpython-312-x86_64-linux-gnu.so`) as the GPL-3
   `osmium-tool` binary, because both are named `osmium`. Fixed by requiring
   a *file* match, not a directory match — the CLI tool addendum L1 means is
   a single executable, not a Python package.

None of these three would have been caught by a check that only ran once and
trusted a clean-looking pass; each was verified against what was actually on
disk before being accepted.

## 3. Windows / macOS x86 / macOS arm — via GitHub-hosted CI

Runs: [34771996128](https://github.com/gnfrazier/plotlines/actions/runs/34771996128)
(2026-09-13; windows + arm64 legs) and
[34995277914](https://github.com/gnfrazier/plotlines/actions/runs/34995277914)
(2026-09-15; all three legs). Same-day, same-runner pair on each leg, per
`HARNESS.md` §1; raw artifacts in `../raw/`.

| target | runner | baseline (real sidecar) | probe (+ osmium) | delta |
|---|---|---|---|---|
| windows-x86_64 | `windows-latest` | 220,404,529 B (210.19 MB) | 224,752,668 B (214.34 MB) | **+4,348,139 B (+4.15 MB)** |
| macos-x86_64 | `macos-15-intel` | 245,348,359 B (233.98 MB) | 249,014,081 B (237.48 MB) | **+3,665,722 B (+3.50 MB)** |
| macos-arm64 | `macos-14` | 233,136,501 B (222.34 MB) | 236,724,382 B (225.76 MB) | **+3,587,881 B (+3.42 MB)** |

All three probes reported the same `{"ok": true, "nodes": 4, "edges": 6,
"plotlines_way_tags_count": 15, "plotlines_node_tags_count": 1, "frozen":
true}` shape as Linux — pyosmium's two-pass reader ran inside the compiled
binary and handed real output to osmnx's graph pipeline on each. `read_s`
ranged 0.015 s (Windows) to 0.096 s (macOS x86) on a seven-element fixture,
which says nothing about throughput (`HARNESS.md` §3) and everything about
the C extension having loaded.

**The macOS x86_64 leg cost two days for a reason worth recording.** The
matrix was first written against `macos-13`, and that job never got a
runner: it sat `queued` for exactly 24 h and was auto-cancelled, twice
(attempts 1 and 2 of run 34771996128). GitHub retired the macOS 13 hosted
image in December 2025; the label still parses, it just never schedules.
`macos-15-intel` is the one Intel image left in the pool and is the leg
that reported. `macos-14` (arm64) is itself marked deprecated in
`actions/runner-images` as of this run — it still schedules today, but a
future re-run of this matrix should expect to move it to `macos-15`.

**Reproducibility, for free.** The `macos-13` swap re-ran the Windows and
arm64 legs two days after their first pass. Both reproduced their delta
**byte-for-byte** (+4,348,139 and +3,587,881) while their baselines moved by
~17 KB (`../raw/run-34995277914-repeat-legs.json`) — i.e. the pair design
isolates osmium's footprint from whatever else drifts between builds, which
is exactly what `HARNESS.md` §1 built it to do.

**Compressed sizes were measured on Linux only** (77.12 → 78.11 MB,
+0.99 MB). The CI legs record uncompressed tree bytes; the compressed F4
band (≤5 MB) is inferred to hold on the other three from the Linux ratio
(osmium's compiled extension compresses ~4.5:1) and the smaller uncompressed
deltas — not measured directly. Noted in §5.

## 4. What this decides

1. **Phase 3's reader is pyosmium, and it ships on all four targets.**
   `service/pyproject.toml` keeps pyosmium behind the `mirror-clip` extra
   with a comment deferring to this spike; that deferral is now answered and
   #272 can move it into the sidecar's base dependencies. The production
   `build_sidecar.sh` needs the same four additions `build_probe.sh` made
   (`osmium` in `COLLECT_DATA`, `COLLECT_SUBMODULES`, `COPY_METADATA`) —
   nothing else changed between the two scripts.
2. **A5, restated with numbers.** ARCH v2 A5 reads *"Frozen binary
   (150–300 MB) stacks on heavier packages — Medium."* Measured uncompressed
   sidecar totals **with** osmium: Windows 214 MB, macOS arm 226 MB, macOS
   x86 237 MB, Linux 279 MB — all inside the 150–300 MB range, Linux near
   its top. osmium's share of that is **3.4–4.5 MB, 1.5–1.9 % per
   platform**. The pressure on A5 is the geospatial stack the sidecar
   already carries (baseline 210–275 MB), not the PBF reader; adding osmium
   does not change A5's likelihood or its band, and the mitigation ("strip
   deps") still points at rasterio/pyproj/osmnx, not here. **A5 stays
   Medium; its 150–300 MB figure is confirmed, not widened.**
3. **The no-GPL check is a build gate, not a memory.** `check_no_gpl.py`
   passed on all four targets against the real build venv and the real
   frozen tree. Phase 3 should wire the same invocation into
   `packaging/build_sidecar.sh` (or `ci.yml`'s packaging step) so addendum
   2a fails a build rather than relying on anyone remembering §2's three
   false-positive lessons.
4. **Nothing in §8 needs rescoping.** The "negative on Windows or macOS arm"
   outcome the issue was written to catch early did not occur.

## 5. What this does not prove

- **Cold-start time** with osmium added — not measured here; SPIKE-00's
  cold-start budget was dominated by geospatial-stack import and graph
  loading, and one small compiled extension is not expected to move it, but
  that expectation is not re-verified against a stopwatch in this spike.
- **Real-extract read performance** — the fixture is a handful of nodes.
  SPIKE-I already measured real-extract clip/read cost server-side; this
  spike is about freeze survival, not throughput.
- **Local Windows toolchain remediation** — routed around via CI rather than
  fixed; the local gap still exists and isn't this spike's to close.
- **Compressed delta off-Linux** — inferred from the Linux ratio, not
  measured (§3). The uncompressed deltas are small enough that this cannot
  change the verdict, but the number is not on file.
- **The dependency tree was recorded on Linux only** (§6). The CI venvs
  install from the same `pyproject.toml` pins, so the *set* is the same;
  platform-specific wheels (pyosmium bundles expat/zlib differently per
  wheel) are not separately inventoried.

## 6. Frozen dependency tree — input to the L5 / 2d notice bundle

`../raw/dependency-tree-linux-x86_64.tsv` lists every distribution in the
build venv the probe was frozen from (37 after excluding the build-only
toolchain `check_no_gpl.py` also excludes), with the licence each declares
in its own metadata. Summary:

| licence family | distributions |
|---|---|
| MIT / MIT-style | anyio, attrs, annotated-*, charset-normalizer, fastapi, h11, osmnx, pydantic, pydantic_core, pyogrio*, pyparsing, pyproj, six, typing-inspection, urllib3 |
| BSD-2 / BSD-3 | **osmium (BSD-2-Clause)**, affine, click, geopandas, idna, networkx, numpy (+0BSD/Zlib/CC0), pandas, pmtiles, rasterio, shapely, starlette, uvicorn |
| Apache-2.0 | requests, packaging (OR BSD-2) |
| MPL-2.0 | certifi |
| PSF-2.0 | typing_extensions |
| Dual Apache-2.0 / BSD-3 | python-dateutil |
| project-own | plotlines-core, plotlines-service |

\* pyogrio is in the venv but on the sidecar's `--exclude-module` list
(SPIKE-00's decision); it is not in the frozen tree.

No GPL, AGPL, or LGPL entry. The bundle 2d asks for is a build task
(#267's territory), not this spike's deliverable; this table and the TSV
are its starting inventory.
