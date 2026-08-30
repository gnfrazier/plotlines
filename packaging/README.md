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
