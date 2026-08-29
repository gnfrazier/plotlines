import analyze
import regions as R


def test_analyze_region_shape():
    ro = analyze.analyze_region("avl")
    assert ro["region"] == "avl"
    assert ro["candidates_v1_2_0"] == 715
    assert set(ro["strategies"]) == set(analyze.STRATEGIES)
    for s in ro["strategies"].values():
        assert s["band"] in ("green", "amber", "red")
        for z in R.ZOOM_LEVELS:
            assert str(z) in s["by_zoom"]


def test_summary_recommends_salience_gated():
    regions_out = [analyze.analyze_region(r) for r in R.REGIONS]
    s = analyze.summarize(regions_out)
    assert s["recommended_strategy"] == "salience_gated"
    assert s["per_strategy_bands"]["zoom_threshold"]["worst"] == "red"
    assert s["per_strategy_bands"]["naive"]["worst"] == "red"


def test_density_ceiling_brackets_ruleset_and_flood():
    regions_out = [analyze.analyze_region(r) for r in R.REGIONS]
    s = analyze.summarize(regions_out)
    ceiling = s["gpu_display_density_ceiling"]
    assert R.REGIONS["sgv"].candidates_v1_2_0 < ceiling < R.REGIONS["sgv"].candidates_v1_1_0


def test_a16_restated_above_spike14():
    regions_out = [analyze.analyze_region(r) for r in R.REGIONS]
    s = analyze.summarize(regions_out)
    assert s["a16_restated"]["budget_mb"] > 1024
    assert "release build" in s["a16_restated"]["statement"]


def test_sparse_region_is_green_under_salience_gating():
    ro = analyze.analyze_region("lwr")
    assert ro["strategies"]["salience_gated"]["band"] == "green"
