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
- `docs/Plotlines_MVP_Scope_and_Setup.md` — desktop MVP scope, repo layout, build/version pipeline
- `docs/Plotlines_Research_Spikes.md` — feasibility unknowns

## Monorepo layout

```
plotlines/
├── core/            # plotlines-core — pure Python routing library (P1: no fastapi import)
├── service/         # plotlines-service — FastAPI wrapper (sidecar now, hosted later)
├── client/          # Flutter app (desktop first); client/design/ holds the Author Desktop
│                     # wireframe imported from Claude Design — the presentation/ reference
├── packaging/        # frozen-binary build, installers, signing; version.lock is the
│                     # single source of truth both client and sidecar stamp themselves with
├── docs/             # PRD, architecture, MVP scope, research spikes
└── .github/workflows/  # CI — currently just the P1 boundary lint (core must not import fastapi)
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

No build/run instructions yet — `core`, `service`, and `client` are scaffolding only at
this stage (no routing, scoring, or UI implementation). Those land in the next sessions per
`docs/Plotlines_MVP_Scope_and_Setup.md` §6.

