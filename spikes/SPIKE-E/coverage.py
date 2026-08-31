"""The advisory half's denominators (FR29a) — offline, over the committed pulls.

The issue is explicit about the denominator: *"Report percentage tagged on approach
roads specifically, not on the road network at large, because the network average will
be flattering and the approaches are the whole point."* So there are four, reported
side by side widest to narrowest, SPIKE-C's discipline for the same reason — the
narrowing is the argument, and a reader should watch the figure move as each
concession is made rather than be handed the one that suits:

| scope | what it is | why it is here |
|---|---|---|
| `network` | every car-usable way in the bbox | the flattering average the issue warns about |
| `corridor` | ways within 15 km **driving distance** of the trailhead | "approach roads", defined structurally rather than by which route this spike happened to solve |
| `route` | the ways the solved approach actually uses | what a leg summary would read |
| `last_mile` | the final 5 km of that route | FR29's own sentence, taken literally |

**Ways, not edges.** A two-way road is two directed edges of the same OSM way; counting
edges would double every two-way road and silently weight the answer toward town.
Everything below de-duplicates on `(osmid, {u, v})` first.

**Two figures per cell, always.** Percentage of *ways* tagged and percentage of
*kilometres* tagged. They separate on purpose: one 40 km untagged forest road and forty
untagged 100 m spurs are the same way-percentage and very different drives.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from regions import band_for

#: `tracktype` is only meaningful on `highway=track` (its wiki page is about tracks),
#: so counting it against every road would manufacture a near-zero. Each signal
#: declares the ways it is eligible on; a cell whose eligible set is under
#: `MIN_ELIGIBLE_WAYS` reports `n/a`, never `absent`.
ELIGIBILITY: dict[str, str] = {
    "surface": "all",
    "smoothness": "all",
    "tracktype": "track_only",
    "4wd_only": "all",
    "motor_vehicle": "all",
}

#: FR29a lists `highway=track` among its signals, but a highway class is not a tag
#: that can be present or absent — it is always present. Reported as prevalence
#: (what share of the approach *is* track) and kept out of the coverage table, because
#: a 100%-"covered" row that means nothing would flatter every total it joined.
PREVALENCE = ("track",)


def _first(value):
    return value[0] if isinstance(value, list) and value else value


def tag(data: dict, key: str) -> str | None:
    value = _first(data.get(key))
    return str(value).lower() if value is not None else None


def _osmid_key(data: dict) -> tuple:
    osmid = data.get("osmid")
    if isinstance(osmid, list):
        osmid = tuple(osmid)
    return osmid


@dataclass
class Ways:
    """A de-duplicated way set with its lengths — one scope's denominator."""

    scope: str
    ways: dict = field(default_factory=dict)   # key -> (tags, length_m)

    @property
    def count(self) -> int:
        return len(self.ways)

    @property
    def km(self) -> float:
        return sum(length for _tags, length in self.ways.values()) / 1000.0


def collect(edges, scope: str) -> Ways:
    """De-duplicate directed edges into ways. `edges` is an iterable of `(u, v, data)`."""
    out = Ways(scope=scope)
    for u, v, data in edges:
        key = (_osmid_key(data), frozenset((u, v)))
        if key in out.ways:
            continue
        out.ways[key] = (data, float(data.get("length", 0.0)))
    return out


def _eligible(ways: Ways, rule: str) -> list[tuple[dict, float]]:
    items = list(ways.ways.values())
    if rule == "track_only":
        return [(d, m) for d, m in items if tag(d, "highway") == "track"]
    return items


def signal_coverage(ways: Ways) -> dict:
    """Per-signal coverage over one scope."""
    out: dict[str, dict] = {}
    for signal, rule in ELIGIBILITY.items():
        items = _eligible(ways, rule)
        eligible_km = sum(m for _d, m in items) / 1000.0
        tagged = [(d, m) for d, m in items if tag(d, signal) is not None]
        tagged_km = sum(m for _d, m in tagged) / 1000.0
        pct_ways = 100.0 * len(tagged) / len(items) if items else 0.0
        pct_km = 100.0 * tagged_km / eligible_km if eligible_km else 0.0
        out[signal] = {
            "eligible_ways": len(items),
            "eligible_km": round(eligible_km, 2),
            "tagged_ways": len(tagged),
            "tagged_km": round(tagged_km, 2),
            "pct_ways": round(pct_ways, 1),
            "pct_km": round(pct_km, 1),
            "band": band_for(pct_ways, len(items)),
            "values": _value_counts(tagged, signal),
        }
    return out


def _value_counts(tagged, signal: str) -> dict:
    counts: dict[str, int] = {}
    for data, _m in tagged:
        value = tag(data, signal) or "?"
        counts[value] = counts.get(value, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: -kv[1])[:8])


def any_signal_coverage(ways: Ways) -> dict:
    """The number FR29a's honesty clause actually rests on: how much of this scope
    carries **any** contrary-signal-capable tag at all. An unflagged leg is only
    informative in proportion to this figure."""
    items = list(ways.ways.values())
    total_km = sum(m for _d, m in items) / 1000.0
    keys = [s for s in ELIGIBILITY if s != "motor_vehicle"]  # access, not capability
    with_signal = [
        (d, m) for d, m in items
        if any(tag(d, k) is not None for k in keys) or tag(d, "highway") == "track"
    ]
    signal_km = sum(m for _d, m in with_signal) / 1000.0
    return {
        "ways": len(items),
        "km": round(total_km, 2),
        "ways_with_signal": len(with_signal),
        "km_with_signal": round(signal_km, 2),
        "pct_ways": round(100.0 * len(with_signal) / len(items), 1) if items else 0.0,
        "pct_km": round(100.0 * signal_km / total_km, 1) if total_km else 0.0,
        "band": band_for(
            100.0 * len(with_signal) / len(items) if items else 0.0, len(items)),
    }


def prevalence(ways: Ways) -> dict:
    """`highway=track` share — FR29a's one signal that is a class, not a tag."""
    items = list(ways.ways.values())
    total_km = sum(m for _d, m in items) / 1000.0
    track = [(d, m) for d, m in items if tag(d, "highway") == "track"]
    track_km = sum(m for _d, m in track) / 1000.0
    return {
        "track_ways": len(track),
        "track_km": round(track_km, 2),
        "pct_ways": round(100.0 * len(track) / len(items), 1) if items else 0.0,
        "pct_km": round(100.0 * track_km / total_km, 1) if total_km else 0.0,
    }
