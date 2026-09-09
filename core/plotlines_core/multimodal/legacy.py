"""Legacy travel-mode aliases — issue #315.

`mountain_biking`, `packrafting` and `riverboarding` were their own
`travel_mode` enum values through v2.0. Issue #315 settled the model question
the other way (Model B): a *discipline* is a variant under a mode, not a mode of
its own, so those three come out of the enum and become disciplines —
`mountain` under `cycling`, `packraft` / `riverboard` under `paddling` — reusing
the weight profiles they already carried (`multimodal.disciplines`).

This module is the one place that knows the old spelling. It has **no imports
from the rest of `multimodal`** on purpose, so `modes.py` and `disciplines.py`
can both import it without a cycle. `migrate_payload_modes` rewrites a stored
trip payload in place-safe fashion (it deep-copies) so a trip saved before the
change loads without a schema-validation failure; the service applies the same
map at its ingestion points as defence in depth.
"""

from __future__ import annotations

import copy
from collections.abc import Mapping
from typing import Any

#: old `travel_mode` value -> (category it becomes, discipline it becomes).
LEGACY_MODE_ALIASES: dict[str, tuple[str, str]] = {
    "mountain_biking": ("cycling", "mountain"),
    "packrafting": ("paddling", "packraft"),
    "riverboarding": ("paddling", "riverboard"),
}


def canonical_mode(mode: str) -> str:
    """The current `travel_mode` value for a possibly-legacy one — the category
    a removed mode folded into, or `mode` unchanged."""
    alias = LEGACY_MODE_ALIASES.get(mode)
    return alias[0] if alias is not None else mode


def _migrate_segment(seg: dict[str, Any]) -> None:
    alias = LEGACY_MODE_ALIASES.get(seg.get("mode", ""))
    if alias is None:
        return
    base, discipline = alias
    seg["mode"] = base
    # Only fill the discipline if the payload does not already carry one — an
    # Author who later re-picks the discipline must win over the migration.
    seg.setdefault("discipline", discipline)


def _migrate_transition(t: dict[str, Any]) -> None:
    for key in ("from_mode", "to_mode"):
        if t.get(key) in LEGACY_MODE_ALIASES:
            t[key] = LEGACY_MODE_ALIASES[t[key]][0]


def _migrate_rollup(rollup: Mapping[str, Any] | None) -> None:
    if not isinstance(rollup, dict):
        return
    for entry in rollup.get("by_mode", []) or []:
        if isinstance(entry, dict) and entry.get("mode") in LEGACY_MODE_ALIASES:
            # A day that mixed cycling and mountain-biking legs can end up with
            # two `by_mode` entries for `cycling` here. That is a metrics
            # artefact, harmless, and regenerated whole on the next solve — not
            # worth a merge pass in a migration.
            entry["mode"] = LEGACY_MODE_ALIASES[entry["mode"]][0]


def migrate_payload_modes(payload: Mapping[str, Any]) -> dict[str, Any]:
    """A copy of `payload` with every removed `travel_mode` value rewritten to
    its category, and `segment.discipline` seeded where it was absent.

    Idempotent: a payload that carries none of the legacy values comes back
    field-for-field equal (a fresh deep copy).
    """
    out = copy.deepcopy(dict(payload))
    _migrate_rollup(out.get("metrics"))
    for day in out.get("days", []) or []:
        if not isinstance(day, dict):
            continue
        for seg in day.get("segments", []) or []:
            if isinstance(seg, dict):
                _migrate_segment(seg)
        for t in day.get("transitions", []) or []:
            if isinstance(t, dict):
                _migrate_transition(t)
        _migrate_rollup(day.get("metrics"))
    return out
