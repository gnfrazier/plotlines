# SPIKE-16 — Byte-accurate FIT export

**Issue:** [#163](https://github.com/gnfrazier/plotlines/issues/163) ·
**Covers:** PRD **FR44 / FR45** · story **F3** `[MVP]` · ARCH §6.1 / §7.2 / §13.3 · risk **A5** · punch-list §6A.2 ·
**Run before:** F3 (#69) ·
**Result:** [`results/RESULTS.md`](results/RESULTS.md)

```bash
# offline self-check — CI-safe, no product code. 25 checks:
# CRC vs 10 real Garmin files, encoder structure, decode round-trip,
# course_point type coverage, FR45 notes, §6A.2 reveal-in-bytes.
core/.venv/bin/python spikes/SPIKE-16/run.py --json selfcheck.json

# write the actual .fit course + the language-neutral fixture (for the harness)
core/.venv/bin/python spikes/SPIKE-16/emit_fit.py --dump

# tests
core/.venv/bin/python -m pytest spikes/SPIKE-16/tests -q
```

## The question

Two unknowns from the issue. **First:** can a writer *outside* the Garmin FIT SDK
produce a FIT course file a real head unit accepts — FIT being a binary protocol
that devices reject rather than degrade? **Second, the P1 one:** the
spike-candidates note proposes Dart FFI against the official SDK, which forks FIT
out of `plotlines-core` away from GPX/TCX/GeoJSON and gives sidecar and hosted
different writers. Decide it on evidence.

## What ran here vs what `HARNESS.md` specifies

| | here (offline) | `HARNESS.md` (needs hardware) |
|---|---|---|
| pure-Python FIT course writer exists | ✅ `fitenc.py` + `profile.py`, ~90 LOC, 0 deps | — |
| CRC + framing correct vs **real Garmin files** | ✅ 10/10 (`spikes/fit_files/`) | official `FitCSVTool` pre-flight |
| generated course round-trips to the byte | ✅ `fitdec.py` | — |
| 5 `course_point` types present, right enums | ✅ | **what each device draws for each** |
| revealed notes survive as native point names | ✅ | device display + truncation floor |
| §6A.2 — unrevealed note absent from bytes | ✅ | belt-and-braces field check |
| Dart-FFI arm — build cost, fidelity | — | ✅ Arm B |
| loads + navigates on 2 vendors | — | ✅ the issue's "done when" |

## Files

| file | what it is |
|---|---|
| `crc.py` | FIT CRC-16 (CRC-16/ARC). Validated against every reference file's stored CRCs. |
| `profile.py` | The 7-message course sub-profile — message/field/enum numbers, unit conversions, with `basis`. |
| `fitenc.py` | The candidate: zero-dependency Python FIT encoder. |
| `fitdec.py` | Minimal FIT reader — verifies own output, reads the real device corpus. |
| `fixture.py` | One real routed segment (French Broad Greenway, in SPIKE-A's `avl`), 5 course-point types + an unrevealed canary + an FR108 area + an FR107 offset. |
| `course.py` | fixture → FIT bytes, **reveal applied before the first byte**. |
| `run.py` | 25-check offline self-check → `results/selfcheck.json`. |
| `emit_fit.py` | Writes `results/spike16_course.fit` + `results/fixture.json`. |
| `HARNESS.md` | The device run — both arms, Garmin + Wahoo, the FR45 per-type table, a pre-registered decision rule. |
| `licence_notes.md` | FIT SDK redistribution terms — directional; the asymmetry between the two arms. |
| `results/RESULTS.md` | The verdict and the doc edits it owes. |
| `tests/` | 24 pytest — CRC, encoder, decoder-vs-corpus, reveal/fidelity. |

## No product code changed

Same discipline as SPIKE-A/B/C/D/G/H. `core/plotlines_core/export/` still holds
only its docstring. The writer here is the reference F3 ports in — the spike
decides *which* writer and *where it runs*, not the shipping implementation.
