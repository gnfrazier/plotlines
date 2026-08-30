# packaging

Frozen-binary build, installers, and signing for the desktop distribution (ARCH §12).

## version.lock

`version.lock` holds the one version string both build artifacts — the frozen Python
sidecar and the Flutter client — stamp themselves with at build time. The client checks
the sidecar's reported version (via `/health`) against its own at runtime and refuses a
mismatch (ARCH §12.1). This is the concrete implementation of risk A8's mitigation: the
two artifacts version-lock instead of quietly diverging.

**Sidecar half: done and verified on Linux and Windows** (SPIKE-00). `build_sidecar.sh`
bundles `version.lock` into the binary, and the sidecar reports it via both `/health` and
`--version`. Verified on both platforms by changing the repo's `version.lock` to a
sentinel and confirming all three built binaries still reported their build-time value —
they read the bundled copy, not the source tree. `--version` works without `--cache-dir`
so the client can run the A8 check *before* spawning anything.

**Client half: built.** `SidecarManager` (`client/lib/data/sidecar_manager.dart`)
runs the client's own `--version` check against the spawned binary and refuses a mismatch
before anything else is committed. The OS-process concern lives behind `SidecarProcess`
(`client/lib/data/sidecar_process.dart`): POSIX is `dart:io` `SIGTERM → SIGKILL`; Windows
spawns via Win32 `CreateProcess` with `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`, holds
the child in a `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` Job Object, and stops it with
`AttachConsole` + `CTRL_BREAK_EVENT` — the §7.3 dance SPIKE-00 found cannot be improvised,
now with the `taskkill` stand-in gone. Still unverified end-to-end from the client on real
Windows hardware — see `TODO.md`.

## Building the sidecar

```bash
./packaging/build_sidecar.sh pyinstaller-onedir   # the shipping configuration
./packaging/build_sidecar.sh pyinstaller-onefile  # smaller file, much slower start
./packaging/build_sidecar.sh nuitka               # measured for Q4; not the choice
```

One script covers Linux, macOS, and Windows. On Windows run it from Git Bash — the same
thing `shell: bash` gives you on a `windows-latest` CI runner — and it switches to
`.venv/Scripts`, `.exe`, and PyInstaller's `;` data separator on its own. It stays a
single script deliberately: every flag in it is a build failure SPIKE-00 hit and fixed,
and a second copy of that list is how one platform quietly stops getting a fix.

The flag sets in that script are not boilerplate — each one is a build failure SPIKE-00
hit and fixed (dynamic Cython imports, missing `.dist-info`, out-of-band GDAL/PROJ data).
The geospatial stack breaks freezers through dynamic imports and data files rather than
ordinary imports, so treat any new dependency as guilty until
`spikes/SPIKE-00/harness/lifecycle.py` passes against a fresh build.

## Decisions

Q4 (freezer) and Q5 (bundle vs. download) were **resolved by SPIKE-00** — see `TODO.md`
for the calls and their revisit triggers, and `spikes/SPIKE-00/results/RESULTS.md` for the
measurements behind them.

## Elevation API key (OpenTopography) — FR87

Elevation is GEDTM30 via OpenTopography, the **single** source with no fallback (FR85,
ARCH D20). The key that reaches it is a **licensing** decision as much as a config one,
so the terms are enforced in code — `core/plotlines_core/elevation/keys.py`, refusals not
warnings — rather than written down here and hoped for.

| Tier | Daily ceiling | Commercial distribution |
|---|---|---|
| `free-non-academic` (default) | **50 calls / 24 h** | **No** |
| `enterprise` (paid) | set by the key's own contract | Yes |

**The rule behind that table**, not just the table (punch-list §0): a tier is admissible
only when *both* of its terms are stated — the daily ceiling and whether it permits
integration into software that is sold. A tier added with only one stated defaults the
other to the permissive reading, and the breach is then silent. A key issued under some
other arrangement supplies its own `TierTerms` rather than being filed under the
nearest-looking tier.

### The clause that cannot be un-broken

> A paid Enterprise key is required once elevation is integrated into **commercial
> software**. Plotlines' core app remaining free is what keeps Phase-1 usage within the
> free tier legally. — FR87, ARCH A13

Exceeding the rate limit gets a request refused; shipping GEDTM30 inside paid software on
a free key is a licence breach no later retry fixes. So `OpenTopographyClient` refuses to
be **constructed** at all when the posture is `COMMERCIAL` and the key is not Enterprise —
a commercial build cannot hold a client it could spend from. **Anything that puts
elevation behind a payment** — sold builds, a paid tier that unlocks it, a hosted plan
whose price includes it — flips that posture, and re-licensing elevation is a prerequisite
of the release, not a follow-up to it.

### Configuring it

```bash
export PLOTLINES_OPENTOPOGRAPHY_API_KEY=...          # required; acquisition is off without it
export PLOTLINES_OPENTOPOGRAPHY_KEY_TIER=enterprise  # optional; defaults to free-non-academic
```

An unset key is not an error state — the local DEM cache and the shipped region tarball
(FR90) are unaffected, and an unresolvable bbox degrades to flat elevation rather than
blocking planning (FR88). An **unrecognised** tier *is* an error: defaulting it to the
free tier would silently claim non-commercial use.

The 50-call ceiling is survivable because `LocalCacheSource` sits ahead of the provider in
every phase (ARCH P7) — it is 50 *new bboxes* per 24 h, not 50 route solves. The rolling
window is persisted to `<cache-dir>/opentopography_calls.json` so it survives a sidecar
restart; deleting that file re-earns the ceiling and is a licensing act, not a cache
clear. Attribution (CC BY, FR86) is a separate obligation the key does not discharge.

## Elevation region asset — the shipped home-region raster (FR90)

The **home region** (Buncombe County, NC — the same constant extent the basemap ships
under, FR96 / ARCH D41) has its elevation raster **shipped**, not fetched. It is
distributed out of band as a **versioned tarball asset** and installed once by the setup
step below. This is distinct from a trip bbox, whose DEM is fetched on demand from
OpenTopography and is gated on FR87 (issue #148) — the home-region raster needs no API
key and touches no network.

`core/plotlines_core/elevation/region_asset.py` owns the asset's identity (region, bbox,
version, provider, CC BY licence — FR86), the build step, and the extract/verify checks.

### Building the asset (release step)

With a GeoTIFF DEM clipped to `HOME_REGION_BBOX` (GEDTM30 via OpenTopography, FR85):

```bash
./packaging/build_elevation_asset.sh path/to/gedtm30_buncombe.tif
# → packaging/dist/elevation/plotlines-elevation-buncombe-nc-v1.tar.gz
```

The tarball is **flat** — the raster (named as the `LocalCacheSource` cache stem) plus a
`*.manifest.json` carrying provider, licence, and version — so the install step needs no
`--strip-components`. Bump `ELEVATION_ASSET_VERSION` in `region_asset.py` whenever the
raster's contents change; the version is in the filename and the manifest, so a stale
install is detectable (`installed_asset_is_current`).

### One-time setup step (install)

Extract the tarball into the sidecar's **elevation cache directory** (the `--cache-dir`
the client passes, i.e. the OS app-support dir). `LocalCacheSource` then resolves the
home-region DEM as an ordinary local-cache hit — no code path changes.

**macOS / Linux:**

```bash
tar -C "<elevation-cache-dir>" -xf plotlines-elevation-buncombe-nc-v1.tar.gz
```

**Windows** (`tar` / bsdtar ships with Windows 10 1803+ — run from `cmd`, PowerShell, or
Git Bash):

```bat
tar -C "<elevation-cache-dir>" -xf plotlines-elevation-buncombe-nc-v1.tar.gz
```

It is the **same command** on every platform. Extract with `tar -C <dir>` — **never** a
PowerShell `>` redirection (`... > file.tif`) or `Invoke-WebRequest -OutFile` piped
through one: PowerShell's `>` reencodes the stream and corrupts the binary raster. The
programmatic equivalent, used by tests and any installer that wants to do this in-process,
is `plotlines_core.elevation.region_asset.extract_region_asset(tarball, cache_dir)`.
