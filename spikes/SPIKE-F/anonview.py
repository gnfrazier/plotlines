"""Strand 3 — what an accountless reader is served.

An anonymous share-token reader has **no account and no device GPS**, so
nothing can ever fire a reveal (ARCH Q17). The model gap is: there is no
per-Character `reveal_state` row for them and never will be. This module
resolves that by construction — the anonymous reader is treated as a
Character whose revealed set is **permanently empty**, and the projection
below is what `RevealResolver` would emit for that reader.

`anonymous_view(payload)` therefore takes **no identity argument** — there is
nothing to key on, and adding a parameter would invite a caller to pass a
"trusted" flag that becomes the spoiler path FR116 exists to prevent.

Rules, in order of precedence:

1. `hazard: true` on a role, and every entry in a passage/day `hazards[]`,
   is emitted **in full** — no Author setting can hide it (PRD §1.5).
2. A `provision` role is emitted in full — provision content is always
   visible (PRD §1.4).
3. A role with effective reveal `always_visible` is emitted in full.
4. A role with reveal `on_arrival` (and not a hazard) is emitted as a
   **withheld placeholder** that keeps its `kind` and its `arc` stage but
   drops all content. Not omitted entirely: FR116 requires the arc's shape
   to survive, and a hole in the list cannot carry shape. The placeholder is
   the honest "there is a plot point here, read it in the app on arrival".
5. `arc` stages on roles and segments are always emitted (label + position).
"""

from __future__ import annotations

from typing import Any

WITHHELD_MESSAGE = (
    "A plot point is held here until you arrive. Open the trip in the "
    "Plotlines app with an account to read it in the field."
)

# Content-bearing keys a role/segment/hazard might carry. Anything here is
# stripped from a withheld role and kept on a visible one.
_CONTENT_KEYS = ("note", "content", "body", "media", "audio", "narration")


def _effective_reveal(role: dict[str, Any]) -> str:
    if role.get("hazard") is True:
        return "always_visible"
    if role.get("kind") == "provision":
        return "always_visible"
    return role.get("reveal") or "always_visible"


def _project_role(role: dict[str, Any]) -> dict[str, Any]:
    kind = role.get("kind")
    arc = role.get("arc")
    hazard = bool(role.get("hazard"))
    if _effective_reveal(role) == "always_visible":
        out = {k: v for k, v in role.items()}
        out["_visibility"] = "hazard" if hazard else "visible"
        return out
    # withheld
    out: dict[str, Any] = {"kind": kind, "arc": arc, "_visibility": "withheld"}
    out["withheld"] = True
    out["note"] = WITHHELD_MESSAGE
    return out


def _project_hazards(hazards: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [dict(h, _visibility="hazard") for h in hazards]


def anonymous_view(payload: dict[str, Any]) -> dict[str, Any]:
    """Reveal-filtered projection for a reader with an empty revealed set."""
    out: dict[str, Any] = {
        "schema_version": payload.get("schema_version"),
        "name": payload.get("name"),
        "bbox": payload.get("bbox"),
        "reader": "anonymous",
        "days": [],
    }
    for day in payload.get("days", []):
        d_out: dict[str, Any] = {
            "index": day.get("index"),
            "title": day.get("title"),
            "anchors": [],
            "segments": [],
            "hazards": _project_hazards(day.get("hazards", []) or []),
        }
        for anchor in day.get("anchors", []):
            a_out = {
                "id": anchor.get("id"),
                "coord": anchor.get("coord"),
                "roles": [_project_role(r) for r in anchor.get("roles", [])],
            }
            d_out["anchors"].append(a_out)
        for seg in day.get("segments", []):
            s_out = {
                "id": seg.get("id"),
                "from": seg.get("from"),
                "to": seg.get("to"),
                "arc": seg.get("arc"),
                "hazards": _project_hazards(seg.get("hazards", []) or []),
            }
            d_out["segments"].append(s_out)
        out["days"].append(d_out)
    return out


def arc_shape(view: dict[str, Any]) -> list[str]:
    """The ordered list of arc stages still visible in a projection — the
    thing FR116 says a paper copy must keep even when plot points are held."""
    stages: list[str] = []
    for day in view.get("days", []):
        for anchor in day.get("anchors", []):
            for role in anchor.get("roles", []):
                if role.get("arc"):
                    stages.append(role["arc"])
        for seg in day.get("segments", []):
            if seg.get("arc"):
                stages.append(seg["arc"])
    return stages
