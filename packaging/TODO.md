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

## Confirmed on Windows (2026-08-14)

Both calls above were re-measured on Windows 11 x86_64 and **both hold** —
[`spikes/SPIKE-00/results/WINDOWS.md`](../spikes/SPIKE-00/results/WINDOWS.md):

| | Linux | Windows |
|---|---|---|
| onedir compressed (what ships) | 68.9 MB | **51.7 MB** |
| onedir steady cold start | 1.25 s | 1.57 s |
| onedir **first** launch (AV scan) | n/a | **5.5 s** |
| onefile penalty vs onedir | 1.7× | **4.2×** |
| Nuitka advantage vs onedir | 0.17 s | 0.50 s |

Q5 gains headroom (51.7 MB is further under the ~150 MB revisit trigger). Q4's
`--onefile` half hardens — the onefile penalty is 4.2× on Windows, and onedir is again
smaller compressed. **One Q4 nuance worth recording:** Nuitka's startup advantage is 3×
larger on Windows (0.50 s vs Linux's 0.17 s), because more of Windows' startup is import
machinery. It still loses on a 17× build time, +4.1 MB shipped, and the worst first
launch of any build (11.5 s vs 5.5 s). **Added revisit trigger:** if steady-state cold
start becomes the binding UX constraint on Windows specifically, Nuitka is worth 0.5 s.

## Still open

- **macOS** — signing, notarization, arm64. Now the only untested desktop platform;
  SPIKE-00's two-platform bar is met, so this no longer blocks the spike.
- **Signing and notarization** (ARCH §12.3). Nothing here is signed yet. Windows
  sharpened the target: SmartScreen gates *shell* launches, not `CreateProcess`, so a
  spawned sidecar is unaffected even unsigned — **the installer is what needs signing**,
  and the sidecar inherits trust by being installed rather than downloaded.
- **Client-side version check.** The sidecar half is done and verified on both platforms
  (Nuitka included). The Flutter client does not exist yet, so the comparison that
  refuses a mismatch is unwritten.
- **Client-side Windows process control** — new, and the one thing that would ship broken
  if forgotten. The client must spawn `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`, hold
  the sidecar in a **Job Object** (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) so a client crash
  cannot orphan it, and stop it via `AttachConsole` + `CTRL_BREAK_EVENT`. A GUI process
  cannot send a console control event without that dance — the send fails outright. See
  ARCH §7.3 and WINDOWS.md §3.
- **First-launch antivirus cost in onboarding.** ~5–6.7 s on first run versus ~1.6 s
  after, on Windows. The §7.3 wait-state design should be sized for the first run. Worth
  re-measuring once a real installer exists, since install-time file writes may absorb
  some of the scan.
- **CI build matrix.** `build_sidecar.sh` now runs on Linux, macOS and Windows (Git Bash
  / `shell: bash`), and the lifecycle harness runs on both platforms and fails on a
  non-graceful stop or a leaked process — so it gates correctly as-is. Not yet wired up.
