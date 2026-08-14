# packaging

Frozen-binary build, installers, and signing for the desktop distribution (ARCH §12).

## version.lock

`version.lock` holds the one version string both build artifacts — the frozen Python
sidecar and the Flutter client — stamp themselves with at build time. The client checks
the sidecar's reported version (via `/health`) against its own at runtime and refuses a
mismatch (ARCH §12.1). This is the concrete implementation of risk A8's mitigation: the
two artifacts version-lock instead of quietly diverging.

**Sidecar half: done and verified** (SPIKE-00). `build_sidecar.sh` bundles `version.lock`
into the binary, and the sidecar reports it via both `/health` and `--version`. Verified
by changing the repo's `version.lock` to a sentinel and confirming the built binaries
still reported their build-time value — they read the bundled copy, not the source tree.
`--version` works without `--cache-dir` so the client can run the A8 check *before*
spawning anything.

**Client half: not built.** The Flutter client doesn't exist yet, so nothing yet compares
the two versions or refuses a mismatch.

## Building the sidecar

```bash
./packaging/build_sidecar.sh pyinstaller-onedir   # the shipping configuration
./packaging/build_sidecar.sh pyinstaller-onefile  # smaller file, 2.4× slower start
./packaging/build_sidecar.sh nuitka               # measured for Q4; not the choice
```

The flag sets in that script are not boilerplate — each one is a build failure SPIKE-00
hit and fixed (dynamic Cython imports, missing `.dist-info`, out-of-band GDAL/PROJ data).
The geospatial stack breaks freezers through dynamic imports and data files rather than
ordinary imports, so treat any new dependency as guilty until
`spikes/SPIKE-00/harness/lifecycle.py` passes against a fresh build.

## Decisions

Q4 (freezer) and Q5 (bundle vs. download) were **resolved by SPIKE-00** — see `TODO.md`
for the calls and their revisit triggers, and `spikes/SPIKE-00/results/RESULTS.md` for the
measurements behind them.
