# SPIKE-J — Packaging the native OSM dependency

**Issue:** [#266](https://github.com/gnfrazier/plotlines/issues/266) ·
**Epic:** [#268](https://github.com/gnfrazier/plotlines/issues/268) ·
**Bands:** [`HARNESS.md`](HARNESS.md), committed before the first measurement ·
**Results:** [`results/RESULTS.md`](results/RESULTS.md)

## Why GitHub-hosted CI runners, not acquired hardware

This spike needs four targets (Linux, Windows, macOS x86, macOS arm) and the
local machine has one of them — Windows build dependencies are unsatisfied
locally, and there is no macOS hardware at all. `windows-latest`, `macos-13`
and `macos-14` GitHub-hosted runners stand in for the other three
(`.github/workflows/spike-266-freeze-matrix.yml`, `workflow_dispatch` only —
this is spike infrastructure, not a standing CI gate):

- **No setup cost.** A GitHub-hosted runner is a `runs-on:` value, not
  infrastructure to install or register — unlike a self-hosted runner, which
  would need an agent on owned hardware.
- **No billing.** This repo is public; public repos get free GitHub-hosted
  runner minutes, including macOS (normally billed at a 10× multiplier on
  private repos).
- **`packaging/build_sidecar.sh` already anticipated this.** Its own header
  comment says a `windows-latest` runner under `shell: bash` is "the same
  thing" as Git Bash locally — this spike is the first time that path is
  actually exercised.

## What's frozen here, and what isn't

**Not `packaging/sidecar_entry.py`.** `service/pyproject.toml` keeps pyosmium
as the `mirror-clip` extra, deliberately excluded from the sidecar's base
dependencies and therefore from `packaging/build_sidecar.sh`'s import graph —
its own comment says why: "SPIKE-J (#266) has not yet measured whether
pyosmium survives a PyInstaller freeze on all four client targets." Wiring
pyosmium into the real client-side transport is Phase 3 (#272) — path T
itself doesn't exist in `core/` yet. This spike builds a **separate probe**
(`probe_entry.py` + `build_probe.sh`) whose import graph is the real sidecar's
plus pyosmium, same convention SPIKE-00 used to test the pyogrio exclusion
without touching the shipped entry point.

## Files

| | |
|---|---|
| `fixture.py` | tiny synthetic `.osm.pbf` — never a real download or committed binary |
| `probe_entry.py` | the frozen entry point: reads the fixture with pyosmium, builds a graph via osmnx's own pipeline |
| `build_probe.sh` | fork of `packaging/build_sidecar.sh` — same flags, +osmium, +the matching `--add-data` |
| `check_no_gpl.py` | mechanical assert-the-absence check for addendum 2a / L1 |
| `.github/workflows/spike-266-freeze-matrix.yml` | drives the same three steps on `windows-latest` / `macos-13` / `macos-14` |
| `results/RESULTS.md` | the four-target verdict |

## Running it

```bash
# Linux, locally:
./packaging/build_sidecar.sh pyinstaller-onedir   # baseline
./spikes/SPIKE-J/build_probe.sh                   # probe (baseline + osmium)
.venv/bin/python spikes/SPIKE-J/fixture.py /tmp/fixture.osm.pbf
./spikes/SPIKE-J/dist/probe/plotlines-spike-j-probe/plotlines-spike-j-probe \
  --pbf /tmp/fixture.osm.pbf --bbox=-105.30,40.00,-105.25,40.05 --network-type bike
.venv/bin/python spikes/SPIKE-J/check_no_gpl.py --venv .venv \
  --dist spikes/SPIKE-J/dist/probe/plotlines-spike-j-probe

# Windows / macOS x86 / macOS arm:
gh workflow run spike-266-freeze-matrix.yml
gh run watch
```
