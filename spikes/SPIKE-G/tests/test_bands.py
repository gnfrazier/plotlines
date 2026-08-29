import bands
from bands import AxisResult, Band


def _axis(**kw):
    base = dict(
        frame_ok_gpu=True, frame_ok_swraster_overview=True, select_ok_gpu=True,
        intent_hard_fail=False, intent_soft_fail=False, reasons=(),
    )
    base.update(kw)
    return AxisResult(**base)


def test_all_clear_is_green():
    assert bands.classify(_axis()) is Band.GREEN


def test_hard_intent_failure_is_red():
    assert bands.classify(_axis(intent_hard_fail=True)) is Band.RED


def test_frame_fail_on_gpu_is_red():
    assert bands.classify(_axis(frame_ok_gpu=False)) is Band.RED


def test_selection_fail_on_gpu_is_red():
    assert bands.classify(_axis(select_ok_gpu=False)) is Band.RED


def test_soft_intent_cost_is_amber_not_red():
    assert bands.classify(_axis(intent_soft_fail=True)) is Band.AMBER


def test_software_raster_floor_miss_is_amber():
    assert bands.classify(_axis(frame_ok_swraster_overview=False)) is Band.AMBER


def test_a16_budget_adds_headroom():
    b = bands.a16_budget_mb(1000, 5.0)
    assert b == 1000 + 5 + bands.A16_HEADROOM_MB
