"""The pre-registered bands are themselves testable, and they should be.

`bands.py` is the file that decides whether this spike passed. A bug in its
ladder would be indistinguishable from a result, which is exactly the failure
mode the pre-registration exists to prevent — so the ladder gets tests that
would fail if a threshold were loosened or a veto quietly demoted.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SPIKE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SPIKE))

import bands  # noqa: E402


def cell(**over) -> bands.CellResult:
    base = dict(
        region="test", network_type="bike", path=bands.Path.TRANSPORT,
        filter_false_accepts=0, filter_false_rejects=0,
        golden_nodes=10_000, unattributed_node_diff=0,
        golden_edges=25_000, unattributed_edge_diff=0,
        edge_key_stability=1.0, rekeyed_on_single_edge_uv=0,
        golden_scc=10_000, local_scc=10_000,
        golden_scc_ratio=1.0, local_scc_ratio=1.0,
        length_delta_p99_m=0.0, length_delta_max_m=0.0,
        tag_losses={},
    )
    base.update(over)
    return bands.CellResult(**base)


def test_a_perfect_cell_is_parity():
    assert bands.classify((cell(),)) is bands.Band.PARITY


def test_one_lost_tag_is_a_veto_not_a_percentage():
    """B5 has no RECALIBRATE row. A tag lost on one edge out of 25,000 is still
    a shipped rule that is now wrong, with no way to tell which edge."""
    c = cell(tag_losses={"graph:motor_vehicle": 1})
    assert bands.classify((c,)) is bands.Band.RESCOPE
    assert any("motor_vehicle" in r for r in bands.veto_reasons((c,)))


def test_a_false_reject_is_a_veto_and_names_spike_e():
    """B0's false-reject row is SPIKE-E's defect: a real way that never reaches
    the graph on a path that reports success."""
    c = cell(filter_false_rejects=1)
    assert bands.classify((c,)) is bands.Band.RESCOPE
    assert any("SPIKE-E" in r for r in bands.veto_reasons((c,)))


def test_a_shrunken_scc_is_rescope_in_a_single_cell():
    """B3's asymmetry. A 2% smaller SCC means real road fell out of the routable
    set; the aggregate is where that hides, so one cell is enough."""
    c = cell(local_scc=9_800, golden_scc=10_000)
    assert c.scc_shrank_beyond_band
    assert bands.classify((c,)) is bands.Band.RESCOPE


def test_a_larger_scc_within_band_is_only_recalibrate():
    """The other direction is also a bug — the clip admitted ways the filter
    excluded — but it is a loud one, so it does not skip the ladder."""
    c = cell(local_scc=10_050, local_scc_ratio=1.0)
    assert not c.scc_shrank_beyond_band
    assert bands.classify((c,)) is bands.Band.RECALIBRATE


def test_a_rekey_on_a_single_edge_uv_is_rescope():
    """`k` moving where there are no parallel edges is not insertion order, and
    we do not know what it is. B2b's RECALIBRATE row only tolerates the
    ordering explanation."""
    c = cell(edge_key_stability=0.9999, rekeyed_on_single_edge_uv=1)
    assert bands.classify((c,)) is bands.Band.RESCOPE


def test_worst_cell_wins_the_rollup():
    """SPIKE-13's rule with regions in place of mail hosts: a rollup can never
    launder one bad cell."""
    good, bad = cell(), cell(region="bad", unattributed_node_diff=40)
    assert bands.classify((good, bad)) is bands.Band.RECALIBRATE


def test_node_diff_band_is_a_fraction_not_a_count():
    """0.5% of 10,000 is 50. 51 crosses it; the band must be read against the
    golden's size, not against an absolute."""
    assert bands.classify((cell(unattributed_node_diff=50),)) is bands.Band.RECALIBRATE
    assert bands.classify((cell(unattributed_node_diff=51),)) is bands.Band.RESCOPE


def test_a_dev_box_clip_cannot_reach_parity():
    """Addendum 2c makes server-side measurement the condition on which Q1-C is
    decidable. A fast dev-box number is still not the measurement."""
    fast = bands.ClipResult(
        bbox_key="x", measured_on_mirror=False,
        p95_wall_s=1.0, peak_rss_mb=100.0, output_fraction=0.001,
    )
    assert bands.clip_band(fast) is bands.Band.RECALIBRATE
    on_mirror = bands.ClipResult(
        bbox_key="x", measured_on_mirror=True,
        p95_wall_s=1.0, peak_rss_mb=100.0, output_fraction=0.001,
    )
    assert bands.clip_band(on_mirror) is bands.Band.PARITY


def test_rss_over_the_band_is_not_rescued_by_a_fast_clip():
    """The Pi has 8 GB and also serves the static tree — §11.3's availability
    warning is why RSS is graded at all."""
    r = bands.ClipResult(
        bbox_key="x", measured_on_mirror=True,
        p95_wall_s=2.0, peak_rss_mb=4096.0, output_fraction=0.001,
    )
    assert bands.clip_band(r) is bands.Band.RESCOPE


def test_classify_does_not_prefer_the_transport_path():
    """Encoding a preference for path T in the pre-registration would be
    deciding the answer before the run. A failing R cell must drag the verdict
    down and the write-up must explain it."""
    t = cell(path=bands.Path.TRANSPORT)
    r = cell(region="r", path=bands.Path.REIMPLEMENTATION,
             unattributed_node_diff=40)
    assert bands.classify((t, r)) is bands.Band.RECALIBRATE


def test_band_tag_list_matches_the_product_constant():
    """`bands.py` mirrors `PLOTLINES_WAY_TAGS` rather than importing it, so the
    pre-registration is self-contained. This is the assertion that keeps the
    mirror honest — if the product constant is narrowed later, the band does not
    silently narrow with it; this fails instead."""
    sys.path.insert(0, str(SPIKE.parent.parent / "core"))
    from plotlines_core.graph.regions import PLOTLINES_NODE_TAGS, PLOTLINES_WAY_TAGS

    assert tuple(PLOTLINES_WAY_TAGS) == bands.ZERO_TOLERANCE_WAY_TAGS
    assert tuple(PLOTLINES_NODE_TAGS) == bands.ZERO_TOLERANCE_NODE_TAGS
