"""Every MVP-scope FR that describes trip-shaped data, mapped to a schema field.

The point of this table is the third column. A requirement that maps to a JSON
pointer is covered; one that maps to nothing is either honestly out of the payload
(a user preference, a transient request parameter) or a gap — and a gap found here,
as a missing schema field, costs a schema patch. Found later it costs a missing
story, which is the failure MVP §1.4.5 called blocking.

Scope is MVP Scope §1.4.1–1.4.2's 31 stories plus the four obligations of §1.4.3
(G2a, K10, M12, M13). `run.py` resolves every pointer against the schema and fails if
one does not exist, so this file cannot quietly drift away from the document it maps.

Status values:
  mapped          — the FR's data has a home in the payload
  out_of_payload  — deliberately not trip data; the reason is the note
  placeholder     — the field exists, another spike fills it
  gap             — nothing carries it yet, and that is a finding
"""

from __future__ import annotations

MAPPING: list[dict] = [
    # ---- Epic A: theme-driven routing -----------------------------------
    {"fr": "FR2", "story": "A1", "what": "climbing weight (\"peaks\")",
     "status": "mapped", "pointer": "/$defs/weight_profile/properties/climbing",
     "note": "Stored on the Author's 0.0–5.0 scale; the solver's bipolar -1..1 form "
             "is derived, never stored beside it."},
    {"fr": "FR3", "story": "A2", "what": "traffic-tolerance weight (\"cars\")",
     "status": "mapped", "pointer": "/$defs/weight_profile/properties/traffic"},
    {"fr": "FR4", "story": "A3", "what": "per-class bipolar surface weight",
     "status": "mapped", "pointer": "/$defs/weight_profile/properties/surface",
     "note": "One 0–5 axis per class (SPIKE-03), not one relative dial."},
    {"fr": "FR5", "story": "A4", "what": "POI density + Author-set type",
     "status": "mapped", "pointer": "/$defs/weight_profile/properties/poi"},
    {"fr": "FR6", "story": "A5", "what": "min/max bands on realised attributes",
     "status": "mapped", "pointer": "/$defs/band",
     "note": "`source` distinguishes an envelope-probed default from an Author's own "
             "band — A5's AC requires the first."},
    {"fr": "FR9", "story": "A6", "what": "named conflicts and relaxations",
     "status": "mapped", "pointer": "/$defs/violation",
     "note": "Only the violations are stored. SPIKE-02 measured diagnosis at "
             "1.3–15.0 s against a 27–218 ms solve, so the named conflict and its "
             "relaxations arrive asynchronously and belong to the response, not the "
             "saved trip."},
    {"fr": "FR7", "story": "A7", "what": "route shape",
     "status": "mapped", "pointer": "/$defs/segment/properties/shape"},
    {"fr": "FR8", "story": "A8", "what": "banded target distance",
     "status": "mapped", "pointer": "/$defs/target_distance"},
    {"fr": "FR8a", "story": "A9", "what": "via-nodes on a loop",
     "status": "mapped", "pointer": "/$defs/segment/properties/via",
     "note": "`solve.hit_via` records that each was actually reached; A9a's advisory "
             "case is `target_distance.advisory`, a value rather than a schema change."},

    # ---- Epic B: multimodal composition ---------------------------------
    {"fr": "FR10", "story": "B1", "what": "segment with start, end, mode",
     "status": "mapped", "pointer": "/$defs/segment"},
    {"fr": "FR11", "story": "B2", "what": "segment ordering + endpoint-gap warning",
     "status": "mapped", "pointer": "/$defs/transition/properties/gap_m",
     "note": "Order is the `day.segments` array; the gap is measured once by "
             "compose_day and stored, not recomputed per render."},
    {"fr": "FR12", "story": "B3", "what": "transition nodes with instructions",
     "status": "mapped", "pointer": "/$defs/transition"},
    {"fr": "FR16", "story": "B7", "what": "mode/terrain travel speeds → time & ETA",
     "status": "mapped", "pointer": "/$defs/route_metrics/properties/pace_source",
     "note": "Promoted partially in §1.4.2. `pace_source` is stored because SPIKE-05 "
             "measured the system default at 31.4% error for cycling and 9.6% for "
             "hiking — a number whose trustworthiness depends on where it came from "
             "must carry where it came from."},
    {"fr": "FR16a", "story": "B7", "what": "activity-derived personal pace",
     "status": "mapped", "pointer": "/$defs/route_metrics/properties/pace_source",
     "note": "Only the enum value `activity_derived` reaches the payload. The derived "
             "profile itself is rider data (FR78-consentable), not trip data."},

    # ---- Epic C: multi-day logistics ------------------------------------
    {"fr": "FR17", "story": "C1", "what": "adventure duration",
     "status": "mapped", "pointer": "/$defs/duration"},
    {"fr": "FR18", "story": "C2", "what": "start / end / rest days",
     "status": "mapped", "pointer": "/$defs/day/properties/roles",
     "note": "A rest day is `kind: rest` with no segments — not a separate type, so "
             "every roll-up iterates one collection."},
    {"fr": "FR19", "story": "C3", "what": "per-mode daily distance bounds",
     "status": "mapped", "pointer": "/$defs/day_limits",
     "note": "Breaches are stored as data (`roll_up.limit_breaches`), not left to a "
             "UI-time comparison one call site can forget."},
    {"fr": "FR20", "story": "C4", "what": "tagged alternates",
     "status": "mapped", "pointer": "/$defs/alternate"},
    {"fr": "FR21", "story": "C5", "what": "waypoints, regroup points, rest stops",
     "status": "mapped", "pointer": "/$defs/node_kind"},
    {"fr": "FR27", "story": "C11", "what": "hazard and crux warnings",
     "status": "mapped", "pointer": "/$defs/hazard"},
    {"fr": "FR15", "story": "B6", "what": "portages (auto-included in cue sheets)",
     "status": "mapped", "pointer": "/$defs/portage",
     "note": "B6 itself is P1, but F1 `[MVP]` requires portages on cue sheets, so the "
             "record has to exist in an MVP payload. Always Author-drawn (SPIKE-04)."},
    {"fr": "FR28", "story": "C12", "what": "scheduled, time-bound events",
     "status": "mapped", "pointer": "/$defs/scheduled_window",
     "note": "Same reason as FR15: C12 is P1, F1's AC names events on cue sheets."},

    # ---- Epic D: metrics -------------------------------------------------
    {"fr": "FR31", "story": "D1", "what": "live planning dashboard totals",
     "status": "mapped", "pointer": "/$defs/roll_up"},

    # ---- Epic E: curation ------------------------------------------------
    {"fr": "FR37", "story": "E1", "what": "rich notes and media on any node",
     "status": "mapped", "pointer": "/$defs/node/properties/note"},
    {"fr": "FR38", "story": "E2", "what": "narrative-arc stages",
     "status": "mapped", "pointer": "/$defs/node/properties/arc_stage"},
    {"fr": "FR40", "story": "E4", "what": "POI audio narration",
     "status": "mapped", "pointer": "/$defs/narration/properties/media_id"},
    {"fr": "FR41", "story": "E4", "what": "per-node narration trigger distance",
     "status": "mapped", "pointer": "/$defs/narration/properties/trigger_distance_m",
     "note": "Authoring half only — playback is H2/FR49, out of desktop MVP."},
    {"fr": "FR43", "story": "E5", "what": "GeoJSON export",
     "status": "out_of_payload", "pointer": "/$defs/line_string",
     "note": "An export is a projection of the payload, not a field in it. The "
             "payload's geometry is already RFC 7946 in shape and coordinate order, "
             "which is what makes E5 a writer rather than a conversion."},

    # ---- Epic F: outputs -------------------------------------------------
    {"fr": "FR46", "story": "F1", "what": "per-day cue sheets",
     "status": "placeholder", "pointer": "/$defs/cue_sheet",
     "note": "SPIKE-21 derives the cues; SPIKE-20 fixes where they land and what "
             "identity they carry."},
    {"fr": "FR44", "story": "F3", "what": "GPX/TCX/FIT export contents & splitting",
     "status": "out_of_payload", "pointer": None,
     "note": "Contents and splitting are parameters of an export request. Storing the "
             "last export's toggles in the canonical trip would make an export "
             "setting part of the plotline."},
    {"fr": "FR45", "story": "F3", "what": "waypoints/notes preserved as course points",
     "status": "mapped", "pointer": "/$defs/node",
     "note": "What the writers preserve is exactly the node record — kind, title, "
             "note, coordinate — so the payload is the source and the format is the "
             "constraint."},

    # ---- Epic G / K / M: workspace, platform, seams ----------------------
    {"fr": "FR74a", "story": "G2a", "what": "save / reopen / list local trips",
     "status": "mapped", "pointer": "/properties/title",
     "note": "The list surface reads `title` and the drift row's `updated_at`; the "
             "row carries identity and sync state (id, version, dirty, "
             "server_version) so a library screen never decodes a payload to draw a "
             "list. ARCH §10.3's columns, unchanged."},
    {"fr": "FR79", "story": "K5", "what": "display & measurement preferences",
     "status": "out_of_payload", "pointer": None,
     "note": "User-scoped, not trip-scoped: miles/km and °F/°C are applied at render. "
             "The payload is SI throughout — a trip authored in miles and read in "
             "kilometres must be the same trip."},
    {"fr": "FR81", "story": "K8", "what": "reset planning controls",
     "status": "out_of_payload", "pointer": None,
     "note": "Reset acts on the unsaved planning state, not on a stored trip."},
    {"fr": "FR86", "story": "K10", "what": "elevation attribution (CC BY)",
     "status": "mapped", "pointer": "/$defs/provenance/properties/attribution",
     "note": "Recorded at write time so the About surface credits the data actually "
             "used rather than a hardcoded list that can fall out of date."},
    {"fr": "FR95", "story": "K10", "what": "basemap attribution (ODbL)",
     "status": "mapped", "pointer": "/$defs/provenance/properties/attribution",
     "note": "A separate obligation under a different licence — both are owed."},
    {"fr": "FR36", "story": "M2 / C15", "what": "scoped weight profiles",
     "status": "mapped", "pointer": "/$defs/segment/properties/weights",
     "note": "Trip default → day override → segment override. The scalar case is "
             "`defaults.weights` and nothing else, which is exactly the seam M2 asks "
             "to exist before scoped weights are needed."},
    {"fr": "FR62", "story": "M3", "what": "one elevation interface",
     "status": "mapped", "pointer": "/$defs/elevation"},
    {"fr": "FR85", "story": "M3", "what": "GEDTM30 as the single elevation source",
     "status": "mapped", "pointer": "/$defs/elevation/properties/source"},
    {"fr": "FR88", "story": "M3", "what": "elevation voids never raise or block",
     "status": "mapped", "pointer": "/$defs/elevation/properties/void_samples",
     "note": "A void reads 0.0 and is not an error, so a flat profile is ambiguous "
             "between flat ground and a missing raster. The count is what "
             "disambiguates it — and it is also what keeps a NaN from reaching JSON."},
    {"fr": "FR89", "story": "M3", "what": "positive-only elevation gain",
     "status": "mapped", "pointer": "/$defs/elevation/properties/ascent_m"},
    {"fr": "M12", "story": "M12", "what": "client↔sidecar version check",
     "status": "mapped", "pointer": "/$defs/provenance/properties/sidecar_version",
     "note": "The runtime check is against `/health`; what the payload records is "
             "which versions produced these bytes, which is the only way a file found "
             "later can be read with the right expectations."},
    {"fr": "M13", "story": "M13", "what": "error & empty-state taxonomy",
     "status": "out_of_payload", "pointer": None,
     "note": "A handling surface, not stored data. The one place it touches the "
             "payload is the elevation-void rule above, which is deliberately not a "
             "user-facing error."},

    # ---- Known gaps ------------------------------------------------------
    {"fr": "FR14", "story": "B8", "what": "advisory gauge band on a paddling segment",
     "status": "gap", "pointer": None,
     "note": "Leg 3, and deliberately absent: SPIKE-19 has not yet confirmed which "
             "identifier joins a reach to a gauge after the NHD retirement, and a "
             "field shaped around the wrong identifier is worse than no field. Adding "
             "it is a `paddling_gauge` object on `segment` — additive, no "
             "restructuring, because segments already carry per-mode detail."},
    {"fr": "FR22", "story": "C6", "what": "target group-size tier",
     "status": "gap", "pointer": None,
     "note": "P1. One enum on the trip root when C6 lands."},
    {"fr": "FR35", "story": "C14", "what": "offline buffer distance",
     "status": "gap", "pointer": None,
     "note": "P1, and arguably not trip canon at all — it is a download parameter. "
             "Recorded so the question is asked rather than assumed."},
]


def pointers() -> list[tuple[str, str]]:
    """(fr, pointer) for every entry that claims one."""
    return [(row["fr"], row["pointer"]) for row in MAPPING if row.get("pointer")]


def summary() -> dict:
    counts: dict[str, int] = {}
    for row in MAPPING:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    return {"requirements": len(MAPPING), "by_status": counts}
