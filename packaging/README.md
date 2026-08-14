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

**Client half: not built.** The Flutter client doesn't exist yet, so nothing yet compares
the two versions or refuses a mismatch. On Windows the client also owes the §7.3 process
control that SPIKE-00 found cannot be improvised — see `TODO.md`.

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
