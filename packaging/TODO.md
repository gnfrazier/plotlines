# packaging TODO

## Resolved by SPIKE-00 (2026-08-13)

Both Q4 and Q5 were decided on measurements, not preference. Full numbers,
methodology, and caveats: [`spikes/SPIKE-00/results/RESULTS.md`](../spikes/SPIKE-00/results/RESULTS.md).

### Q4 — Freezer choice → **PyInstaller, `--onedir`**

Both freezers produced a working sidecar that generated an identical route, so this
was decided on the surrounding costs:

| | PyInstaller onedir | Nuitka standalone |
|---|---|---|
| Build time | **16 s** | 755 s (~47× slower) |
| Size on disk | **267 MB** | 365 MB |
| Compressed (what ships) | **68.9 MB** | 81.1 MB |
| Cold start → ready | 1.25 s | **1.08 s** |
| Toolchain | pip-installable | needs a C toolchain + `patchelf` |

Nuitka starts 0.17 s faster — real, but not worth a 47× slower build, +98 MB on disk,
+12 MB shipped, and a C toolchain. Nuitka's usual advantage barely shows up because
startup here is dominated by importing the geospatial stack and loading the graph:
I/O and native-library work that compiling Python to C does not speed up.

**`--onedir`, not `--onefile`**, the less obvious half of the call: onefile re-extracts
its whole payload to a temp dir on *every* launch, costing **2.15 s vs 1.25 s** to
ready — and it isn't even smaller where it counts. Compressed for shipping, onedir is
**68.9 MB against onefile's 91.7 MB**, because onefile's single file is already
internally compressed and barely shrinks further.

**Revisit if:** a target platform can't run PyInstaller acceptably (Windows antivirus
heuristics on frozen binaries are the likeliest trigger), or startup becomes
CPU-bound rather than I/O-bound.

### Q5 — Bundle vs. download → **Bundle in the installer**

The sidecar compresses to **68.9 MB** — well under ARCH §4's 150–300 MB per-platform
budget, and that is the number an installer actually carries. So
downloading separately buys little size and costs a first-run network dependency in an
offline-first product (P2), a download-failure path in onboarding, a second artifact to
host/sign/version, and a fresh way for client and sidecar to diverge — the exact A8
failure `version.lock` exists to prevent. Bundling keeps desktop as **one artifact, one
version, one install**, which is what ARCH §12.1's update flow already assumes.

**Revisit if:** a platform's compressed sidecar exceeds ~150 MB, or multimodal data
(SPIKE-04) / narration audio (SPIKE-10) push the installer to a size users notice.

## Still open

- **Second desktop OS.** SPIKE-00 ran on Linux x86_64 only. Its own "done when" bar is
  two platforms. macOS (signing, notarization, arm64) and Windows (antivirus behaviour)
  are unmeasured — this is the top packaging unknown.
- **Signing and notarization** (ARCH §12.3). Nothing here is signed yet.
- **Client-side version check.** The sidecar half is done and verified — it stamps
  itself from `version.lock` and surfaces it via `/health` and `--version`. The Flutter
  client does not exist yet, so the comparison that refuses a mismatch is unwritten.
- **CI build matrix.** `build_sidecar.sh` runs locally only.
