# SPIKE-00 results — Windows (second desktop platform)

**Run:** 2026-08-14 · **Verdict: the sidecar model holds on Windows too, and SPIKE-00's
two-platform bar is met.** A frozen binary built by the same script spawns as a child
process, serves FastAPI on loopback, generates a route **identical to the Linux one in
every reported field**, and shuts down cleanly — at a smaller size than Linux and a
steady-state cold start of ~1.57 s. **SPIKE-00 can close.**

**Two things Windows changed, neither of which is a size or speed problem:**

1. **ARCH §7.3's stop step was not implementable as written.** SIGTERM does not exist on
   Windows; the natural translation is an unblockable kill that runs no handler, and the
   obvious replacement — sending `CTRL_BREAK_EVENT` — *fails outright* from a GUI
   process like the Flutter client. Both halves are now fixed and verified: the sidecar
   handles `SIGBREAK`, and §7.3 carries the exact client-side sequence. See
   [§3](#3-the-stop-contract-did-not-survive-the-port).
2. **First launch after install costs ~5–6.7 s, every launch after it ~1.55 s.** That is
   Defender scanning 207 newly written binaries once. It is the number onboarding
   should design for, and it is invisible if you only measure steady state — see
   [§4](#4-the-first-launch-antivirus-tax).

**The named Windows risk did not materialise as feared.** No false positive, no
quarantine, no SmartScreen block on the sidecar. The antivirus cost is *latency*, once,
not blocking. See [§5](#5-antivirus-and-smartscreen-the-risk-as-actually-observed).

**Q4 and Q5 both hold, on evidence that moved in both directions**: `--onefile` is much
worse here than on Linux (4.2× vs 1.7×), while Nuitka's startup advantage is 3× larger
(0.50 s vs 0.17 s) without being enough to win. See
[§6](#6-headline-numbers-and-why-q4-and-q5-still-hold).

---

## 1. Environment

| | |
|---|---|
| Platform | Windows 11 Pro 10.0.26200 (build 26200), x86_64 |
| Hardware | Intel Core i7-1270P, 12 cores / 16 threads, 31.7 GB RAM, NVMe SSD |
| Python | 3.12.12 (uv-managed) — **same build as the Linux run** |
| Defender | Real-time protection **on**, tamper protection on, engine 1.1.26070.7 |
| Freezers | PyInstaller 6.22.0 · Nuitka 4.1.3 |

Dependency versions were **identical to the Linux run** — osmnx 2.1.1, rasterio 1.5.1,
shapely 2.1.2, pyproj 3.7.2, geopandas 1.1.4, pandas 3.0.5, numpy 2.5.2, fastapi
0.141.1, uvicorn 0.52.3. Same fixtures, same request, same Python. So every difference
below is attributable to the operating system rather than to a drifting dependency set,
which is what makes the comparison worth anything.

---

## 2. Route equivalence — the result that matters most

**Every Windows build returned exactly the route the Linux builds returned:**

| | Linux x86_64 | Windows x86_64 |
|---|---|---|
| Distance | 4,985.0 m | **4,985.0 m** |
| Nodes / coordinates | 85 / 85 | **85 / 85** |
| Ascent / descent | 238.3 m / 657.4 m | **238.3 m / 657.4 m** |
| Elevation min / max | 1653.7 m / 2080.7 m | **1653.7 m / 2080.7 m** |

Identical across two operating systems, two C toolchains, and three build
configurations. GEOS, GDAL/PROJ and numpy are producing the same answers on both
platforms, so a plotline generated on one desktop is the same plotline on the other —
and desktop output can be compared against hosted output without a per-platform
tolerance. Solve time was also unchanged (~24 ms); routing is not where Windows costs
anything.

---

## 3. The stop contract did not survive the port

This is the substantive architectural finding, and it would have shipped as a latent bug.

§7.3 said: `App exit → SIGTERM → SIGKILL after grace`. **Windows cannot deliver
SIGTERM.** `Popen.terminate()` and `Popen.send_signal(SIGTERM)` both call
`TerminateProcess()` there — an unblockable kill that runs no handler at all. A client
written to the old wording would look correct, pass a naive test (the process does
disappear, and quickly), and silently sever whatever request was in flight instead of
letting it finish. The failure mode is invisible until a user loses work.

Measured against a real frozen sidecar by
[`harness/windows_stop_matrix.py`](../harness/windows_stop_matrix.py), which reports the
exit code each mechanism produces — the exit code being what separates "shut down" from
"was killed":

| Mechanism (parent has a console) | Exit code | Graceful? |
|---|---|---|
| **`CTRL_BREAK_EVENT` to the child's process group** | **0** | **yes — the only one that works** |
| `Popen.terminate()` | 1 | no — `TerminateProcess`, no handler |
| `Popen.send_signal(SIGTERM)` | 1 | no — same call underneath |
| `CTRL_C_EVENT` to the child's process group | 1, after a 15 s timeout | no — a new process group ignores Ctrl-C by design |

**The sidecar's half of the fix:** register a `SIGBREAK` handler alongside `SIGTERM`
(`service/plotlines_service/__main__.py`). uvicorn's own handlers cover SIGINT and
SIGTERM only, so without this the sidecar has no catchable stop on Windows at all.

### …and the client's half is not what the table above implies

Console control events are delivered through a console, and **a Flutter desktop app is a
GUI process with no console.** So the terminal result is not transferable, and testing
that carelessly is easy to get wrong: neither `pythonw.exe` nor `DETACHED_PROCESS`
reliably produces a console-less process — a console-subsystem binary is handed a fresh
console regardless, and the test then passes for the wrong reason. Using `FreeConsole()`,
which is unconditional:

| Mechanism (parent has **no** console — the real client) | Exit code | Graceful? |
|---|---|---|
| `CTRL_BREAK_EVENT`, sent directly | 1 | **no — the send itself fails**, `ERROR_INVALID_HANDLE` |
| **`CREATE_NO_WINDOW` + `AttachConsole` + `CTRL_BREAK_EVENT`** | **0** | **yes** |

**A client that just sends `CTRL_BREAK_EVENT` has no graceful stop at all** — the call
fails and the only remaining option is a hard kill. The working recipe, verified
end-to-end against the frozen sidecar:

1. Spawn with `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`. The sidecar then owns a
   console **with no visible window** — nothing flashes on screen (`GetConsoleWindow()`
   stays `0`), and it is addressable.
2. Hold the process in a **Job Object** with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
3. To stop: `AttachConsole(pid)` → `SetConsoleCtrlHandler(NULL, TRUE)` (the client must
   mute its own Ctrl handling, since the event reaches every process on that console,
   including itself) → `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid)` → wait →
   `FreeConsole()` and restore the handler.
4. Hard-kill after the grace period, as on POSIX.

Graceful stop then takes ~0.36 s, matching Linux's SIGTERM path. No new HTTP surface is
needed — which is the reason to prefer this over adding a `/shutdown` endpoint. The full
matrix is reproducible via
[`harness/windows_stop_matrix.py`](../harness/windows_stop_matrix.py); raw output in
[`windows-stop-matrix.txt`](windows-stop-matrix.txt).

**Orphan semantics differ too, and the §7.3 sweep is not sufficient on its own.**
Windows has no process groups to poll and never reparents, so a dead parent PID proves
nothing — the check has to snapshot the children while the sidecar is alive and re-test
those PIDs afterwards, which is what the harness now does. But that only *detects*
orphans. The mechanism that *prevents* them is a **Job Object** with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`: the OS then reaps the sidecar even if the client
crashes without running any cleanup. On Linux the process group plus the next-launch
sweep covers this; on Windows a crashed client leaves a live sidecar holding a port.
ARCH §7.3 now specifies both.

---

## 4. The first-launch antivirus tax

Cold start on Windows has **two** values, and reporting only the second would misdescribe
what a user experiences after installing:

| | First launch, ever | Every launch after |
|---|---|---|
| PyInstaller onedir | **6.75 s** | **1.55 s** |

**This is Defender, and the experiment separates it from disk I/O.** Copying the built
tree to a path Defender has never seen leaves the page cache *warm* (the files were just
written) while making them new to the scanner. First launch from such a copy:
**5.00 s**, then 1.54 s. Replicated on a second fresh copy: **5.00 s**, then 1.53 s. If
this were cold-cache disk I/O, the freshly written copy would have been fast.

Corroborated independently in Defender's own log: of 134 "Dynamic Signature Service"
lookups (event 2010) in the surrounding hour, **111 fall in the two minutes** when
PyInstaller wrote the binaries and the first launch happened. Afterwards the rate drops
to 1–2 per minute, matching the 1.55 s steady state. The scan surface is **207
`.dll`/`.pyd`/`.exe` files totalling 151 MB** inside the onedir tree.

**Consequences worth carrying forward:**

- The wait-state design in §7.3 (PRD FR48 / Story C27's themed messages) should be sized
  for the *first* run, not the median. ~7 s of "generating your first plotline" is fine
  if expected; it looks broken if the UI was tuned to 1.5 s.
- An installer that touches every shipped file (most do) may absorb some of this scan
  cost at install time instead — untested, and worth measuring once a real installer
  exists.
- Anyone benchmarking this later will get 1.5 s and conclude the 6.7 s figure was wrong.
  It is not; they are measuring an already-scanned tree.

---

## 5. Antivirus and SmartScreen — the risk as actually observed

The spike named Windows AV as its top unknown ("false positives on frozen binaries are
common and sometimes severe"). What was actually observed, on a machine with real-time
protection and tamper protection enabled:

| Check | Result |
|---|---|
| Defender threat detections for our binaries | **none** |
| Quarantine / deletion of the built exe | **none** — all builds intact and runnable |
| Build blocked or interfered with | no — PyInstaller succeeded first try |
| Mark-of-the-Web (`ZoneId=3`) on the exe | **does not block execution** — ran and returned `0.0.1` |
| Authenticode status | `NotSigned` (nothing is signed yet) |

**The precise shape of the SmartScreen risk**: SmartScreen gates *shell* launches —
double-clicking a downloaded file in Explorer — not `CreateProcess`. A sidecar spawned by
the client is therefore unaffected even unsigned and even carrying MOTW. **The exposure
is the installer, not the sidecar**, which sharpens ARCH §12.3: the thing that must be
signed to avoid alarming users is the installer, and the sidecar inherits trust by being
installed rather than downloaded.

This is one machine with one AV product, which is the main limit on the finding — see
[§9](#9-what-this-does-not-prove).

---

## 6. Headline numbers, and why Q4 and Q5 still hold

All builds strip `pyogrio`. Cold start is wall-clock from `Popen()` to `/health`
reporting `ready: true`, median of 5 runs on an idle machine. **First launch** is a
single run from a tree Defender has never scanned (§4) — measured separately because
averaging the two describes nobody's experience.

| Build | Ships as | On disk | Compressed¹ | First launch | Steady cold start | Build time |
|---|---|---|---|---|---|---|
| Source (unfrozen) | — | — | — | — | 1.567 s | — |
| **PyInstaller onedir** ⭐ | tree | 206 MB | **51.7 MB** | 5.52 s | **1.565 s** | **94 s** |
| PyInstaller onefile | 1 file | **73.6 MB** | 72.4 MB | 8.10 s | 6.614 s | 43 s |
| Nuitka standalone | tree | 273 MB | 55.8 MB | **11.48 s** | **1.063 s** | 27 m 17 s² |

¹ `tar \| xz -9`, same method as the Linux run. ² overlapped with other work on this
machine, so treat as approximate — it is ~17× PyInstaller's either way.
⭐ the shipping configuration.

**Freezing is free on Windows.** Source 1.567 s → frozen onedir 1.565 s. On Linux
freezing cost +0.32 s. What is *not* free is Windows itself: the unfrozen baseline here
is 1.57 s against Linux's 0.93 s, and in-process work is not the reason — the graph and
DEM load in 0.407 s on Windows versus 0.452 s on Linux, i.e. slightly **faster**. The
~0.6 s gap is process spawn and loading 207 DLLs, before app code runs at all.

**Route generation remains free.** A full loopback round-trip is 35 ms (≈20–24 ms of it
the solve) across every build, matching Linux. Cold start dominates by ~45×, which is
still exactly why §7.3 specifies a readiness check.

### Q4 → still PyInstaller `--onedir`, but the reasoning shifts on Windows

**Nuitka's startup advantage is three times larger here than on Linux** — 1.063 s vs
1.565 s (0.50 s, 32%) where Linux saw 0.17 s (14%). That is the one result that
genuinely argues for revisiting, and it is worth recording rather than burying: more of
Windows' startup is import machinery, which is precisely what compiling to C removes.

It still does not win, on three counts:

- **Build time 27 min vs 94 s** (~17×), needing a downloaded MinGW64 toolchain.
- **+67 MB on disk and +4.1 MB compressed** (273 vs 206 MB; 55.8 vs 51.7 MB shipped).
- **The worst first launch of any build: 11.48 s vs 5.52 s.** Nuitka is fastest on the
  launches a returning user sees and slowest on the one launch that forms a first
  impression — a bad trade for an app people open occasionally.

Q4's stated revisit trigger was "a target platform can't run PyInstaller acceptably."
Windows runs it fine, so **the decision stands**. The trigger worth adding: *if
steady-state cold start ever becomes the binding UX constraint on Windows, Nuitka buys a
real 0.5 s* — at a build-time cost that only matters to developers.

### `--onefile` is much worse here than on Linux — Q4's second half hardens

| | Linux | Windows |
|---|---|---|
| onefile vs onedir, steady cold start | 2.15 s vs 1.25 s (**1.7×**) | 6.61 s vs 1.57 s (**4.2×**) |
| onefile vs onedir, compressed | 91.7 vs 68.9 MB | 72.4 vs **51.7 MB** |

Onefile re-extracts its whole payload to `%TEMP%` on every launch, and on Windows that
costs ~5 s rather than Linux's ~0.9 s. In-process load is nearly identical between the
two builds (0.596 s vs 0.407 s), so essentially the entire gap is the bootloader
unpacking ~200 MB before Python starts. Creating that many files is expensive on Windows
and real-time AV inspects each write. Note this is *not* repeated reputation checking:
launching onefile three times produced **zero** additional Defender cloud-lookup events,
so the recurring cost is local scanning and file I/O, not cloud lookups.

Onefile is smaller only as a bare file on disk — a number nobody experiences, since
installers ship compressed and onedir compresses better. **Onedir is faster and smaller
in the form users download, on both platforms.**

### Q5 → still bundle in the installer, with more headroom

**51.7 MB compressed**, against ARCH §4's 150–300 MB per-platform budget and Q5's ~150 MB
revisit trigger. Windows compresses *better* than Linux (51.7 vs 68.9 MB), so the call to
bundle rather than download is, if anything, safer here.

---

## 7. Lifecycle conformance and failure modes

Every §7.3 requirement passes on Windows, across all four configurations (`passed: true`
in each `results/windows-*.json`), once the stop mechanism from §3 is used:

| §7.3 requirement | Result |
|---|---|
| Find free port, spawn with `--port/--mode/--cache-dir` | ✅ |
| Poll `/health` until ready | ✅ |
| Health is **readiness, not liveness** | ✅ `loading` → `ready`, never ready mid-load |
| Real route over loopback | ✅ 4,985 m / 85 nodes, identical to Linux |
| Graceful stop → clean exit | ✅ exit 0 in ~0.34–0.40 s via `CTRL_BREAK_EVENT` |
| No orphaned processes | ✅ across all runs; sidecar spawns no children |

### Named failure modes — all fail honestly on Windows

| Failure | Behaviour |
|---|---|
| **Missing/empty cache dir** | `/health` → `{"status":"failed","detail":"FileNotFoundError: no cached graph at …"}` in 1.08 s; `/segments/generate` → **503** with the reason. Never hangs. |
| **Port already in use** | Exits **rc=3** in 1.39 s with `[WinError 10048] only one usage of each socket address…` — the analogue of Linux's errno 98, equally detectable and retryable. |
| **Non-loopback bind in sidecar mode** | Refused, rc=2. The §7.1 trust boundary is enforced by the binary on both platforms. |

### Version-lock (ARCH §12.1 / risk A8) — re-verified on Windows

With the repo's `version.lock` temporarily set to `9.9.9-not-bundled`, **all three**
built binaries still reported `0.0.1` — they read their bundled copy, not the source
tree. Notably **Nuitka reports correctly on Windows too**, confirming the Linux fix
(probe every candidate path rather than branching on `sys.frozen`, which Nuitka does not
set) was the right shape and not a Linux-specific patch. `--version` works without
`--cache-dir`, so the client can run the A8 check before spawning.

*Minor, noted so the next person doesn't lose time to it:* the sidecar's stderr is
written in the console's code page, so `§` in the non-loopback refusal message arrives
as `�`. Harmless for the rc-based checks the client actually relies on, but a client
that parses stderr text should not assume UTF-8.

---

## 8. Where the size goes on Windows

Windows is **smaller than Linux**, which was not the expected direction:

| | Linux | Windows |
|---|---|---|
| onedir on disk | 267 MB | **206 MB** |
| onedir compressed (`tar \| xz -9`) | 68.9 MB | **51.7 MB** |

Top components of the Windows `_internal` tree:

| Component | Size |
|---|---|
| `rasterio.libs` | 56.8 MB |
| `rasterio` | 35.8 MB |
| `numpy.libs` | 20.1 MB |
| `pyproj` | 16.9 MB |
| `pandas` | 12.5 MB |
| `libcrypto-3-x64.dll` | 7.6 MB |
| `python312.dll` | 6.7 MB |
| `pyproj.libs` | 6.7 MB |

**The `pyogrio` exclusion held**: 0 files matching `pyogrio` or `fiona` anywhere in the
tree, and the route still generates — so the second vendored GDAL build is absent on
Windows exactly as on Linux, and the §5 tripwire in `build_sidecar.sh` applies unchanged.
`shapely`, `rasterio` and `pyproj` all ship; `geopandas` is pure Python and lives in the
PYZ rather than as a directory, matching Linux.

At **51.7 MB compressed**, Q5's "bundle in the installer" call has *more* headroom on
Windows than on Linux — well under the ~150 MB revisit trigger.

---

## 9. What this does not prove

- **One machine, one AV product.** Defender only, with a current engine, on a fast NVMe
  laptop. Third-party AV (which is where the severe frozen-binary false positives are
  usually reported) is untested, and heuristics vary by vendor and by how new the binary
  is. A fresh unsigned build from an unknown publisher is the worst case, and this build
  has no reputation at all — yet was still not flagged.
- **No installer, and no signing.** Everything measured here is a loose build tree. MSI
  or NSIS packaging, code signing, and their effect on both SmartScreen and the
  first-launch scan are unmeasured.
- **macOS is still untested.** The spike's bar was two platforms and two is met, but
  signing, notarization and arm64 remain open, and notarization in particular has no
  analogue in what was measured here.
- **Same small graph.** 5k nodes. The Linux caveat stands unchanged: cold start scales
  with graph size, not binary size, so metro-scale graphs will move these numbers.
- **Steady-state cold start assumes a scanned tree.** Any change that rewrites the
  binaries — an update, a repair install — re-incurs the §4 first-launch cost.

---

## 10. Outstanding after this run

1. **macOS**, for signing/notarization/arm64 — no longer blocking SPIKE-00, but the
   remaining desktop unknown.
2. **Client-side process control and version check** — the §7.3 halves that live in the
   Flutter client, which does not exist yet: spawn flags, the Job Object, the
   `AttachConsole` + `CTRL_BREAK_EVENT` stop sequence (§3), and the A8 version
   comparison. The stop sequence is the one that ships broken if forgotten, because the
   naive version looks correct and hard-kills instead.
3. **Installer and signing** (ARCH §12.3), including whether install-time file writes
   absorb the first-launch scan.
4. **Lifecycle harness in CI on both platforms.** It exits non-zero on failure and now
   also fails on a non-graceful stop or a leaked process, so it gates correctly as-is.
5. **Re-measure at realistic graph scale** — carried over from the Linux run, unchanged.
