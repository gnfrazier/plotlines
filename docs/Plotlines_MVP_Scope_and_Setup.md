# Plotlines — MVP Scope & Setup

**Purpose:** The day-one document for the fresh repository. It draws the explicit "build this, skip that" line for the desktop MVP and captures the first-week structural decisions — repo layout, the core/sidecar build-and-version pipeline, error/empty-state handling, and config/secrets — that the PRD and architecture imply but don't pin down.

**Companion to:** `Plotlines_PRD.md` (what/why), `Plotlines_ARCHITECTURE.md` (how), `Plotlines_Research_Spikes.md` (what to prove first). Where those decided something, this doesn't re-argue it — it points.

**The MVP in one sentence:** a **desktop** Plotlines client that generates theme-weighted, multimodal-capable routes locally via the sidecar, curates them, and exports them — with **no hosted service, no accounts, no sync, no Web, no mobile field execution.**

---

## 1. MVP scope — build this, skip that

The line here is the one already drawn in the earlier conversation ("can I get to MVP without Render") and in the architecture's tiering. Restated concretely for the repo.

### 1.1 In scope for desktop MVP

| Area | What ships | Reference |
|---|---|---|
| **Routing core** | `plotlines-core` as a pure library: graph build, scoring, elevation, solve, export | ARCH §6 |
| **Themes/weights** | Climbing, traffic, surface, POI-density weights; min/max bands on *realized* attributes, defaults derived from the region's attainable envelope; shape; target distance (banded, not a soft target); via-node loops at 1–2 nodes (A9; 3+ is A9a, P1) | PRD FR2–FR9, FR8a; SPIKE-01/03 |
| **Multimodal (schema + cycling/hiking real)** | Mode-per-segment, transitions, day composition; paddling *pending SPIKE-04* | PRD FR10–FR16; SPIKE-04 |
| **Logistics** | Day splitting, alternates, waypoints/regroup/rest, lodging, historical weather, live metrics dashboard | PRD Epic C, D |
| **Curation** | Node notes/media, narrative arc, POI-themed trips, trigger-distance metadata (authored, not played) | PRD Epic E |
| **Outputs** | GPX/TCX/FIT/GeoJSON export with selectable contents; cue sheets; itineraries | PRD Epic F |
| **Sidecar** | Frozen binary, spawn/health/lifecycle, direct external calls (Phase-1 elevation) | ARCH §4, §7.3, §11.1 |
| **Local storage** | drift (SQLite) for trips; no sync | ARCH §9.2 |
| **About surface** | Attribution (required), app+sidecar version | ARCH §12.4 |
| **UI reference** | Author Desktop wireframe imported from Claude Design → `client/design/` | §2.4 |
| **Distribution** | Manual GitHub Releases, signed installer | ARCH §12.2–12.3 |

### 1.2 Explicitly skipped for desktop MVP

Each of these is deferred *on purpose*, not forgotten. Naming them keeps them from sneaking in.

- **Everything hosted:** Render, custom domain, Postgres, the FastAPI hosted mode. (ARCH §7.1 hosted column, §9.3.)
- **Accounts & auth:** magic-link, sessions — sidecar mode registers no `/auth/*` routes. (ARCH §7.1.)
- **Sync & version-check:** single-device local storage has nothing to reconcile. (ARCH §10.4 is a hosted concern.)
- **Guest tier & rate limiting:** protects the hosted service; irrelevant locally. (ARCH §7.4–7.5.)
- **Web client:** the whole Leg-4 tranche. (PRD Leg 4.)
- **Mobile & field execution:** GPS-triggered narration, cue HUD, adaptive accuracy, dead-zone odometer, the Dart offline engine. (PRD Epic I, ARCH §5.)
- **Group relay:** field notes, amendments, trip feedback — needs the hosted relay. (ARCH §8.)
- **Portability suite (S3–S6 / L1–L4):** GeoJSON auto-backup, archive export/restore — P1, not MVP. (PRD Epic L.)
- **Plugins:** the Leg-7 interface is designed-for, not built. (ARCH §13.)

### 1.3 The one scope decision still open

**Paddling in MVP hinges on SPIKE-04.** The PRD commits to full multimodal MVP, but whether paddling has adequate open data is unproven. Build the multimodal *schema* and cycling/hiking for certain; treat paddling as gated on the spike. The core is safe either way (paddling data enters via a provider seam — ARCH §6.4, §13.2); only the product scope is at risk. Run SPIKE-04 early so this resolves before it blocks anything.

---

## 2. Repository structure — monorepo

**Decision: monorepo.** The two build artifacts (`plotlines-core` Python, the Flutter client) must version-lock or they produce platform-divergent routes (ARCH risk A8, §12.1). A monorepo makes that lock natural — one commit, one version, both artifacts — and keeps the pure-library boundary (P1) visible and enforceable in one place. Two repos would push version coordination into tags and submodules for no MVP benefit.

### 2.1 Proposed layout

```
plotlines/
├── core/                     # plotlines-core — pure Python library (P1)
│   ├── plotlines_core/
│   │   ├── graph/  elevation/  scoring/  routing/
│   │   ├── multimodal/  trips/  content/  export/
│   │   └── providers/        # interfaces only (ARCH §13.2)
│   ├── tests/
│   │   ├── fixtures/         # committed graph extracts (ARCH §14.1)
│   │   └── golden/           # golden-route expectations
│   └── pyproject.toml
├── service/                  # plotlines-service — FastAPI wrapper
│   ├── plotlines_service/    # sidecar + (later) hosted mode
│   └── tests/
├── client/                   # Flutter app (desktop first)
│   ├── lib/
│   │   ├── presentation/  state/  domain/  data/
│   │   └── ...
│   ├── design/               # imported Claude Design wireframe (Author Desktop) — the presentation reference
│   └── test/
├── packaging/                # frozen-binary build, installers, signing
│   └── version.lock          # single source of truth for the paired version
├── docs/                     # PRD, ARCHITECTURE, SPIKES, this doc
├── .github/workflows/        # CI (ARCH §14.5)
└── README.md
```

### 2.2 The version-lock mechanism

`packaging/version.lock` holds the one version string both artifacts stamp themselves with. The build reads it into the frozen sidecar and into the Flutter client at build time; the client checks the sidecar's reported version (via `/health`) against its own at runtime and refuses a mismatch (ARCH §12.1). This is the concrete implementation of A8's mitigation — write it once, at the start, so the two artifacts can never quietly diverge.

### 2.3 The P1 boundary as a CI gate

`core/` may not import `fastapi`. This is a CI lint (ARCH §14.5, risk A7), not a review convention. Put it in the workflow on day one — it is the cheapest possible defense of the principle the whole two-deployment model rests on, and it is nearly free before there's code to violate it.

### 2.4 The desktop UI reference — Claude Design wireframe

The MVP desktop UI targets the **Author Desktop** persona, and its wireframe lives in a Claude Design project (`Plotlines Author Desktop.dc.html`). It is imported into the repo at `client/design/` as the **source-of-truth visual reference** the Flutter `presentation/` layer is built against — imported as reference, not as shipped code. The import is done via the Claude Design MCP (`https://api.anthropic.com/v1/design/mcp`, auth via `/design-login`) from within Claude Code, where the connector and auth live; the setup prompt handles this as a distinct phase.

Two boundaries matter. First, **importing the wireframe and implementing it in Flutter are separate steps** — the setup run imports the reference; translating it into widgets is later work, reviewed on its own. Second, **the wireframe may show more than MVP builds** (§1.2 skips whole tiers); where the design depicts screens or components outside MVP scope, that is a mismatch to flag and scope deliberately, not to build silently.

---

## 3. Build & version pipeline

The first-week pipeline, minimal but complete:

1. **`core` builds and tests as a normal Python package** — pure, fast, offline (committed fixtures, no live OSM).
2. **`service` wraps `core`** and runs its contract + lifecycle tests.
3. **`packaging` freezes `service`+`core` into a per-platform sidecar binary** (PyInstaller vs. Nuitka is Open Question Q4 — pick during the sidecar prototype), stamped with `version.lock`.
4. **`client` builds the Flutter desktop app**, stamped with the same version, bundling (or fetching — Q5) the sidecar binary.
5. **A signed installer** is produced per platform (signing per ARCH §12.3) and published to GitHub Releases.

**Sequencing note:** prototype the frozen sidecar on your primary desktop platform *first* — it's the easy case (no iOS constraints) and it validates the whole two-artifact model before any UI polish. This is the same "prove the sidecar early" guidance from ARCH §4.1, applied to desktop.

---

## 4. Error & empty-state taxonomy

The architecture is principled about *honest* failure but never enumerates the states. For desktop MVP, these are the ones a user will actually hit. Each gets one defined, consistent treatment — not an ad-hoc dialog invented at the call site. All of this follows the PRD's "quiet, honest state" values (PRD §2.6) and the ARCH cold-start handling (§7.3).

| State | Trigger | Treatment |
|---|---|---|
| **Sidecar starting** | Cold launch, graph still loading | The cycling-themed wait, escalating if slow (PRD Story C27 lineage); never a bare spinner or a hang |
| **Sidecar won't start** | Health-check timeout | Honest message + retry; the app doesn't pretend it's working |
| **Sidecar died mid-session** | Process crash | Transparent single restart; if that fails, degrade honestly — cached trips still viewable, generation unavailable, stated inline |
| **No route possible** | Constraints conflict | Named conflict + nearest relaxation with trade-off (PRD FR9); never a raw failure |
| **No data for area** | Region has no/thin OSM coverage | Clear "this area doesn't have routable data" — distinct from a conflict; don't return an empty map silently |
| **Elevation void / missing tile** | DEM gap | Silent zero-delta per ARCH §6.5 — *not* a user-facing error; logged once |
| **External provider unreachable** | Elevation/weather API down or rate-limited | Degrade honestly: route still generates (elevation void rule), weather shows last-cached age-stamped or "unavailable"; never block generation |
| **Export failed** | Write error / unsupported content combo | Explicit, actionable message; the generated route is never lost because an export failed |

The rule tying these together: **a failure in an optional enrichment (elevation, weather, export) never destroys the primary work (the route).** That's P5 and the honest-state value applied to the desktop error surface.

---

## 5. Config & secrets

Even desktop-only needs the elevation provider's API key. The minimal, correct handling:

- **The elevation API key lives in the sidecar's environment/config, never in the client and never in the repo.** The client never talks to the provider directly (ARCH §11.1) — only the sidecar does — so the key belongs there.
- **Local config file, git-ignored**, with a committed `.example` template so a fresh clone knows what's needed. No secrets in source control, ever.
- **Weather (Open-Meteo) needs no key** (ARCH §11) — one less thing to manage.
- **No other secrets exist at MVP** — no DB credentials, no session signing keys, no OAuth tokens, because none of those tiers are built. This is a genuine benefit of the desktop-first scope: the secret surface is exactly one key.
- **Attribution is not config** — it's a build requirement (ARCH §11.2/§12.4), present regardless of keys.

---

## 6. First-week checklist

The concrete "open the empty repo and do this" order:

1. **Create the monorepo skeleton** (§2.1) and drop the four docs into `docs/`.
2. **Stand up `core/` with the P1 CI lint** (no `fastapi` import) before writing routing code (§2.3).
3. **Commit the first graph fixture** and write one golden-route test — establish the pattern before the solver grows (ARCH §14.1).
4. **Wire `version.lock`** and the client↔sidecar version check, even against a stub sidecar (§2.2). The seam matters more than the content this early.
5. **Import the Author Desktop wireframe** from Claude Design into `client/design/` (§2.4) so `presentation/` has a reference to build against.
6. **Prototype the frozen sidecar** on your desktop platform; resolve Q4 (freezer) and Q5 (bundle vs. download) from what you learn (§3).
7. **Run SPIKE-04 (paddling data)** in parallel — it's the one open scope decision (§1.3) and it doesn't block the cycling path.
8. **Stub the error taxonomy** (§4) as a single error-handling surface, so states are handled uniformly from the first screen rather than retrofitted.

Items 2–4 are the ones that are painful to retrofit and cheap to establish now (the P1 CI gate, the first golden test, the version-lock seam). Everything else — including the design import (5) and the sidecar prototype (6) — builds on them.

---

## 7. What this doc deliberately leaves to later

So the deferral is a choice, not a gap:

- **Observability beyond local logging.** MVP has local debug logging; anything more waits (P3 forbids telemetry by default). A local log file the user can find and share for bug reports is enough.
- **The two flagged Design decisions** — trigger overlap/priority (ARCH Q3) and medical-field surfacing (Q7) — belong to the field-execution and profile-sharing tiers, neither of which is in desktop MVP.
- **Accessibility** is addressed in the product/design docs, not here.
- **The hosted/Web/mobile setup** (Render, domain, Postgres, signing for silent update, mobile build pipelines) lands with those milestones, front-loaded into Leg 4 and the mobile work by design.
