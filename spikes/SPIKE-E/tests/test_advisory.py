"""The advisory prototype's own invariants — the ones FR29a states as requirements."""

from __future__ import annotations

import copy

from advisory import (
    ACCESS_NOTES, DECLARABLE, GAP_TOLERANCE_M, Capability, advisory_cues, assess,
    requirement_for, surveyed,
)


def edge(start, end, **tags):
    tags.setdefault("highway", "unclassified")
    tags["length"] = end - start
    return (float(start), float(end), tags)


def test_ladder_is_ordered():
    rough = [edge(0, 1000, surface="dirt")]
    assert assess(rough, Capability.TWO_WD).state == "flagged"
    assert assess(rough, Capability.AWD).state == "no_contrary_signal"
    assert assess(rough, Capability.FOUR_WD).state == "no_contrary_signal"


def test_beyond_4wd_flags_even_the_top_declaration():
    """FR29a's declaration tops out at 4WD; `smoothness=impassable` is above it, and
    a road no vehicle can use must not come back within the declared capability."""
    impassable = [edge(0, 500, smoothness="impassable")]
    assert assess(impassable, Capability.FOUR_WD).state == "flagged"


def test_graded_gravel_is_not_flagged_for_2wd():
    """The advisory must not cry wolf: a maintained gravel forest road is a 2WD road,
    and flagging every unpaved metre would make the real flags unreadable."""
    assert assess([edge(0, 1000, surface="gravel")], Capability.TWO_WD).state != "flagged"
    assert assess([edge(0, 1000, tracktype="grade1")], Capability.TWO_WD).state != "flagged"


def test_worst_signal_wins_on_one_edge():
    requires, hits = requirement_for(
        {"surface": "dirt", "smoothness": "horrible", "highway": "track"})
    assert requires is Capability.FOUR_WD
    assert [rule.key for rule in hits] == ["smoothness"]


def test_assess_never_mutates_its_input():
    """FR29a: advisory, not a constraint. The weakest form of that promise is that
    reading a route does not write to it."""
    edges = [edge(0, 1000, surface="dirt"), edge(1000, 2000, smoothness="very_bad")]
    before = copy.deepcopy(edges)
    assess(edges, Capability.TWO_WD)
    assert edges == before


def test_state_is_three_valued_and_carries_no_verdict_boolean():
    result = assess([edge(0, 1000)], Capability.TWO_WD)
    assert result.state == "insufficient_signal"
    assert not {"passable", "ok", "clear", "safe"} & set(vars(result))


def test_insufficient_and_clear_summaries_share_no_claim():
    thin = assess([edge(0, 1000)], Capability.TWO_WD)
    read = assess([edge(0, 1000, surface="asphalt")], Capability.TWO_WD)
    assert thin.state == "insufficient_signal"
    assert read.state == "no_contrary_signal"
    assert "not a road confirmed passable" in read.summary
    assert "passable" not in thin.summary
    assert "Author's to declare" in thin.summary


def test_surveyed_counts_presence_not_severity():
    """A paved road is surveyed. Counting only flag-triggering values would make a
    well-mapped approach look unmapped and invert the honesty clause."""
    assert surveyed({"surface": "asphalt"})
    assert surveyed({"highway": "track"})
    assert not surveyed({"highway": "unclassified", "name": "Nameless Road"})


def test_runs_merge_across_a_short_unsurveyed_gap():
    edges = [
        edge(0, 1000, surface="dirt"),
        edge(1000, 1000 + GAP_TOLERANCE_M - 1),          # untagged gap
        edge(1000 + GAP_TOLERANCE_M - 1, 3000, surface="dirt"),
    ]
    result = assess(edges, Capability.TWO_WD)
    assert result.raw_sections == 2
    assert len(result.flags) == 1


def test_runs_do_not_merge_across_a_long_gap():
    edges = [
        edge(0, 1000, surface="dirt"),
        edge(1000, 1000 + GAP_TOLERANCE_M + 10),
        edge(1000 + GAP_TOLERANCE_M + 10, 4000, surface="dirt"),
    ]
    assert len(assess(edges, Capability.TWO_WD).flags) == 2


def test_runs_never_merge_across_a_surveyed_clear_stretch():
    """A stretch the map says is asphalt is evidence, not a gap — swallowing it would
    report rough ground where there is a record of good road."""
    edges = [
        edge(0, 1000, surface="dirt"),
        edge(1000, 1100, surface="asphalt"),
        edge(1100, 2000, surface="dirt"),
    ]
    assert len(assess(edges, Capability.TWO_WD).flags) == 2


def test_access_values_are_notes_not_capability_flags():
    """`motor_vehicle=private` is on FR29a's signal list but says who may drive, not
    what they need to drive in — a flag an Author cannot act on by borrowing a truck."""
    result = assess([edge(0, 1000, motor_vehicle="private")], Capability.FOUR_WD)
    assert result.state != "flagged"
    assert [note.value for note in result.access_notes] == ["private"]
    assert ACCESS_NOTES["private"] in advisory_cues(result)[0]["instruction"]


def test_cues_name_the_signal_and_both_capabilities():
    """C13a: "with the specific signal that triggered the flag"."""
    result = assess([edge(0, 2000, smoothness="very_bad", name="Forest Road 568")],
                    Capability.AWD)
    text = advisory_cues(result)[0]["instruction"]
    assert "smoothness=very_bad" in text
    assert "Forest Road 568" in text
    assert "high-clearance" in text and "AWD" in text


def test_every_declarable_level_is_below_the_top_of_the_ladder():
    assert max(DECLARABLE) < Capability.BEYOND_4WD
