"""JSON <-> `plotlines_core.trips.payload` dataclass conversion for the
service layer (ARCH §7.2's `/days/compose`, `/trips/split`).

Written generically rather than as one hand-written parser per class: the
payload tree (`docs/schemas/trip_payload.schema.json`) is ~15 nested
dataclasses deep, `compose_day`/`split_trip` only ever touch a few fields on
most of them, and the other fields still have to round-trip losslessly
through `.to_dict()` on the way back out — which means every nested object
needs to become a real dataclass instance, not a passthrough dict, or
`.to_dict()` throws on it. One reflection-based parser, built off
`typing.get_type_hints` (which resolves `payload.py`'s `from __future__
import annotations` string hints back to real types), covers all of them
and stays correct automatically as the schema grows a field — a hand-written
parser per class would silently drop new fields until someone remembered to
update it.
"""

from __future__ import annotations

import dataclasses
import types
import typing


#: Classes where a Python field name differs from its wire key — `payload.py`
#: hand-writes `to_dict()` per class specifically to absorb these, so the
#: generic reverse direction needs the same short list rather than a false
#: promise that field name == wire key everywhere. Keyed by
#: `f"{cls.__module__}.{cls.__qualname__}"` so this file never has to import
#: `plotlines_core.trips.payload` just to spell the class objects.
_FIELD_ALIASES: dict[str, dict[str, str]] = {
    "plotlines_core.trips.payload.Band": {"min": "minimum", "max": "maximum"},
}


def _unwrap_optional(tp):
    """`X | None` -> `X`; anything else -> itself unchanged."""
    if typing.get_origin(tp) in (typing.Union, types.UnionType):
        args = [a for a in typing.get_args(tp) if a is not type(None)]
        if len(args) == 1:
            return args[0]
    return tp


def parse_value(tp, value):
    """Parse `value` (raw JSON) against the resolved type hint `tp`."""
    if value is None:
        return None
    tp = _unwrap_optional(tp)
    origin = typing.get_origin(tp)

    if origin is list:
        (item_type,) = typing.get_args(tp)
        return [parse_value(item_type, v) for v in value]

    if origin is dict:
        _, value_type = typing.get_args(tp)
        return {k: parse_value(value_type, v) for k, v in value.items()}

    if dataclasses.is_dataclass(tp):
        return parse_dataclass(tp, value)

    return value


def parse_dataclass(cls, data: dict):
    """Build a `cls` instance from a JSON-shaped dict, recursing into every
    nested dataclass/list/dict field per its resolved type hint. Unknown
    keys are ignored (the client already enforces `additionalProperties:
    false` on its own writes via `JsonFields.done()`; the server side of
    this boundary stays lenient rather than duplicating that check)."""
    hints = typing.get_type_hints(cls)
    aliases = _FIELD_ALIASES.get(f"{cls.__module__}.{cls.__qualname__}", {})
    wire_to_field = {**{f: f for f in hints}, **aliases}
    kwargs = {}
    for wire_key, field_name in wire_to_field.items():
        # Rule 3 (trip_payload.schema.json): absent means unset, and `null`
        # is never a legal value — so a `null` here means the same thing a
        # missing key does. This matters in practice, not just in theory:
        # `Day.to_dict()`/`Segment.to_dict()` are NOT pruned on their own
        # (only `Trip.to_dict()` prunes, at the top level, for a Day/Segment
        # embedded inside a full trip) — a Day round-tripped standalone
        # through `/days/compose` comes back with explicit `"limits": null`
        # etc., and passing that through as `field=None` would override a
        # dataclass's `default_factory=dict`/`list` with `None` instead of
        # leaving it unset.
        if wire_key not in data or data[wire_key] is None:
            continue
        kwargs[field_name] = parse_value(hints[field_name], data[wire_key])
    return cls(**kwargs)
