"""F1 / FR133 (the Frodo principle) — a node's C5 amenities (water, toilets,
food, shelter) are woven into its own cue line rather than living in a
separate logistics list. Same synthetic-straight-line `Route` approach
`test_cue_transitions.py` already uses for `node_cues` — these assertions
are about node projection and cue text, not graph traversal.
"""

import math

from plotlines_core.trips.cues import CueSettings, Route, node_cues
from plotlines_core.trips.payload import Node

_STEP_DEG = 100.0 / (math.cos(math.radians(40.0)) * math.pi * 6_371_000.0 / 180.0)


def _route() -> Route:
    coords = [[-105.30 + _STEP_DEG * i, 40.0] for i in range(11)]
    return Route(coords=coords, cumulative_m=[100.0 * i for i in range(11)], edges=[])


def _poi(**kwargs) -> Node:
    return Node(kind="poi", coord=[-105.30 + _STEP_DEG * 5, 40.0], **kwargs)


def test_a_node_with_amenities_is_cued_as_a_provision():
    node = _poi(title="Overlook Camp", amenities=["water", "toilets"])

    cues, stats = node_cues(_route(), [node], CueSettings())

    assert stats["emitted"] == 1
    assert cues[0].kind == "provision"
    assert cues[0].instruction == "Point of interest: Overlook Camp — water, toilets"


def test_amenities_render_in_a_fixed_readable_order_not_tag_order():
    node = _poi(title="Trailhead", amenities=["shelter", "water"])

    cues, _ = node_cues(_route(), [node], CueSettings())

    assert cues[0].instruction.endswith("— water, shelter")


def test_an_unrecognised_amenity_tag_is_dropped_rather_than_shown_raw():
    node = _poi(title="Camp", amenities=["water", "wifi"])

    cues, _ = node_cues(_route(), [node], CueSettings())

    assert cues[0].instruction == "Point of interest: Camp — water"


def test_a_node_with_no_amenities_keeps_the_generic_node_kind():
    node = _poi(title="Scenic viewpoint")

    cues, _ = node_cues(_route(), [node], CueSettings())

    assert cues[0].kind == "node"
    assert "—" not in cues[0].instruction or "viewpoint" in cues[0].instruction


def test_a_transition_node_with_amenities_keeps_its_transition_kind():
    """Amenities weave into the text either way, but a transition's own kind
    (safety-critical — never merged away) is never demoted to "provision"."""
    node = Node(kind="transition", coord=[-105.30 + _STEP_DEG * 5, 40.0],
               title="Put-in", amenities=["water"])

    cues, _ = node_cues(_route(), [node], CueSettings())

    assert cues[0].kind == "transition"
    assert cues[0].instruction == "Mode change: Put-in — water"
