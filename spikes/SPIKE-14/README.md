# SPIKE-14 — Vector mapping: `maplibre_gl` + PMTiles

Run 2026-08-15. Results: [`results/RESULTS.md`](results/RESULTS.md).

The spike asks whether a Flutter **desktop** client can draw a real routed polyline with
node markers over a vector basemap served from a local tile archive, offline, fast
enough — and which tile source we are licensed to use.

Run on **Linux** 2026-08-15 and on **Windows** the same day, closing the "two desktop
platforms" clause the first pass could not reach from WSL.

## Layout

```
probes/make_route.py      solve real routes on the shared fixtures → harness/assets/*.geojson
probes/bench.py           run the rendering matrix → results/results{,_windows}.json
probes/simplify_labels.py build a reduced label theme → harness/assets/style_labels.json
harness/                  Flutter desktop app (linux/ and windows/) that renders and measures
tools/pmtiles             go-pmtiles CLI v1.31.2 (downloaded, not committed)
tiles/                    extracted PMTiles archives (not committed — see below)
results/                  RESULTS.md, results.json, results_windows.json, region_sizes.json, shots/
```

`harness/pubspec.lock` is force-committed past Flutter's default ignore. The exact
resolved versions *are* a finding here — the stack works on a `vector_map_tiles`
pre-release and renders an unusable basemap on the last stable (ARCH A14) — so the lock
file is evidence, not build noise.

## Reproducing

The route payloads and tile archives are inputs, and both are regenerated rather than
committed — the archives alone are 160 MB.

```bash
# 1. Route geometry from the SPIKE-01/02/03 fixture graphs
../../.venv/bin/python probes/make_route.py

# 2. Tile archives, extracted from the Protomaps daily planet build
cd tools
./pmtiles extract https://build.protomaps.com/<YYYYMMDD>.pmtiles \
    ../tiles/boulder.pmtiles --bbox=-105.36,39.94,-105.17,40.08 --maxzoom=15

# 3. Explode one archive into assets/tiles/{z}/{x}/{y}.mvt — see RESULTS.md for why
#    the harness reads a directory rather than the archive it came from.

# 4. Build and measure. Profile mode is required: vector_map_tiles disables its
#    isolate concurrency in debug builds.
cd ../harness && flutter build linux --profile      # or: flutter build windows --profile
cd .. && python3 probes/bench.py
```

`bench.py` detects the platform, picks the right binary and tile-cache path, and writes
`results.json` on Linux / `results_windows.json` on Windows. **The two runs used
byte-identical inputs** — the same three route payloads and the same 171 exploded tiles,
copied across rather than regenerated, verified by hash — and the same locked dependency
set. They did **not** use the same Flutter: 3.44.5 on Linux, 3.44.7 on Windows, same Dart
SDK. Two patch releases apart, recorded in RESULTS.md §3 rather than glossed.

## Running one configuration by hand

The harness is driven entirely by environment variables, so a single binary covers the
whole matrix:

| Variable | Values | Meaning |
|---|---|---|
| `SPIKE14_PAYLOAD` | `day` \| `multi` \| `stress` | route size (1.2k / 6.9k / 41k vertices) |
| `SPIKE14_BASEMAP` | `vector` \| `none` | basemap on, or route-only to attribute cost |
| `SPIKE14_THEME` | `light` \| `dark` | which extracted Protomaps v4 style to parse |
| `SPIKE14_ZOOM` | e.g. `14` | initial zoom; the scripted camera cycles ±1.5 around it |
| `SPIKE14_SECONDS` | e.g. `10` | benchmark duration after a 5 s warm-up |
| `SPIKE14_SHOT` | path | write a PNG capture at the end of warm-up |

```bash
cd harness
SPIKE14_PAYLOAD=multi SPIKE14_ZOOM=14 SPIKE14_SECONDS=10 \
  SPIKE14_SHOT=../results/shots/example.png \
  ./build/linux/x64/profile/bundle/spike14_harness
```

Two things will invalidate a measurement if you forget them:

- **`vector_map_tiles` keeps a persistent file cache at `/tmp/.vector_map`** that
  survives across runs and across *different builds of the harness*. Delete it for a
  cold measurement. The first version of these results reported zero tile reads
  because every tile was served from a cache an earlier experiment had written.
- **Anything else using the CPU.** These numbers come off a software rasterizer with
  no GPU; a stray process from an earlier probe swung the same configuration between
  34 and 107 fps. `probes/bench.py` waits for the load average to fall before each
  cell.

## Offline verification

The offline claim is checked at the OS level, not by asking the app:

```bash
unshare -rn ./build/linux/x64/profile/bundle/spike14_harness
```

`unshare -rn` puts the process in a network namespace with nothing but a down
loopback — no route, no DNS. A map that still renders there is genuinely offline.

**On Windows this check is weaker, and the difference is not cosmetic.** Taking the
network from a single process there means a Windows Firewall rule, which requires
Administrator. `bench.py` falls back to auditing the process's sockets while it runs
(`Get-NetTCPConnection`/`Get-NetUDPEndpoint` by PID) and records what it saw in
`results_windows.json`. That observes the app made no outside connection; it does not
make one impossible, and a connection shorter than the poll interval could hide from it.
**The Linux namespace result stays the load-bearing evidence for P2's offline claim** —
the Windows audit corroborates it on a second platform rather than replacing it.
