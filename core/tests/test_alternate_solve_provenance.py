"""FR140 / Q3 (issue #344) — an alternate carries its own `solve` provenance.

`SolveProvenance.stale` was per-`Segment`. An alternate has its own `geometry`,
`metrics` and `elevation`, so an edit that invalidates *its* derived half — the
Author moving where the path forks or rejoins — has to be recordable somewhere
that does not also claim the parent passage is stale, because the passage was
not touched and re-solving it would be work the Author did not ask for.

The modelling answer is the one FR140 already mandates — "reusing `solve.stale`
(ARCH D30) — no new mechanism" — one level down: the same `$defs/solve_provenance`
object, on the alternate. A bare `stale: true` boolean would have been a second
mechanism, and it could not have answered the other half of Flow 11 §06, that an
alternate's distances "are the ones it was solved with, and they say so wherever
they appear" — which needs `solved_at`/`engine_version`, not a flag.

The Dart half of the same field is pinned in `client/test/segment_test.dart` and
`client/test/stale_work_test.dart`; this module pins the payload shape.
"""

import json
from pathlib import Path

from plotlines_core.trips import payload

_SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json")
    .read_text()
)
_ALTERNATE_KEYS = set(_SCHEMA["$defs"]["alternate"]["properties"])
_SOLVE_KEYS = set(_SCHEMA["$defs"]["solve_provenance"]["properties"])


def _line() -> payload.LineString:
    return payload.LineString(coordinates=[[-105.3, 40.0], [-105.2, 40.05]])


def test_solve_is_a_known_alternate_field_and_reuses_the_segments_own_shape():
    """FR140's "reusing `solve.stale` — no new mechanism", read literally: the
    alternate points at `$defs/solve_provenance`, so the two objects can never
    grow apart into a per-object dialect of staleness."""
    assert "solve" in _ALTERNATE_KEYS
    assert _SCHEMA["$defs"]["alternate"]["properties"]["solve"]["$ref"] == (
        "#/$defs/solve_provenance"
    )
    assert "stale" in _SOLVE_KEYS


def test_an_alternate_with_no_solve_omits_it_entirely():
    """Absent means never solved. That is a different statement from "solved,
    then gone stale", and every alternate written before this field existed
    already read as the first one."""
    alt = payload.Alternate(kind="bypass", geometry=_line())
    assert alt.solve is None
    assert alt.to_dict()["solve"] is None


def test_an_alternates_solve_round_trips_every_field():
    alt = payload.Alternate(
        kind="extension",
        geometry=_line(),
        intent="branch",
        label="Past the Sugarloaf mine",
        diverges_at_m=11_000.0,
        rejoins_at_m=22_700.0,
        solve=payload.SolveProvenance(
            engine_version="0.0.1", graph_region="abc123", solve_ms=41.5,
            solver_calls=1, solved_at="2026-09-10T16:28:00Z", stale=True,
        ),
    )
    d = alt.to_dict()
    assert set(d) - _ALTERNATE_KEYS == set()
    assert d["solve"]["stale"] is True
    assert d["solve"]["solved_at"] == "2026-09-10T16:28:00Z"
    assert d["solve"]["engine_version"] == "0.0.1"
    assert d["solve"]["solve_ms"] == 41.5
    assert set(d["solve"]) - _SOLVE_KEYS == set()


def test_a_stale_alternate_leaves_its_parent_segments_solve_alone():
    """The whole reason the flag lives here: Flow 11 §06's "neither refused nor
    asked, just stale" moves one fork and marks one branch. A segment-level flag
    would have pulled the day's own route into the stale list with it, and
    re-solve-all would then have re-run a solve nothing invalidated."""
    fresh = payload.SolveProvenance(solved_at="2026-09-10T15:00:00Z", stale=False)
    alt = payload.Alternate(
        kind="bypass", geometry=_line(),
        solve=payload.SolveProvenance(solved_at="2026-09-10T15:00:00Z", stale=True),
    )
    seg = payload.Segment(
        mode="cycling", shape="point_to_point", geometry=_line(),
        alternates=[alt], solve=fresh,
    )
    d = seg.to_dict()
    assert d["solve"]["stale"] is False
    assert d["alternates"][0]["solve"]["stale"] is True
