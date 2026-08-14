# Plotlines — Research Spikes

**Purpose:** Feasibility, cost, and platform-behavior unknowns that should be de-risked with a time-boxed spike *before* the corresponding feature is committed to build. These are distinct from the Design decisions in the PRD's Open Items (which concern *what* to build); a spike answers *whether — and at what cost —* it can be built as written.

**How to read the priority:** **Scope-shaping** spikes can send you back to revise the PRD if they come back negative. **Implementation-informing** spikes won't change scope but determine how a committed feature is built. Do the scope-shaping ones first.

**Companion to:** `Plotlines_PRD.md` (89 FRs / 95 stories).

---

## Priority order (by risk of reshaping scope)

**Gates desktop MVP (do first):**
0. Frozen sidecar packaging — the desktop-MVP foundation — **ARCH §4, A1/A5, Q4/Q5**

**Scope-shaping (later milestones):**
1. ~~Multimodal / paddling data availability~~ — **complete (SPIKE-04, 2026-08-14)**
2. Backgrounded GPS-triggered audio on real devices — **FR49, FR47, FR50a**
3. Via-node loop routing — **FR8a**
4. Dart-first offline engine at feature scale — **FR63, FR64**

Everything below these is implementation-informing rather than scope-shaping.

**Note on sequencing:** SPIKE-00 was the only one that blocked the *near-term* build. SPIKE-01 (via-node) and SPIKE-04 (paddling) were the routing unknowns worth running alongside early desktop work; the rest gate later milestones (field execution, mobile, Web) and can wait for those.

**Status (2026-08-14):** **SPIKE-00 and SPIKE-04 are both complete.** SPIKE-04 came back negative on class ratings and reshaped PRD scope accordingly (B4/B5 removed — ARCH D19), which is the outcome this whole document exists to make cheap. **SPIKE-01 (via-node loops) is now the next unrun scope-shaping spike**, and the only routing unknown still open before the MVP routing build.

---

## Packaging & distribution (desktop MVP foundation)

### SPIKE-00 — Frozen sidecar packaging ✅ **COMPLETE**
**Covers:** ARCH §4 (portability), risks A1/A5, Open Questions Q4/Q5 — the foundation of desktop MVP
**Priority:** Scope-shaping — **was the only spike blocking the near-term build**
**Run:** 2026-08-13 (Linux) + 2026-08-14 (Windows) · **Result:** [`spikes/SPIKE-00/results/RESULTS.md`](../spikes/SPIKE-00/results/RESULTS.md) and [`WINDOWS.md`](../spikes/SPIKE-00/results/WINDOWS.md) — **the sidecar model holds (ARCH D1 confirmed).** Q4 → PyInstaller `--onedir`; Q5 → bundle in the installer. Identical routes on both platforms; §7.3's stop contract corrected for Windows. **Closed.**
**Unknown:** Can `plotlines-core` plus its heavy native dependency tree (GDAL, GEOS, rasterio, numpy, shapely) actually be frozen into a standalone binary that the Flutter app spawns as a child process, serves FastAPI on loopback, and shuts down cleanly — at an acceptable binary size and cold-start time? Every other spike concerns a later milestone; this one gates the thing being built first.
**Spike question:** On your primary desktop platform, freeze `service`+`core` (try PyInstaller and Nuitka — Q4) into a single binary; confirm it spawns, answers a `/health` and a real `/segments/generate` call over loopback, and terminates on signal. Measure binary size and cold-start-to-ready time. Repeat on a second desktop OS to expose cross-platform surprises. Assess bundle-in-installer vs. download-on-first-run (Q5) from the resulting size.
**Decides:** Whether the sidecar model (ARCH D1) holds for desktop as designed, and the answers to Q4 (which freezer) and Q5 (bundle vs. download). A negative result reshapes the entire desktop delivery approach before any UI is built.
**Done when:** A frozen binary generates a real route over loopback on two desktop platforms, with size and startup time quantified — or the blocking failure is documented and the delivery model revisited.

---

## Routing-algorithm feasibility

### SPIKE-01 — Via-node loop routing
**Covers:** FR8a (Story A9)
**Priority:** Scope-shaping
**Unknown:** Can the OSMnx/solver approach constrain a loop to pass through one or more mandatory via-nodes while still honoring weights and a target distance — without unacceptable compute time or degenerate routes?
**Spike question:** Generate loops through 1, 2, and 3 forced via-nodes on a real graph; measure solve time and route quality vs. an unconstrained themed loop.
**Decides:** Whether A9 is promotable to MVP. If via-node and start/destination turn out to be the same constraint primitive, A9 is nearly free and should land in MVP; if not, it stays P1.
**Done when:** A via-node loop generates in acceptable time and returns a sensible route, or the cost is quantified and the P1/MVP call is made on evidence.

### SPIKE-02 — Conflict detection & relaxation
**Covers:** FR9 (Story A6)
**Priority:** Implementation-informing
**Unknown:** Can the solver introspect an infeasible constraint set to name *which* constraints conflict and propose the nearest relaxation — rather than just returning an empty result?
**Spike question:** Construct several deliberately-infeasible weight/constraint combinations; determine whether the engine can identify the binding constraints and compute a minimal relaxation.
**Done when:** The engine names a real conflict and a valid relaxation for the test cases, or the limitation is documented so A6's AC can be adjusted.

### SPIKE-03 — Min/max weight-band convergence
**Covers:** FR6 (Story A5)
**Priority:** Implementation-informing
**Unknown:** Does compromise-finding across multiple bounded (min/max) weights converge to a good route, or do bands routinely over-constrain into infeasibility?
**Spike question:** Run realistic competing bands (e.g. high climbing-min + low traffic-max) across varied geographies; measure how often a valid route exists and whether it's good.
**Done when:** Band behavior is characterized well enough to set sensible default ranges and know how often A6's conflict path will fire.

---

## Multimodal routing data

### SPIKE-04 — Paddling network & difficulty data availability ✅ **COMPLETE**
**Covers:** FR14, FR14a, FR15 (Stories B6, B8, H11) — *originally FR13–FR15 / B4, B5, B6, H11*
**Priority:** Scope-shaping — **was the highest risk in the PRD**
**Run:** 2026-08-14 · **Result:** [`spikes/SPIKE-04/results/RESULTS.md`](../spikes/SPIKE-04/results/RESULTS.md) — **network yes, gauge yes, access partial, class no, portage no.**
The waterway network and live gauge data are solid and public-domain, but from **USGS (NHDPlus HR / Water Data APIs / NLDI), not OSM** — which resolved ARCH Q2 and makes `WaterwayDataProvider` a real implementation. **Class ratings do not exist in open data** (one graded feature across all three regions; 58 in all of North America) and American Whitewater prohibits reuse of its inventory.
**Scope decision taken (2026-08-14, PRD §8 / ARCH D19):** FR13 retired, **stories B4 and B5 removed** as unbuildable, FR14 narrowed to an advisory gauge band (new story B8, Leg 3, alongside weather), FR15/B6 portages made Author-drawn. Paddling stays a first-class mode. **Closed — reopen only if American Whitewater licensing or North American OSM adoption makes per-reach class ratings available.**
**Unknown:** Does usable data exist to route and grade paddling segments? Cycling on OSM is proven; the waterway network, put-ins/take-outs, portages, class ratings, and gauge readings are not.
**Spike question:** For 2–3 representative regions, assess whether OSM carries the paddling waterway graph and access points; identify whether class ratings and gauge heights require third-party sources (e.g. American Whitewater, USGS water-services gauge APIs) and whether those are licensable/usable.
**Decides:** Whether full multimodal MVP (cycling + hiking + paddling as equals) is grounded in real data, or whether paddling scope must be narrowed, deferred, or made dependent on a data partnership.
**Done when:** A clear yes/no per data element (network, access points, class, gauge) with a source and licensing note, feeding a go/no-go on paddling-in-MVP.

### SPIKE-05 — Mode/terrain travel-speed calibration
**Covers:** FR16, FR31 (Story B7)
**Priority:** Implementation-informing (can become scope-shaping if ETAs prove untrustworthy)
**Unknown:** Can believable moving-time/ETA figures be produced across pavement/gravel/singletrack and flatwater/moving-water, given the terrain data available?
**Spike question:** Feed real GPX from cycling, hiking, and paddling activities through a draft speed model; compare predicted vs. actual elapsed times.
**Done when:** The model predicts within a tolerance you'd trust to show a Character, or the gap is quantified so FR16's default/custom/aggregated pace options can be tuned.

---

## Platform & OS behavior (field execution)

### SPIKE-06 — Backgrounded GPS-triggered audio on real devices
**Covers:** FR49, FR47, FR50a (Stories H2, I1, I2a)
**Priority:** Scope-shaping
**Unknown:** Reading the platform docs is not proving it works. Does GPS-triggered narration + silent cue advancement actually survive screen-lock and app-backgrounding on real iOS and Android hardware, across OS versions?
**Spike question:** Build a throwaway app that fires an audio trigger at a geofenced point with the screen locked and the phone pocketed. Run on real iOS and Android devices across at least two OS versions each. Confirm it survives backgrounding, screen-lock, and the 60–130-minute continuous-background-update drop-off reported on iOS.
**Platform notes to verify in the spike:**
- iOS: "While in Use" + `location` background mode + `allowsBackgroundLocationUpdates`; `pausesLocationUpdatesAutomatically = false`; correct `activityType`. Confirm updates persist past ~2 hours.
- Android: typed foreground service (`foregroundServiceType="location"`, `FOREGROUND_SERVICE_LOCATION`) with the mandatory persistent notification; confirm starting the service while foregrounded is sufficient (no "Allow all the time" needed) for the pocketed-but-just-opened flow.
**Decides:** Whether the pocketed-companion model — the core of the field experience — is deliverable as written, or whether the interaction model needs rethinking.
**Done when:** A trigger reliably fires screen-locked and pocketed on both platforms for a multi-hour session, or the failure modes are documented and H2/I2a are revised.

### SPIKE-07 — Adaptive location-accuracy battery savings
**Covers:** FR54a (Story I6a)
**Priority:** Implementation-informing
**Unknown:** Does the low-power→high-accuracy escalation actually save meaningful battery while still firing triggers reliably at their Author-set distances?
**Spike question:** Instrument battery draw over a simulated multi-hour ride, comparing continuous high-accuracy GNSS against the adaptive tier; verify triggers still fire at 50–400 m radii.
**Done when:** A measured battery delta justifies the added complexity, and trigger reliability is confirmed under the adaptive tier.

### SPIKE-08 — Power-saving-mode survival across OEMs
**Covers:** FR67, M9 (Story M9)
**Priority:** Implementation-informing
**Unknown:** Does a typed foreground service keep delivering location under each platform's battery-saver mode on real devices — including aggressive OEM battery managers (Samsung, Xiaomi, etc.)?
**Spike question:** Run the SPIKE-06 test app under OS battery-saver on a spread of real devices from different manufacturers; confirm location keeps flowing.
**Done when:** Location delivery is confirmed under battery-saver on the target device spread, or per-OEM caveats are documented.

### SPIKE-12 — Backgrounded audio playback
**Covers:** FR49, FR50a (Stories H2, I2a) — the audio half of the pocketed-companion model
**Priority:** Scope-shaping (pairs with SPIKE-06)
**Unknown:** SPIKE-06 proves the *trigger fires* when backgrounded; it does not prove the *narration plays*. iOS and Android treat background audio as a separate session/permission concern from background location — playing sound while the screen is locked and the app is backgrounded requires an audio session explicitly configured for background playback, which may interact with other audio (music, turn-by-turn from another app) and with silent-mode/ringer settings.
**Spike question:** Extend the SPIKE-06 test app to *play an audio clip* on the geofence trigger, screen-locked and pocketed. Verify on iOS (background audio mode, `AVAudioSession` category/mixing behavior, silent-switch interaction) and Android (audio focus, playback from a backgrounded foreground-service context). Confirm it plays over or ducks other audio sensibly and isn't silenced by the ringer switch.
**Decides:** Whether narration actually reaches the Character's ears in the pocketed model, or whether the audio-session model needs rethinking (e.g. requiring headphones, or a haptic-plus-audio cue).
**Done when:** A triggered clip reliably plays screen-locked and pocketed on both platforms, with sensible mixing and mode behavior — or the constraints are documented and H2/I2a revised.

---

## Offline engine

### SPIKE-09 — Dart-first offline routing at feature scale
**Covers:** FR63 (Story I7)
**Priority:** Scope-shaping
**Unknown:** The rebrand-plan calls Dart-first offline routing a *direction from a spike*, not a proven feature. Does the offline engine route acceptably within a downloaded map set on a phone's compute and memory budget?
**Spike question:** Route realistic point-to-point requests within a downloaded region on mid-range and low-end phones; measure solve time, memory, and route quality.
**Decides:** Whether Leg 5 can be built on the Dart-first engine as planned, or whether the offline routing approach needs to change.
**Done when:** Offline point-to-point routing performs acceptably on target-tier hardware, or the limits are quantified against Leg 5's scope.

### SPIKE-10 — Adventure-package size
**Covers:** FR64, FR35 (Story H7, C14)
**Priority:** Implementation-informing (scope-shaping if sizes are extreme)
**Unknown:** How large is a realistic offline package — routes + basemap buffer + narration audio + node media — for a multi-day trip?
**Spike question:** Assemble a representative week-long, multi-day package at a typical buffer distance; measure on-disk size and download time on a normal connection.
**Done when:** Package size is known for realistic trips, informing whether the buffer-distance control (C14) and download UX need constraints or tiering.

---

## Cross-account sync

### SPIKE-11 — Group amendment & field-note propagation
**Covers:** FR56, FR56a, FR59 (Stories I9, I9a, I9b)
**Priority:** Implementation-informing
**Unknown:** How do route amendments and field notes reach connected group members, and how does the version-checked conditional write (FR59) behave when several participants amend near-simultaneously? This is the one device→group→devices path in an otherwise per-account local-first model.
**Spike question:** Simulate multiple participants publishing amendments/notes on one trip with overlapping timing; observe notification delivery and conflict behavior under the version check.
**Done when:** Propagation and near-simultaneous-edit behavior are characterized, and any conflict-handling gap for group content is identified before I9/I9a–b are built.

---

## Authentication

### SPIKE-13 — Magic-link email deliverability
**Covers:** FR57 (Story K1) — the sole auth path (Web/Leg-4 milestone)
**Priority:** Implementation-informing — but with an unusually high failure cost
**Unknown:** Magic-link-only auth has a single point of failure by design: there is no password fallback (ARCH D9). If the login email lands in spam, is delayed minutes, or is dropped, the user simply *cannot log in*. Whether a chosen transactional-email provider delivers reliably and within seconds — across common consumer mail hosts and their spam filters — is an unglamorous but real feasibility question.
**Spike question:** Send magic-link emails through a candidate provider (e.g. a transactional-email service) to accounts on the major consumer mail hosts; measure delivery rate, time-to-inbox, and spam-folder placement. Check SPF/DKIM/DMARC setup and whether the custom domain (ARCH §9.3) is needed for sender reputation too.
**Decides:** Which email provider and sender configuration the Web milestone depends on, and whether magic-link-only is safe as the sole path or wants a documented backup (e.g. re-send, or a support recovery route).
**Done when:** Delivery rate and time-to-inbox meet a bar you'd stake login on across the major mail hosts, or the gap is documented so the auth approach can add a fallback before Web ships.

---

## Summary table

| Spike | Covers | Priority | Reshapes scope? |
|---|---|---|---|
| ~~**SPIKE-00 Frozen sidecar**~~ | ARCH §4, A1/A5 | Scope-shaping | **Run 2026-08-13/14 — closed.** Sidecar model holds; Q4/Q5 answered |
| ~~SPIKE-04 Paddling data~~ | FR14–15 | Scope-shaping | **Complete 2026-08-14.** Network/gauge yes (USGS), class no → **B4/B5 removed**, FR14 narrowed (ARCH D19) |
| SPIKE-06 Backgrounded GPS audio | FR49, FR47, FR50a | Scope-shaping | Yes |
| SPIKE-12 Backgrounded audio playback | FR49, FR50a | Scope-shaping | Yes (pairs with 06) |
| SPIKE-01 Via-node loops | FR8a | Scope-shaping | Yes (MVP/P1 call) |
| SPIKE-09 Dart offline engine | FR63 | Scope-shaping | Yes |
| SPIKE-05 Travel-speed calibration | FR16, FR31 | Implementation | Possibly |
| SPIKE-10 Package size | FR64, FR35 | Implementation | Possibly |
| SPIKE-02 Conflict/relaxation | FR9 | Implementation | No |
| SPIKE-03 Weight-band convergence | FR6 | Implementation | No |
| SPIKE-07 Adaptive accuracy | FR54a | Implementation | No |
| SPIKE-08 Power-saving OEMs | FR67 | Implementation | No |
| SPIKE-11 Group propagation | FR56, FR56a, FR59 | Implementation | No |
| SPIKE-13 Magic-link deliverability | FR57 | Implementation | No (high failure cost) |
