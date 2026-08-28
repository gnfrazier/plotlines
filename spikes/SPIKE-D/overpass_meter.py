"""Instrumentation for the product's own Overpass calls — issue #159 point 4.

A23 asks what a candidate pull *costs* against public Overpass: how many
requests it becomes, how long each takes, how many bytes come back, how often
one is throttled and retried. None of that is visible from outside
`OsmLayerProvider.fetch`, and the obvious way to get it — reissuing the same
queries against a raw HTTP client — would double the load on the public
commons this spike exists to worry about.

So nothing here queries anything. It wraps osmnx's own `_overpass_request` and
`_get_overpass_pause` for the duration of a block, and every number comes from
requests the product would have made anyway.

Three details of osmnx 2.1's request path shape what can be measured:

- **The rate-limit pause happens inside the request**, not before it:
  `_overpass_request` calls `_get_overpass_pause`, sleeps for exactly that
  many seconds, and only then posts. So a stopwatch around `fetch` reports
  queueing and server time as one number. Wrapping `_get_overpass_pause` and
  recording its *return value* separates them, which matters because a 90 s
  pull that is 75 s of waiting for a slot is a different engineering problem
  from one that is 75 s of server work.
- **429/504 retries recurse through the module global**, so a throttled
  request re-enters this wrapper and is counted. Nested calls are recorded at
  depth > 0 and excluded from the totals (their time is already inside the
  parent's), which is what makes `retries` a real count rather than
  double-counting.
- **Cache hits return before either of the above**, so a warm run reports zero
  requests, which is the honest answer: it never went to Overpass.
"""

from __future__ import annotations

import json
import time
from contextlib import contextmanager
from dataclasses import dataclass, field

from osmnx import _overpass


@dataclass
class Call:
    total_s: float
    bytes: int
    elements: int
    depth: int = 0
    error: str | None = None
    #: True when this call did not fetch anything itself — it was throttled,
    #: slept, recursed, and returned *its child's* response. Its `bytes` and
    #: `elements` are that child's, already counted one level down, and adding
    #: them again inflates the wire cost by exactly the number of retries.
    #: (Two 429s on one 704 km2 pull reported 16.4 MB / 209,409 elements for a
    #: response that was 5.5 MB / 69,803 — caught because the warm re-read of
    #: the same query reported exactly a third.)
    propagated: bool = False


@dataclass
class OverpassCost:
    """What one block of extraction cost the public Overpass instance."""

    calls: list[Call] = field(default_factory=list)
    pause_s: float = 0.0

    @property
    def top(self) -> list[Call]:
        return [c for c in self.calls if c.depth == 0]

    @property
    def requests(self) -> int:
        return len(self.top)

    @property
    def retries(self) -> int:
        return len([c for c in self.calls if c.depth > 0])

    @property
    def total_s(self) -> float:
        """Wall time inside Overpass calls, queueing included."""
        return sum(c.total_s for c in self.top)

    @property
    def server_s(self) -> float:
        """Total minus the rate-limit sleep — actual query time."""
        return max(self.total_s - self.pause_s, 0.0)

    @property
    def fetched(self) -> list[Call]:
        """Calls that actually put a response on the wire — retry parents
        excluded, since their payload is their child's."""
        return [c for c in self.calls if not c.propagated and not c.error]

    @property
    def bytes(self) -> int:
        return sum(c.bytes for c in self.fetched)

    @property
    def elements(self) -> int:
        return sum(c.elements for c in self.fetched)

    @property
    def failures(self) -> list[str]:
        return [c.error for c in self.calls if c.error]

    def to_dict(self) -> dict:
        return {
            "requests": self.requests,
            "retries": self.retries,
            "total_s": round(self.total_s, 2),
            "slot_pause_s": round(self.pause_s, 2),
            "server_s": round(self.server_s, 2),
            "bytes": self.bytes,
            "elements": self.elements,
            "failures": self.failures,
            "per_request_s": [round(c.total_s, 2) for c in self.top],
            "fetch_calls": len(self.fetched),
        }


def _sizeof(response: object) -> int:
    try:
        return len(json.dumps(response, separators=(",", ":")))
    except (TypeError, ValueError):
        return 0


@contextmanager
def measure():
    """`with measure() as cost:` around anything that reaches Overpass through
    osmnx — `features_from_bbox`, `graph_from_bbox`, or product code wrapping
    either."""
    cost = OverpassCost()
    real_request = _overpass._overpass_request
    real_pause = _overpass._get_overpass_pause
    depth = [0]

    def request(data, *args, **kwargs):
        d = depth[0]
        depth[0] += 1
        before = len(cost.calls)
        t0 = time.perf_counter()
        try:
            response = real_request(data, *args, **kwargs)
        except Exception as exc:  # noqa: BLE001 — recorded, then re-raised
            cost.calls.append(Call(time.perf_counter() - t0, 0, 0, d,
                                   f"{type(exc).__name__}: {exc}"))
            raise
        finally:
            depth[0] -= 1
        elements = len(response.get("elements", [])) if isinstance(response, dict) else 0
        # If any call was recorded while this one was outstanding, this call
        # recursed (osmnx's 429/504 handler) and is returning its child's
        # response rather than one it fetched itself.
        cost.calls.append(Call(time.perf_counter() - t0, _sizeof(response), elements, d,
                               propagated=len(cost.calls) > before))
        return response

    def pause(*args, **kwargs):
        seconds = real_pause(*args, **kwargs)
        try:
            cost.pause_s += float(seconds)
        except (TypeError, ValueError):
            pass
        return seconds

    _overpass._overpass_request = request
    _overpass._get_overpass_pause = pause
    try:
        yield cost
    finally:
        _overpass._overpass_request = real_request
        _overpass._get_overpass_pause = real_pause
