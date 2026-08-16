# Plotlines

**Your Journey, Your Story**

Planning a journey is much like planning to write a story. You have your characters, the friends who are going with you. The setting, where you are going and what you will see. Then the plot, a route to follow.

Creating a good story has an arc to it, establishing the characters, adding key points that make things interesting, navigating some struggle or obstacle to overcome, and reaching a conclusion where the characters arrive at a stopping point.

Plotlines enables multimodal adventure trips that include cycling, hiking, paddling, cross-country skiing, climbing, packrafting, riverboarding, canyoneering, and jumaring. Different ways to get yourself from here to there.

Getting there is part of the fun; sometimes the last mile to the trailhead or put-in is the most harrowing moment of the day. Routes for auto trips and notes for train and plane transport are easy to access.

Trip authors bring their expertise, deep knowledge of how group dynamics influence an experience, and personal flair to the adventure. From a rest stop at a historic clock tower, to a cycling leg with a bit of hiking to a scenic overlook, to a rest day where the lodging is convenient to hot springs, a sauna, and a supermarket. Authors are the most important people in creating the outline of the story.

When characters embark on the journey, they can sync the plan to their mobile app, view it on a webpage, or even print a paper copy of the routes, itineraries, cue sheets, POI notes, and author's plot points. Characters export daily routes to their preferred navigation device or application, whether it is Garmin, Coros, RideWithGPS, or another application that accepts GPX, FIT, or TCX files.

---

## Current focus: desktop MVP

This repo is currently building the **desktop MVP**: a local Plotlines client that generates
theme-weighted, multimodal-capable routes via a sidecar, curates them, and exports them — no
hosted service, no accounts, no sync, no Web, no mobile field execution. See
`docs/Plotlines_MVP_Scope_and_Setup.md` §1 for the exact in/out-of-scope line.

## Docs

The planning docs live in `/docs` and are the source of truth:

- `docs/Plotlines_PRD.md` — what/why
- `docs/Plotlines_ARCHITECTURE.md` — how (tiers, principles, the sidecar model)
- `docs/Plotlines_MVP_Scope_and_Setup.md` — desktop MVP scope, repo layout, build/version
  pipeline. **§1.4 is the authoritative desktop-MVP story list** — the PRD's `[MVP]` tag
  covers field and account work this milestone does not build, and §1.1's capability table
  names several `[P1]` stories. §1.4 reconciles both and governs where they disagree.
- `docs/Plotlines_Research_Spikes.md` — feasibility unknowns
- `docs/schemas/trip_payload.schema.json` — **the trip payload contract, and source of
  truth for its shape** (SPIKE-20, ARCH D28). One document serving `plotlines-core`'s
  return type, drift's `trip.payload`, the hosted JSONB column, and the Flutter domain
  layer. Where an implementation disagrees with it, it wins.
- `docs/Plotlines - Spike Candidates.md` — **provenance, not source of truth.** A
  technology-choice note from the PRD work, filed 2026-08-15. Its four spike candidates
  became SPIKE-14 … SPIKE-17 and its other three rows are reconciled at the end of the
  spikes doc; read those, not this.

## Monorepo layout

```
plotlines/
├── core/            # plotlines-core — pure Python routing library (P1: no fastapi import)
├── service/         # plotlines-service — FastAPI wrapper (sidecar now, hosted later)
├── client/          # Flutter app (desktop first)
│   ├── design/      #   imported Claude Design reference — wireframes, brand guide,
│   │                #   UI gallery, CSS tokens, specimen cards
│   └── packages/    #   plotlines_ui — the design system as a Flutter package
│                    #   (a path dependency, not reference; never yet compiled)
├── packaging/        # frozen-binary build, installers, signing; version.lock is the
│                     # single source of truth both client and sidecar stamp themselves with
├── docs/             # PRD, architecture, MVP scope, research spikes
│   └── schemas/      #   trip_payload.schema.json — the one contract core, drift and
│                     #   the Dart domain layer all read (SPIKE-20, ARCH D28)
└── .github/workflows/  # CI — the P1 boundary lint (core must not import fastapi) and
                      # the trip-payload schema check
```

## Getting started (desktop dev)

Toolchain, verified for WSL/Ubuntu:

- **Python 3.11+** with working `venv`/`pip` (on Debian/Ubuntu: `python3.12-venv` and
  `python3-pip` if missing) — plus `libgdal-dev`, `libgeos-dev`, `libproj-dev`, and
  `build-essential` for the geospatial stack (`core/pyproject.toml` lists the intended deps,
  commented out until real core work begins).
- **[uv](https://github.com/astral-sh/uv)** for Python dependency management.
- **Flutter SDK** with Linux desktop enabled (`flutter config --enable-linux-desktop`);
  run `flutter doctor` to confirm. Needs a working display — WSLg provides this on WSL2.
- **Git.**

No build/run instructions yet. `client` is scaffolding only (no UI implementation), and
`service` is the sidecar shell from SPIKE-00. `core` is no longer empty: the spikes landed
real graph loading, scoring, routing and trip composition under `core/plotlines_core/`
(SPIKE-00 through SPIKE-03, and SPIKE-20's `trips/`) — spike-driven code in the product's
own package, not a parallel prototype. The remaining first-week items are in
`docs/Plotlines_MVP_Scope_and_Setup.md` §6.

