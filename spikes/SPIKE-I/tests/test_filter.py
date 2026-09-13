"""B0's filter reimplementation, tested against Overpass QL's actual semantics.

`HARNESS.md` §0.1 names this as the single most likely source of a path-T
difference, and for the SPIKE-E reason: a filter that is subtly wrong produces a
graph that is smaller and reports success. These tests pin the three behaviours
that are easy to get wrong, all of which fail in the permissive direction.
"""

from __future__ import annotations

import sys
from pathlib import Path

SPIKE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SPIKE))

import elements as E  # noqa: E402


def bike():
    return E.network_clauses("bike")


def test_filter_is_parsed_from_osmnx_not_transcribed():
    """If osmnx changes a filter, this changes with it. A hand-copied filter
    would drift and the drift would look like a parity finding."""
    from osmnx import _overpass

    raw = _overpass._get_network_filter("bike")
    clauses = E.parse_overpass_filter(raw)
    assert any(c.key == "highway" and c.op == "exists" for c in clauses)
    assert any(c.key == "bicycle" and c.op == "not_matches" for c in clauses)
    assert any(c.key == "access" and c.op == "not_matches" for c in clauses)


def test_absent_key_passes_a_negated_clause():
    """Overpass `[k!~"v"]` is true when the key is ABSENT. Getting this wrong
    the other way would reject every untagged way — i.e. almost the whole
    network."""
    c = E.Clause("bicycle", "not_matches", "no")
    assert c.test({"highway": "residential"}) is True
    assert c.test({"highway": "residential", "bicycle": "yes"}) is True
    assert c.test({"highway": "residential", "bicycle": "no"}) is False


def test_regex_is_unanchored():
    """`["highway"!~"motor"]` excludes `motorway` and `motorway_link`, not just
    a literal `motor`. `re.search`, not `re.fullmatch` — and this is why the
    `bike` filter spells the exclusion `motor` rather than listing three values."""
    assert not E.way_passes({"highway": "motorway"}, bike())
    assert not E.way_passes({"highway": "motorway_link"}, bike())
    assert E.way_passes({"highway": "residential"}, bike())


def test_unanchored_matching_has_a_surprising_true_positive():
    """`["bicycle"!~"no"]` excludes `bicycle=unknown`, because "unknown"
    contains "no". Overpass does this too. Path T reproducing it is parity;
    path T "fixing" it would be a divergence — so it is pinned deliberately
    rather than left to be discovered and "corrected" later."""
    assert not E.way_passes({"highway": "track", "bicycle": "unknown"}, bike())


def test_drive_reproduces_spike_e_s_finding():
    """SPIKE-E: `network_type="drive"` is a download filter that drops
    `highway=track` and `highway=service` before a way reaches the graph. The
    local filter must drop them identically. Parity with a known defect is
    parity; silently fixing it here would make the transport swap look like a
    routing change."""
    drive = E.network_clauses("drive")
    assert not E.way_passes({"highway": "track"}, drive)
    assert not E.way_passes({"highway": "service"}, drive)
    assert E.way_passes({"highway": "residential"}, drive)

    # ...and the bike filter keeps both, which is why boulder runs twice.
    assert E.way_passes({"highway": "track"}, bike())
    assert E.way_passes({"highway": "service"}, bike())


def test_area_and_access_exclusions_hold():
    assert not E.way_passes({"highway": "footway", "area": "yes"}, bike())
    assert not E.way_passes({"highway": "residential", "access": "private"}, bike())


def test_matching_is_case_sensitive():
    """No `,i` modifier appears on any filter osmnx builds, so `Motorway` is
    not excluded by `!~"motor"`. That is Overpass's behaviour and reproducing
    it matters more than it being sensible."""
    assert E.way_passes({"highway": "Motorway"}, bike())
